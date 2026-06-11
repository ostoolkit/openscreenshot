import AppKit
import SwiftUI

/// Orchestrates every capture flow: selection UI -> engine -> routing
/// (clipboard / disk / Quick Access Overlay / editor / OCR / recorder).
@MainActor
final class CaptureController {
    private var services: AppServices { AppServices.shared }

    // MARK: - Entry points

    func startAreaCapture() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .screenshot) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startWindowCapture() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .screenshot, startInWindowMode: true) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startAllInOne() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .allInOne) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startOCRCapture() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .ocr) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startRecordingSelection(gif: Bool) {
        guard PermissionsManager.ensureScreenRecording() else { return }
        guard !services.recording.isRecording else { return }
        SelectionOverlayController.begin(purpose: gif ? .recordGIF : .recordVideo) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startScrollingCapture() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .scrolling) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func startSelfTimerCapture(delay: Int) {
        guard PermissionsManager.ensureScreenRecording() else { return }
        SelectionOverlayController.begin(purpose: .screenshot, timerDelay: delay) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    func captureFullscreen() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screen(containing: mouse) ?? NSScreen.main
        guard let screen else { return }
        Task {
            await self.withIconsHiddenIfConfigured {
                do {
                    let image = try await self.services.captureEngine.captureDisplay(screen: screen)
                    self.finishImage(image, scale: screen.backingScaleFactor)
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    func capturePreviousArea() {
        guard PermissionsManager.ensureScreenRecording() else { return }
        guard let rect = services.settings.lastSelectionRect else {
            Toast.show("No previous area yet", systemImage: "exclamationmark.circle.fill")
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        Task {
            await self.withIconsHiddenIfConfigured {
                do {
                    let image = try await self.services.captureEngine.captureRect(
                        cgGlobal: Coordinates.cgRect(fromAppKit: rect))
                    self.finishImage(image, scale: screen?.backingScaleFactor ?? 2)
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    // MARK: - Selection outcome routing

    private func handle(_ outcome: SelectionOutcome) {
        switch outcome {
        case .cancelled:
            break

        case let .areaImage(image, rect, screen, purpose, timerDelay):
            services.settings.lastSelectionRect = rect
            switch purpose {
            case .ocr:
                runOCR(on: image)
            case .screenshot, .allInOne:
                if let delay = timerDelay, delay > 0 {
                    runTimedCapture(rect: rect, screen: screen, delay: delay)
                } else {
                    finishImage(image, scale: screen.backingScaleFactor)
                }
            default:
                break
            }

        case let .window(info, purpose):
            switch purpose {
            case .recordVideo, .recordGIF:
                services.recording.start(windowID: info.windowID, gif: purpose == .recordGIF)
            case .ocr:
                Task {
                    do {
                        let image = try await self.services.captureEngine.captureWindow(
                            windowID: info.windowID)
                        self.runOCR(on: image)
                    } catch { self.fail(error) }
                }
            default:
                Task {
                    await self.withIconsHiddenIfConfigured {
                        do {
                            let image = try await self.services.captureEngine.captureWindow(
                                windowID: info.windowID)
                            let screen = NSScreen.screens.first { $0.cgFrame.intersects(info.cgFrame) }
                            // Padding/shadow/transparency become editable
                            // canvas settings rather than baked pixels.
                            let canvas: CanvasStyle = self.services.settings.captureWindowShadow
                                ? .windowCapture : .plain
                            self.finishImage(image, scale: screen?.backingScaleFactor ?? 2,
                                             canvas: canvas)
                        } catch { self.fail(error) }
                    }
                }
            }

        case let .recordArea(rect, screen, gif):
            services.settings.lastSelectionRect = rect
            services.recording.start(areaRect: rect, on: screen, gif: gif)

        case let .scrollArea(rect, screen):
            services.settings.lastSelectionRect = rect
            ScrollingCaptureController.shared.begin(rect: rect, screen: screen)
        }
    }

    private func runTimedCapture(rect: NSRect, screen: NSScreen, delay: Int) {
        CountdownOverlay.show(seconds: delay, on: screen) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let image = try await self.services.captureEngine.captureRect(
                        cgGlobal: Coordinates.cgRect(fromAppKit: rect))
                    self.finishImage(image, scale: screen.backingScaleFactor)
                } catch { self.fail(error) }
            }
        }
    }

    private func runOCR(on image: CGImage) {
        Task {
            let result = await TextRecognizer.recognize(image: image)
            switch result {
            case .text(let string):
                NSPasteboard.copyString(string)
                SoundPlayer.playCapture()
                Toast.show("Text copied to clipboard", systemImage: "doc.on.clipboard.fill")
            case .qrCode(let payload):
                NSPasteboard.copyString(payload)
                if let url = URL(string: payload), url.scheme?.hasPrefix("http") == true {
                    Toast.show("QR code link copied", systemImage: "qrcode")
                } else {
                    Toast.show("QR code copied to clipboard", systemImage: "qrcode")
                }
            case .nothing:
                Toast.show("No text found", systemImage: "exclamationmark.circle.fill")
            }
        }
    }

    // MARK: - Finish

    func finishImage(_ image: CGImage, scale: CGFloat, canvas: CanvasStyle = .plain) {
        SoundPlayer.playCapture()
        guard let capture = CaptureStore.makeImageCapture(image, scale: scale, canvas: canvas) else {
            Toast.show("Failed to save capture", systemImage: "xmark.circle.fill")
            return
        }
        routeFinished(capture)
    }

    func finishFileCapture(tempURL: URL, kind: CaptureKind) {
        guard let capture = CaptureStore.makeFileCapture(tempURL: tempURL, kind: kind) else {
            Toast.show("Failed to save capture", systemImage: "xmark.circle.fill")
            return
        }
        routeFinished(capture)
    }

    private func routeFinished(_ capture: Capture) {
        if services.settings.copyToClipboardAfterCapture {
            CaptureStore.copyToClipboard(capture)
        }
        services.history.add(capture)
        if services.settings.showQuickAccessOverlay {
            services.overlay.show(capture)
        }
    }

    private func fail(_ error: Error) {
        NSLog("Capture failed: \(error)")
        Toast.show(error.localizedDescription, systemImage: "xmark.circle.fill")
    }

    private func withIconsHiddenIfConfigured(_ body: @escaping () async -> Void) async {
        let hider = services.desktopIcons
        let shouldHide = services.settings.hideIconsWhileCapturing && !hider.isHidden
        if shouldHide {
            hider.hide()
            // Give the wallpaper overlay a beat to draw before capturing.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await body()
        if shouldHide {
            hider.restore()
        }
    }
}
