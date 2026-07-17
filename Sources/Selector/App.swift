import ApplicationServices
import Cocoa

private let axObserverCallback: AXObserverCallback = { _, _, notificationName, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<SelectionTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notificationName as String
    tracker.handleAccessibilityNotification(name)
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tracker = Unmanaged<SelectionTracker>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tracker.enableEventTap()
        return Unmanaged.passUnretained(event)
    }

    tracker.rememberPointerLocation(event.location)

    switch type {
    case .leftMouseDown:
        tracker.handleMouseDown(flags: event.flags)
    case .leftMouseDragged:
        tracker.handleMouseDragged()
    case .leftMouseUp:
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        tracker.handleMouseUp(clickCount: clickCount, flags: event.flags)
    case .rightMouseDown, .otherMouseDown:
        tracker.clearVisibleSelection()
    case .keyDown:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        tracker.handleKeyDown(flags: event.flags, keyCode: keyCode)
    case .scrollWheel:
        tracker.clearVisibleSelection()
    default:
        break
    }

    return Unmanaged.passUnretained(event)
}

enum CaptureMethod: String {
    case ax
    case pasteboard
    case none
}

struct CaptureDebugState {
    var trusted: Bool = false
    var lastSourceApp: String = "—"
    var lastMethod: CaptureMethod = .none
    var lastLength: Int = 0
    var lastFailure: String = "—"
    var lastTrigger: String = "—"
    var lastSampleAt: Date? = nil

    func snapshotString() -> String {
        let ts = lastSampleAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
        return """
        Selector debug snapshot
        trusted: \(trusted)
        last source app: \(lastSourceApp)
        last method: \(lastMethod.rawValue)
        last length: \(lastLength)
        last failure: \(lastFailure)
        last trigger: \(lastTrigger)
        last sample at: \(ts)
        """
    }
}

enum CaptureOutcome {
    case ax(text: String, bounds: CGRect?)
    case pasteboard(text: String)
    case empty
    case failed(reason: String)
}

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
        let session = AskSession(groq: groq)
        let overlay = SelectionOverlayController()
        let chatPanel = ChatPanelController(session: session)
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

        for menuItem in menu.items where menuItem.action == #selector(openAccessibilitySettings) {
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

enum Logger {
    private static let url = URL(fileURLWithPath: "/tmp/selector.log")

    static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

enum AccessibilityPermission {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

struct SelectionSnapshot {
    let text: String
    let bounds: CGRect?
    let fallbackPoint: CGPoint
}

final class SelectionTracker {
    static let selectionDisplayDelay: TimeInterval = 0.5
    private static let pasteboardPollDeadline: TimeInterval = 0.4
    private static let pasteboardPollStep: TimeInterval = 0.02

    private let overlay: SelectionOverlayController
    private let session: AskSession
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var appObserver: AXObserver?
    private var observedPID: pid_t?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var pendingSample: DispatchWorkItem?
    private var lastPointerLocation = NSEvent.mouseLocation
    private var mouseDownLocation: CGPoint?
    private var mouseDraggedSinceDown = false
    private var mouseDownHadShift = false
    private var lastTrigger: String = "—"
    private var suppressFocusHideUntil: Date?

    private var debugState = CaptureDebugState()
    var onDebugUpdate: ((CaptureDebugState) -> Void)?

    init(overlay: SelectionOverlayController, session: AskSession) {
        self.overlay = overlay
        self.session = session
    }

