import AppKit

/// Lightweight wrapper over CGWindowListCopyWindowInfo for hover-highlighting
/// and edge snapping in the selection UI.
struct WindowInfo: Equatable {
    let windowID: CGWindowID
    /// Frame in CG global (top-left origin) coordinates.
    let cgFrame: CGRect
    let title: String
    let ownerName: String
    let ownerPID: pid_t
    let layer: Int

    /// Frame in AppKit global (bottom-left origin) coordinates.
    var appKitFrame: NSRect { Coordinates.appKitRect(fromCG: cgFrame) }

    /// On-screen windows, front to back, excluding our own and non-normal layers.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let alpha = entry[kCGWindowAlpha as String] as? CGFloat, alpha > 0
            else { continue }
            let frame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                               width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            guard frame.width >= 40, frame.height >= 40 else { continue }
            result.append(WindowInfo(
                windowID: windowID,
                cgFrame: frame,
                title: entry[kCGWindowName as String] as? String ?? "",
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                ownerPID: pid,
                layer: layer))
        }
        return visibleOnly(result)
    }

    /// Drop windows that are entirely hidden behind windows above them —
    /// only windows the user can actually see should be selectable.
    private static func visibleOnly(_ windows: [WindowInfo]) -> [WindowInfo] {
        var visible: [WindowInfo] = []
        var aboveFrames: [CGRect] = []
        for window in windows { // front-to-back
            if hasVisiblePoint(window.cgFrame, above: aboveFrames) {
                visible.append(window)
            }
            aboveFrames.append(window.cgFrame)
        }
        return visible
    }

    /// Sample a 5×5 grid: the window counts as visible if any sample point
    /// is not covered by a window higher in the z-order.
    private static func hasVisiblePoint(_ frame: CGRect, above: [CGRect]) -> Bool {
        guard !above.isEmpty else { return true }
        for ix in 0..<5 {
            for iy in 0..<5 {
                let p = CGPoint(x: frame.minX + frame.width * (CGFloat(ix) + 0.5) / 5,
                                y: frame.minY + frame.height * (CGFloat(iy) + 0.5) / 5)
                if !above.contains(where: { $0.contains(p) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Frontmost normal window under a CG global point.
    static func window(at cgPoint: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.cgFrame.contains(cgPoint) }
    }
}
