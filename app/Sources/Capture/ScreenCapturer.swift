import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Captures the display at NATIVE pixel resolution via ScreenCaptureKit and writes
/// `screen.mov` (HEVC) + `system.caf` (48kHz). `showsCursor = false` — the cursor is
/// drawn by us later (SPEC §2.1). Pixel format `'420v'` feeds the HW HEVC encoder
/// without a BGRA→YUV copy, halving per-frame bytes (memory-critical at 2×, §2.1/§10).
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let displayID: CGDirectDisplayID

    private var stream: SCStream!
    private let videoWriter: SegmentWriter
    private let audioWriter: SegmentWriter
    private let videoQueue = DispatchQueue(label: "dev.miciodev.screen.video")
    private let audioQueue = DispatchQueue(label: "dev.miciodev.screen.audio")

    init(display: SCDisplay, clock: RecordingClock, outputDir: URL) throws {
        displayID = display.displayID
        // True native Retina pixels (SCDisplay.width/height are in points).
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        pixelWidth = mode?.pixelWidth ?? display.width
        pixelHeight = mode?.pixelHeight ?? display.height

        videoWriter = try SegmentWriter(
            url: outputDir.appendingPathComponent("screen.mov"),
            fileType: .mov, mediaType: .video,
            outputSettings: SegmentWriter.hevcVideo(width: pixelWidth, height: pixelHeight),
            sessionStart: clock.t0Host)
        audioWriter = try SegmentWriter(
            url: outputDir.appendingPathComponent("system.caf"),
            fileType: .caf, mediaType: .audio,
            outputSettings: SegmentWriter.pcmAudio48k(channels: 2),
            sessionStart: clock.t0Host)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // '420v'
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps dev loop
        config.queueDepth = 6

        super.init()

        // The delegate is set only via the initializer, which needs self.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
    }

    func start() async throws { try await stream.startCapture() }

    func stop() async {
        try? await stream.stopCapture()
        await videoWriter.finish()
        await audioWriter.finish()
    }

    // MARK: SCStreamOutput — screen frames on videoQueue, audio on audioQueue.
    // Each writer is touched by exactly one queue, so no synchronization is needed.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard isCompleteFrame(sampleBuffer) else { return } // skip idle/blank frames
            videoWriter.append(sampleBuffer)
        case .audio:
            audioWriter.append(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ScreenCapturer] stopped with error: \(error.localizedDescription)")
    }

    /// Only append frames the compositor marked `.complete` — idle frames carry no
    /// new pixels and would otherwise write blank/duplicate content.
    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