    func start() {
        observeActiveApplication()
        installEventTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeApplicationChanged() {
        Logger.log("Active application changed")
        clearVisibleSelection()
        observeActiveApplication()
    }

    private func observeActiveApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier

        guard pid != ProcessInfo.processInfo.processIdentifier else {
            overlay.hide()
            return
        }

        guard observedPID != pid else { return }
        removeCurrentObserver()

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            Logger.log("Failed to create AX observer for pid \(pid)")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        addNotification(kAXFocusedUIElementChangedNotification, to: appElement, observer: observer, refcon: refcon)
        addNotification(kAXFocusedWindowChangedNotification, to: appElement, observer: observer, refcon: refcon)
        addNotification(kAXSelectedTextChangedNotification, to: appElement, observer: observer, refcon: refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObserver = observer
        observedPID = pid
        Logger.log("Observing pid \(pid) \(app.localizedName ?? "Unknown")")
    }

    private func addNotification(_ name: String, to element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        _ = AXObserverAddNotification(observer, element, name as CFString, refcon)
    }

    private func removeCurrentObserver() {
        guard let appObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
        self.appObserver = nil
        observedPID = nil
    }

    private func installEventTap() {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("Failed to install event tap; Input Monitoring may be missing")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        enableEventTap()
        Logger.log("Installed listen-only event tap")
    }

    func enableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func rememberPointerLocation(_ cgLocation: CGPoint) {
        lastPointerLocation = SelectionOverlayController.convertQuartzPointToAppKit(cgLocation)
    }

    func handleMouseDown(flags: CGEventFlags) {
        mouseDownLocation = lastPointerLocation
        mouseDraggedSinceDown = false
        mouseDownHadShift = flags.contains(.maskShift)
        if overlay.containsAppKitPoint(lastPointerLocation) {
            return
        }
        clearVisibleSelection()
    }

    func handleMouseDragged() {
        guard let mouseDownLocation else { return }
        let distance = hypot(lastPointerLocation.x - mouseDownLocation.x, lastPointerLocation.y - mouseDownLocation.y)
        if distance > 3 {
            mouseDraggedSinceDown = true
        }
    }

    func handleMouseUp(clickCount: Int, flags: CGEventFlags) {
        let dragged = mouseDraggedSinceDown
        let shiftClick = mouseDownHadShift
        let multiClick = clickCount >= 2
        mouseDownLocation = nil
        mouseDraggedSinceDown = false
        mouseDownHadShift = false

        let trigger: String?
        switch true {
        case dragged:    trigger = "drag"
        case multiClick: trigger = "multi-click(\(clickCount))"
        case shiftClick: trigger = "shift-click"
        default:         trigger = nil
        }

        if let trigger {
            lastTrigger = trigger
            scheduleSelectionSample(after: Self.selectionDisplayDelay)
        }
    }

    func handleKeyDown(flags: CGEventFlags, keyCode: CGKeyCode) {
        let isArrowOrEnd = Self.isSelectionNavigationKey(keyCode)
        let shift = flags.contains(.maskShift)
        let command = flags.contains(.maskCommand)

        if shift && isArrowOrEnd {
            lastTrigger = "shift-nav"
            scheduleSelectionSample(after: Self.selectionDisplayDelay)
            return
        }

        if command && keyCode == 0 { // Cmd+A
            lastTrigger = "cmd-a"
            scheduleSelectionSample(after: Self.selectionDisplayDelay)
            return
        }

        clearVisibleSelection()
    }

    func handleAccessibilityNotification(_ name: String) {
        if name == kAXFocusedUIElementChangedNotification || name == kAXFocusedWindowChangedNotification {
            if let until = suppressFocusHideUntil, Date() < until {
                return
            }
            clearVisibleSelection()
        }
    }

    func clearVisibleSelection() {
        pendingSample?.cancel()
        overlay.hide()
    }

    private static func isSelectionNavigationKey(_ keyCode: CGKeyCode) -> Bool {
        switch keyCode {
        case 115, 116, 117, 119, 121, 123, 124, 125, 126:
            return true
        default:
            return false
        }
    }

    func scheduleSelectionSample(after delay: TimeInterval) {
        pendingSample?.cancel()

        let sample = DispatchWorkItem { [weak self] in
            self?.sampleSelection()
        }
        pendingSample = sample
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: sample)
    }

    private func publishDebug(method: CaptureMethod, length: Int, failure: String) {
        debugState.lastSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        debugState.lastMethod = method
        debugState.lastLength = length
        debugState.lastFailure = failure
        debugState.lastTrigger = lastTrigger
        debugState.lastSampleAt = Date()
        onDebugUpdate?(debugState)
    }

    private func sampleSelection() {
        let outcome = captureSelection()
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Selection"

        switch outcome {
        case .ax(let text, let bounds):
            let snapshot = SelectionSnapshot(text: text, bounds: bounds, fallbackPoint: lastPointerLocation)
            let selection = Selection(text: text, sourceApp: sourceApp, captureMethod: .ax)
            handleCapture(selection: selection, snapshot: snapshot, method: .ax)
        case .pasteboard(let text):
            let snapshot = SelectionSnapshot(text: text, bounds: nil, fallbackPoint: lastPointerLocation)
            let selection = Selection(text: text, sourceApp: sourceApp, captureMethod: .pasteboard)
            handleCapture(selection: selection, snapshot: snapshot, method: .pasteboard)
        case .empty:
            overlay.hide()
            publishDebug(method: .none, length: 0, failure: "empty")
        case .failed(let reason):
            overlay.hide()
            Logger.log("Sample failed: \(reason)")
            publishDebug(method: .none, length: 0, failure: reason)
        }
    }

