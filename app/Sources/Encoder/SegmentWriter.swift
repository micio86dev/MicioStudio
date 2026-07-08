import AVFoundation

/// Thin `AVAssetWriter` wrapper for a single output file (one video or audio track).
/// NOT thread-safe by design: every method must be called on ONE serial queue —
/// the owning capturer's sample-buffer callback queue. This keeps non-`Sendable`
/// `CMSampleBuffer`s from ever crossing isolation boundaries (Swift 6).
final class SegmentWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// Shared timeline origin (= t0 host time). Anchoring every track here means
    /// screen/camera/mic/system and events.jsonl all share ONE origin (SPEC §5.2).
    private let sessionStart: CMTime
    private var started = false
    private(set) var droppedSamples = 0

    init(url: URL, fileType: AVFileType, mediaType: AVMediaType, outputSettings: [String: Any], sessionStart: CMTime) throws {
        self.url = url
        self.sessionStart = sessionStart
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings)
        // Real-time source: honor back-pressure instead of buffering (memory-critical
        // at native 2× on 8GB — SPEC §10).
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "SegmentWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add \(mediaType.rawValue) input for \(url.lastPathComponent)"])
        }
        writer.add(input)
    }

    /// Append a sample. Starts the writer session on the first sample using its PTS,
    /// so every track shares the same source-time origin. Drops samples when the
    /// input isn't ready (back-pressure) rather than growing memory.
    func append(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sessionStart)
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            droppedSamples += 1
            return
        }
        input.append(sample)
    }

    /// Finish writing and flush the file. Safe to call even if nothing was written.
    func finish() async {
        guard started else { return }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
    }

    // MARK: - Output-settings factories

    /// Hardware HEVC video at the given pixel dimensions. Bitrate tuning is Phase 5;
    /// Phase 1 lets VideoToolbox pick a sensible quality.
    static func hevcVideo(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }

    /// 48kHz 16-bit LPCM audio (SPEC §2.2). LPCM keeps mixing trivial at export.
    static func pcmAudio48k(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
