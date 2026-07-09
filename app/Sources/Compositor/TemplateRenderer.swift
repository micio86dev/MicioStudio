import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import Metal
import Vision

/// Phase 3 compositor core: composes the captured sources into one frame per a
/// template (SPEC §6 Phase 3), bottom→top: background (blurred screen / color /
/// image), then framed screen/camera/image layers with rounded corners + shadow.
/// Pure rendering (images in → image out) so it drives BOTH the live editor preview
/// and the video export, and is testable by rendering a single frame.
enum TemplateRenderer {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Render from CGImage sources (editor preview / stills).
    static func render(template: TemplateDoc, screen: CGImage?, cameras: [CGImage],
                       outputSize: CGSize) -> CIImage {
        render(template: template, screenCI: screen.map { CIImage(cgImage: $0) },
               camerasCI: cameras.map { CIImage(cgImage: $0) }, outputSize: outputSize)
    }

    /// Render one composited frame from CIImage sources (video compositor path).
    /// `cameras` are matched to camera layers in order. Missing sources fall back to a
    /// flat placeholder so the layout is still visible.
    static func render(template: TemplateDoc, screenCI: CIImage?, camerasCI: [CIImage],
                       outputSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: outputSize)
        var result = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.06)).cropped(to: canvas)
        let cameras = camerasCI
        var cameraIndex = 0

        for layer in template.layers {
            if layer.hidden == true { continue }   // OBS-style visibility
            switch layer.kind {
            case .background:
                result = background(layer, screen: screenCI, canvas: canvas).composited(over: result)
            case .screen:
                guard let img = screenCI ?? placeholder(.systemBlue, outputSize), let r = layer.rect else { continue }
                result = framed(img, rect: r, cornerRadius: layer.cornerRadius ?? 0,
                                shadow: layer.shadow, mirror: false, fit: layer.fit, canvas: outputSize).composited(over: result)
            case .camera:
                var img = cameraIndex < cameras.count ? cameras[cameraIndex]
                                                      : (placeholder(.systemGreen, outputSize) ?? screenCI ?? CIImage.empty())
                cameraIndex += 1
                if let mode = layer.bgMode, mode != "none" {
                    img = virtualBackground(img, mode: mode, imagePath: layer.bgImage) ?? img
                }
                guard let r = layer.rect else { continue }
                result = framed(img, rect: r, cornerRadius: layer.cornerRadius ?? 0,
                                shadow: layer.shadow, mirror: layer.mirror ?? false, fit: layer.fit, canvas: outputSize).composited(over: result)
            case .image:
                guard let r = layer.rect,
                      let path = layer.path.map({ ($0 as NSString).expandingTildeInPath }),
                      let ns = NSImage(contentsOfFile: path),
                      let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                var img = CIImage(cgImage: cg)
                if let o = layer.opacity, o < 1 { img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(o))]) }
                result = framed(img, rect: r, cornerRadius: 0, shadow: nil, mirror: false, fit: layer.fit, canvas: outputSize).composited(over: result)
            }
        }
        return result
    }

    static func renderCG(template: TemplateDoc, screen: CGImage?, cameras: [CGImage], outputSize: CGSize) -> CGImage? {
        let image = render(template: template, screen: screen, cameras: cameras, outputSize: outputSize)
        return context.createCGImage(image, from: CGRect(origin: .zero, size: outputSize))
    }

    // MARK: - Layers

    private static func background(_ layer: Layer, screen: CIImage?, canvas: CGRect) -> CIImage {
        switch layer.source ?? .color {
        case .color:
            return CIImage(color: ciColor(layer.color ?? "#0B0B0F")).cropped(to: canvas)
        case .screen:
            guard let screen else { return CIImage(color: .black).cropped(to: canvas) }
            let filled = aspectFill(screen, into: canvas)
            let blurred = filled
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": CGFloat(layer.blur ?? 40)])
                .cropped(to: canvas)
            let darken = CGFloat(layer.darken ?? 0.35)
            let veil = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: darken)).cropped(to: canvas)
            return veil.composited(over: blurred)
        case .image:
            guard let path = layer.path.map({ ($0 as NSString).expandingTildeInPath }),
                  let ns = NSImage(contentsOfFile: path),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return CIImage(color: .black).cropped(to: canvas)
            }
            return aspectFill(CIImage(cgImage: cg), into: canvas)
        }
    }

    /// Scale `image` to fill `rect` (aspect fill), round its corners, add a drop shadow.
    /// Template rects are top-left origin; Core Image is bottom-left, so flip Y.
    private static func framed(_ image: CIImage, rect r: RectN, cornerRadius: Double,
                               shadow: ShadowN?, mirror: Bool, fit: String?, canvas: CGSize) -> CIImage {
        let px = CGRect(x: r.x * canvas.width,
                        y: (1 - r.y - r.h) * canvas.height,   // Y flip
                        width: r.w * canvas.width, height: r.h * canvas.height)
        var src = image
        if mirror {
            src = src.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                     .transformed(by: CGAffineTransform(translationX: src.extent.width, y: 0))
        }
        var placed = fit == "contain" ? aspectFit(src, into: px) : aspectFill(src, into: px)
        let radius = CGFloat(cornerRadius)
        if radius > 0 {
            placed = placed.applyingFilter("CISourceInCompositing", parameters: [
                "inputBackgroundImage": roundedMask(px, radius: radius)])
        }
        if let sh = shadow, sh.opacity > 0 {
            let shape = roundedMask(px, radius: radius)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(sh.opacity))])
                .transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(sh.dy)))   // dy: downward
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": CGFloat(sh.radius)])
            return placed.composited(over: shape)
        }
        return placed
    }

    // MARK: - Virtual background (webcam)

    /// Replace the camera background: keep the segmented person, put a blurred version of
    /// the feed (3 intensities) or a cover image behind them. Falls back to nil if
    /// segmentation is unavailable (caller keeps the raw frame).
    private static func virtualBackground(_ image: CIImage, mode: String, imagePath: String?) -> CIImage? {
        guard let mask = personMask(image) else { return nil }
        let ext = image.extent
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))

        let bg: CIImage
        if mode == "image",
           let p = imagePath.map({ ($0 as NSString).expandingTildeInPath }),
           let ns = NSImage(contentsOfFile: p),
           let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            bg = aspectFill(CIImage(cgImage: cg), into: ext)
        } else {
            let radius: CGFloat = mode == "blurStrong" ? 34 : (mode == "blurMedium" ? 18 : 8)
            bg = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                .cropped(to: ext)
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": bg, "inputMaskImage": scaled])
    }

    private static func personMask(_ image: CIImage) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let buffer = req.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    // MARK: - Helpers

    private static func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image.cropped(to: rect) }
        let scale = max(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let tx = rect.midX - s.midX
        let ty = rect.midY - s.midY
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: rect)
    }

    /// Scale to FIT inside `rect` (contain / letterbox), centered — no cropping.
    private static func aspectFit(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image.cropped(to: rect) }
        let scale = min(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - s.midX,
                                                        y: rect.midY - s.midY)).cropped(to: rect)
    }

    private static func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        f.color = CIColor.white
        return f.outputImage ?? CIImage(color: .white).cropped(to: rect)
    }

    private static func placeholder(_ ns: NSColor, _ size: CGSize) -> CIImage? {
        let c = ns.usingColorSpace(.deviceRGB) ?? .gray
        return CIImage(color: CIColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func ciColor(_ hex: String) -> CIColor {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(s, radix: 16) else { return CIColor(red: 0.04, green: 0.04, blue: 0.06) }
        if s.count == 8 {
            return CIColor(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                           blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
        if s.count == 6 {
            return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255)
        }
        return CIColor(red: 0.04, green: 0.04, blue: 0.06)
    }
}
