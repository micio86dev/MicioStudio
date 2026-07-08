import AVFoundation

/// Captures the default webcam via `AVCaptureSession` and writes `camera.mov` (HEVC).
/// Delivered frames are `'420v'` for direct HW HEVC encoding. Optional: if no camera
/// is present, construction throws and the coordinator records without it.
final class CameraCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.miciodev.camera.video")
    private let writer: SegmentWriter
    private let t0Host: CMTime

    init(clock: RecordingClock, outputDir: URL) throws {
        t0Host = clock.t0Host
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "CameraCapturer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no webcam available"])
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input) else {
            throw NSError(domain: "CameraCapturer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add camera input"])
        }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            throw NSError(domain: "CameraCapturer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add camera output"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        // activeFormat now reflects the preset → use its native dimensions.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        writer = try SegmentWriter(
            url: outputDir.appendingPathComponent("camera.mov"),
            fileType: .mov, mediaType: .video,
            outputSettings: SegmentWriter.hevcVideo(width: Int(dims.width), height: Int(dims.height)))

        super.init()
        // Delegate can only be set after super.init (needs self).
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() {
        session.startRunning()
        // AVCapture PTS are on the session's synchronization clock (may differ from the
        // host clock). Anchor at t0 converted INTO that clock so this track aligns with
        // the SCK streams (SPEC §5.2).
        let syncClock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        writer.setSessionStart(CMSyncConvertTime(t0Host, from: CMClockGetHostTimeClock(), to: syncClock))
    }

    func stopCapture() { session.stopRunning() }
    func finishWriting() async { await writer.finish() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.append(sampleBuffer)
    }
}
