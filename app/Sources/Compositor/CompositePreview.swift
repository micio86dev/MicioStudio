import SwiftUI
import AVFoundation

/// Loads still frames from a recording session to feed the compositor preview.
@MainActor
final class PreviewSources: ObservableObject {
    @Published var screen: CGImage?
    @Published var cameras: [CGImage] = []
    private var loadedDir: URL?

    func load(from sessionDir: URL?) {
        guard let dir = sessionDir, dir != loadedDir else { return }
        loadedDir = dir
        Task { @MainActor in
            screen = await Self.firstFrame(dir.appendingPathComponent("screen.mov"))
            var cams: [CGImage] = []
            if let c = await Self.firstFrame(dir.appendingPathComponent("camera.mov")) { cams.append(c) }
            var i = 1
            while true {
                let url = dir.appendingPathComponent("camera-\(i).mov")
                guard FileManager.default.fileExists(atPath: url.path), let c = await Self.firstFrame(url) else { break }
                cams.append(c)
                i += 1
            }
            cameras = cams
        }
    }

    private static func firstFrame(_ url: URL) async -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}

/// Renders the composited template (via TemplateRenderer). Missing sources fall back
/// to placeholders, so the layout is visible even without a recording.
struct CompositePreview: View {
    let doc: TemplateDoc
    @ObservedObject var sources: PreviewSources

    var body: some View {
        let size = CGSize(width: 1280, height: 720)
        Group {
            if let cg = TemplateRenderer.renderCG(template: doc, screen: sources.screen,
                                                  cameras: sources.cameras, outputSize: size) {
                Image(decorative: cg, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                Color.black.aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