    private func handleCapture(selection: Selection, snapshot: SelectionSnapshot, method: CaptureMethod) {
        // AskSession owns the routing rule: idle → emits onNeedsOverlay (handled by
        // wiring in SelectorApp.startTracker); active → appends to the Selection Stack.
        let wasActive = session.isActive
        session.ingest(selection: selection, snapshot: snapshot)
        let label = wasActive ? "stacked" : "—"
        Logger.log("SelectionTracker.handleCapture via \(method.rawValue) (\(selection.text.count) chars, active=\(wasActive))")
        publishDebug(method: method, length: selection.text.count, failure: label)
    }

    private func captureSelection() -> CaptureOutcome {
        guard AccessibilityPermission.isTrusted(prompt: false) else {
            return .failed(reason: "accessibility not trusted")
        }

        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID == ProcessInfo.processInfo.processIdentifier {
            return .failed(reason: "front app is self")
        }

        let focusedElement = focusedAccessibilityElement()

        if let focusedElement, isSecureField(focusedElement) {
            return .failed(reason: "secure field")
        }

        if let focusedElement,
           let text = selectedText(from: focusedElement),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let rawBounds = selectedTextBounds(from: focusedElement)
            let bounds = rawBounds.flatMap { Self.isPlausibleSelectionBounds($0) ? $0 : nil }
            return .ax(text: text, bounds: bounds)
        }

        if let text = pasteboardFallback(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .pasteboard(text: text)
        }

        return .empty
    }

    private func focusedAccessibilityElement() -> AXUIElement? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return (rawValue as! AXUIElement)
    }

    private static func isPlausibleSelectionBounds(_ rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        guard rect.height < 200 else { return false }
        let onAnyScreen = NSScreen.screens.contains { screen in
            let quartzFrame = CGRect(
                x: screen.frame.minX,
                y: NSScreen.mainFrameMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return quartzFrame.intersects(rect)
        }
        return onAnyScreen
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawValue)
        guard error == .success, let role = rawValue as? String else { return false }
        return role == "AXSecureTextField"
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return rawValue as? String
    }

