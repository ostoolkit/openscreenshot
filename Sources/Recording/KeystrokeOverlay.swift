import AppKit
import SwiftUI

/// Keystroke HUD shown near the bottom of the recorded area.
/// Requires Accessibility / Input Monitoring for global key events.
@MainActor
final class KeystrokeOverlayController {
    private var panel: NSPanel?
    private var monitor: Any?
    private var localMonitor: Any?
    private let model = KeystrokeModel()
    private var fadeTask: Task<Void, Never>?

    func start(areaRect: NSRect, screen: NSScreen) {
        if !PermissionsManager.hasAccessibilityPermission {
            PermissionsManager.requestAccessibility()
            Toast.show("Grant Accessibility access to show keystrokes",
                       systemImage: "keyboard")
            return
        }

        let size = NSSize(width: 420, height: 56)
        let rect = areaRect.isEmpty ? screen.visibleFrame : areaRect
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 24)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        // Default sharing type: the HUD must appear in the recording.
        panel.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        fadeTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func handle(_ event: NSEvent) {
        model.text = Self.describe(event)
        panel?.alphaValue = 1

        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.animator().alphaValue = 0
        }
    }

    static func describe(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        if let s = special[event.keyCode] {
            parts.append(s)
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            parts.append(chars.uppercased())
        }
        return parts.joined()
    }
}

@MainActor
final class KeystrokeModel: ObservableObject {
    @Published var text = ""
}

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel

    var body: some View {
        ZStack {
            if !model.text.isEmpty {
                Text(model.text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
