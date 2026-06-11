import AppKit
import SwiftUI

/// "Pin to screen": floating always-on-top image windows.
@MainActor
final class PinController {
    private var panels: [PinPanel] = []

    func pin(image: CGImage, near rect: NSRect? = nil) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pointSize = NSSize(width: CGFloat(image.width) / scale,
                               height: CGFloat(image.height) / scale)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var frame: NSRect
        if let rect, !rect.isEmpty {
            frame = rect
        } else {
            frame = NSRect(x: screen.visibleFrame.midX - pointSize.width / 2,
                           y: screen.visibleFrame.midY - pointSize.height / 2,
                           width: pointSize.width, height: pointSize.height)
        }
        // Keep pins manageable on screen.
        let maxW = screen.visibleFrame.width * 0.8
        if frame.width > maxW {
            let r = maxW / frame.width
            frame.size = NSSize(width: frame.width * r, height: frame.height * r)
        }

        let panel = PinPanel(image: image, frame: frame) { [weak self] panel in
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.orderFrontRegardless()
    }
}

final class PinPanel: NSPanel {
    private let image: CGImage
    private let onClose: (PinPanel) -> Void
    private let aspect: CGFloat

    init(image: CGImage, frame: NSRect, onClose: @escaping (PinPanel) -> Void) {
        self.image = image
        self.onClose = onClose
        self.aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentAspectRatio = NSSize(width: 1, height: aspect)

        contentView = NSHostingView(rootView: PinView(image: image, panel: self))
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        orderOut(nil)
        onClose(self)
    }

    func setOpacity(_ value: CGFloat) {
        animator().alphaValue = max(0.15, min(1, value))
    }

    /// Scroll to resize, Option+scroll to change opacity.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            setOpacity(alphaValue + event.scrollingDeltaY * 0.01)
            return
        }
        let factor = 1 + event.scrollingDeltaY * 0.005
        var f = frame
        let newW = min(max(f.width * factor, 80), (screen?.frame.width ?? 4000))
        let newH = newW * aspect
        // Anchor at the center.
        f.origin.x -= (newW - f.width) / 2
        f.origin.y -= (newH - f.height) / 2
        f.size = NSSize(width: newW, height: newH)
        setFrame(f, display: true)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: closePin() // Esc
        default: super.keyDown(with: event)
        }
    }

    func toggleActualSize() {
        let scale = screen?.backingScaleFactor ?? 2
        let actual = NSSize(width: CGFloat(image.width) / scale,
                            height: CGFloat(image.height) / scale)
        var f = frame
        let center = NSPoint(x: f.midX, y: f.midY)
        f.size = actual
        f.origin = NSPoint(x: center.x - actual.width / 2, y: center.y - actual.height / 2)
        setFrame(f, display: true, animate: true)
    }
}

private struct PinView: View {
    let image: CGImage
    weak var panel: PinPanel?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2)
                )

            if hovering {
                Button {
                    panel?.closePin()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            panel?.toggleActualSize()
        }
        .contextMenu {
            Button("Copy") { NSPasteboard.copyImage(image) }
            Button("Annotate") {
                EditorWindowController.open(image: image)
                panel?.closePin()
            }
            Button("Save…") {
                if let capture = CaptureStore.makeImageCapture(image, scale: 1) {
                    CaptureStore.saveAs(capture)
                }
            }
            Menu("Opacity") {
                ForEach([100, 80, 60, 40, 20], id: \.self) { pct in
                    Button("\(pct)%") { panel?.setOpacity(CGFloat(pct) / 100) }
                }
            }
            Button("Actual Size") { panel?.toggleActualSize() }
            Divider()
            Button("Close", role: .destructive) { panel?.closePin() }
        }
    }
}
