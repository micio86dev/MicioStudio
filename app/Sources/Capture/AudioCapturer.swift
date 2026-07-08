import AVFoundation

/// Captures the default microphone via `AVCaptureSession` and writes `mic.caf`
/// (48kHz mono LPCM, SPEC §2.2). Kept separate from system audio so tracks can be
/// mixed at export, not at capture.
final class AudioCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dev.miciodev.mic.audio")
    private let writer: SegmentWriter
    private let t0Host: CMTime

    init(clock: RecordingClock, outputDir: URL) throws {
        t0Host = clock.t0Host
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "AudioCapturer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone available"])
        }
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

    func start() {
        session.startRunning()
        // The mic session's clock is typically the audio device clock, offset from the
        // host clock. Anchor at t0 converted into that clock so mic.caf aligns with the
        // screen (SPEC §5.2) — this is the fix for the multi-second mic drift.
        let syncClock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        writer.setSessionStart(CMSyncConvertTime(t0Host, from: CMClockGetHostTimeClock(), to: syncClock))
    }

    func stopCapture() { session.stopRunning() }
    func finishWriting() async { await writer.finish() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.append(sampleBuffer)
    }
}
