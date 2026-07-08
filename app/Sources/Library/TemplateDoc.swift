import Foundation

/// Editable Swift mirror of the template JSON (SPEC §3.2). The Rust core remains the
/// source of truth for validation (`normalizeTemplateJson`); this model exists so the
/// SwiftUI editor can bind to fields. A flat `Layer` (kind + optional fields) keeps the
/// UI simple; custom Codable maps to/from the tagged JSON on disk.
struct TemplateDoc: Codable, Equatable {
    var version = 1
    var canvas = CanvasSize(width: 1920, height: 1080)
    var layers: [Layer] = []

    static let `default` = TemplateDoc(version: 1, canvas: .init(width: 1920, height: 1080), layers: [
        Layer(kind: .background, source: .screen, blur: 55, darken: 0.35),
        Layer(kind: .screen, rect: RectN(x: 0.03, y: 0.12, w: 0.72, h: 0.76), cornerRadius: 16,
              shadow: ShadowN(radius: 40, opacity: 0.45, dy: 12)),
        Layer(kind: .camera, rect: RectN(x: 0.77, y: 0.62, w: 0.20, h: 0.26), cornerRadius: 20, mirror: true),
    ])

    func jsonString() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    static func parse(_ json: String) throws -> TemplateDoc {
        try JSONDecoder().decode(TemplateDoc.self, from: Data(json.utf8))
    }
}

struct CanvasSize: Codable, Equatable { var width: Int; var height: Int }
struct RectN: Codable, Equatable { var x: Double; var y: Double; var w: Double; var h: Double }
struct ShadowN: Codable, Equatable { var radius = 0.0; var opacity = 0.0; var dy = 0.0 }

enum LayerKind: String, Codable, CaseIterable, Identifiable {
    case background, screen, camera, image
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum BackgroundSource: String, Codable, CaseIterable, Identifiable {
    case screen, color, image
    var id: String { rawValue }
}

/// One layer, flattened for editing. Only the fields relevant to `kind` are used.
struct Layer: Identifiable, Equatable {
    var id = UUID()
    var kind: LayerKind

    // background
    var source: BackgroundSource?
    var blur: Double?
    var darken: Double?
    var color: String?
    var fit: String?

    // framed (screen / camera / image)
    var rect: RectN?
    var cornerRadius: Double?
    var shadow: ShadowN?
    var mirror: Bool?       // camera
    var path: String?       // image / background image
    var opacity: Double?    // image
}

// MARK: - Tagged Codable (maps the flat model to the `"type"` / `"source"` JSON)

extension Layer: Codable {
    private enum Keys: String, CodingKey {
        case type, source, blur, darken, color, fit
        case rect, cornerRadius, shadow, mirror, path, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decode(LayerKind.self, forKey: .type)
        source = try c.decodeIfPresent(BackgroundSource.self, forKey: .source)
        blur = try c.decodeIfPresent(Double.self, forKey: .blur)
        darken = try c.decodeIfPresent(Double.self, forKey: .darken)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        fit = try c.decodeIfPresent(String.self, forKey: .fit)
        rect = try c.decodeIfPresent(RectN.self, forKey: .rect)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
        shadow = try c.decodeIfPresent(ShadowN.self, forKey: .shadow)
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .type)
        switch kind {
        case .background:
            try c.encodeIfPresent(source, forKey: .source)
            try c.encodeIfPresent(blur, forKey: .blur)
            try c.encodeIfPresent(darken, forKey: .darken)
            try c.encodeIfPresent(color, forKey: .color)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(fit, forKey: .fit)
        case .screen:
            try c.encodeIfPresent(rect, forKey: .rect)
            try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
            try c.encodeIfPresent(shadow, forKey: .shadow)
        case .camera:
            try c.encodeIfPresent(rect, forKey: .rect)
            try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
            try c.encodeIfPresent(mirror, forKey: .mirror)
            try c.encodeIfPresent(shadow, forKey: .shadow)
        case .image:
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(rect, forKey: .rect)
            try c.encodeIfPresent(opacity, forKey: .opacity)
        }
    }
}
