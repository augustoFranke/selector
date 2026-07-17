import Cocoa

// MARK: - Cozy Cantaloupe design system
//
// A small, opinionated palette + typography helper shared by the Chat Panel and
// the Selection Overlay. The goal is a warm, sticky-note-pal feel: SF Rounded
// type, a single peach accent, full pills for primary affordances, continuous
// (squircle) corner curves.

enum Friendly {
    static let accent      = NSColor(srgbRed: 1.00, green: 0.61, blue: 0.36, alpha: 1.0)  // cantaloupe
    static let accentSoft  = NSColor(srgbRed: 1.00, green: 0.61, blue: 0.36, alpha: 0.16)
    static let lavender    = NSColor(srgbRed: 0.66, green: 0.58, blue: 0.94, alpha: 1.0)
    static let lavenderBg  = NSColor(srgbRed: 0.66, green: 0.58, blue: 0.94, alpha: 0.14)
    static let sky         = NSColor(srgbRed: 0.36, green: 0.66, blue: 0.94, alpha: 1.0)
    static let skyBg       = NSColor(srgbRed: 0.36, green: 0.66, blue: 0.94, alpha: 0.14)
    static let chipBg      = NSColor(srgbRed: 1.00, green: 0.96, blue: 0.91, alpha: 1.0)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let f = NSFont(descriptor: desc, size: size) {
            return f
        }
        return base
    }
}

/// A rounded-corner button that paints a solid pill behind its title. Used for
/// Send / Screenshot. Re-renders its attributed title whenever `title` changes
/// so the toggle to "Stop" stays styled.
final class PillButton: NSButton {
    private let fill: NSColor
    private let textColor: NSColor

    init(title: String, fill: NSColor, textColor: NSColor = .white, symbol: String? = nil) {
        self.fill = fill
        self.textColor = textColor
        super.init(frame: .zero)
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.setButtonType(.momentaryChange)
        self.wantsLayer = true
        self.layer?.backgroundColor = fill.cgColor
        self.layer?.cornerCurve = .continuous
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            self.image = img
            self.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            self.imageScaling = .scaleProportionallyDown
            self.contentTintColor = textColor
        }
        self.title = title
        applyAttributedTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var title: String {
        didSet { applyAttributedTitle() }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width  += 18   // horizontal padding inside the pill
        s.height = max(s.height + 6, 26)
        return s
    }

    private func applyAttributedTitle() {
        guard !title.isEmpty else { attributedTitle = NSAttributedString(); return }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Friendly.rounded(12.5, .semibold),
            .foregroundColor: textColor
        ])
    }
}

/// Small circular icon button (e.g. the panel's close affordance). Sits flat
/// until hover, then dims a tinted background in.
final class SoftIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHover = false

    init(symbol: String, tooltip: String? = nil) {
        super.init(frame: .zero)
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.setButtonType(.momentaryChange)
        self.wantsLayer = true
        self.layer?.cornerCurve = .continuous
        self.title = ""
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.contentTintColor = .secondaryLabelColor
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            self.image = img.withSymbolConfiguration(cfg) ?? img
        }
        self.toolTip = tooltip
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateBg()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { isHover = true; updateBg() }
    override func mouseExited(with event: NSEvent)  { isHover = false; updateBg() }

    private func updateBg() {
        layer?.backgroundColor = (isHover ? NSColor.labelColor.withAlphaComponent(0.10) : .clear).cgColor
    }
}

/// Pure presenter for the active **Ask Session** (see CONTEXT.md → Chat Panel).
/// Renders Source Chips, the response area, and the input row.
/// Holds no attachment or stream state — everything is read off `session`.
final class ChatPanelController: NSObject {
    private let session: AskSession
    private let speech: SpeechService

    private let panel: NSPanel
    private let chipsStack: NSStackView
    private let responseView: NSTextView
    private let responseScroll: NSScrollView
    private let inputField: NSTextField
    private let sendButton: NSButton
    private let clearChipsButton: NSButton
    private let screenshotButton: NSButton
    private let speakButton: NSButton
    private let titleDot: NSView   // pulses while streaming

