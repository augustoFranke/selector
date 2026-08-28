import Cocoa

/// The Selection Overlay's hover-bubble: a neutral glass capsule (Liquid Glass
/// on macOS 26+, vibrancy fallback earlier) with an "Ask" label. Hover adds a
/// subtle neutral highlight.
final class BubbleContentView: NSView {
    var onClick: (() -> Void)?
    private let background: NSView
    private let hoverView = NSView()
    private var trackingArea: NSTrackingArea?
    private var hoverHighlight: CALayer? { hoverView.layer }

    override init(frame frameRect: NSRect) {
        let (bg, host) = GlassSurface.make(cornerRadius: frameRect.height / 2)
        background = bg
        super.init(frame: frameRect)
        wantsLayer = true

        bg.frame = bounds
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)

        let label = NSTextField(labelWithString: "Ask")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])

        // Topmost sibling view: a sublayer of our own layer would render
        // beneath the glass subview.
        hoverView.wantsLayer = true
        hoverView.frame = bounds
        hoverView.autoresizingMask = [.width, .height]
        hoverView.layer?.backgroundColor = NSColor.clear.cgColor
        hoverView.layer?.actions = ["backgroundColor": NSNull()] // we'll opt in to animation manually
        addSubview(hoverView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        GlassSurface.setCornerRadius(radius, on: background)
        hoverHighlight?.cornerRadius = radius
        hoverHighlight?.cornerCurve = .continuous
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { setHighlightAlpha(0.08) }
    override func mouseExited(with event: NSEvent)  { setHighlightAlpha(0) }

    private func setHighlightAlpha(_ a: CGFloat) {
        guard let highlight = hoverHighlight else { return }
        let color = NSColor.labelColor.withAlphaComponent(a).cgColor
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = highlight.backgroundColor
        anim.toValue   = color
        anim.duration  = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        highlight.backgroundColor = color
        highlight.add(anim, forKey: "highlight")
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
        let cv = BubbleContentView(frame: NSRect(x: 0, y: 0, width: 62, height: 32))
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
