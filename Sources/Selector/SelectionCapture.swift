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
    private var mouseDownHadOption = false
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
        mouseDownHadOption = flags.contains(.maskAlternate)
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
        let optionArmed = mouseDownHadOption
        mouseDownLocation = nil
        mouseDraggedSinceDown = false
        mouseDownHadShift = false
        mouseDownHadOption = false

        // Option must be held for the gesture to count as a Trigger — plain
        // selection stays silent, Option+selection arms Selector.
        guard optionArmed else { return }

        let trigger: String?
        switch true {
        case dragged:    trigger = "option-drag"
        case multiClick: trigger = "option-multi-click(\(clickCount))"
        case shiftClick: trigger = "option-shift-click"
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
        let option = flags.contains(.maskAlternate)

        if option && shift && isArrowOrEnd {
            lastTrigger = "option-shift-nav"
            scheduleSelectionSample(after: Self.selectionDisplayDelay)
            return
        }

        if option && command && keyCode == 0 { // Option+Cmd+A
            lastTrigger = "option-cmd-a"
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