    var isOpen: Bool { panel.isVisible }

    init(session: AskSession, speech: SpeechService) {
        self.session = session
        self.speech = speech

        let panelWidth: CGFloat = 388
        let panelHeight: CGFloat = 340

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.material = .popover           // softer/warmer than .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        // A whisper-thin warm hairline so the panel reads as hand-tinted, not generic chrome.
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Friendly.accent.withAlphaComponent(0.14).cgColor

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        // A small peach dot + wordmark — friendlier than a bare "Ask Selector".
        // Pulses while a response is streaming (see setStreamingState).
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Friendly.accent.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8)
        ])
        titleDot = dot

        let title = NSTextField(labelWithString: "selector")
        title.font = Friendly.rounded(13.5, .semibold)
        title.textColor = .labelColor

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clearChipsButton = NSButton(title: "clear", target: nil, action: #selector(clearChipsTapped))
        clearChipsButton.bezelStyle = .accessoryBarAction
        clearChipsButton.isBordered = false
        clearChipsButton.attributedTitle = NSAttributedString(string: "clear", attributes: [
            .font: Friendly.rounded(11, .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        speakButton = SoftIconButton(symbol: "speaker.wave.2.fill",
                                     tooltip: "Speak latest answer")
        speakButton.target = nil
        speakButton.action = #selector(speakTapped)
        speakButton.isHidden = true

        let close = SoftIconButton(symbol: "xmark", tooltip: "Close")
        close.target = nil
        close.action = #selector(closeTapped)

        header.addArrangedSubview(dot)
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(speakButton)
        header.addArrangedSubview(clearChipsButton)
        header.addArrangedSubview(close)

        chipsStack = NSStackView()
        chipsStack.orientation = .vertical
        chipsStack.alignment = .leading
        chipsStack.spacing = 6
        chipsStack.translatesAutoresizingMaskIntoConstraints = false

        responseScroll = NSScrollView()
        responseScroll.translatesAutoresizingMaskIntoConstraints = false
        responseScroll.hasVerticalScroller = true
        responseScroll.drawsBackground = false
        responseScroll.borderType = .noBorder
        // Soft inset "card" so the conversation has its own surface inside the panel.
        responseScroll.wantsLayer = true
        responseScroll.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        responseScroll.layer?.cornerRadius = 12
        responseScroll.layer?.cornerCurve = .continuous
        responseScroll.layer?.masksToBounds = true
        responseScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        responseView = NSTextView()
        responseView.isEditable = false
        responseView.isSelectable = true
        responseView.drawsBackground = false
        responseView.font = Friendly.rounded(12.5)
        responseView.textColor = .secondaryLabelColor
        responseView.textContainerInset = NSSize(width: 6, height: 6)
        responseScroll.documentView = responseView

        inputField = NSTextField()
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = "what's on your mind?"
        inputField.font = Friendly.rounded(13)
        inputField.bezelStyle = .roundedBezel
        inputField.focusRingType = .default

        sendButton = PillButton(title: "Send", fill: Friendly.accent)
        sendButton.target = nil
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        screenshotButton = PillButton(title: "",
                                      fill: NSColor.labelColor.withAlphaComponent(0.08),
                                      textColor: .labelColor,
                                      symbol: "camera.fill")
        screenshotButton.target = nil
        screenshotButton.action = #selector(addScreenshotTapped)
        screenshotButton.toolTip = "Snap a screenshot around the cursor"
        screenshotButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            screenshotButton.widthAnchor.constraint(equalToConstant: 36),
            screenshotButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .centerY
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addArrangedSubview(inputField)
        inputRow.addArrangedSubview(screenshotButton)
        inputRow.addArrangedSubview(sendButton)

        let stack = NSStackView(views: [header, chipsStack, responseScroll, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            chipsStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            chipsStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            responseScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            responseScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            responseScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            inputRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            inputField.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])

        panel = NSPanel(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init()
        close.target = self
        clearChipsButton.target = self
        sendButton.target = self
        screenshotButton.target = self
        speakButton.target = self
        inputField.target = self
        inputField.action = #selector(sendTapped)
        panel.delegate = self
        speech.onStateChange = { [weak self] speaking in
            self?.updateSpeakButton(speaking: speaking)
        }

        wireSession()
        renderResponsePlaceholder()
        rebuildChips()
    }

    // MARK: Session wiring

    private func wireSession() {
        session.onActivated = { [weak self] snapshot in
            self?.openPanel(near: snapshot)
        }
        session.onAttachmentsChanged = { [weak self] in
            self?.rebuildChips()
        }
        session.onAnswerStarted = { [weak self] userPrompt in
            guard let self else { return }
            self.speech.stop()
            self.speakButton.isHidden = true
            self.sendButton.title = "Stop"
            self.inputField.isEnabled = false
            self.beginExchange(userPrompt: userPrompt)
            self.setStreamingState(true)
            self.inputField.stringValue = ""
        }
        session.onAnswerDelta = { [weak self] chunk in
            self?.appendResponse(chunk)
        }
        session.onAnswerFinished = { [weak self] result in
            guard let self else { return }
            self.sendButton.title = "Send"
            self.inputField.isEnabled = true
            self.setStreamingState(false)
            self.panel.makeFirstResponder(self.inputField)
            switch result {
            case .success:
                let answer = self.session.latestAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.speakButton.isHidden = answer.isEmpty
            case .failure(let err):
                self.appendResponse("\n\n[error] \(err.localizedDescription)")
            }
        }
        session.onClosed = { [weak self] in
            self?.hidePanel()
        }
    }

    private func openPanel(near snapshot: SelectionSnapshot) {
        renderResponsePlaceholder()
        inputField.stringValue = ""
        positionPanel(near: snapshot)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputField)
        Logger.log("ChatPanel opened isVisible=\(panel.isVisible) frame=\(panel.frame)")
    }

    private func hidePanel() {
        speech.stop()
        speakButton.isHidden = true
        panel.orderOut(nil)
        rebuildChips()
    }

    func panelContainsAppKitPoint(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    // MARK: Rendering

    private func rebuildChips() {
        chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if session.attachments.isEmpty {
            let empty = NSTextField(labelWithString: "nothing pinned yet — grab some text and I'll be ready ✨")
            empty.font = Friendly.rounded(11.5)
            empty.textColor = .tertiaryLabelColor
            empty.maximumNumberOfLines = 2
            empty.lineBreakMode = .byWordWrapping
            empty.preferredMaxLayoutWidth = 340
            chipsStack.addArrangedSubview(empty)
            clearChipsButton.isHidden = true
            return
        }

        clearChipsButton.isHidden = false
        for attachment in session.attachments {
            switch attachment {
            case .selection(let s):
                chipsStack.addArrangedSubview(makeSelectionChipView(for: s))
            case .link(let l):
                chipsStack.addArrangedSubview(makeLinkChipView(for: l))
            case .screenshot(let s):
                chipsStack.addArrangedSubview(makeScreenshotChipView(for: s))
            }
        }
    }

    // MARK: Chip building blocks

    private static func makeChipContainer(fill: NSColor, border: NSColor) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 12
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = fill.cgColor
        row.layer?.borderWidth = 1
        row.layer?.borderColor = border.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static func makeChipBadge(text: String, color: NSColor) -> NSTextField {
        let badge = NSTextField(labelWithString: text)
        badge.font = Friendly.rounded(10.5, .semibold)
        badge.textColor = color
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    private static func makeChipBody(text: String) -> NSTextField {
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = Friendly.rounded(12.5)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byTruncatingTail
        body.translatesAutoresizingMaskIntoConstraints = false
        return body
    }

    private func makeChipRemoveButton(for attachmentID: UUID) -> ChipRemoveButton {
        let remove = ChipRemoveButton(title: "", target: self, action: #selector(removeAttachmentTapped(_:)))
        remove.bezelStyle = .accessoryBarAction
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .tertiaryLabelColor
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            remove.image = img.withSymbolConfiguration(cfg) ?? img
        }
        remove.attachmentID = attachmentID
        remove.translatesAutoresizingMaskIntoConstraints = false
        return remove
    }

    private func makeSelectionChipView(for selection: Selection) -> NSView {
        let row = Self.makeChipContainer(fill: Friendly.chipBg, border: Friendly.accent.withAlphaComponent(0.18))
        let source = Self.makeChipBadge(text: selection.sourceApp.lowercased(), color: Friendly.accent)
        let preview = Self.makeChipBody(text: selection.text)
        let remove = makeChipRemoveButton(for: selection.id)

        row.addSubview(source)
        row.addSubview(preview)
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            source.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            remove.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            source.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -6),
            preview.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            preview.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
        ])
        return row
    }

    private func makeLinkChipView(for link: LinkContext) -> NSView {
        let row = Self.makeChipContainer(fill: Friendly.skyBg, border: Friendly.sky.withAlphaComponent(0.22))

        let badgeText: String
        let badgeColor: NSColor
        let titleText: String
        switch link.status {
        case .fetching:
            badgeText = "link · fetching\u{2026}"
            badgeColor = .secondaryLabelColor
            titleText = link.url.absoluteString
        case .ok:
            badgeText = "link · ready"
            badgeColor = Friendly.sky
            titleText = link.pageTitle ?? link.url.absoluteString
        case .failed(let reason):
            badgeText = "link · couldn't fetch"
            badgeColor = .systemOrange
            titleText = "\(link.url.absoluteString) — \(reason)"
        }

        let badge = Self.makeChipBadge(text: badgeText, color: badgeColor)
        let title = Self.makeChipBody(text: titleText)

        row.addSubview(badge)
        row.addSubview(title)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            title.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
        ])
        return row
    }

    private func makeScreenshotChipView(for shot: ScreenshotAttachment) -> NSView {
        let row = Self.makeChipContainer(fill: Friendly.lavenderBg, border: Friendly.lavender.withAlphaComponent(0.22))
        let badge = Self.makeChipBadge(text: "screenshot", color: Friendly.lavender)

        let thumb = NSImageView()
        thumb.image = NSImage(data: shot.data)
        thumb.imageScaling = .scaleProportionallyDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let meta = NSTextField(labelWithString: "\(shot.data.count / 1024) KB · \(shot.mimeType)")
        meta.font = Friendly.rounded(11)
        meta.textColor = .secondaryLabelColor
        meta.translatesAutoresizingMaskIntoConstraints = false

        let remove = makeChipRemoveButton(for: shot.id)

        row.addSubview(badge)
        row.addSubview(thumb)
        row.addSubview(meta)
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            remove.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            thumb.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            thumb.widthAnchor.constraint(equalToConstant: 96),
            thumb.heightAnchor.constraint(equalToConstant: 64),
            thumb.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            meta.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            meta.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10)
        ])
        return row
    }

    private func renderResponsePlaceholder() {
        let keyHint = session.provider.hasAPIKey
            ? "hey 👋 — type below and I'll think it over.\nrunning on \(session.provider.modelName)."
            : "I need an API key to come alive. menu bar → Set Groq API Key…"
        responseView.string = keyHint
        responseView.font = Friendly.rounded(12.5)
        responseView.textColor = .secondaryLabelColor
    }

    private func appendResponse(_ chunk: String) {
        responseView.textStorage?.append(NSAttributedString(
            string: chunk,
            attributes: [
                .font: Friendly.rounded(12.5),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        responseView.scrollToEndOfDocument(nil)
    }

    private func setResponse(_ text: String, dim: Bool = false) {
        responseView.string = text
        responseView.font = Friendly.rounded(12.5)
        responseView.textColor = dim ? .secondaryLabelColor : .labelColor
    }

    /// Compose the response area as a styled exchange: a small "you" tag in
    /// peach, the question in body text, a thin separator, and a "selector"
    /// tag the streamed answer flows below.
    private func beginExchange(userPrompt: String) {
        let body = Friendly.rounded(12.5)
        let tag  = Friendly.rounded(10, .semibold)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 4
        para.lineSpacing = 1

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "YOU\n", attributes: [
            .font: tag,
            .foregroundColor: Friendly.accent,
            .kern: 1.2,
            .paragraphStyle: para
        ]))
        attr.append(NSAttributedString(string: userPrompt + "\n\n", attributes: [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        attr.append(NSAttributedString(string: "SELECTOR\n", attributes: [
            .font: tag,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.2,
            .paragraphStyle: para
        ]))
        responseView.textStorage?.setAttributedString(attr)
        responseView.scrollToEndOfDocument(nil)
    }

    /// Pulse the title dot while a response is streaming. A subtle "yes, I'm
    /// listening" signal that lives in the wordmark itself rather than as
    /// another spinner stuck in the chrome.
    private func setStreamingState(_ streaming: Bool) {
        guard let layer = titleDot.layer else { return }
        if streaming {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        } else {
            layer.removeAnimation(forKey: "pulse")
            layer.opacity = 1.0
        }
    }

    private func positionPanel(near snapshot: SelectionSnapshot) {
        let anchor: CGPoint
        if let bounds = snapshot.bounds {
            let topLeft = SelectionOverlayController.convertQuartzPointToAppKit(CGPoint(x: bounds.minX, y: bounds.maxY))
            anchor = CGPoint(x: topLeft.x, y: topLeft.y - 6)
        } else {
            anchor = CGPoint(x: snapshot.fallbackPoint.x + 10, y: snapshot.fallbackPoint.y - 12)
        }

        var frame = panel.frame
        frame.origin.x = anchor.x
        frame.origin.y = anchor.y - frame.height

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            if frame.maxX > v.maxX { frame.origin.x = v.maxX - frame.width - 8 }
            if frame.minX < v.minX { frame.origin.x = v.minX + 8 }
            if frame.minY < v.minY { frame.origin.y = v.minY + 8 }
            if frame.maxY > v.maxY { frame.origin.y = v.maxY - frame.height - 8 }
        }

        panel.setFrame(frame, display: true)
    }

    private func updateSpeakButton(speaking: Bool) {
        let symbol = speaking ? "stop.fill" : "speaker.wave.2.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            speakButton.image = img.withSymbolConfiguration(cfg) ?? img
        }
        speakButton.toolTip = speaking ? "Stop speaking" : "Speak latest answer"
    }

    // MARK: Intent → session

    @objc private func closeTapped() {
        session.close()
    }

    @objc private func clearChipsTapped() {
        session.clearAttachments()
    }

    @objc private func removeAttachmentTapped(_ sender: ChipRemoveButton) {
        guard let id = sender.attachmentID else { return }
        session.removeAttachment(id: id)
    }

    @objc private func addScreenshotTapped() {
        let permission = ScreenshotContextService.ensurePermission()
        guard permission == .granted else {
            setResponse("Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then relaunch Selector.", dim: true)
            Logger.log("Screenshot capture blocked: permission denied")
            return
        }
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let data = ScreenshotContextService.captureAroundCursor()
            if wasKey { self.panel.makeKeyAndOrderFront(nil) } else { self.panel.orderFront(nil) }
            self.panel.makeFirstResponder(self.inputField)
            guard let data else {
                self.setResponse("Screenshot capture failed. Check Screen Recording permission and try again.", dim: true)
                Logger.log("Screenshot capture returned nil")
                return
            }
            self.session.addScreenshot(data: data, mimeType: "image/jpeg")
        }
    }

    @objc private func sendTapped() {
        if session.isStreaming {
            session.cancelStream()
            return
        }
        let prompt = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard session.provider.hasAPIKey else {
            setResponse("No API key configured. Use the menu bar → Set Groq API Key…, or launch via `make run-api` with GROQ_API_KEY exported.", dim: true)
            return
        }
        session.send(prompt: prompt)
    }

    @objc private func speakTapped() {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        let answer = session.latestAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        speech.speak(answer)
    }
}

extension ChatPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        session.close()
    }
}

final class ChipRemoveButton: NSButton {
    var attachmentID: UUID?
}
