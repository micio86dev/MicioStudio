import AVFoundation
import CoreImage
import Metal

/// Layout of one clip for the compositor: where it sits on the timeline, its track, and
/// the transition entering it.
struct ClipLayout {
    let start: Double
    let duration: Double
    let trackID: CMPersistentTrackID
    let transition: String
    let overlap: Double
}

final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    // Protocol-mandated [NSValue]? isn't Sendable, but it's an immutable `let` of immutable
    // NSNumbers set once in init — safe to share across the compositor's queues.
    nonisolated(unsafe) let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layout: [ClipLayout]
    let renderSize: CGSize

    init(timeRange: CMTimeRange, layout: [ClipLayout], renderSize: CGSize) {
        self.timeRange = timeRange
        self.layout = layout
        self.renderSize = renderSize
        self.requiredSourceTrackIDs = Set(layout.map { $0.trackID }).map { NSNumber(value: $0) }
        super.init()
    }

    /// Active clip at `t`, and (during a transition overlap) the outgoing clip + progress.
    func resolve(atSeconds t: Double) -> (cur: ClipLayout, prev: ClipLayout?, progress: Double)? {
        var current: ClipLayout?
        var previous: ClipLayout?
        for (i, c) in layout.enumerated() where c.start <= t + 0.0001 {
            current = c
            previous = i > 0 ? layout[i - 1] : nil
        }
        guard let cur = current else { return nil }
        if let prev = previous, cur.transition != "cut", cur.overlap > 0, t < cur.start + cur.overlap {
            return (cur, prev, max(0, min(1, (t - cur.start) / cur.overlap)))
        }
        return (cur, nil, 1)
    }
}

final class TimelineCompositor: NSObject, AVVideoCompositing {
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()
    nonisolated(unsafe) private var renderContext: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "dev.miciodev.timeline")

    // Protocol requires only { get }; these never change, so `let` avoids the mutable-stored-
    // property warning on this Sendable-conforming class.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let inst = request.videoCompositionInstruction as? TimelineInstruction,
                  let ctx = self.renderContext, let dest = ctx.newPixelBuffer(),
                  let r = inst.resolve(atSeconds: request.compositionTime.seconds) else {
                request.finish(with: NSError(domain: "TimelineCompositor", code: 1))
                return
            }
            func frame(_ id: CMPersistentTrackID) -> CIImage? {
                request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) }
            }
            let cur = frame(r.cur.trackID) ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: inst.renderSize))
            var composed = cur
            if let prev = r.prev, let prevImg = frame(prev.trackID), r.progress < 1 {
                composed = TemplateCompositor.blend(from: prevImg, to: cur, progress: r.progress,
                                                    kind: r.cur.transition, canvas: inst.renderSize)
            }
            self.ciContext.render(composed, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }
}

enum TimelineExporter {
    enum ExportError: LocalizedError {
        case noVideoTrack, noExportSession, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "source has no video track"
            case .noExportSession: return "could not create export session"
            case .failed(let m): return m
            }
        }
    }

    /// Build the AVComposition + AVVideoComposition for the current timeline. Used by both
    /// the live preview (AVPlayerItem) and the export.
    @MainActor
    static func build(_ model: TimelineModel) async throws -> (AVComposition, AVVideoComposition) {
        let asset = AVURLAsset(url: model.sourceURL)
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await srcVideo.load(.naturalSize)
        let renderSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))

        guard renderSize.width > 0 && renderSize.height > 0 else { throw ExportError.noVideoTrack }

        let composition = AVMutableComposition()
        // Two alternating video tracks so transition overlaps render on separate tracks.
        // Single audio track: audio for clip i starts after its incoming transition ends,
        // so clips never overlap in the audio timeline → no doubling or desync.
        guard let vt1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1),
              let vt2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2) else {
            throw ExportError.noVideoTrack
        }
        let vTracks = [vt1, vt2]
        let audioTrack = srcAudio == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)

        let scale: CMTimeScale = 48_000   // exact for 48kHz audio and 30fps video
        var layout: [ClipLayout] = []
        let clips = model.clips
        // Overlaps are computed locally here — the display model uses 0 overlap so clips
        // don't shift in the timeline (CapCut style). The export composition still crossfades
        // by borrowing transitionDuration/2 frames from each adjacent clip.
        var exportCursor = 0.0
        for i in clips.indices {
            let c = clips[i]
            let overlapBefore: Double
            if i > 0, c.transitionIn != "cut" {
                overlapBefore = min(model.transitionDuration,
                                    min(clips[i - 1].duration, c.duration) / 2)
            } else {
                overlapBefore = 0
            }
            let compStartSec = exportCursor - overlapBefore
            let compStart = CMTime(seconds: compStartSec, preferredTimescale: scale)
            let videoRange = CMTimeRange(start: CMTime(seconds: c.sourceStart, preferredTimescale: scale),
                                        duration: CMTime(seconds: c.duration, preferredTimescale: scale))
            try vTracks[i % 2].insertTimeRange(videoRange, of: srcVideo, at: compStart)

            // Audio: skip the incoming transition overlap to avoid doubling.
            if let srcAudio, let at = audioTrack {
                let audioSrcStart = c.sourceStart + overlapBefore
                let audioDuration = c.duration - overlapBefore
                if audioDuration > 0 {
                    let audioCompStart = CMTime(seconds: compStartSec + overlapBefore, preferredTimescale: scale)
                    let audioRange = CMTimeRange(
                        start: CMTime(seconds: audioSrcStart, preferredTimescale: scale),
                        duration: CMTime(seconds: audioDuration, preferredTimescale: scale))
                    try? at.insertTimeRange(audioRange, of: srcAudio, at: audioCompStart)
                }
            }

            layout.append(ClipLayout(start: compStartSec, duration: c.duration,
                                     trackID: vTracks[i % 2].trackID, transition: c.transitionIn,
                                     overlap: overlapBefore))
            exportCursor = compStartSec + c.duration
        }

        let exportDuration = max(exportCursor, 0.1)
        let total = CMTime(seconds: exportDuration, preferredTimescale: scale)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TimelineCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [TimelineInstruction(
            timeRange: CMTimeRange(start: .zero, duration: total), layout: layout, renderSize: renderSize)]

        return (composition, videoComposition)
    }

    /// Single-track composition for live preview — no custom compositor, no requiredSourceTrackIDs
    /// conflicts. Clips are simply concatenated; seeking uses previewTime(for:) to convert from
    /// the model's timeline time (which accounts for transition overlaps) to this flat timeline.
    @MainActor
    static func buildPreview(_ model: TimelineModel) async throws -> AVComposition {
        let asset = AVURLAsset(url: model.sourceURL)
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let vt = composition.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: 1) else {
            throw ExportError.noVideoTrack
        }
        let at = srcAudio == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
        let scale: CMTimeScale = 48_000
        var cursor = CMTime.zero
        for clip in model.clips {
            let range = CMTimeRange(
                start:    CMTime(seconds: clip.sourceStart, preferredTimescale: scale),
                duration: CMTime(seconds: clip.duration,    preferredTimescale: scale))
            try vt.insertTimeRange(range, of: srcVideo, at: cursor)
            if let srcAudio, let at {
                try? at.insertTimeRange(range, of: srcAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return composition
    }

    @MainActor
    static func export(_ model: TimelineModel, to out: URL,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (composition, videoComposition) = try await build(model)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.noExportSession
        }
        export.videoComposition = videoComposition
        onProgress(0.05)
        try await export.export(to: out, as: .mov)
        onProgress(1.0)
        return out
    }
}
