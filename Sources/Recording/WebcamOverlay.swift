import AppKit
import AVFoundation

/// Floating circular webcam bubble. Uses the default window sharing type so
/// it is part of the captured screen content — no compositing needed.
@MainActor
final class WebcamOverlayController {
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    func show(near areaRect: NSRect, on screen: NSScreen) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted else {
                    Toast.show("Camera access denied", systemImage: "video.slash.fill")
                    return
                }
                self.buildPanel(near: areaRect, on: screen)
            }
        }
    }

    private func buildPanel(near areaRect: NSRect, on screen: NSScreen) {
        guard let device = AVCaptureDevice.default(for: .video) else {
            Toast.show("No camera found", systemImage: "video.slash.fill")
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        self.session = session

        let diameter: CGFloat = 180
        let margin: CGFloat = 16
        let visible = areaRect.intersection(screen.visibleFrame).isEmpty ? screen.visibleFrame : areaRect
        let origin = NSPoint(x: visible.maxX - diameter - margin, y: visible.minY + margin)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: diameter, height: diameter)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Intentionally NOT sharingType = .none: the bubble must be recorded.

        let container = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        container.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = container.bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = diameter / 2
        previewLayer.masksToBounds = true
        previewLayer.borderWidth = 3
        previewLayer.borderColor = CGColor(gray: 1, alpha: 0.9)
        container.layer = CALayer()
        container.layer?.addSublayer(previewLayer)
        panel.contentView = container

        panel.orderFrontRegardless()
        self.panel = panel

        Task.detached {
            session.startRunning()
        }
    }

    func hide() {
        session?.stopRunning()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
