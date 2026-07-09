import AVFoundation
import CoreImage
import Metal

/// Per-instruction data for the custom compositor: the whole template (all scenes), the
/// scene-switch timeline, and which composition tracks feed the screen and each scene's
/// camera layers.
final class TemplateInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let template: TemplateDoc
    let screenTrackID: CMPersistentTrackID
    /// Ordered camera track IDs for each scene's camera layers (index = scene index).
    let sceneCameraTracks: [[CMPersistentTrackID]]
    let timeline: [RecordingCoordinator.SceneSwitch]
    let transitionMs: Double
    let outputSize: CGSize

    init(timeRange: CMTimeRange, template: TemplateDoc, screenTrackID: CMPersistentTrackID,
         sceneCameraTracks: [[CMPersistentTrackID]], timeline: [RecordingCoordinator.SceneSwitch],
         transitionMs: Double, outputSize: CGSize) {
        self.timeRange = timeRange
        self.template = template
        self.screenTrackID = screenTrackID
        self.sceneCameraTracks = sceneCameraTracks
        self.timeline = timeline
        self.transitionMs = transitionMs
        self.outputSize = outputSize
        let allCams = Set(sceneCameraTracks.flatMap { $0 })
        self.requiredSourceTrackIDs = ([screenTrackID] + Array(allCams)).map { NSNumber(value: $0) }
        super.init()
    }

    /// Which scene is showing at `tMs`, the outgoing scene during a transition, the
    /// transition progress (0..1), and the transition kind.
    func resolve(atMs tMs: Double) -> (current: Int, previous: Int?, progress: Double, kind: String) {
        guard !timeline.isEmpty else { return (0, nil, 1, "cut") }
        var idx = 0
        for (i, s) in timeline.enumerated() where Double(s.tMs) <= tMs { idx = i }
        let entry = timeline[idx]
        let current = min(max(entry.sceneIndex, 0), max(template.scenes.count - 1, 0))
        guard idx > 0, entry.transition != "cut", transitionMs > 0 else {
            return (current, nil, 1, entry.transition)
        }
        let elapsed = tMs - Double(entry.tMs)
        if elapsed >= transitionMs { return (current, nil, 1, entry.transition) }
        let prev = min(max(timeline[idx - 1].sceneIndex, 0), max(template.scenes.count - 1, 0))
        return (current, prev, max(0, min(1, elapsed / transitionMs)), entry.transition)
    }
}

/// Custom AVVideoCompositing that renders each output frame by feeding source track
/// frames through TemplateRenderer, picking the active scene from the timeline and
/// blending during transitions.
final class TemplateCompositor: NSObject, AVVideoCompositing {
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()
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
            guard let inst = request.videoCompositionInstruction as? TemplateInstruction,
                  let ctx = self.renderContext, let dest = ctx.newPixelBuffer() else {
                request.finish(with: NSError(domain: "TemplateCompositor", code: 1))
                return
            }
            let screenCI = request.sourceFrame(byTrackID: inst.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let tMs = request.compositionTime.seconds * 1000
            let r = inst.resolve(atMs: tMs)

            let current = self.renderScene(r.current, inst: inst, request: request, screenCI: screenCI)
            var composed = current
            if let prev = r.previous, r.progress < 1 {
                let previous = self.renderScene(prev, inst: inst, request: request, screenCI: screenCI)
                composed = Self.blend(from: previous, to: current, progress: r.progress,
                                      kind: r.kind, canvas: inst.outputSize)
            }
            self.ciContext.render(composed, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }

    private func renderScene(_ index: Int, inst: TemplateInstruction,
                             request: AVAsynchronousVideoCompositionRequest, screenCI: CIImage?) -> CIImage {
        var doc = inst.template
        doc.activeSceneIndex = index
        let tracks = inst.sceneCameraTracks.indices.contains(index) ? inst.sceneCameraTracks[index] : []
        let camerasCI = tracks.compactMap { request.sourceFrame(byTrackID: $0).map { CIImage(cvPixelBuffer: $0) } }
        return TemplateRenderer.render(template: doc, screenCI: screenCI, camerasCI: camerasCI,
                                       outputSize: inst.outputSize)
    }

    /// Blend the outgoing scene into the incoming one for `progress` 0..1.
    static func blend(from prev: CIImage, to cur: CIImage, progress: Double,
                      kind: String, canvas: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let p = CGFloat(progress)
        switch kind {
        case "slide":
            let shifted = cur.transformed(by: CGAffineTransform(translationX: (1 - p) * canvas.width, y: 0))
            return shifted.composited(over: prev).cropped(to: rect)
        case "swipe":
            let reveal = cur.cropped(to: CGRect(x: 0, y: 0, width: p * canvas.width, height: canvas.height))
            return reveal.composited(over: prev)
        default: // fade
            let faded = cur.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)])
            return faded.composited(over: prev)
        }
    }
}

