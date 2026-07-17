import Foundation

// MARK: - Domain types

/// One captured chunk of user-selected text from another macOS app.
/// Carries the *what* (text) and the *where* (source app + capture method).
struct Selection {
    let id: UUID
    let text: String
    let sourceApp: String
    let captureMethod: CaptureMethod
    let capturedAt: Date

    init(text: String, sourceApp: String, captureMethod: CaptureMethod) {
        self.id = UUID()
        self.text = text
        self.sourceApp = sourceApp
        self.captureMethod = captureMethod
        self.capturedAt = Date()
    }
}

/// A user-triggered cursor-region screen capture attached to the active Ask Session.
struct ScreenshotAttachment {
    let id: UUID
    let data: Data
    let mimeType: String
    let capturedAt: Date

    init(data: Data, mimeType: String) {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
        self.capturedAt = Date()
    }
}

/// Umbrella for everything an Ask Session can show to the model.
/// V1: Selection, Link Context, Screenshot.
enum ContextAttachment {
    case selection(Selection)
    case link(LinkContext)
    case screenshot(ScreenshotAttachment)

    var id: UUID {
        switch self {
        case .selection(let s): return s.id
        case .link(let l): return l.id
        case .screenshot(let s): return s.id
        }
    }
}

// MARK: - Ask Session

/// The single live conversation draft (see CONTEXT.md → Ask Session).
///
/// Owns:
///   - the Selection Stack and other Context Attachments
///   - the prompt build for the next request
///   - the Groq stream lifecycle and the latest answer text
///   - the routing rule: idle capture → overlay; active capture → append
///
/// Does **not** own:
///   - the Chat Panel view (presenter only)
///   - the Selection Overlay view (presenter only)
///   - capture mechanics (AX, event tap, pasteboard fallback)
///   - speech output (separate SpeechService)
final class AskSession {
    // MARK: State

    private(set) var attachments: [ContextAttachment] = []
    private(set) var latestAnswer: String = ""
    private(set) var isActive: Bool = false
    private(set) var isStreaming: Bool = false
    private(set) var seedSnapshot: SelectionSnapshot?

    var selections: [Selection] {
        attachments.compactMap { if case .selection(let s) = $0 { s } else { nil } }
    }
    var linkContexts: [LinkContext] {
        attachments.compactMap { if case .link(let l) = $0 { l } else { nil } }
    }
    var screenshots: [ScreenshotAttachment] {
        attachments.compactMap { if case .screenshot(let s) = $0 { s } else { nil } }
    }

    // MARK: Events (main-queue callbacks)

    /// A new capture arrived while the session was idle — the overlay should appear.
    var onNeedsOverlay: ((Selection, SelectionSnapshot) -> Void)?
    /// The session just activated with a seed selection — the panel should open near `snapshot`.
    var onActivated: ((SelectionSnapshot) -> Void)?
    /// Attachments changed (added, removed, link-fetch status changed). Triggers chip rebuild.
    var onAttachmentsChanged: (() -> Void)?
    /// A new send was initiated; latestAnswer has been reset.
    var onAnswerStarted: ((_ userPrompt: String) -> Void)?
    /// Streaming delta arrived; latestAnswer already includes it.
    var onAnswerDelta: ((String) -> Void)?
    /// Stream finished (or errored).
    var onAnswerFinished: ((Result<Void, ProviderError>) -> Void)?
    /// The session was closed — the panel should hide.
    var onClosed: (() -> Void)?

    // MARK: Collaborators

    let provider: ModelProvider

    init(provider: ModelProvider) {
        self.provider = provider
    }

    // MARK: Capture-side intent

    /// A fresh capture from the selection capture layer.
    /// If the session is active → append; otherwise → emit `onNeedsOverlay` so capture can show the bubble.
    func ingest(selection: Selection, snapshot: SelectionSnapshot) {
        if isActive {
            append(selection: selection)
            Logger.log("AskSession.ingest appended (\(selection.text.count) chars from \(selection.sourceApp), stack=\(selections.count))")
        } else {
            onNeedsOverlay?(selection, snapshot)
        }
    }

    /// The user clicked the Selection Overlay bubble.
    /// Marks the session active with this selection as the seed and triggers the panel.
    func activate(with selection: Selection, snapshot: SelectionSnapshot) {
        attachments = [.selection(selection)]
        seedSnapshot = snapshot
        isActive = true
        latestAnswer = ""
        Logger.log("AskSession.activate seed=\(selection.text.count) chars from \(selection.sourceApp)")
        onActivated?(snapshot)
        onAttachmentsChanged?()
        kickoffLinkFetchIfNeeded(for: selection)
    }

    // MARK: Panel-side intent

    func addScreenshot(data: Data, mimeType: String) {
        let shot = ScreenshotAttachment(data: data, mimeType: mimeType)
        attachments.append(.screenshot(shot))
        Logger.log("AskSession.addScreenshot \(data.count) bytes; vision routing engaged on next send")
        onAttachmentsChanged?()
    }

