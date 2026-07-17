import XCTest
@testable import Selector

final class MockProvider: ModelProvider {
    var hasAPIKey = true
    var modelName = "mock-model"
    var visionModelName = "mock-vision"
    var streamedMessages: [[ChatMessage]] = []
    var deltasToEmit: [String] = []
    var cancelCount = 0

    func stream(messages: [ChatMessage],
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (Result<Void, ProviderError>) -> Void) {
        streamedMessages.append(messages)
        deltasToEmit.forEach(onDelta)
        onDone(.success(()))
    }

    func cancel() {
        cancelCount += 1
    }
}

final class AskSessionTests: XCTestCase {
    private func makeSnapshot(text: String) -> SelectionSnapshot {
        SelectionSnapshot(text: text, bounds: nil, fallbackPoint: .zero)
    }

    private func makeSelection(_ text: String, sourceApp: String = "Notes") -> Selection {
        Selection(text: text, sourceApp: sourceApp, captureMethod: .ax)
    }

    func testIdleIngestEmitsOverlayAndStaysIdle() {
        let session = AskSession(provider: MockProvider())
        var overlayCalls: [String] = []
        session.onNeedsOverlay = { selection, _ in overlayCalls.append(selection.text) }

        session.ingest(selection: makeSelection("hello"), snapshot: makeSnapshot(text: "hello"))

        XCTAssertEqual(overlayCalls, ["hello"])
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.attachments.isEmpty)
    }

    func testActivateSeedsStackAndOpensPanel() {
        let session = AskSession(provider: MockProvider())
        var activated = false
        session.onActivated = { _ in activated = true }

        session.activate(with: makeSelection("seed"), snapshot: makeSnapshot(text: "seed"))

        XCTAssertTrue(activated)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.selections.map(\.text), ["seed"])
    }

    func testActiveIngestAppendsToSelectionStack() {
        let session = AskSession(provider: MockProvider())
        session.activate(with: makeSelection("first", sourceApp: "Notes"), snapshot: makeSnapshot(text: "first"))
        var overlayCalls = 0
        session.onNeedsOverlay = { _, _ in overlayCalls += 1 }

        session.ingest(selection: makeSelection("second", sourceApp: "Safari"), snapshot: makeSnapshot(text: "second"))

        XCTAssertEqual(overlayCalls, 0)
        XCTAssertEqual(session.selections.map(\.text), ["first", "second"])
        XCTAssertEqual(session.selections.map(\.sourceApp), ["Notes", "Safari"])
    }

    func testDuplicateSelectionsAllowed() {
        let session = AskSession(provider: MockProvider())
        session.activate(with: makeSelection("same"), snapshot: makeSnapshot(text: "same"))
        session.ingest(selection: makeSelection("same"), snapshot: makeSnapshot(text: "same"))

        XCTAssertEqual(session.selections.count, 2)
    }

    func testRemoveSelectionAlsoRemovesDependentLinkContext() {
        let session = AskSession(provider: MockProvider())
        // 127.0.0.1:1 fails fast locally; the link attachment is appended synchronously
        // before any fetch result arrives, which is all this test needs.
        let urlText = "http://127.0.0.1:1/page"
        let seed = makeSelection(urlText)
        session.activate(with: seed, snapshot: makeSnapshot(text: urlText))

        XCTAssertEqual(session.selections.count, 1)
        XCTAssertEqual(session.linkContexts.count, 1, "dominant URL selection should append a Link Context")

        session.removeAttachment(id: seed.id)

        XCTAssertTrue(session.attachments.isEmpty, "removing a selection must remove its dependent link contexts")
    }

    func testSendBuildsLabeledContextBlocksAndStreams() {
        let provider = MockProvider()
        provider.deltasToEmit = ["Hel", "lo"]
        let session = AskSession(provider: provider)
        session.activate(with: makeSelection("some captured text", sourceApp: "Notes"), snapshot: makeSnapshot(text: "x"))

        var finished: Result<Void, ProviderError>?
        session.onAnswerFinished = { finished = $0 }
        session.send(prompt: "  summarize this  ")

        XCTAssertEqual(provider.streamedMessages.count, 1)
        let messages = provider.streamedMessages[0]
        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertTrue(messages[1].content.contains("[Selection 1 · source: Notes]"))
        XCTAssertTrue(messages[1].content.contains("some captured text"))
        XCTAssertTrue(messages[1].content.contains("Instruction:\nsummarize this"))
        XCTAssertEqual(session.latestAnswer, "Hello")
        guard case .success = finished else {
            return XCTFail("expected success, got \(String(describing: finished))")
        }
    }

    func testSendWithoutAPIKeyFailsWithoutCallingProvider() {
        let provider = MockProvider()
        provider.hasAPIKey = false
        let session = AskSession(provider: provider)
        session.activate(with: makeSelection("text"), snapshot: makeSnapshot(text: "text"))

        var finished: Result<Void, ProviderError>?
        session.onAnswerFinished = { finished = $0 }
        session.send(prompt: "hi")

        XCTAssertTrue(provider.streamedMessages.isEmpty)
        guard case .failure(.missingAPIKey) = finished else {
            return XCTFail("expected missingAPIKey, got \(String(describing: finished))")
        }
    }

    func testEmptyPromptIsIgnored() {
        let provider = MockProvider()
        let session = AskSession(provider: provider)
        session.activate(with: makeSelection("text"), snapshot: makeSnapshot(text: "text"))

        session.send(prompt: "   \n  ")

        XCTAssertTrue(provider.streamedMessages.isEmpty)
    }

    func testCloseResetsEverything() {
        let session = AskSession(provider: MockProvider())
        var closed = false
        session.onClosed = { closed = true }
        session.activate(with: makeSelection("text"), snapshot: makeSnapshot(text: "text"))

        session.close()

        XCTAssertTrue(closed)
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.attachments.isEmpty)
        XCTAssertEqual(session.latestAnswer, "")
        XCTAssertNil(session.seedSnapshot)
    }

    func testScreenshotAttachmentSwitchesMessagesToImages() {
        let provider = MockProvider()
        let session = AskSession(provider: provider)
        session.activate(with: makeSelection("text"), snapshot: makeSnapshot(text: "text"))
        session.addScreenshot(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")

        session.send(prompt: "what is this?")

        let user = provider.streamedMessages[0][1]
        XCTAssertEqual(user.images.count, 1)
        XCTAssertEqual(user.images[0].mimeType, "image/jpeg")
        XCTAssertTrue(user.content.contains("[Screenshots attached: 1."))
    }
}
