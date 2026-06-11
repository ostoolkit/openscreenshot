import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum GIFExporter {
    enum GIFError: LocalizedError {
        case noVideoTrack
        case encodingFailed
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The recording has no video track."
            case .encodingFailed: "GIF encoding failed."
            }
        }
    }

    /// Convert an MP4 into an animated GIF, downsampled for sane file sizes.
    static func export(videoURL: URL, fps: Int, maxWidth: Int = 960) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0,
              let _ = try await asset.loadTracks(withMediaType: .video).first
        else { throw GIFError.noVideoTrack }

        let fps = min(max(fps, 5), 30)
        let frameCount = max(1, Int(duration * Double(fps)))
        let delay = 1.0 / Double(fps)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenScreenshot-\(UUID().uuidString).gif")

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        else { throw GIFError.encodingFailed }

        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ] as CFDictionary

        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            do {
                let image = try await generator.image(at: time).image
                CGImageDestinationAddImage(destination, image, frameProperties)
            } catch {
                continue // skip unreadable frames near the end
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.encodingFailed
        }
        return outputURL
    }
}
