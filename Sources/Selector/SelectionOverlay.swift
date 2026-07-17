import Cocoa

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

extension NSScreen {
    static var mainFrameMaxY: CGFloat {
        main?.frame.maxY ?? screens.map(\.frame.maxY).max() ?? 0
    }
}
