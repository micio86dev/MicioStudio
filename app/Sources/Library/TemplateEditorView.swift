import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Color {
    /// Parse "#RRGGBB", "#RGB", or "#RRGGBBAA".
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Format as "#RRGGBBAA".
    func hexStringRGBA() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()), Int((ns.alphaComponent * 255).rounded()))
    }
}

/// Phase 2 template editor: drag layers on a normalized 0..1 canvas, tweak style, and
/// save. Validation is delegated to the Rust core (via TemplateStore.save →
/// normalizeTemplateJson). Supports `.json` export / import (the Phase 2 gate).
/// A selectable capture source (camera or display) for per-layer binding.
struct SourceOption: Identifiable, Hashable {
    let id: String
    let label: String
}

struct TemplateEditorView: View {
    @ObservedObject var store: TemplateStore
    let templateID: String
    let isBuiltin: Bool
    var cameras: [SourceOption] = []
    var screens: [SourceOption] = []
    var previewSessionDir: URL?

    @State var name: String
    @State var doc: TemplateDoc
    @State private var selection: UUID?
    @State private var errorText: String?
    @State private var showPreview = false
    @StateObject private var sources = PreviewSources()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Template name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
                Toggle(isOn: $showPreview) { Label("Preview", systemImage: "eye") }
                    .toggleStyle(.button)
                    .onChange(of: showPreview) { _, on in if on { sources.load(from: previewSessionDir) } }
                Button("Import JSON…", action: importJSON)
                Button("Export JSON…", action: exportJSON)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            HStack(spacing: 0) {
                Group {
                    if showPreview {
                        CompositePreview(doc: doc, sources: sources)
                    } else {
                        CanvasView(doc: $doc, selection: $selection)
                    }
                }
                .padding()
                .frame(minWidth: 460, minHeight: 300)
                Divider()
                LayerPanel(doc: $doc, selection: $selection, cameras: cameras, screens: screens)
                    .frame(width: 250)
            }

            if let errorText {
                Divider()
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption).padding(8)
            }
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    private func save() {
        do {
            try store.save(id: templateID, name: name, doc: doc, isBuiltin: isBuiltin)
            dismiss()
        } catch {
            errorText = "Invalid template: \(error)"
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try doc.jsonString().data(using: .utf8)?.write(to: url) }
        catch { errorText = "Export failed: \(error)" }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            _ = try normalizeTemplateJson(json: json)   // core validates before we accept
            doc = try TemplateDoc.parse(json)
            errorText = nil
        } catch {
            errorText = "Import failed: \(error)"
        }
    }
}

// MARK: - Canvas

/// Editable normalized 0..1 canvas: draggable/resizable layers. Shared by the template
/// editor and the main-window live layout.
struct CanvasView: View {
    @Binding var doc: TemplateDoc
    @Binding var selection: UUID?

