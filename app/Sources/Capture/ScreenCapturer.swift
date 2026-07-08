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
    private var loggedFirstFrame = false

    /// Called on the audio queue with a 0..1 system-audio level for the UI meter.
    var onSystemLevel: (@Sendable (Float) -> Void)?

    /// Capture a whole display at native pixels.
    convenience init(display: SCDisplay, clock: RecordingClock, outputDir: URL) throws {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let w = mode?.pixelWidth ?? display.width
        let h = mode?.pixelHeight ?? display.height
        try self.init(filter: SCContentFilter(display: display, excludingWindows: []),
                      width: w, height: h, displayID: display.displayID, clock: clock, outputDir: outputDir)
    }

    /// Capture a single application window (e.g. a Chrome tab). Its audio is still picked
    /// up via the system-audio track.
    convenience init(window: SCWindow, clock: RecordingClock, outputDir: URL) throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let w = Int((filter.contentRect.width * scale).rounded())
        let h = Int((filter.contentRect.height * scale).rounded())
        try self.init(filter: filter, width: max(w, 2), height: max(h, 2),
                      displayID: CGMainDisplayID(), clock: clock, outputDir: outputDir)
    }

    private init(filter: SCContentFilter, width: Int, height: Int, displayID: CGDirectDisplayID,
                 clock: RecordingClock, outputDir: URL) throws {
        self.displayID = displayID
        // HEVC/'420v' needs even dimensions.
        pixelWidth = width - (width % 2)
        pixelHeight = height - (height % 2)

        videoWriter = try SegmentWriter(
            url: outputDir.appendingPathComponent("screen.mov"),
            fileType: .mov, mediaType: .video,
            outputSettings: SegmentWriter.hevcVideo(width: pixelWidth, height: pixelHeight))
        audioWriter = try SegmentWriter(
            url: outputDir.appendingPathComponent("system.caf"),
            fileType: .caf, mediaType: .audio,
            outputSettings: SegmentWriter.pcmAudio48k(channels: 2))
        // SCK sample PTS are already on the host-time clock, so t0 needs no conversion.
        videoWriter.setSessionStart(clock.t0Host)
        audioWriter.setSessionStart(clock.t0Host)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // '420v'
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false // capture the soundboard's own playback too
        config.sampleRate = 48_000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps dev loop
        config.queueDepth = 6

        super.init()

        // The delegate is set only via the initializer, which needs self.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
    }

    func start() async throws { try await stream.startCapture() }

    /// Stop capture delivery (fast). Separated from finalization so the coordinator
    /// can stop every stream near-simultaneously before any writer is flushed.
    func stopCapture() async { try? await stream.stopCapture() }

    /// Flush and close the output files. Call after stopCapture().
    func finishWriting() async {
        await videoWriter.finish()
        await audioWriter.finish()
    }

    // MARK: SCStreamOutput — screen frames on videoQueue, audio on audioQueue.
    // Each writer is touched by exactly one queue, so no synchronization is needed.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Append any frame carrying pixels (including .idle repeats) so the screen
            // is recorded continuously from t0 — skipping idle frames made screen.mov
            // start at the first on-screen change, misaligning it from the audio.
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            if !loggedFirstFrame {
                loggedFirstFrame = true
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                NSLog("[screen-sync] firstFramePTS=\(pts) hostNow=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds)")
            }
            videoWriter.append(sampleBuffer)
        case .audio:
            onSystemLevel?(AudioLevel.rms(from: sampleBuffer))
            audioWriter.append(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ScreenCapturer] stopped with error: \(error.localizedDescription)")
    }
}
