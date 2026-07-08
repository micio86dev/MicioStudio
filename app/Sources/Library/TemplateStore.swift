import Foundation

/// Phase 2: reads/writes templates through the Rust core's SQLite `Library`, and
/// validates template documents via the core (`normalizeTemplateJson`). Proves the
/// core owns persistence + validation; the editor UI builds on this.
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [TemplateRow] = []
    @Published private(set) var error: String?

    private var library: Library?

    func load() {
        do {
            let lib = try library ?? Self.openLibrary()
            library = lib
            if try lib.listTemplates().isEmpty {
                try seedBuiltins(into: lib)
            }
            templates = try lib.listTemplates()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func seedBuiltins(into lib: Library) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // normalize = parse + validate + pretty-print in the core; throws if invalid.
        let definition = try normalizeTemplateJson(json: Self.floatingScreenJSON)
        try lib.upsertTemplate(row: TemplateRow(
            id: "builtin-floating-screen",
            name: "Floating Screen",
            definition: definition,
            isBuiltin: true,
            createdAt: now,
            updatedAt: now))
    }

    private static func openLibrary() throws -> Library {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(Config.productName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Library.open(path: dir.appendingPathComponent("library.sqlite").path)
    }

    /// The default built-in template (SPEC §3.2 shape).
    static let floatingScreenJSON = """
    {
      "version": 1,
      "canvas": { "width": 1920, "height": 1080 },
      "layers": [
        { "type": "background", "source": "screen", "blur": 55, "darken": 0.35 },
        { "type": "screen", "rect": { "x": 0.03, "y": 0.12, "w": 0.72, "h": 0.76 },
          "cornerRadius": 16, "shadow": { "radius": 40, "opacity": 0.45, "dy": 12 } },
        { "type": "camera", "rect": { "x": 0.77, "y": 0.62, "w": 0.20, "h": 0.26 },
          "cornerRadius": 20, "mirror": true }
      ]
    }
    """
}
