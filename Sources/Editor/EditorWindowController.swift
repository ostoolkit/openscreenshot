import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private static var windows: [NSWindow] = []
    private static var documents: [ObjectIdentifier: EditorDocument] = [:]
    private static var deleteKeyMonitor: Any?

    static func open(image: CGImage, canvas: CanvasStyle = .plain,
                     capture: Capture? = nil, sourceURL: URL? = nil) {
        let document = EditorDocument(image: image, canvas: canvas)
        let view = EditorView(document: document)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [] // keep our window size, not SwiftUI's ideal
        let window = NSWindow(contentViewController: hosting)
        window.title = sourceURL?.lastPathComponent ?? "Annotate"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false

        // Size the window to fit the composition (image + padding) comfortably.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let comp = document.compositionSize
        let imageSize = NSSize(width: comp.width / scale, height: comp.height / scale)
        // +368: canvas sidebar (248) + canvas margins.
        let w = min(max(imageSize.width + 368, 1000), screen.width * 0.9)
        let h = min(max(imageSize.height + 160, 540), screen.height * 0.9)
        window.setContentSize(NSSize(width: w, height: h))
        window.center()

        windows.append(window)
        documents[ObjectIdentifier(window)] = document
        installDeleteKeyMonitorIfNeeded()
                        AppActivation.windowOpened()

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            Task { @MainActor in
                windows.removeAll { $0 === window }
                documents.removeValue(forKey: ObjectIdentifier(window))
                if documents.isEmpty, let monitor = deleteKeyMonitor {
                    NSEvent.removeMonitor(monitor)
                    deleteKeyMonitor = nil
                }
                AppActivation.windowClosed()
            }
        }

        window.makeKeyAndOrderFront(nil)
    }

    /// Backspace / forward-delete removes the selected annotation.
    /// (SwiftUI's onDeleteCommand needs view focus the canvas never has,
    /// so handle the key at the window level.)
    private static func installDeleteKeyMonitorIfNeeded() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51 || event.keyCode == 117, // ⌫ / ⌦
                  let window = event.window,
                  let document = documents[ObjectIdentifier(window)],
                  !(window.firstResponder is NSTextView), // typing in a text field
                  document.editingTextID == nil,
                  document.selectedID != nil
            else { return event }
            document.deleteSelected()
            return nil
        }
    }
}
