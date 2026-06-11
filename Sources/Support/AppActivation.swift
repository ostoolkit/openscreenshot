import AppKit

/// As an LSUIElement app, OpenScreenshot is normally invisible to Cmd+Tab.
/// While document-style windows (editor, trimmer, history, settings) are
/// open, temporarily become a regular app so the windows participate in the
/// app switcher; drop back to accessory when the last one closes.
@MainActor
enum AppActivation {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
