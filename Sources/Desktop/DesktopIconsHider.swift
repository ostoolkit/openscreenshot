import AppKit

/// Hides desktop icons by covering the desktop with per-screen wallpaper
/// windows just above the icon layer (no Finder restart needed).
@MainActor
final class DesktopIconsHider {
    private var windows: [NSWindow] = []

    var isHidden: Bool { !windows.isEmpty }

    func toggle() {
        isHidden ? restore() : hide()
    }

    func hide() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            // Default sharing type on purpose: must appear in captures.

            // Aspect-fill the wallpaper like the real desktop does
            // (NSImageView would stretch or letterbox it).
            let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            contentView.wantsLayer = true
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let image = NSImage(contentsOf: url) {
                contentView.layer?.contents = image
                contentView.layer?.contentsGravity = .resizeAspectFill
                contentView.layer?.masksToBounds = true
                window.backgroundColor = .black
            } else {
                // Dynamic/rotating wallpapers may not resolve to a file; use a clean color.
                window.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1)
            }
            window.contentView = contentView
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func restore() {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
    }
}
