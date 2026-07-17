import AppKit
import CoreGraphics

enum ScreenshotPermission {
    case granted
    case denied
}

enum ScreenshotContextService {
    /// Returns whether Screen Recording permission is currently granted.
    /// If not granted, triggers the system prompt (which guides the user to
    /// System Settings); the user will typically need to relaunch Selector
    /// after granting before captures succeed.
    static func ensurePermission() -> ScreenshotPermission {
        let initial = CGPreflightScreenCaptureAccess()
        if initial { return .granted }
        let requested = CGRequestScreenCaptureAccess()
        let after = CGPreflightScreenCaptureAccess()
        Logger.log("ScreenCapture permission preflight=\(initial) request=\(requested) postflight=\(after)")
        return after ? .granted : .denied
    }

    /// Captures a region around the current cursor. PLAN1 Prototype 5: capture
    /// "a padded rectangle around the current selection bounds when available;
    /// otherwise capture a small region around the cursor." Selection-bounds
    /// plumbing is flagged for polish; for now we always capture around the cursor.
    static func captureAroundCursor(size: CGSize = CGSize(width: 520, height: 360)) -> Data? {
        guard ensurePermission() == .granted else { return nil }

        let mouseLoc = NSEvent.mouseLocation // AppKit coords, bottom-left origin, across all screens
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) ?? NSScreen.main else {
            return nil
        }

        // Convert AppKit point to display-local Quartz rect (top-left origin within the screen).
        let screenFrame = screen.frame
        let localX = mouseLoc.x - screenFrame.minX
        let localY = screenFrame.maxY - mouseLoc.y

        var rect = CGRect(x: localX - size.width / 2,
                          y: localY - size.height / 2,
                          width: size.width,
                          height: size.height)

        // Clamp to the screen.
        rect.origin.x = max(0, min(rect.origin.x, screenFrame.width - rect.width))
        rect.origin.y = max(0, min(rect.origin.y, screenFrame.height - rect.height))

        // CGWindowListCreateImage expects screen coordinates in the global Quartz space
        // (top-left origin across the whole virtual display). Compute that from local rect.
        let primary = NSScreen.screens.first?.frame ?? screenFrame
        let globalX = screenFrame.minX + rect.minX
        let globalY = primary.maxY - (screenFrame.maxY - rect.minY)
        let globalRect = CGRect(x: globalX, y: globalY, width: rect.width, height: rect.height)

        guard let cg = CGWindowListCreateImage(globalRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
