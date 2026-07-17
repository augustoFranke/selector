import ApplicationServices
import Cocoa

final class SelectorApp: NSObject, NSApplicationDelegate {
    private var tracker: SelectionTracker?
    private var chatPanelRef: ChatPanelController?
    private var trustTimer: Timer?
    private var statusItem: NSStatusItem?
    private var trustWasGranted = false

    private var debugState = CaptureDebugState()
    private var debugItems: [NSMenuItem] = []
    private var copyDebugItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Logger.log("Selector launched")
        installStatusItem()

        let trusted = AccessibilityPermission.isTrusted(prompt: true)
        updateTrustState(trusted: trusted, initial: true)

        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            let nowTrusted = AccessibilityPermission.isTrusted(prompt: false)
            self?.updateTrustState(trusted: nowTrusted, initial: false)
        }
    }

    private func updateTrustState(trusted: Bool, initial: Bool) {
        debugState.trusted = trusted
        refreshStatusItemTitle(trusted: trusted)
        refreshDebugMenu()

        if trusted && !trustWasGranted {
            trustWasGranted = true
            Logger.log(initial ? "Accessibility trusted at launch" : "Accessibility permission granted")
            startTracker()
        } else if !trusted && initial {
            Logger.log("Accessibility not trusted; waiting silently for permission")
        }
    }

    private func startTracker() {
        guard tracker == nil else { return }
        let groq = GroqClient()
        let session = AskSession(provider: groq)
        let overlay = SelectionOverlayController()
        let chatPanel = ChatPanelController(session: session, speech: SpeechService(provider: groq))
        let tracker = SelectionTracker(overlay: overlay, session: session)

        // Capture-side wiring: idle captures spawn the bubble.
        session.onNeedsOverlay = { [weak overlay] selection, snapshot in
            overlay?.show(snapshot: snapshot, selection: selection)
        }
        // Bubble click activates the session; the panel opens itself via session.onActivated.
        overlay.onAskTapped = { [weak overlay, weak session] selection, snapshot in
            overlay?.hide()
            session?.activate(with: selection, snapshot: snapshot)
        }

        tracker.onDebugUpdate = { [weak self] state in
            guard let self else { return }
            var merged = state
            merged.trusted = self.debugState.trusted
            self.debugState = merged
            self.refreshDebugMenu()
        }
        self.tracker = tracker
        // The chat panel listens to session events; retain it so it stays alive.
        self.chatPanelRef = chatPanel
        tracker.start()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(NSMenuItem(title: "Set Groq API Key…", action: #selector(setAPIKeyTapped), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let header = NSMenuItem(title: "Capture debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let labels = [
            "Trust: …",
            "Source: —",
            "Method: —",
            "Length: 0",
            "Trigger: —",
            "Failure: —",
            "Sampled: —"
        ]
        for label in labels {
            let row = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            debugItems.append(row)
        }

        let copy = NSMenuItem(title: "Copy debug snapshot", action: #selector(copyDebugSnapshot), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        copyDebugItem = copy

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Selector", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action == #selector(openAccessibilitySettings) || menuItem.action == #selector(setAPIKeyTapped) {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshStatusItemTitle(trusted: false)
        refreshDebugMenu()
    }

    private func refreshStatusItemTitle(trusted: Bool) {
        statusItem?.button?.title = trusted ? "◉ Selector" : "◌ Selector"
        statusItem?.button?.toolTip = trusted
            ? "Selector is running. AX trust granted."
            : "Selector is waiting for Accessibility permission. Open System Settings to grant."
    }

    private static let debugSampleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func refreshDebugMenu() {
        guard debugItems.count == 7 else { return }
        let ts = debugState.lastSampleAt.map { Self.debugSampleFormatter.string(from: $0) } ?? "—"
        debugItems[0].title = "Trust: \(debugState.trusted ? "granted" : "missing")"
        debugItems[1].title = "Source: \(debugState.lastSourceApp)"
        debugItems[2].title = "Method: \(debugState.lastMethod.rawValue)"
        debugItems[3].title = "Length: \(debugState.lastLength)"
        debugItems[4].title = "Trigger: \(debugState.lastTrigger)"
        debugItems[5].title = "Failure: \(debugState.lastFailure)"
        debugItems[6].title = "Sampled: \(ts)"
    }

    @objc private func setAPIKeyTapped() {
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Stored in your login Keychain. Takes effect on the next request. Leave empty to remove the saved key."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "gsk_…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            SecretsStore.deleteGroqAPIKey()
            Logger.log("Groq API key removed from Keychain")
        } else {
            let ok = SecretsStore.setGroqAPIKey(key)
            Logger.log("Groq API key saved to Keychain: \(ok)")
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyDebugSnapshot() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(debugState.snapshotString(), forType: .string)
    }
}
