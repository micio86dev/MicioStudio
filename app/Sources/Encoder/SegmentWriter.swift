import AVFoundation

/// Thin `AVAssetWriter` wrapper for a single output file (one video or audio track).
/// NOT thread-safe by design: every method must be called on ONE serial queue —
/// the owning capturer's sample-buffer callback queue. This keeps non-`Sendable`
/// `CMSampleBuffer`s from ever crossing isolation boundaries (Swift 6).
final class SegmentWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// Shared recording origin t0, expressed in THIS track's own sample clock (SPEC
    /// §5.2). All tracks anchor at the same real instant, so their timelines and
    /// durations align even when devices (mic) run on clocks offset from the host.
    /// Set once via `setSessionStart` after the source's clock is known.
    private var sessionStart: CMTime?
    /// When set, the anchor is derived EMPIRICALLY on the first sample: that sample's
    /// PTS is known to have been delivered at "now" on the host clock, so
    /// anchor = firstPTS + (hostOrigin − hostNow). This aligns sources whose sample
    /// clock differs from and is not reliably convertible via synchronizationClock
    /// (the mic's audio device clock). Rate difference over a short clip is negligible.
    private var hostOrigin: CMTime?
    private var started = false
    private(set) var droppedSamples = 0

    init(url: URL, fileType: AVFileType, mediaType: AVMediaType, outputSettings: [String: Any]) throws {
        self.url = url
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

    /// Anchor at `t0` given directly in this track's sample clock (use for SCK, whose
    /// PTS are already on the host clock). Must be called before the first `append`.
    func setSessionStart(_ t0: CMTime) { sessionStart = t0 }

    /// Anchor at the shared host-clock origin `t0`, mapped empirically on the first
    /// sample (use for AVCapture sources on a foreign clock). Before first `append`.
    func setHostOrigin(_ t0: CMTime) { hostOrigin = t0 }

    /// Append a sample. On the first sample the session start is chosen: the empirical
    /// host mapping if `hostOrigin` is set, else `sessionStart`, else this PTS. Samples
    /// that predate the origin are dropped. Also drops under back-pressure.
    func append(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !started {
            let anchor: CMTime
            if let hostOrigin {
                let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
                anchor = CMTimeAdd(pts, CMTimeSubtract(hostOrigin, hostNow))
            } else {
                anchor = sessionStart ?? pts
            }
            sessionStart = anchor
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: anchor)
            started = true
        }
        if let start = sessionStart, pts < start { return } // predates t0 — drop
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
