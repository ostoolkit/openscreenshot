import AppKit
import ScreenCaptureKit

/// One-shot screenshot machinery on top of ScreenCaptureKit.
@MainActor
final class CaptureEngine {
    struct DisplaySnapshot {
        let screen: NSScreen
        let image: CGImage
        let scale: CGFloat
    }

    enum CaptureError: LocalizedError {
        case displayNotFound
        case windowNotFound
        case noPermission
        case timedOut

        var errorDescription: String? {
            switch self {
            case .displayNotFound: "Could not find the display to capture."
            case .windowNotFound: "Could not find the window to capture."
            case .noPermission: "Screen Recording permission is missing."
            case .timedOut: "Screen capture timed out — please try again."
            }
        }
    }

    /// The very first ScreenCaptureKit call after a fresh permission grant can
    /// stall for several seconds (one-time system-side initialization). Run a
    /// throwaway fetch + 2px screenshot at launch so the stall happens in the
    /// background instead of underneath the full-screen selection overlay.
    func warmUp() {
        guard PermissionsManager.hasScreenRecordingPermission else { return }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: 0, y: 0, width: 2, height: 2)
                config.width = 2
                config.height = 2
                config.showsCursor = false
                _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                NSLog("Capture warm-up failed: \(error)")
            }
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withTimeout(8) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Never let a wedged capture call hang the UI flow — fail with a
    /// user-visible error instead.
    private func withTimeout<T>(_ seconds: Double,
                                _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureError.timedOut
            }
            guard let result = try await group.next() else {
                throw CaptureError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func scDisplay(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        return display
    }

    // MARK: - Full display

    func captureDisplay(screen: NSScreen, showCursor: Bool? = nil) async throws -> CGImage {
        let content = try await shareableContent()
        let display = try scDisplay(for: screen, in: content)
        let scale = screen.backingScaleFactor

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = baseConfig(showCursor: showCursor)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        return try await withTimeout(10) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Frozen snapshots of every display, used as the backdrop of the selection UI.
    func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        var result: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            let image = try await captureDisplay(screen: screen)
            result.append(DisplaySnapshot(screen: screen, image: image, scale: screen.backingScaleFactor))
        }
        return result
    }

    // MARK: - Area (live)

    /// Live capture of an area given in CG global (top-left origin) coordinates.
    func captureRect(cgGlobal rect: CGRect, showCursor: Bool? = nil) async throws -> CGImage {
        guard let screen = NSScreen.screens.first(where: { $0.cgFrame.intersects(rect) }) else {
            throw CaptureError.displayNotFound
        }
        let content = try await shareableContent()
        let display = try scDisplay(for: screen, in: content)
        let scale = screen.backingScaleFactor

        let local = CGRect(x: rect.origin.x - screen.cgFrame.origin.x,
                           y: rect.origin.y - screen.cgFrame.origin.y,
                           width: rect.width,
                           height: rect.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = baseConfig(showCursor: showCursor)
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        return try await withTimeout(10) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    // MARK: - Window

    /// Tight capture of a window's content (no margin, no synthetic shadow —
    /// the window-capture "look" is applied later via CanvasStyle so the
    /// editor can change or remove it).
    func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let screen = NSScreen.screens.first {
            $0.cgFrame.intersects(window.frame)
        } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = baseConfig(showCursor: false)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        return try await withTimeout(10) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    // MARK: - Config

    private func baseConfig(showCursor: Bool?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = showCursor ?? AppServices.shared.settings.captureCursor
        config.captureResolution = .best
        config.backgroundColor = .clear
        config.scalesToFit = false
        return config
    }
}
