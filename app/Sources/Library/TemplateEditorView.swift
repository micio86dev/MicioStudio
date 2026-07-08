import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Phase 2 template editor: drag layers on a normalized 0..1 canvas, tweak style, and
/// save. Validation is delegated to the Rust core (via TemplateStore.save →
/// normalizeTemplateJson). Supports `.json` export / import (the Phase 2 gate).
struct TemplateEditorView: View {
    @ObservedObject var store: TemplateStore
    let templateID: String
    let isBuiltin: Bool

    @State var name: String
    @State var doc: TemplateDoc
    @State private var selection: UUID?
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Template name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
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
                CanvasView(doc: $doc, selection: $selection)
                    .padding()
                    .frame(minWidth: 460, minHeight: 300)
                Divider()
                LayerPanel(doc: $doc, selection: $selection)
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

private struct CanvasView: View {
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

    @State private var startRect: RectN?

    private let minSize = 0.05

    var body: some View {
        let r = layer.rect ?? RectN(x: 0, y: 0, w: 0.1, h: 0.1)
        let w = CGFloat(r.w) * canvas.width
        let h = CGFloat(r.h) * canvas.height
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: selected ? 2.5 : 1))
                .overlay(Text(layer.kind.label).font(.caption2).foregroundStyle(.white))
                .contentShape(Rectangle())
                .gesture(moveGesture(base: r))
            if selected {
                // bottom-right resize handle
                Circle().fill(.white).overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: 7, y: 7)
                    .gesture(resizeGesture(base: r))
            }
        }
        .frame(width: max(w, 8), height: max(h, 8))
        .position(x: CGFloat(r.x) * canvas.width + w / 2, y: CGFloat(r.y) * canvas.height + h / 2)
        .onTapGesture { onSelect() }
    }

    private func moveGesture(base r: RectN) -> some Gesture {
        DragGesture()
            .onChanged { value in
                onSelect()
                let base = startRect ?? r
                if startRect == nil { startRect = r }
                var nr = base
                nr.x = min(max(0, base.x + Double(value.translation.width / canvas.width)), 1 - base.w)
                nr.y = min(max(0, base.y + Double(value.translation.height / canvas.height)), 1 - base.h)
                onChange(nr)
            }
            .onEnded { _ in startRect = nil }
    }

    private func resizeGesture(base r: RectN) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = startRect ?? r
                if startRect == nil { startRect = r }
                var nr = base
                nr.w = min(max(minSize, base.w + Double(value.translation.width / canvas.width)), 1 - base.x)
                nr.h = min(max(minSize, base.h + Double(value.translation.height / canvas.height)), 1 - base.y)
                onChange(nr)
            }
            .onEnded { _ in startRect = nil }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    Button("Screen") { add(.screen) }
                    Button("Camera") { add(.camera) }
                    Button("Image") { add(.image) }
                    Button("Background") { add(.background) }
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
                        Button(role: .destructive) {
                            doc.layers.removeAll { $0.id == layer.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .tag(layer.id)
                }
            }
            .frame(maxHeight: 180)

            Divider()
            if let idx = doc.layers.firstIndex(where: { $0.id == selection }) {
                Inspector(layer: $doc.layers[idx]).padding(8)
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
        case .screen, .camera: layer.rect = RectN(x: 0.25, y: 0.25, w: 0.4, h: 0.4); layer.cornerRadius = 12
        case .image: layer.rect = RectN(x: 0.4, y: 0.4, w: 0.2, h: 0.12); layer.opacity = 1; layer.path = ""
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

private struct Inspector: View {
    @Binding var layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(layer.kind.label).font(.subheadline).bold()
            switch layer.kind {
            case .background:
                Picker("Source", selection: Binding(get: { layer.source ?? .color }, set: { layer.source = $0 })) {
                    ForEach(BackgroundSource.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                if layer.source == .color {
                    TextField("Color (#RRGGBB)", text: Binding(get: { layer.color ?? "#000000" }, set: { layer.color = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            case .screen, .camera:
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
}
