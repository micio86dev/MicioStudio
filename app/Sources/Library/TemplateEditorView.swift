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

/// Scene switcher: chips to select the active scene (+ add / rename / delete). Shared by
/// the editor and the main window. Editing here mutates `doc.activeSceneIndex`/`scenes`.
struct SceneBar: View {
    @Binding var doc: TemplateDoc
    @State private var renaming: Int?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(doc.scenes.enumerated()), id: \.element.id) { index, scene in
                        Button { doc.activeSceneIndex = index } label: {
                            Text(scene.name).lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(index == doc.activeSceneIndex ? .accentColor : .gray)
                        .contextMenu {
                            Button("Rename") { renaming = index; renameText = scene.name }
                            if doc.scenes.count > 1 {
                                Button("Delete", role: .destructive) { deleteScene(index) }
                            }
                        }
                    }
                }
            }
            Button { addScene() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                .help("Add scene")
            Button {
                renaming = doc.activeSceneIndex
                renameText = doc.activeScene?.name ?? ""
            } label: { Image(systemName: "pencil") }
                .help("Rename current scene")
            Button(role: .destructive) { deleteScene(doc.activeSceneIndex) } label: { Image(systemName: "trash") }
                .help("Delete current scene")
                .disabled(doc.scenes.count <= 1)
        }
        .alert("Rename scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let i = renaming, doc.scenes.indices.contains(i) { doc.scenes[i].name = renameText }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func addScene() {
        let scene = SceneDoc(name: "Scene \(doc.scenes.count + 1)", canvas: doc.canvas,
                             layers: [Layer(kind: .background, source: .color, color: "#0B0B0FFF")])
        doc.scenes.append(scene)
        doc.activeSceneIndex = doc.scenes.count - 1
    }

    private func deleteScene(_ index: Int) {
        guard doc.scenes.count > 1, doc.scenes.indices.contains(index) else { return }
        doc.scenes.remove(at: index)
        doc.activeSceneIndex = min(doc.activeSceneIndex, doc.scenes.count - 1)
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
    @StateObject private var screenSnap = ScreenSnapshot()
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

            SceneBar(doc: $doc)
                .padding(.horizontal).padding(.vertical, 6)
            Divider()

            HStack(spacing: 0) {
                Group {
                    if showPreview {
                        CompositePreview(doc: doc, sources: sources)
                    } else {
                        CanvasView(doc: $doc, selection: $selection, live: true,
                                   screenImage: screenSnap.image, defaultCameraID: cameras.first?.id)
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
        .task { screenSnap.start(displayID: nil, windowID: nil) }
        .onDisappear { screenSnap.stop() }
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
    /// When true, layers show their live source (webcam / screen snapshot / image).
    var live = false
    var screenImage: NSImage?
    var defaultCameraID: String?

    var body: some View {
        GeometryReader { geo in
            let ar = CGFloat(doc.canvas.width) / CGFloat(max(doc.canvas.height, 1))
            let size = fit(aspect: ar, in: geo.size)
            ZStack {
                Rectangle().fill(Color.black)
                if live { backgroundContent }
                Rectangle().stroke(.white.opacity(0.15))
                ForEach(doc.layers) { layer in
                    if layer.rect != nil {
                        DraggableLayer(
                            layer: layer,
                            selected: selection == layer.id,
                            canvas: size,
                            live: live,
                            screenImage: screenImage,
                            defaultCameraID: defaultCameraID,
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

    /// Live full-canvas background (SwiftUI approximation of the renderer's background).
    @ViewBuilder private var backgroundContent: some View {
        if let bg = doc.layers.first(where: { $0.kind == .background }) {
            switch bg.source ?? .color {
            case .color:
                Color(hexString: bg.color ?? "#0B0B0F")
            case .screen:
                if let img = screenImage {
                    Image(nsImage: img).resizable().scaledToFill()
                        .blur(radius: CGFloat((bg.blur ?? 40) / 6))
                        .overlay(Color.black.opacity(bg.darken ?? 0.35))
                } else { Color.black }
            case .image:
                if let p = bg.path, let img = NSImage(contentsOfFile: (p as NSString).expandingTildeInPath) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { Color.black }
            }
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
    var live: Bool = false
    var screenImage: NSImage?
    var defaultCameraID: String?
    let onSelect: () -> Void
    let onChange: (RectN) -> Void

    // Local live rect during a drag. Updating a LOCAL @State (not `doc`) means only this
    // layer re-renders, not the whole editor. Kept until the committed rect propagates
    // back through `layer` — which removes the one-frame snap-back @GestureState caused.
    @State private var dragRect: RectN?
    private let minSize = 0.05

    private var committed: RectN { layer.rect ?? RectN(x: 0, y: 0, w: 0.1, h: 0.1) }
    private var locked: Bool { layer.locked == true }
    // Option always frees; otherwise honor the layer's aspect mode (webcam free by default).
    private var freeResize: Bool {
        if NSEvent.modifierFlags.contains(.option) { return true }
        if let m = layer.aspectMode { return m == "free" }
        return layer.kind == .camera
    }

    var body: some View {
        let base = dragRect ?? committed
        let w = CGFloat(base.w) * canvas.width
        let h = CGFloat(base.h) * canvas.height
        ZStack(alignment: .bottomTrailing) {
            liveContent
                .frame(width: max(w, 8), height: max(h, 8))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(live ? 0.0 : (layer.hidden == true ? 0.1 : 0.28)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: selected ? 2.5 : 1))
                .overlay(badge)
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .gesture(moveGesture)
            if selected && !locked {
                Circle().fill(.white).overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: 7, y: 7)
                    .gesture(resizeGesture)
            }
        }
        .frame(width: max(w, 8), height: max(h, 8))
        .position(x: CGFloat(base.x) * canvas.width + w / 2, y: CGFloat(base.y) * canvas.height + h / 2)
        .opacity(layer.hidden == true ? 0.55 : 1)
        .onChange(of: layer.rect) { _, r in if r == dragRect { dragRect = nil } }
    }

    /// The live source shown behind the drag chrome (webcam feed / screen snapshot / image).
    @ViewBuilder private var liveContent: some View {
        if live && layer.hidden != true {
            switch layer.kind {
            case .camera:
                WebcamPreview(deviceID: layer.deviceId ?? defaultCameraID, active: true)
            case .screen:
                if let img = screenImage {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { Color.black }
            case .image:
                if let p = layer.path, !p.isEmpty,
                   let img = NSImage(contentsOfFile: (p as NSString).expandingTildeInPath) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { Color.gray.opacity(0.3) }
            case .background:
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    private var badge: some View {
        HStack(spacing: 3) {
            if locked { Image(systemName: "lock.fill") }
            if layer.hidden == true { Image(systemName: "eye.slash.fill") }
            Text(layer.kind.label)
        }
        .font(.caption2).foregroundStyle(.white)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { v in guard !locked else { return }; dragRect = moved(committed, by: v.translation) }
            .onEnded { v in
                guard !locked else { return }
                let final = moved(committed, by: v.translation)
                dragRect = final; onSelect(); onChange(final)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { v in dragRect = resized(committed, by: v.translation, free: freeResize) }
            .onEnded { v in
                let final = resized(committed, by: v.translation, free: freeResize)
                dragRect = final; onSelect(); onChange(final)
            }
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
        // Enforce the target ratio in PIXEL space (so "16:9" is visually 16:9 on the canvas).
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let ratio = visualRatio(base, cw: cw, ch: ch)
        var wpx = max(8, base.w * cw + Double(t.width))
        var hpx = wpx / ratio
        let maxW = (1 - base.x) * cw, maxH = (1 - base.y) * ch
        if wpx > maxW { wpx = maxW; hpx = wpx / ratio }
        if hpx > maxH { hpx = maxH; wpx = hpx * ratio }
        var r = base
        r.w = max(minSize, wpx / cw)
        r.h = max(minSize, hpx / ch)
        return r
    }

    /// Target width/height ratio in pixels for the layer's aspect mode.
    private func visualRatio(_ base: RectN, cw: Double, ch: Double) -> Double {
        switch layer.aspectMode {
        case "16:9": return 16.0 / 9
        case "4:3": return 4.0 / 3
        case "9:16": return 9.0 / 16
        case "1:1": return 1.0
        default: return (base.w * cw) / max(base.h * ch, 0.0001)   // lock current visual ratio
        }
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

/// Layer list (add / reorder / lock / hide / delete) + inspector for the selected layer.
/// Shared by the editor sheet and the main-window studio sidebar.
struct LayerPanel: View {
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
                    HStack(spacing: 6) {
                        Image(systemName: icon(layer.kind))
                        Text(layer.kind.label).lineLimit(1)
                        Spacer()
                        if layer.kind != .background {   // background is mandatory + fixed
                            Button { toggleHidden(layer.id) } label: {
                                Image(systemName: layer.hidden == true ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless).help("Show / hide")
                            Button { toggleLocked(layer.id) } label: {
                                Image(systemName: layer.locked == true ? "lock.fill" : "lock.open")
                            }.buttonStyle(.borderless).help("Lock / unlock")
                            Button(role: .destructive) {
                                doc.layers.removeAll { $0.id == layer.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    .tag(layer.id)
                }
                .onMove { doc.layers.move(fromOffsets: $0, toOffset: $1) }   // drag to reorder (z-index)
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

    private func toggleHidden(_ id: UUID) {
        if let i = doc.layers.firstIndex(where: { $0.id == id }) {
            doc.layers[i].hidden = !(doc.layers[i].hidden ?? false)
        }
    }

    private func toggleLocked(_ id: UUID) {
        if let i = doc.layers.firstIndex(where: { $0.id == id }) {
            doc.layers[i].locked = !(doc.layers[i].locked ?? false)
        }
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
                } else if layer.source == .image {
                    imageField("Image", Binding(get: { layer.path ?? "" }, set: { layer.path = $0 }))
                }
            case .screen, .camera:
                devicePicker(layer.kind == .camera ? "Webcam" : "Monitor",
                             options: layer.kind == .camera ? cameras : screens)
                slider("Corner radius", Binding(get: { layer.cornerRadius ?? 0 }, set: { layer.cornerRadius = $0 }), 0...64)
                aspectAndFit
                if layer.kind == .camera {
                    Toggle("Mirror", isOn: Binding(get: { layer.mirror ?? false }, set: { layer.mirror = $0 }))
                    Picker("Background", selection: Binding(
                        get: { layer.bgMode ?? "none" }, set: { layer.bgMode = $0 })) {
                        Text("Original").tag("none")
                        Text("Blur (light)").tag("blurLight")
                        Text("Blur (medium)").tag("blurMedium")
                        Text("Blur (strong)").tag("blurStrong")
                        Text("Cover image").tag("image")
                    }
                    .font(.caption)
                    if layer.bgMode == "image" {
                        imageField("Cover image", Binding(get: { layer.bgImage ?? "" }, set: { layer.bgImage = $0 }))
                    }
                }
            case .image:
                slider("Opacity", Binding(get: { layer.opacity ?? 1 }, set: { layer.opacity = $0 }), 0...1)
                imageField("Image", Binding(get: { layer.path ?? "" }, set: { layer.path = $0 }))
                aspectAndFit
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

    /// Aspect-ratio lock (for resize) + content fit (cover/contain) for framed layers.
    @ViewBuilder private var aspectAndFit: some View {
        Picker("Aspect", selection: Binding(get: { layer.aspectMode ?? "lock" }, set: { layer.aspectMode = $0 })) {
            Text("Free").tag("free"); Text("Lock").tag("lock")
            Text("16:9").tag("16:9"); Text("4:3").tag("4:3")
            Text("9:16").tag("9:16"); Text("1:1").tag("1:1")
        }
        .font(.caption)
        Picker("Fit", selection: Binding(get: { layer.fit ?? "cover" }, set: { layer.fit = $0 })) {
            Text("Cover").tag("cover"); Text("Contain").tag("contain")
        }
        .font(.caption)
    }

    /// Pick an image file via a panel (no manual paths). Shows the filename + a clear button.
    @ViewBuilder
    private func imageField(_ label: String, _ path: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption)
            Text(path.wrappedValue.isEmpty ? "None" : (path.wrappedValue as NSString).lastPathComponent)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
            if !path.wrappedValue.isEmpty {
                Button { path.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
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
