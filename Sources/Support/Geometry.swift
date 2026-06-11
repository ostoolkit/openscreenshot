import AppKit

/// AppKit uses a bottom-left-origin global coordinate space; CoreGraphics /
/// ScreenCaptureKit use top-left-origin (relative to the primary display).
/// All conversions go through here.
enum Coordinates {
    /// Height of the primary display (the one whose AppKit origin is 0,0).
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AppKit global rect -> CG/SCK global rect (top-left origin).
    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// CG/SCK global rect -> AppKit global rect (bottom-left origin).
    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func cgPoint(fromAppKit point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// This screen's frame in CG global (top-left origin) coordinates.
    var cgFrame: CGRect { Coordinates.cgRect(fromAppKit: frame) }

    static func screen(containing appKitPoint: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(appKitPoint, $0.frame, false) }
    }
}

extension CGRect {
    var standardizedIntegral: CGRect { standardized.integral }

    func clamped(to bounds: CGRect) -> CGRect {
        intersection(bounds)
    }
}
