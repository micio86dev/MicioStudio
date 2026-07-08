import AVFoundation

/// Captures a chosen microphone via `AVCaptureSession` and writes `mic.caf`
/// (48kHz mono LPCM, SPEC §2.2). Reports a 0..1 level for the UI meter.
final class AudioCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dev.miciodev.mic.audio")
    private let writer: SegmentWriter
    private let t0Host: CMTime
    private let debugURL: URL
    private var sessionStartSet = false

    /// Called on the audio queue with a 0..1 level. Wire to a main-actor UI update.
    var onLevel: (@Sendable (Float) -> Void)?

    init(clock: RecordingClock, device: AVCaptureDevice, outputDir: URL) throws {
        t0Host = clock.t0Host
        debugURL = outputDir.appendingPathComponent("sync-debug.txt")
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
        // Deliver already-converted 16-bit mono 48kHz LPCM. Without this the device's
        // native format (typically 32-bit float) reached the 16-bit writer and was
        // written as broadband NOISE (float bytes reinterpreted as int16).
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        session.commitConfiguration()

        writer = try SegmentWriter(
            url: outputDir.appendingPathComponent("mic.caf"),
            fileType: .caf, mediaType: .audio,
            outputSettings: SegmentWriter.pcmAudio48k(channels: 1))
        // The mic clock is the audio device clock; anchor via the empirical host mapping.
        writer.setHostOrigin(clock.t0Host)

        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() { session.startRunning() }
    func stopCapture() { session.stopRunning() }
    func finishWriting() async { await writer.finish() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !sessionStartSet {
            sessionStartSet = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let line = "mic firstPTS=\(pts) hostNow=\(hostNow) t0Host=\(t0Host.seconds) syncClock=\(session.synchronizationClock == nil ? "nil" : "set")\n"
            try? line.data(using: .utf8)?.write(to: debugURL)
        }
        onLevel?(AudioLevel.rms(from: sampleBuffer))
        writer.append(sampleBuffer)
    }
}