    func removeAttachment(id: UUID) {
        // Removing a selection also removes its dependent link contexts.
        var doomedSelectionID: UUID?
        if case .selection(let s)? = attachments.first(where: { $0.id == id }) {
            doomedSelectionID = s.id
        }
        attachments.removeAll { att in
            if att.id == id { return true }
            if let selID = doomedSelectionID, case .link(let l) = att, l.sourceSelectionID == selID { return true }
            return false
        }
        onAttachmentsChanged?()
    }

    func clearAttachments() {
        attachments = []
        onAttachmentsChanged?()
    }

    func send(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard provider.hasAPIKey else {
            onAnswerFinished?(.failure(.missingAPIKey))
            return
        }

        cancelStream()
        latestAnswer = ""
        isStreaming = true
        onAnswerStarted?(trimmed)

        let messages = buildMessages(userPrompt: trimmed)
        let activeModel = screenshots.isEmpty ? provider.modelName : provider.visionModelName
        Logger.log("AskSession.send model=\(activeModel) selections=\(selections.count) links=\(linkContexts.count) screenshots=\(screenshots.count) prompt=\(trimmed.count) chars")

        provider.stream(
            messages: messages,
            onDelta: { [weak self] chunk in
                guard let self else { return }
                self.latestAnswer.append(chunk)
                self.onAnswerDelta?(chunk)
            },
            onDone: { [weak self] result in
                guard let self else { return }
                self.isStreaming = false
                Logger.log("AskSession.send finished answer=\(self.latestAnswer.count) chars result=\(result)")
                self.onAnswerFinished?(result)
            }
        )
    }

    func cancelStream() {
        guard isStreaming else { return }
        provider.cancel()
        isStreaming = false
    }

    func close() {
        cancelStream()
        attachments = []
        latestAnswer = ""
        seedSnapshot = nil
        isActive = false
        onClosed?()
    }

    // MARK: Internals

    private func append(selection: Selection) {
        attachments.append(.selection(selection))
        onAttachmentsChanged?()
        kickoffLinkFetchIfNeeded(for: selection)
    }

    private func kickoffLinkFetchIfNeeded(for selection: Selection) {
        guard let url = LinkContextFetcher.dominantURL(in: selection.text) else { return }
        if linkContexts.contains(where: { $0.url == url }) { return }
        let ctx = LinkContext(url: url, sourceSelectionID: selection.id)
        attachments.append(.link(ctx))
        onAttachmentsChanged?()
        Logger.log("AskSession.linkFetch begin \(url.absoluteString)")
        LinkContextFetcher.fetch(ctx) { [weak self] updated in
            guard let self else { return }
            switch updated.status {
            case .ok:
                Logger.log("AskSession.linkFetch ok \(updated.url.absoluteString) chars=\(updated.extractedText?.count ?? 0)")
            case .failed(let reason):
                Logger.log("AskSession.linkFetch failed \(updated.url.absoluteString): \(reason)")
            case .fetching:
                break
            }
            self.onAttachmentsChanged?()
        }
    }

    func buildMessages(userPrompt: String) -> [ChatMessage] {
        var blocks: [String] = []
        for (idx, sel) in selections.enumerated() {
            blocks.append("[Selection \(idx + 1) · source: \(sel.sourceApp)]\n\(sel.text)")
        }
        for (idx, link) in linkContexts.enumerated() {
            switch link.status {
            case .ok:
                let title = link.pageTitle.map { " · title: \($0)" } ?? ""
                let body = link.extractedText ?? ""
                blocks.append("[WebContext \(idx + 1) · url: \(link.url.absoluteString)\(title)]\n\(body)")
            case .failed(let reason):
                blocks.append("[WebContext \(idx + 1) · url: \(link.url.absoluteString) · fetch failed: \(reason)]\nAnswer from the URL itself; the page body is unavailable.")
            case .fetching:
                blocks.append("[WebContext \(idx + 1) · url: \(link.url.absoluteString) · still fetching]\nThe page body has not arrived yet; answer from the URL alone or note the missing context.")
            }
        }
        if !screenshots.isEmpty {
            blocks.append("[Screenshots attached: \(screenshots.count). Use the image input(s) to answer questions about visible UI/text.]")
        }
        let contextBlock = blocks.isEmpty ? "(no attachments)" : blocks.joined(separator: "\n\n")
        let system = "You are Selector, a concise macOS assistant. The user has captured one or more text selections from their apps, optionally with web context and/or screenshots. Use everything as the primary context for their instruction. Be brief unless asked to elaborate."
        let user = "Context:\n\(contextBlock)\n\nInstruction:\n\(userPrompt)"
        let images = screenshots.map { ChatImage(data: $0.data, mimeType: $0.mimeType) }
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user, images: images)
        ]
    }
}