    var body: some View {
        GeometryReader { geo in
            let ar = CGFloat(doc.canvas.width) / CGFloat(max(doc.canvas.height, 1))
            let size = fit(aspect: ar, in: geo.size)
            ZStack {
                Rectangle().fill(Color.black)
                Rectangle().stroke(.white.opacity(0.15))
                ForEach(doc.layers) { layer in
                    if layer.rect != nil {
                        DraggableLayer(
                            layer: layer,
                            selected: selection == layer.id,
                            canvas: size,
                            onSelect: { selection = layer.id },
                            onChange: { newRect in
                                if let i = doc.layers.firstIndex(where: { $0.id == layer.id }) {
                                    doc.layers[i].rect = newRect
                                }
                            })
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fit(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        let byWidth = CGSize(width: bounds.width, height: bounds.width / aspect)
        return byWidth.height <= bounds.height
            ? byWidth
            : CGSize(width: bounds.height * aspect, height: bounds.height)
    }
}

private struct DraggableLayer: View {
    let layer: Layer
    let selected: Bool
    let canvas: CGSize
    let onSelect: () -> Void
    let onChange: (RectN) -> Void

    // Transient gesture translations. Applied VISUALLY during the drag and committed to
    // the document only on release — so `doc` isn't mutated every frame (that caused the
    // whole editor to re-render and flicker).
    @GestureState private var moveT: CGSize = .zero
    @GestureState private var resizeT: CGSize = .zero

    private let minSize = 0.05

    var body: some View {
        let base = layer.rect ?? RectN(x: 0, y: 0, w: 0.1, h: 0.1)
        let eff = effective(base)
        let w = CGFloat(eff.w) * canvas.width
        let h = CGFloat(eff.h) * canvas.height
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: selected ? 2.5 : 1))
                .overlay(Text(layer.kind.label).font(.caption2).foregroundStyle(.white))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($moveT) { v, s, _ in s = v.translation }
                        .onEnded { v in onSelect(); onChange(moved(base, by: v.translation)) }
                )
                .onTapGesture { onSelect() }
            if selected {
                Circle().fill(.white).overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: 7, y: 7)
                    .gesture(
                        DragGesture()
                            .updating($resizeT) { v, s, _ in s = v.translation }
                            .onEnded { v in onSelect(); onChange(resized(base, by: v.translation, free: freeResize)) }
                    )
            }
        }
        .frame(width: max(w, 8), height: max(h, 8))
        .position(x: CGFloat(eff.x) * canvas.width + w / 2, y: CGFloat(eff.y) * canvas.height + h / 2)
    }

    /// Hold Option while resizing to free-resize (crop, via the renderer's aspect-fill)
    /// instead of keeping the source aspect ratio.
    private var freeResize: Bool { NSEvent.modifierFlags.contains(.option) }

    /// Base rect with the live (uncommitted) move/resize translation applied. Only one
    /// gesture is active at a time.
    private func effective(_ base: RectN) -> RectN {
        if resizeT != .zero { return resized(base, by: resizeT, free: freeResize) }
        return moved(base, by: moveT)
    }

    private func moved(_ base: RectN, by t: CGSize) -> RectN {
        var r = base
        r.x = min(max(0, base.x + Double(t.width / canvas.width)), 1 - base.w)
        r.y = min(max(0, base.y + Double(t.height / canvas.height)), 1 - base.h)
        return r
    }

    /// Resize. Default keeps the rect's w:h ratio (no distortion); `free` (Option held)
    /// resizes each axis independently so the source is cropped by the renderer.
    private func resized(_ base: RectN, by t: CGSize, free: Bool) -> RectN {
        if free {
            var r = base
            r.w = min(max(minSize, base.w + Double(t.width / canvas.width)), 1 - base.x)
            r.h = min(max(minSize, base.h + Double(t.height / canvas.height)), 1 - base.y)
            return r
        }
        let aspect = base.w / max(base.h, 0.0001)
        var w = max(minSize, base.w + Double(t.width / canvas.width))
        var h = w / aspect
        if base.x + w > 1 { w = 1 - base.x; h = w / aspect }
        if base.y + h > 1 { h = 1 - base.y; w = h * aspect }
        var r = base
        r.w = max(minSize, w)
        r.h = max(minSize, h)
        return r
    }

    private var color: Color {
        switch layer.kind {
        case .screen: return .blue
        case .camera: return .green
        case .image: return .orange
        case .background: return .gray
        }
    }
}

// MARK: - Layer list + inspector

private struct LayerPanel: View {
    @Binding var doc: TemplateDoc
    @Binding var selection: UUID?
    var cameras: [SourceOption] = []
    var screens: [SourceOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    Button("Screen") { add(.screen) }
                    Button("Camera") { add(.camera) }
                    Button("Image") { add(.image) }
                    // Exactly one background per scene, and it can't be removed.
                    if !doc.layers.contains(where: { $0.kind == .background }) {
                        Button("Background") { add(.background) }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).frame(width: 28)
            }
            .padding(8)
            Divider()

