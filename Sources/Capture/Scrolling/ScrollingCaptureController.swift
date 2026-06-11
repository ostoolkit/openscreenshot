import AppKit
import SwiftUI

/// Scrolling capture session: the user (or auto-scroll) scrolls the selected
/// area while frames are sampled and stitched into one tall screenshot.
@MainActor
final class ScrollingCaptureController: ObservableObject {
    static let shared = ScrollingCaptureController()

    enum State { case idle, ready, capturing }

    @Published var state: State = .idle
    @Published var capturedHeight = 0
    @Published var autoScroll = false

    private var rect: NSRect = .zero
    private var screen: NSScreen?
    private var panel: NSPanel?
    private var stitcher = ImageStitcher()
    private var captureTask: Task<Void, Never>?
    private var scale: CGFloat = 2

    func begin(rect: NSRect, screen: NSScreen) {
        guard state == .idle else { return }
        self.rect = rect
        self.screen = screen
        self.scale = screen.backingScaleFactor
        stitcher = ImageStitcher()
        capturedHeight = 0
        autoScroll = false
        state = .ready
        showControlPanel()
    }

    private func showControlPanel() {
        guard let screen else { return }
        let size = NSSize(width: 320, height: 64)
        // Place the controls below the selection, or above if there's no room.
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY {
            origin.y = rect.maxY + 12
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ScrollingControlView(controller: self))
        p.orderFrontRegardless()
        panel = p

        // Outline the captured region.
        showOutline()
    }

    private var outlinePanel: NSPanel?

    private func showOutline() {
        let pad: CGFloat = 3
        let frame = rect.insetBy(dx: -pad, dy: -pad)
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .padding(1)
        )
        p.orderFrontRegardless()
        outlinePanel = p
    }

    // MARK: - Session control

    func start() {
        guard state == .ready else { return }
        state = .capturing
        captureTask = Task { [weak self] in
            await self?.captureLoop()
        }
        if autoScroll {
            startAutoScroll()
        }
    }

    func toggleAutoScroll() {
        autoScroll.toggle()
        if autoScroll {
            if !PermissionsManager.hasAccessibilityPermission {
                PermissionsManager.requestAccessibility()
                Toast.show("Grant Accessibility access for auto-scroll", systemImage: "hand.raised")
                autoScroll = false
                return
            }
            if state == .capturing {
                startAutoScroll()
            }
        }
    }

    func finish() {
        captureTask?.cancel()
        let image = stitcher.compose()
        teardown()
        if let image, stitcher.totalHeight > 0 {
            AppServices.shared.capture.finishImage(image, scale: scale)
        } else {
            Toast.show("Nothing captured", systemImage: "exclamationmark.circle.fill")
        }
    }

    func cancel() {
        captureTask?.cancel()
        teardown()
    }

    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        outlinePanel?.orderOut(nil)
        outlinePanel = nil
        state = .idle
        autoScroll = false
    }

    // MARK: - Capture loop

    private func captureLoop() async {
        let cgRect = Coordinates.cgRect(fromAppKit: rect)
        while !Task.isCancelled, state == .capturing {
            do {
                let frame = try await AppServices.shared.captureEngine.captureRect(
                    cgGlobal: cgRect, showCursor: false)
                let added = stitcher.add(frame: frame)
                if added > 0 {
                    capturedHeight = stitcher.totalHeight
                }
            } catch {
                NSLog("Scrolling frame failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if autoScroll {
                postScrollEvent()
            }
        }
    }

    private func startAutoScroll() {
        // Scrolling happens inside the capture loop tick for pacing.
    }

    /// Synthesize a scroll-down event at the center of the captured area.
    private func postScrollEvent() {
        let center = CGPoint(x: rect.midX, y: Coordinates.cgRect(fromAppKit: rect).midY)
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: -Int32(rect.height * 0.5),
                                  wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cghidEventTap)
    }
}

private struct ScrollingControlView: View {
    @ObservedObject var controller: ScrollingCaptureController

    var body: some View {
        HStack(spacing: 10) {
            if controller.state == .ready {
                Button {
                    controller.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Text("Then scroll the content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    controller.finish()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(controller.capturedHeight) px")
                        .font(.system(.caption, design: .monospaced).bold())
                    Toggle("Auto-scroll", isOn: Binding(
                        get: { controller.autoScroll },
                        set: { _ in controller.toggleAutoScroll() }))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                }
            }

            Spacer()

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .padding(2)
    }
}
