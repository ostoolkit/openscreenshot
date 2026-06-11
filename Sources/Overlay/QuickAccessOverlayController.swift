import AppKit
import SwiftUI

/// The floating post-capture thumbnail stack.
@MainActor
final class QuickAccessOverlayController: ObservableObject {
    @Published var items: [Capture] = []

    private var panel: NSPanel?
    private var autoCloseTasks: [UUID: Task<Void, Never>] = [:]

    private let itemWidth: CGFloat = 232
    private let itemHeight: CGFloat = 152
    private let margin: CGFloat = 16

    func show(_ capture: Capture) {
        items.insert(capture, at: 0)
        if items.count > 6 {
            items.removeLast(items.count - 6)
        }
        rebuildPanel()

        let timeout = AppServices.shared.settings.overlayAutoCloseSeconds
        if timeout > 0 {
            let id = capture.id
            autoCloseTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.dismiss(id: id)
            }
        }
    }

    func dismiss(id: UUID) {
        autoCloseTasks[id]?.cancel()
        autoCloseTasks[id] = nil
        items.removeAll { $0.id == id }
        rebuildPanel()
    }

    func dismissAll() {
        for task in autoCloseTasks.values { task.cancel() }
        autoCloseTasks = [:]
        items = []
        rebuildPanel()
    }

    func cancelAutoClose(id: UUID) {
        autoCloseTasks[id]?.cancel()
        autoCloseTasks[id] = nil
    }

    // MARK: - Panel management

    private func rebuildPanel() {
        guard !items.isEmpty else {
            panel?.orderOut(nil)
            panel = nil
            return
        }

        if panel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.sharingType = .none
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = NSHostingView(rootView: QuickAccessStackView(controller: self))
            panel = p
        }

        // 12pt padding top/bottom + per-item height + stack spacing + Close All row.
        let closeAllHeight: CGFloat = items.count > 1 ? 32 : 0
        let height = CGFloat(items.count) * (itemHeight + 10) + 24 + closeAllHeight
        let size = NSSize(width: itemWidth + 24, height: height)
        panel?.setContentSize(size)
        positionPanel(size: size)
        panel?.orderFrontRegardless()
    }

    private func positionPanel(size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let corner = AppServices.shared.settings.overlayCorner
        let origin: NSPoint
        switch corner {
        case .bottomLeft: origin = NSPoint(x: v.minX + margin, y: v.minY + margin)
        case .bottomRight: origin = NSPoint(x: v.maxX - size.width - margin, y: v.minY + margin)
        case .topLeft: origin = NSPoint(x: v.minX + margin, y: v.maxY - size.height - margin)
        case .topRight: origin = NSPoint(x: v.maxX - size.width - margin, y: v.maxY - size.height - margin)
        }
        panel?.setFrameOrigin(origin)
    }

    // MARK: - Item actions

    func save(_ capture: Capture) {
        if capture.savedURL == nil {
            if let url = CaptureStore.saveToUserFolder(capture) {
                Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
            }
        } else {
            CaptureStore.saveAs(capture)
        }
    }

    func copy(_ capture: Capture) {
        CaptureStore.copyToClipboard(capture)
        Toast.show("Copied to clipboard")
        dismiss(id: capture.id)
    }

    func edit(_ capture: Capture) {
        cancelAutoClose(id: capture.id)
        switch capture.kind {
        case .image:
            // Window captures open with their padding/shadow/background as
            // live canvas settings instead of baked pixels.
            if let source = capture.sourceImage, let canvas = capture.canvasStyle {
                EditorWindowController.open(image: source, canvas: canvas, capture: capture)
                dismiss(id: capture.id)
            } else if let image = capture.image ?? NSImage(contentsOf: capture.bestURL)?.cgImage {
                EditorWindowController.open(image: image, capture: capture)
                dismiss(id: capture.id)
            }
        case .video, .gif:
            VideoTrimmerWindowController.open(capture: capture)
            dismiss(id: capture.id)
        }
    }

    func pin(_ capture: Capture) {
        guard capture.kind == .image,
              let image = capture.image ?? NSImage(contentsOf: capture.bestURL)?.cgImage else { return }
        AppServices.shared.pins.pin(image: image)
        dismiss(id: capture.id)
    }

    func showInFinder(_ capture: Capture) {
        NSWorkspace.shared.activateFileViewerSelecting([capture.bestURL])
    }

    func delete(_ capture: Capture) {
        AppServices.shared.history.remove(id: capture.id)
        if let saved = capture.savedURL {
            try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
        }
        dismiss(id: capture.id)
    }
}