    private func selectedTextBounds(from element: AXUIElement) -> CGRect? {
        guard let selectedRange = selectedTextRange(from: element), selectedRange.length > 0 else {
            return nil
        }

        if let firstCharacterBounds = bounds(for: CFRange(location: selectedRange.location, length: 1), in: element) {
            return firstCharacterBounds
        }

        return bounds(for: selectedRange, in: element)
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        guard AXValueGetValue((rawValue as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var rawBounds: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        )
        guard error == .success, let rawBounds, CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((rawBounds as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    private func pasteboardFallback() -> String? {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot(from: pb)
        let priorChangeCount = pb.changeCount

        suppressFocusHideUntil = Date().addingTimeInterval(Self.pasteboardPollDeadline + 0.3)
        postSyntheticCopy()

        let deadline = Date().addingTimeInterval(Self.pasteboardPollDeadline)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(Self.pasteboardPollStep))
            if pb.changeCount != priorChangeCount { break }
        }

        defer { snapshot.restore(to: pb) }

        guard pb.changeCount != priorChangeCount else {
            return nil
        }

        return pb.string(forType: .string)
    }

    private func postSyntheticCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let entries: [Entry]

    init(from pb: NSPasteboard) {
        self.entries = (pb.types ?? []).compactMap { type in
            pb.data(forType: type).map { Entry(type: type, data: $0) }
        }
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !entries.isEmpty else { return }
        pb.declareTypes(entries.map { $0.type }, owner: nil)
        for entry in entries {
            pb.setData(entry.data, forType: entry.type)
        }
    }
}

/// The Selection Overlay's hover-bubble background. A pill-shaped visual
/// effect with a warm peach tint laid over it so the bubble reads as a friendly
/// invitation instead of generic macOS chrome. Hover deepens the tint.
final class BubbleContentView: NSVisualEffectView {
    var onClick: (() -> Void)?
    private let tint = CALayer()
    private var trackingArea: NSTrackingArea?

    private let restingAlpha: CGFloat = 0.18
    private let hoverAlpha: CGFloat   = 0.32
    private let warm = NSColor(srgbRed: 1.00, green: 0.61, blue: 0.36, alpha: 1.0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        tint.backgroundColor = warm.withAlphaComponent(restingAlpha).cgColor
        tint.actions = ["backgroundColor": NSNull()] // we'll opt in to animation manually
        layer?.addSublayer(tint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        tint.frame = bounds
        tint.cornerRadius = radius
        tint.cornerCurve = .continuous
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { setTintAlpha(hoverAlpha) }
    override func mouseExited(with event: NSEvent)  { setTintAlpha(restingAlpha) }

    private func setTintAlpha(_ a: CGFloat) {
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = tint.backgroundColor
        anim.toValue   = warm.withAlphaComponent(a).cgColor
        anim.duration  = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tint.backgroundColor = warm.withAlphaComponent(a).cgColor
        tint.add(anim, forKey: "tint")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class SelectionOverlayController: NSObject {
    var onAskTapped: ((Selection, SelectionSnapshot) -> Void)?

    private let panel: NSPanel
    private let contentView: BubbleContentView
    private var currentSnapshot: SelectionSnapshot?
    private var currentSelection: Selection?

    override init() {
        // Friendlier wordmark: a sparkle glyph + "ask" in SF Rounded medium.
        let labelText = "\u{2728} ask"
        let label = NSTextField(labelWithString: labelText)
        let roundedFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 13, weight: .semibold)
            if let desc = base.fontDescriptor.withDesign(.rounded),
               let f = NSFont(descriptor: desc, size: 13) { return f }
            return base
        }()
        label.font = roundedFont
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let cv = BubbleContentView(frame: NSRect(x: 0, y: 0, width: 86, height: 34))
        cv.material = .popover                // softer/warmer than .hudWindow
        cv.blendingMode = .behindWindow
        cv.state = .active
        cv.wantsLayer = true
        cv.layer?.masksToBounds = true        // cornerRadius set by layout()
        cv.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: cv.centerYAnchor)
        ])

        contentView = cv

        panel = NSPanel(
            contentRect: cv.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = cv
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        super.init()
        cv.onClick = { [weak self] in
            self?.askTapped()
        }
    }

    func show(snapshot: SelectionSnapshot, selection: Selection) {
        currentSnapshot = snapshot
        currentSelection = selection
        let target = snapshot.bounds.map(anchorPoint(for:)) ?? fallbackAnchor(near: snapshot.fallbackPoint)
        panel.setFrameTopLeftPoint(target)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        currentSnapshot = nil
        currentSelection = nil
    }

    func containsAppKitPoint(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    private func anchorPoint(for axBounds: CGRect) -> CGPoint {
        let topLeft = convertAXPointToAppKit(CGPoint(x: axBounds.minX, y: axBounds.minY))
        return CGPoint(x: topLeft.x, y: topLeft.y + 40)
    }

    private func fallbackAnchor(near point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + 10, y: point.y + 44)
    }

    private func convertAXPointToAppKit(_ point: CGPoint) -> CGPoint {
        Self.convertQuartzPointToAppKit(point)
    }

    static func convertQuartzPointToAppKit(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { screen in
            let quartzFrame = CGRect(
                x: screen.frame.minX,
                y: NSScreen.mainFrameMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return quartzFrame.contains(point)
        }) ?? NSScreen.main else {
            return point
        }

        let yFromTopOfScreen = point.y - (NSScreen.mainFrameMaxY - screen.frame.maxY)
        return CGPoint(x: point.x, y: screen.frame.maxY - yFromTopOfScreen)
    }

    private func askTapped() {
        Logger.log("Ask bubble clicked")
        guard let snapshot = currentSnapshot, let selection = currentSelection else {
            Logger.log("Ask click ignored: no current snapshot/selection")
            return
        }
        panel.orderOut(nil)
        onAskTapped?(selection, snapshot)
    }
}

private extension NSScreen {
    static var mainFrameMaxY: CGFloat {
        main?.frame.maxY ?? screens.map(\.frame.maxY).max() ?? 0
    }
}
