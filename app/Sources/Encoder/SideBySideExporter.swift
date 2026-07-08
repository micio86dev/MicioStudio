import AVFoundation

/// Post-processes the separate capture streams into a single side-by-side HEVC
/// (screen | camera + mixed audio) → `combined.mov`.
///
/// This file is a THROWAWAY verification artifact for the Phase 1 gate (SPEC §7),
/// NOT a product feature — the authoritative native-pixel sharpness lives in
/// `screen.mov`; `combined.mov` only needs to show that audio and video stay in
/// sync. Because it is throwaway and quality-non-critical, it uses the compact
/// `AVAssetExportSession` + `AVMutableVideoComposition` path rather than a
/// hand-rolled AVAssetReader/Writer pipeline. Screen is required; camera and each
/// audio track are optional.
enum SideBySideExporter {
    enum ExportError: LocalizedError {
        case missingScreen
        case noExportSession
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingScreen: return "screen.mov not found"
            case .noExportSession: return "could not create export session"
            case .failed(let m): return "export failed: \(m)"
            }
        }
    }

    static func export(sessionDir: URL,
                       renderSize: CGSize = CGSize(width: 1920, height: 1080)) async throws -> URL {
        let outURL = sessionDir.appendingPathComponent("combined.mov")
        try? FileManager.default.removeItem(at: outURL)

        let composition = AVMutableComposition()

        // --- screen (required) → left half ---
        let screenAsset = AVURLAsset(url: sessionDir.appendingPathComponent("screen.mov"))
        guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.missingScreen
        }
        let duration = try await screenAsset.load(.duration)
        let span = CMTimeRange(start: .zero, duration: duration)

        guard let screenComp = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("could not add screen track")
        }
        try screenComp.insertTimeRange(span, of: screenVideo, at: .zero)

        let half = renderSize.width / 2
        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenComp)
        let screenSize = try await screenVideo.load(.naturalSize)
        screenLayer.setTransform(
            fitTransform(from: screenSize, into: CGRect(x: 0, y: 0, width: half, height: renderSize.height)),
            at: .zero)
        var layers = [screenLayer]

        // --- camera (optional) → right half ---
        let cameraURL = sessionDir.appendingPathComponent("camera.mov")
        if FileManager.default.fileExists(atPath: cameraURL.path) {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraVideo = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let camComp = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let camDur = try await cameraAsset.load(.duration)
                try camComp.insertTimeRange(
                    CMTimeRange(start: .zero, duration: min(camDur, duration)), of: cameraVideo, at: .zero)
                let camLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: camComp)
                let camSize = try await cameraVideo.load(.naturalSize)
                camLayer.setTransform(
                    fitTransform(from: camSize, into: CGRect(x: half, y: 0, width: half, height: renderSize.height)),
                    at: .zero)
                layers.append(camLayer)
            }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = span
        instruction.layerInstructions = layers

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        // --- audio (mic + system, both optional) — played together = mixed ---
        for name in ["mic.caf", "system.caf"] {
            let url = sessionDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let comp = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let dur = try await asset.load(.duration)
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, duration)), of: track, at: .zero)
        }

        // --- export HEVC ---
        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.noExportSession
        }
        export.videoComposition = videoComposition
        try await export.export(to: outURL, as: .mov)
        return outURL
    }

    /// Aspect-fit `natural` into `rect` and center it. For non-overlapping halves the
    /// video-composition Y-origin convention is irrelevant (full-height, centered).
    private static func fitTransform(from natural: CGSize, into rect: CGRect) -> CGAffineTransform {
        guard natural.width > 0, natural.height > 0 else { return .identity }
        let scale = min(rect.width / natural.width, rect.height / natural.height)
        let scaledW = natural.width * scale
        let scaledH = natural.height * scale
        let tx = rect.origin.x + (rect.width - scaledW) / 2
        let ty = rect.origin.y + (rect.height - scaledH) / 2
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }
}