/// Builds the composited video (`composed.mov`) from a session's recorded sources + a
/// template (all scenes) + the scene-switch timeline. The real Phase 3 output.
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
                       timeline: [RecordingCoordinator.SceneSwitch] = [],
                       micVolume: Float = 1, systemVolume: Float = 1,
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

        // Camera tracks, in file order; map their device IDs from sources.json.
        let files = cameraFiles(in: sessionDir)
        let deviceIDs = cameraDeviceIDs(in: sessionDir)
        var deviceToTrack: [String: CMPersistentTrackID] = [:]
        var allCameraTracks: [CMPersistentTrackID] = []
        for (i, name) in files.enumerated() {
            let asset = AVURLAsset(url: sessionDir.appendingPathComponent(name))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let dur = try await asset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(10 + i))!
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, duration)), of: track, at: .zero)
            allCameraTracks.append(comp.trackID)
            if i < deviceIDs.count { deviceToTrack[deviceIDs[i]] = comp.trackID }
        }

        var audioParams: [AVMutableAudioMixInputParameters] = []
        for (name, volume) in [("mic.caf", micVolume), ("system.caf", systemVolume)] {
            let url = sessionDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let dur = try await asset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, duration)), of: track, at: .zero)
            let params = AVMutableAudioMixInputParameters(track: comp)
            params.setVolume(volume, at: .zero)
            audioParams.append(params)
        }

        // For each scene, the ordered camera tracks matching its camera layers (by device;
        // no device → the first camera track).
        let sceneCameraTracks: [[CMPersistentTrackID]] = template.scenes.map { scene in
            scene.layers.filter { $0.kind == .camera }.compactMap { layer -> CMPersistentTrackID? in
                if let d = layer.deviceId, let t = deviceToTrack[d] { return t }
                return allCameraTracks.first
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TemplateCompositor.self
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [TemplateInstruction(
            timeRange: span, template: template, screenTrackID: screenComp.trackID,
            sceneCameraTracks: sceneCameraTracks, timeline: timeline, transitionMs: 500, outputSize: outputSize)]

        let out = sessionDir.appendingPathComponent("composed.mov")
        try? FileManager.default.removeItem(at: out)
        // HEVC1920x1080 is single-pass hardware HEVC — far faster than HighestQuality's
        // multi-pass encode, with negligible quality loss at 1080p.
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw ExportError.noExportSession
        }
        export.videoComposition = videoComposition
        if !audioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
            export.audioMix = mix
        }

        // export(to:as:) reliably runs the export and throws a real error on failure
        // (states(updateInterval:) was leaving the composite stuck at 0%).
        onProgress(0.05)
        try await export.export(to: out, as: .mov)
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

    /// Device IDs in camera-file order, from sources.json.
    static func cameraDeviceIDs(in dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("sources.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cams = obj["cameras"] as? [[String: String]] else { return [] }
        return cams.compactMap { $0["deviceId"] }
    }
}
