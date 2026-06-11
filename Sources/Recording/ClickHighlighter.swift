import AppKit
import SwiftUI

/// Shows a radiating circle at every mouse click while recording.
/// The ripple panels use the default sharing type so they are captured.
@MainActor
final class ClickHighlighter {
    private var monitor: Any?
    private var localMonitor: Any?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.ripple(at: NSEvent.mouseLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.ripple(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }

    private func ripple(at point: NSPoint) {
        let size: CGFloat = 64
        let panel = NSPanel(contentRect: NSRect(x: point.x - size / 2, y: point.y - size / 2,
                                                width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RippleView())
        panel.orderFrontRegardless()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            panel.orderOut(nil)
        }
    }
}

private struct RippleView: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(Color.yellow.opacity(animate ? 0 : 0.9), lineWidth: animate ? 1 : 4)
            .background(Circle().fill(Color.yellow.opacity(animate ? 0 : 0.3)))
            .scaleEffect(animate ? 1.0 : 0.3)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) {
                    animate = true
                }
            }
            .padding(2)
    }
}
