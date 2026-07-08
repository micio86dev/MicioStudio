import AVFoundation

/// Captures a chosen microphone via `AVCaptureSession` and writes `mic.caf`
/// (48kHz mono LPCM, SPEC §2.2). Reports a 0..1 level for the UI meter.
final class AudioCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dev.miciodev.mic.audio")
    private let writer: SegmentWriter
    private let t0Host: CMTime
    private var sessionStartSet = false

    /// Called on the audio queue with a 0..1 level. Wire to a main-actor UI update.
    var onLevel: (@Sendable (Float) -> Void)?

    init(clock: RecordingClock, device: AVCaptureDevice, outputDir: URL) throws {
        t0Host = clock.t0Host
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            throw NSError(domain: "AudioCapturer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add mic input"])
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "AudioCapturer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add mic output"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        writer = try SegmentWriter(
            url: outputDir.appendingPathComponent("mic.caf"),
            fileType: .caf, mediaType: .audio,
            outputSettings: SegmentWriter.pcmAudio48k(channels: 1))

        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() { session.startRunning() }
    func stopCapture() { session.stopRunning() }
    func finishWriting() async { await writer.finish() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !sessionStartSet {
            sessionStartSet = true
            // Anchor at the first sample, when synchronizationClock is reliably valid
            // (it can be nil right after startRunning). Convert t0 into this session's
            // clock so mic.caf aligns with the host-clock streams (SPEC §5.2).
            let host = CMClockGetHostTimeClock()
            let syncClock = session.synchronizationClock ?? host
            writer.setSessionStart(CMSyncConvertTime(t0Host, from: host, to: syncClock))
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            NSLog("[mic-sync] syncClock=\(session.synchronizationClock == nil ? "nil" : "set") firstPTS=\(pts) hostNow=\(CMClockGetTime(host).seconds) t0Host=\(t0Host.seconds)")
        }
        onLevel?(AudioLevel.rms(from: sampleBuffer))
        writer.append(sampleBuffer)
    }
}