            List(selection: $selection) {
                ForEach(doc.layers) { layer in
                    HStack {
                        Image(systemName: icon(layer.kind))
                        Text(layer.kind.label)
                        Spacer()
                        if layer.kind != .background {   // background is mandatory, not removable
                            Button(role: .destructive) {
                                doc.layers.removeAll { $0.id == layer.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    .tag(layer.id)
                }
            }
            .frame(maxHeight: 180)

            Divider()
            if let idx = doc.layers.firstIndex(where: { $0.id == selection }) {
                Inspector(layer: $doc.layers[idx], cameras: cameras, screens: screens).padding(8)
            } else {
                Text("Select a layer").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Spacer()
        }
    }

    private func add(_ kind: LayerKind) {
        var layer = Layer(kind: kind)
        switch kind {
        case .background: layer.source = .color; layer.color = "#0B0B0F"
        case .screen, .camera: layer.rect = RectN(x: 0.25, y: 0.25, w: 0.4, h: 0.225); layer.cornerRadius = 12 // 16:9
        case .image: layer.rect = RectN(x: 0.4, y: 0.4, w: 0.2, h: 0.15); layer.opacity = 1; layer.path = ""
        }
        doc.layers.append(layer)
        selection = layer.id
    }

    private func icon(_ k: LayerKind) -> String {
        switch k {
        case .background: return "square.fill"
        case .screen: return "display"
        case .camera: return "web.camera"
        case .image: return "photo"
        }
    }
}

/// Per-layer inspector (source, style). Shared by the editor and the main-window
/// live layout so an element's source can be changed by selecting it — even mid-record.
struct Inspector: View {
    @Binding var layer: Layer
    var cameras: [SourceOption] = []
    var screens: [SourceOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(layer.kind.label).font(.subheadline).bold()
            switch layer.kind {
            case .background:
                Picker("Source", selection: Binding(get: { layer.source ?? .color }, set: { layer.source = $0 })) {
                    ForEach(BackgroundSource.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                if layer.source == .color {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(hexString: layer.color ?? "#0B0B0F") },
                        set: { layer.color = $0.hexStringRGBA() }), supportsOpacity: true)
                    TextField("#RRGGBB or #RRGGBBAA", text: Binding(
                        get: { layer.color ?? "#0B0B0F" }, set: { layer.color = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            case .screen, .camera:
                devicePicker(layer.kind == .camera ? "Webcam" : "Monitor",
                             options: layer.kind == .camera ? cameras : screens)
                slider("Corner radius", Binding(get: { layer.cornerRadius ?? 0 }, set: { layer.cornerRadius = $0 }), 0...64)
                if layer.kind == .camera {
                    Toggle("Mirror", isOn: Binding(get: { layer.mirror ?? false }, set: { layer.mirror = $0 }))
                }
            case .image:
                slider("Opacity", Binding(get: { layer.opacity ?? 1 }, set: { layer.opacity = $0 }), 0...1)
                TextField("Path", text: Binding(get: { layer.path ?? "" }, set: { layer.path = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            if let r = layer.rect {
                Text(String(format: "x %.2f  y %.2f  w %.2f  h %.2f", r.x, r.y, r.w, r.h))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(Int(value.wrappedValue))").font(.caption)
            Slider(value: value, in: range)
        }
    }

    /// Per-layer source picker: bind this layer to a specific camera / display.
    @ViewBuilder
    private func devicePicker(_ label: String, options: [SourceOption]) -> some View {
        Picker(label, selection: Binding(get: { layer.deviceId }, set: { layer.deviceId = $0 })) {
            Text("Default").tag(String?.none)
            ForEach(options) { opt in Text(opt.label).tag(String?.some(opt.id)) }
        }
        .font(.caption)
    }
}
