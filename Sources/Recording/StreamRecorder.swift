import AVFoundation
import ScreenCaptureKit

/// SCStream -> AVAssetWriter pipeline producing an MP4 (H.264 + AAC).
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let outputURL: URL

    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private let videoQueue = DispatchQueue(label: "openscreenshot.record.video")
    private let audioQueue = DispatchQueue(label: "openscreenshot.record.audio")
    private let micQueue = DispatchQueue(label: "openscreenshot.record.mic")

    private var sessionStarted = false
    private var sessionStartTime: CMTime?
    private var stopped = false
    var onStreamError: ((Error) -> Void)?

    init(filter: SCContentFilter,
         configuration: SCStreamConfiguration,
         outputURL: URL,
         recordSystemAudio: Bool,
         recordMicrophone: Bool,
         fps: Int) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = configuration.width
        let height = configuration.height
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * 0.1))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        if recordSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudioInput = input
        }
        if recordMicrophone, #available(macOS 15.0, *) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micInput = input
        }

        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if recordSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if recordMicrophone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "StreamRecorder", code: 1)
        }
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        stopped = true
        try? await stream.stopCapture()
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "StreamRecorder", code: 2)
        }
        return outputURL
    }

    /// Best-effort synchronous teardown for app termination.
    func stopBestEffort() {
        stopped = true
        stream.stopCapture { _ in }
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        writer.finishWriting {}
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Only append fully rendered frames.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete
            else { return }

            if !sessionStarted {
                sessionStarted = true
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                sessionStartTime = pts
                writer.startSession(atSourceTime: pts)
            }
            if writer.status == .writing, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }

        case .audio:
            append(sampleBuffer, to: systemAudioInput)

        case .microphone:
            append(sampleBuffer, to: micInput)

        @unknown default:
            break
        }

        if writer.status == .failed {
            NSLog("AVAssetWriter failed: \(String(describing: writer.error))")
        }
    }

    /// Audio buffers can arrive timestamped before the first complete video
    /// frame; appending those fails the whole writer ("first recording
    /// failed" syndrome). Drop anything earlier than the session start.
    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted,
              writer.status == .writing,
              let start = sessionStartTime,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start,
              let input, input.isReadyForMoreMediaData
        else { return }
        input.append(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        onStreamError?(error)
    }
}
