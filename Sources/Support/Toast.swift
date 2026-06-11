import AppKit
import SwiftUI

/// Lightweight floating HUD used instead of system notifications
/// (no notification permission needed for an LSUIElement app).
@MainActor
final class Toast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ text: String, systemImage: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(text: text, systemImage: systemImage)
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none
        p.ignoresMouseEvents = true
        p.contentView = hosting

        if let screen = NSScreen.main {
            let x = screen.frame.midX - hosting.fittingSize.width / 2
            let y = screen.visibleFrame.maxY - hosting.fittingSize.height - 24
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        panel = p

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            } completionHandler: {
                p.orderOut(nil)
                if panel === p { panel = nil }
            }
        }
    }
}

private struct ToastView: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
    }
}
