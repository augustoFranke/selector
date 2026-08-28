import Cocoa

enum GlassSurface {
    /// `background` is the view to install in the window; `host` is where content
    /// subviews go (NSGlassEffectView requires content inside its contentView).
    static func make(cornerRadius: CGFloat) -> (background: NSView, host: NSView) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            let host = NSView()
            glass.contentView = host
            return (glass, host)
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return (effect, effect)
    }

    static func setCornerRadius(_ radius: CGFloat, on background: NSView) {
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            background.layer?.cornerRadius = radius
        }
    }
}
