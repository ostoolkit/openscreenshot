import SwiftUI

@main
struct OpenScreenshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Placeholder scene: settings live in SettingsWindowController
        // (the Settings scene can't be opened from an AppKit menu on
        // macOS 14+ without deprecation warnings).
        SwiftUI.Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppServices.shared.willTerminate()
        return .terminateNow
    }

    // Opening an image file with the app routes into the annotation editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let image = NSImage(contentsOf: url)?.cgImage {
                EditorWindowController.open(image: image, sourceURL: url)
            }
        }
    }
}
