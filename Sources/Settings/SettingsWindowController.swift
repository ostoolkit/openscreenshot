import AppKit
import SwiftUI

/// Our own settings window. The SwiftUI `Settings` scene can only be opened
/// via `SettingsLink` from within SwiftUI on macOS 14+ (the old
/// `showSettingsWindow:` selector logs a deprecation warning), which doesn't
/// fit an AppKit status-item menu — so we manage the window ourselves.
@MainActor
final class SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window {
            if !window.isVisible {
                AppActivation.windowOpened()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView()
            .environmentObject(AppServices.shared.settings)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [] // keep our window size, not SwiftUI's ideal
        let w = NSWindow(contentViewController: hosting)
        w.title = "OpenScreenshot Settings"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 560, height: 620))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        AppActivation.windowOpened()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { _ in
            Task { @MainActor in
                AppActivation.windowClosed()
            }
        }
        w.makeKeyAndOrderFront(nil)
    }
}
