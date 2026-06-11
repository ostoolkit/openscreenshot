import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Simple video editor: preview + QuickTime-style trim bar + export (MP4 or GIF).
@MainActor
final class VideoTrimmerWindowController {
    private static var windows: [NSWindow] = []

    static func open(capture: Capture) {
        let view = TrimmerView(capture: capture)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [] // keep our window size, not SwiftUI's ideal
        let window = NSWindow(contentViewController: hosting)
        window.title = "Edit Recording — \(capture.displayName)"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        AppActivation.windowOpened()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            Task { @MainActor in
                windows.removeAll { $0 === window }
                AppActivation.windowClosed()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct TrimmerView: View {
    let capture: Capture

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var thumbnails: [NSImage] = []
    @State private var exporting = false
    @State private var timeObserver: Any?

    init(capture: Capture) {
        self.capture = capture
        _player = State(initialValue: AVPlayer(url: capture.bestURL))
    }

    var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: player)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if duration > 0 {
                TrimBar(thumbnails: thumbnails,
                        duration: duration,
                        trimStart: $trimStart,
                        trimEnd: $trimEnd,
                        currentTime: currentTime,
                        onSeek: { seek(to: $0) })
                    .frame(height: 64)
            }

            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                Text("\(timeString(currentTime))  /  \(timeString(duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("Trim: \(timeString(trimStart)) – \(timeString(trimEnd))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.yellow)

                Spacer()

                if exporting {
                    ProgressView().controlSize(.small)
                }
                Button("Export GIF") { export(gif: true) }
                    .disabled(exporting)
                Button("Export Trimmed Video") { export(gif: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(exporting)
            }
        }
        .padding(16)
        .task {
            await load()
        }
        .onDisappear {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            player.pause()
        }
    }

    // MARK: - Setup

    private func load() async {
        let asset = AVURLAsset(url: capture.bestURL)
        guard let d = try? await asset.load(.duration).seconds, d > 0 else { return }
        duration = d
        trimEnd = d

        // Playhead updates + stop at the trim end while playing.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
            Task { @MainActor in
                currentTime = time.seconds
                if isPlaying, currentTime >= trimEnd {
                    player.pause()
                    isPlaying = false
                    seek(to: trimEnd)
                }
            }
        }

        // Filmstrip thumbnails.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frames: [NSImage] = []
        let count = 14
        for i in 0..<count {
            let t = d * (Double(i) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                frames.append(cg.nsImage)
            }
        }
        thumbnails = frames
    }

    // MARK: - Playback

    private func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
                seek(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    private func timeString(_ t: Double) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Export

    private func export(gif: Bool) {
        exporting = true
        Task {
            do {
                let trimmedURL = try await trimmedVideo()
                if gif {
                    let gifURL = try await GIFExporter.export(
                        videoURL: trimmedURL,
                        fps: AppServices.shared.settings.gifFPS)
                    try? FileManager.default.removeItem(at: trimmedURL)
                    AppServices.shared.capture.finishFileCapture(tempURL: gifURL, kind: .gif)
                    Toast.show("GIF exported")
                } else {
                    AppServices.shared.capture.finishFileCapture(tempURL: trimmedURL, kind: .video)
                    Toast.show("Trimmed video exported")
                }
            } catch {
                Toast.show("Export failed: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
            }
            exporting = false
        }
    }

    private func trimmedVideo() async throws -> URL {
        let asset = AVURLAsset(url: capture.bestURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Trimmer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create export session."])
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenScreenshot-trim-\(UUID().uuidString).mp4")
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        await session.export()
        if let error = session.error { throw error }
        return outputURL
    }
}

/// Bare AVPlayerLayer host — no built-in controls (the trim bar is the scrubber).
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = CALayer()
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

/// QuickTime-style trim bar: filmstrip of thumbnails, yellow trim window with
/// side handles, dimmed excluded regions, and a draggable playhead.
private struct TrimBar: View {
    let thumbnails: [NSImage]
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let currentTime: Double
    let onSeek: (Double) -> Void

    private let barHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .topLeading) {
                filmstrip(width: width)

                // Dim the cut-off regions.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(x(trimStart, width), 0), height: barHeight)
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(width - x(trimEnd, width), 0), height: barHeight)
                    .offset(x: x(trimEnd, width))

                // Yellow trim window.
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.yellow, lineWidth: 3)
                    .frame(width: max(x(trimEnd, width) - x(trimStart, width), 12), height: barHeight)
                    .offset(x: x(trimStart, width))

                handle(atX: x(trimStart, width) - 7, chevron: "chevron.compact.left") { locationX in
                    trimStart = min(max(time(locationX, width), 0), trimEnd - 0.1)
                    onSeek(trimStart)
                }
                handle(atX: x(trimEnd, width) - 7, chevron: "chevron.compact.right") { locationX in
                    trimEnd = max(min(time(locationX, width), duration), trimStart + 0.1)
                    onSeek(trimEnd)
                }

                // Playhead.
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: barHeight + 8)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: x(currentTime, width) - 1.5, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "trimbar")
            .contentShape(Rectangle())
            // Drag anywhere on the strip to scrub (handles sit on top and win).
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(time(value.location.x, width))
                    }
            )
        }
    }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(t / duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return duration * Double(min(max(x / width, 0), 1))
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: barHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func handle(atX handleX: CGFloat, chevron: String,
                        onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.yellow)
            .frame(width: 14, height: barHeight)
            .overlay(
                Image(systemName: chevron)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.7))
            )
            .offset(x: handleX)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimbar"))
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
    }
}
