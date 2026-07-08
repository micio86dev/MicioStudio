import AVFoundation
import CoreImage
import Metal

/// Per-instruction data for the custom compositor: which template, and which composition
/// track feeds the screen vs. each camera layer.
final class TemplateInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let template: TemplateDoc
    let screenTrackID: CMPersistentTrackID
    let cameraTrackIDs: [CMPersistentTrackID]
    let outputSize: CGSize

    init(timeRange: CMTimeRange, template: TemplateDoc, screenTrackID: CMPersistentTrackID,
         cameraTrackIDs: [CMPersistentTrackID], outputSize: CGSize) {
        self.timeRange = timeRange
        self.template = template
        self.screenTrackID = screenTrackID
        self.cameraTrackIDs = cameraTrackIDs
        self.outputSize = outputSize
        self.requiredSourceTrackIDs = ([screenTrackID] + cameraTrackIDs).map { NSNumber(value: $0) }
        super.init()
    }
}

/// Custom AVVideoCompositing that renders each output frame by feeding the source track
/// frames through TemplateRenderer.
final class TemplateCompositor: NSObject, AVVideoCompositing {
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()
    // Accessed only via `queue`; the synchronization is manual (hence nonisolated(unsafe)).
    nonisolated(unsafe) private var renderContext: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "dev.miciodev.compositor")

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? TemplateInstruction,
                  let ctx = self.renderContext, let dest = ctx.newPixelBuffer() else {
                request.finish(with: NSError(domain: "TemplateCompositor", code: 1))
                return
            }
            let screenCI = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let camerasCI = instruction.cameraTrackIDs.compactMap {
                request.sourceFrame(byTrackID: $0).map { CIImage(cvPixelBuffer: $0) }
            }
            let composed = TemplateRenderer.render(
                template: instruction.template, screenCI: screenCI, camerasCI: camerasCI,
                outputSize: instruction.outputSize)
            self.ciContext.render(composed, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }
}

/// Builds the composited video (`composed.mov`) from a session's recorded sources + a
/// template, via the custom compositor. This is the real Phase 3 output.
enum TemplateVideoExporter {
    enum ExportError: LocalizedError {
        case missingScreen, noExportSession, failed(String)
        var errorDescription: String? {
            switch self {
            case .missingScreen: return "screen.mov not found"
            case .noExportSession: return "could not create export session"
            case .failed(let m): return m
            }
        }
    }

    static func export(sessionDir: URL, template: TemplateDoc,
                       outputSize: CGSize = CGSize(width: 1920, height: 1080),
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let composition = AVMutableComposition()

        let screenAsset = AVURLAsset(url: sessionDir.appendingPathComponent("screen.mov"))
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.missingScreen
        }
        let duration = try await screenAsset.load(.duration)
        let span = CMTimeRange(start: .zero, duration: duration)

        let screenComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        try screenComp.insertTimeRange(span, of: screenTrack, at: .zero)

        var cameraTrackIDs: [CMPersistentTrackID] = []
        for (i, name) in cameraFiles(in: sessionDir).enumerated() {
            let asset = AVURLAsset(url: sessionDir.appendingPathComponent(name))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let dur = try await asset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(10 + i))!
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, duration)), of: track, at: .zero)
            cameraTrackIDs.append(comp.trackID)
        }

        for name in ["mic.caf", "system.caf"] {
            let url = sessionDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let dur = try await asset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, duration)), of: track, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TemplateCompositor.self
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [TemplateInstruction(
            timeRange: span, template: template, screenTrackID: screenComp.trackID,
            cameraTrackIDs: cameraTrackIDs, outputSize: outputSize)]

        let out = sessionDir.appendingPathComponent("composed.mov")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.noExportSession
        }
        export.videoComposition = videoComposition

        for try await state in export.states(updateInterval: 0.25) {
            if case .exporting(let progress) = state { onProgress(progress.fractionCompleted) }
        }
        guard export.status == .completed else {
            throw ExportError.failed(export.error?.localizedDescription ?? "export failed")
        }
        onProgress(1.0)
        return out
    }

    /// camera.mov, then camera-1.mov, camera-2.mov, … in order.
    static func cameraFiles(in dir: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("camera.mov").path) else { return [] }
        var files = ["camera.mov"]
        var i = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("camera-\(i).mov").path) {
            files.append("camera-\(i).mov")
            i += 1
        }
        return files
    }
}
