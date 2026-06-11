import AppKit
import ScreenCaptureKit

/// Drives screen recordings: countdown, aux overlays (webcam, clicks,
/// keystrokes), the SCStream recorder, and post-processing (GIF).
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var isRecording = false

    private var recorder: StreamRecorder?
    private var isGIF = false
    private var startedAt: Date?
    private var webcam: WebcamOverlayController?
    private var clicks: ClickHighlighter?
    private var keystrokes: KeystrokeOverlayController?

    private var settings: SettingsStore { AppServices.shared.settings }

    // MARK: - Starting

    func start(areaRect: NSRect, on screen: NSScreen, gif: Bool) {
        guard !isRecording else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                    throw CaptureEngine.CaptureError.displayNotFound
                }
                let scale = screen.backingScaleFactor
                let cgRect = Coordinates.cgRect(fromAppKit: areaRect)
                let local = CGRect(x: cgRect.origin.x - screen.cgFrame.origin.x,
                                   y: cgRect.origin.y - screen.cgFrame.origin.y,
                                   width: cgRect.width, height: cgRect.height)

                // Exclude our own UI except overlays meant to be captured
                // (webcam bubble / keystroke HUD use default sharingType).
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = self.streamConfig(gif: gif)
                config.sourceRect = local
                config.width = Int(local.width * scale)
                config.height = Int(local.height * scale)

                await self.beginRecording(filter: filter, config: config, gif: gif,
                                          screen: screen, areaRect: areaRect)
            } catch {
                self.failStart(error)
            }
        }
    }

    func start(windowID: CGWindowID, gif: Bool) {
        guard !isRecording else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureEngine.CaptureError.windowNotFound
                }
                let screen = NSScreen.screens.first { $0.cgFrame.intersects(window.frame) } ?? NSScreen.main
                let scale = screen?.backingScaleFactor ?? 2

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = self.streamConfig(gif: gif)
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)

                await self.beginRecording(filter: filter, config: config, gif: gif,
                                          screen: screen ?? NSScreen.screens[0],
                                          areaRect: Coordinates.appKitRect(fromCG: window.frame))
            } catch {
                self.failStart(error)
            }
        }
    }

    private func streamConfig(gif: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let fps = gif ? max(10, settings.gifFPS) : settings.videoFPS
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = settings.recordCursor
        config.queueDepth = 8
        config.capturesAudio = settings.recordSystemAudio && !gif
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *), settings.recordMicrophone, !gif {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }
        return config
    }

    private func beginRecording(filter: SCContentFilter,
                                config: SCStreamConfiguration,
                                gif: Bool,
                                screen: NSScreen,
                                areaRect: NSRect) async {
        // Countdown before any overlays come up.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            CountdownOverlay.show(seconds: settings.countdownSeconds, on: screen) {
                cont.resume()
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenScreenshot-\(UUID().uuidString).mp4")
        let fps = gif ? max(10, settings.gifFPS) : settings.videoFPS

        do {
            let recorder = try StreamRecorder(
                filter: filter,
                configuration: config,
                outputURL: tempURL,
                recordSystemAudio: settings.recordSystemAudio && !gif,
                recordMicrophone: settings.recordMicrophone && !gif,
                fps: fps)
            recorder.onStreamError = { [weak self] error in
                Task { @MainActor in
                    self?.handleStreamError(error)
                }
            }
            try await recorder.start()
            self.recorder = recorder
        } catch {
            failStart(error)
            return
        }

        isGIF = gif
        isRecording = true
        startedAt = Date()

        if settings.webcamOverlayEnabled, !gif {
            webcam = WebcamOverlayController()
            webcam?.show(near: areaRect, on: screen)
        }
        if settings.highlightClicks {
            clicks = ClickHighlighter()
            clicks?.start()
        }
        if settings.showKeystrokes {
            keystrokes = KeystrokeOverlayController()
            keystrokes?.start(areaRect: areaRect, screen: screen)
        }

        SoundPlayer.playRecordingStart()
        AppServices.shared.statusItem.configureRecording(startedAt: startedAt!)
    }

    private func failStart(_ error: Error) {
        NSLog("Recording failed to start: \(error)")
        Toast.show("Recording failed: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
        AppServices.shared.statusItem.configureIdle()
    }

    private func handleStreamError(_ error: Error) {
        NSLog("Stream stopped with error: \(error)")
        Task { await stop() }
    }

    // MARK: - Stopping

    func stop() async {
        guard isRecording, let recorder else { return }
        isRecording = false

        tearDownOverlays()
        AppServices.shared.statusItem.configureIdle()
        SoundPlayer.playRecordingStop()

        do {
            let url = try await recorder.stop()
            self.recorder = nil
            if isGIF {
                Toast.show("Converting to GIF…", systemImage: "arrow.triangle.2.circlepath")
                let gifURL = try await GIFExporter.export(
                    videoURL: url,
                    fps: AppServices.shared.settings.gifFPS)
                try? FileManager.default.removeItem(at: url)
                AppServices.shared.capture.finishFileCapture(tempURL: gifURL, kind: .gif)
            } else {
                AppServices.shared.capture.finishFileCapture(tempURL: url, kind: .video)
            }
        } catch {
            NSLog("Recording stop failed: \(error)")
            Toast.show("Recording failed: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
            self.recorder = nil
        }
    }

    /// Called from applicationShouldTerminate; cannot await.
    func stopSync() {
        tearDownOverlays()
        recorder?.stopBestEffort()
        recorder = nil
        isRecording = false
    }

    private func tearDownOverlays() {
        webcam?.hide()
        webcam = nil
        clicks?.stop()
        clicks = nil
        keystrokes?.stop()
        keystrokes = nil
    }
}
