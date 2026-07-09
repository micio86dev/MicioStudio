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
    let requiredSourceTrackIDs: [NSValue]?
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

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
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

        let composition = AVMutableComposition()
        // Two alternating video + audio tracks so transition overlaps don't collide.
        let vTracks = [composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!,
                       composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!]
        let aTracks = srcAudio == nil ? [] : [
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)!,
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 4)!]

        let scale: CMTimeScale = 600
        var layout: [ClipLayout] = []
        let clips = model.clips
        for i in clips.indices {
            let c = clips[i]
            let track = vTracks[i % 2]
            let at = CMTime(seconds: model.start(of: i), preferredTimescale: scale)
            let range = CMTimeRange(start: CMTime(seconds: c.sourceStart, preferredTimescale: scale),
                                    duration: CMTime(seconds: c.duration, preferredTimescale: scale))
            try track.insertTimeRange(range, of: srcVideo, at: at)
            if let srcAudio, !aTracks.isEmpty {
                try? aTracks[i % 2].insertTimeRange(range, of: srcAudio, at: at)
            }
            layout.append(ClipLayout(start: model.start(of: i), duration: c.duration,
                                     trackID: track.trackID, transition: c.transitionIn,
                                     overlap: model.overlap(before: i)))
        }

        let total = CMTime(seconds: max(model.totalDuration, 0.1), preferredTimescale: scale)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TimelineCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [TimelineInstruction(
            timeRange: CMTimeRange(start: .zero, duration: total), layout: layout, renderSize: renderSize)]

        return (composition, videoComposition)
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
