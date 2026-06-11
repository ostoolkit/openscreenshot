import AppKit
import SwiftUI

struct QuickAccessStackView: View {
    @ObservedObject var controller: QuickAccessOverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)

            if controller.items.count > 1 {
                Button {
                    controller.dismissAll()
                } label: {
                    Label("Close All", systemImage: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ForEach(controller.items.reversed()) { capture in
                QuickAccessItemView(capture: capture, controller: controller)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct QuickAccessItemView: View {
    @ObservedObject var capture: Capture
    let controller: QuickAccessOverlayController
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail rendered by SwiftUI (scaled-to-fit, never cropped).
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.85)
                if let thumbnail = capture.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
                if capture.kind != .image {
                    Image(systemName: capture.kind == .gif ? "photo.stack.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .frame(width: 232, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            // Invisible AppKit layer providing file drag-out + double-click.
            .overlay {
                DragInteractionLayer(capture: capture) {
                    controller.dismiss(id: capture.id)
                } onDoubleClick: {
                    controller.edit(capture)
                }
            }

            if hovering {
                Button {
                    controller.dismiss(id: capture.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
            }
        }
        .overlay(alignment: .bottom) {
            if hovering {
                actionBar
                    .offset(y: 14)
            }
        }
        .frame(width: 232, height: 152, alignment: .top)
        .onHover { h in
            hovering = h
            if h { controller.cancelAutoClose(id: capture.id) }
        }
        .contextMenu {
            Button("Save As…") { CaptureStore.saveAs(capture) }
            Button("Copy") { controller.copy(capture) }
            Button(capture.kind == .image ? "Annotate" : "Edit") { controller.edit(capture) }
            if capture.kind == .image {
                Button("Pin") { controller.pin(capture) }
            }
            Divider()
            Button("Show in Finder") { controller.showInFinder(capture) }
            Button("Delete", role: .destructive) { controller.delete(capture) }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            actionButton("square.and.arrow.down", "Save") { controller.save(capture) }
            actionButton("doc.on.doc", "Copy") { controller.copy(capture) }
            actionButton(capture.kind == .image ? "pencil.tip" : "scissors", "Edit") {
                controller.edit(capture)
            }
            if capture.kind == .image {
                actionButton("pin", "Pin") { controller.pin(capture) }
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Transparent AppKit view layered over the thumbnail: starts a file drag on
/// mouse-drag, opens the editor on double-click. Draws nothing itself.
struct DragInteractionLayer: NSViewRepresentable {
    let capture: Capture
    let onDragCompleted: () -> Void
    let onDoubleClick: () -> Void

    @MainActor
    func makeNSView(context: Context) -> DragInteractionNSView {
        let view = DragInteractionNSView()
        update(view)
        return view
    }

    @MainActor
    func updateNSView(_ nsView: DragInteractionNSView, context: Context) {
        update(nsView)
    }

    @MainActor
    private func update(_ view: DragInteractionNSView) {
        view.fileURL = capture.bestURL
        view.dragImage = capture.thumbnail
        view.onDragCompleted = onDragCompleted
        view.onDoubleClick = onDoubleClick
    }
}

final class DragInteractionNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var dragImage: NSImage?
    var onDragCompleted: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var mouseDownLocation: NSPoint = .zero

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fileURL else { return }
        let distance = hypot(event.locationInWindow.x - mouseDownLocation.x,
                             event.locationInWindow.y - mouseDownLocation.y)
        guard distance > 5 else { return }

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let image = dragImage ?? NSWorkspace.shared.icon(forFile: fileURL.path)
        let aspect = image.size.height / max(image.size.width, 1)
        let dragSize = NSSize(width: 160, height: max(160 * aspect, 24))
        item.setDraggingFrame(NSRect(origin: NSPoint(x: bounds.midX - dragSize.width / 2,
                                                     y: bounds.midY - dragSize.height / 2),
                                     size: dragSize),
                              contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        if operation != [] {
            Task { @MainActor in
                self.onDragCompleted?()
            }
        }
    }
}
