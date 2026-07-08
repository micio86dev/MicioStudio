import SwiftUI
import AppKit

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct ContentView: View {
    @StateObject private var recorder = RecordingCoordinator()
    @StateObject private var perms = PermissionManager()
    @StateObject private var templates = TemplateStore()
    @StateObject private var soundboard = Soundboard()
    @State private var activeTemplateID: String?
    @State private var liveDoc: TemplateDoc?
    @State private var liveSelection: UUID?
    @State private var transition = "fade"   // scene-switch transition: cut | fade | slide | swipe

    private var cameraOptions: [SourceOption] { recorder.cameraDevices.map { SourceOption(id: $0.id, label: $0.label) } }
    private var screenOptions: [SourceOption] { recorder.displays.map { SourceOption(id: String($0.id), label: $0.label) } }

    /// Binding to the live template that persists + pushes edits to the recorder on write.
    private var liveBinding: Binding<TemplateDoc> {
        Binding(get: { liveDoc ?? .default }, set: { liveDoc = $0; saveLive() })
    }
    private func liveLayerBinding(_ index: Int) -> Binding<Layer> {
        Binding(
            get: { liveDoc?.layers[safe: index] ?? Layer(kind: .background) },
            set: { newValue in
                guard var d = liveDoc, index < d.layers.count else { return }
                d.layers[index] = newValue
                liveDoc = d
                saveLive()
            })
    }

    /// Load the selected template into the editable canvas and arm it for recording.
    private func loadLive() {
        if let id = activeTemplateID, let row = templates.templates.first(where: { $0.id == id }) {
            liveDoc = templates.doc(for: row)
            recorder.activeTemplateDoc = liveDoc
            recorder.activeCameraDeviceIDs = templates.cameraDeviceIDs(templateID: id)
        } else {
            liveDoc = nil
            recorder.activeTemplateDoc = nil
            recorder.activeCameraDeviceIDs = []
        }
        liveSelection = nil
    }

    /// Persist canvas edits and keep the recorder's active template/cameras in sync.
    private func saveLive() {
        guard let id = activeTemplateID, let doc = liveDoc,
              let row = templates.templates.first(where: { $0.id == id }) else { return }
        try? templates.save(id: id, name: row.name, doc: doc, isBuiltin: row.isBuiltin)
        recorder.activeTemplateDoc = doc
        recorder.activeCameraDeviceIDs = templates.cameraDeviceIDs(templateID: id)
    }

    /// Hidden buttons so number keys 1–9 select scenes (works during recording).
    private var sceneShortcuts: some View {
        ForEach(0..<9, id: \.self) { i in
            Button("") {
                guard var d = liveDoc, d.scenes.indices.contains(i) else { return }
                d.activeSceneIndex = i
                liveDoc = d
                saveLive()
            }
            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
            .hidden()
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(Config.productName).font(.largeTitle.bold())

                PermissionsPanel(perms: perms)

                if !templates.templates.isEmpty {
                    Picker("Template", selection: $activeTemplateID) {
                        Text("None (raw streams)").tag(String?.none)
                        ForEach(templates.templates, id: \.id) { t in Text(t.name).tag(String?.some(t.id)) }
                    }
                    .frame(maxWidth: 420)
                    .disabled(recorder.isRecording || recorder.isBusy)
                    .onChange(of: activeTemplateID) { _, _ in loadLive() }
                }

                // Studio layout: large editable preview. Drag/resize elements; select one
                // to change its source (webcam/screen/image) — works during recording too.
                if liveDoc != nil {
                    HStack {
                        SceneBar(doc: liveBinding)
                        Picker("", selection: $transition) {
                            Text("Cut").tag("cut"); Text("Fade").tag("fade")
                            Text("Slide").tag("slide"); Text("Swipe").tag("swipe")
                        }
                        .labelsHidden().frame(width: 90)
                        .help("Transition used when switching scenes")
                    }
                    // Number keys 1–9 switch scenes (recorded during capture).
                    .background(sceneShortcuts)
                    .onChange(of: liveDoc?.activeSceneIndex) { _, idx in
                        if let idx, recorder.isRecording { recorder.recordSceneSwitch(to: idx, transition: transition) }
                    }
                    CanvasView(doc: liveBinding, selection: $liveSelection)
                        .frame(minHeight: 320, maxHeight: 460)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))

                    if let idx = liveDoc?.layers.firstIndex(where: { $0.id == liveSelection }) {
                        GroupBox("Selected element") {
                            Inspector(layer: liveLayerBinding(idx), cameras: cameraOptions, screens: screenOptions)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Tap an element to change its source, or drag to move / drag a corner to resize (⌥ to crop).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Pick a template above to lay out the scene, or record raw streams.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                AudioControls(recorder: recorder)

                SoundboardPanel(board: soundboard)

                if recorder.isRecording || recorder.elapsed > 0 {
                    HStack(spacing: 8) {
                        if recorder.isRecording { Circle().fill(.red).frame(width: 10, height: 10) }
                        Text(Self.timeString(recorder.elapsed))
                            .font(.system(.title2, design: .monospaced).weight(.medium))
                            .foregroundStyle(recorder.isRecording ? .red : .secondary)
                    }
                }

                Button(action: recorder.toggle) {
                    Label(recorder.isRecording ? "Stop" : "Record",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
                .disabled(recorder.isBusy)

                Text(recorder.status.isEmpty ? "Idle" : recorder.status)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(maxWidth: .infinity)

                if recorder.isExporting {
                    VStack(spacing: 4) {
                        ProgressView(value: recorder.exportProgress)
                        Text("Exporting… \(Int(recorder.exportProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 320)
                }
                if let combined = recorder.combinedURL {
                    Button { NSWorkspace.shared.open(combined) } label: {
                        Label("Open last export", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.bordered)
                }
                if let dir = recorder.lastOutputDir {
                    Button("Reveal recording folder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                        .buttonStyle(.link)
                }

                TemplatesPanel(store: templates, cameras: cameraOptions, screens: screenOptions,
                               previewSessionDir: recorder.lastOutputDir)
            }
            .padding(24)
        }
        .frame(minWidth: 660, minHeight: 680)
        .task {
            await perms.refresh()
            await recorder.refreshDisplays()
            recorder.refreshAudioDevices()
            recorder.refreshCameraDevices()
            templates.load()
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Capture sources: which monitor, which microphone, and live input level meters.
/// Audio isn't a visual layer, so it stays a global control: microphone choice + live
/// mic/system level meters. (Monitor/webcam are chosen per-element on the preview.)
private struct AudioControls: View {
    @ObservedObject var recorder: RecordingCoordinator

    var body: some View {
        GroupBox("Audio") {
            VStack(alignment: .leading, spacing: 10) {
                if !recorder.audioDevices.isEmpty {
                    Picker("Microphone", selection: $recorder.selectedAudioDeviceID) {
                        ForEach(recorder.audioDevices) { d in Text(d.label).tag(Optional(d.id)) }
                    }
                    .disabled(recorder.isRecording || recorder.isBusy)
                }
                HStack(spacing: 20) {
                    LevelMeter(label: "Mic", level: recorder.micLevel)
                    LevelMeter(label: "System", level: recorder.systemLevel)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small vertical VU-style meter, 0..1.
private struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level > 0.85 ? Color.red : (level > 0.6 ? .yellow : .green))
                        .frame(height: max(0, min(1, CGFloat(level))) * geo.size.height)
                }
            }
            .frame(width: 14, height: 56)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct PermissionsPanel: View {
    @ObservedObject var perms: PermissionManager

    var body: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                row("Camera", perms.camera, action: "Grant") {
                    Task { await perms.requestCameraAndMic() }
                }
                row("Microphone", perms.microphone, action: "Grant") {
                    Task { await perms.requestCameraAndMic() }
                }
                row("Screen Recording", perms.screenRecording, action: "Open Settings") {
                    perms.openScreenRecordingSettings()
                }
                row("Accessibility (clicks)", perms.accessibility, action: "Open Settings") {
                    perms.promptAccessibility()
                    perms.openAccessibilitySettings()
                }
                if !perms.allReady {
                    Text("After granting Screen Recording or Accessibility, relaunch the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Re-check") { Task { await perms.refresh() } }
                    .font(.footnote)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ granted: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(label)
            Spacer()
            if !granted {
                Button(action, action: perform)
                    .controlSize(.small)
            }
        }
    }
}

/// Phase 2: templates persisted in the Rust core's SQLite library, with a visual editor.
private struct TemplatesPanel: View {
    @ObservedObject var store: TemplateStore
    var cameras: [SourceOption] = []
    var screens: [SourceOption] = []
    var previewSessionDir: URL?
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let id: String
        let name: String
        let doc: TemplateDoc
        let isBuiltin: Bool
    }

    var body: some View {
        GroupBox("Templates") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button { newTemplate() } label: { Label("New", systemImage: "plus") }
                        .controlSize(.small)
                }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if store.templates.isEmpty {
                    Text("No templates yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.templates, id: \.id) { t in
                        HStack {
                            Image(systemName: t.isBuiltin ? "lock.rectangle" : "rectangle.on.rectangle")
                                .foregroundStyle(.secondary)
                            Text(t.name)
                            if t.isBuiltin { Text("built-in").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Edit") { edit(t) }.controlSize(.small)
                            if !t.isBuiltin {
                                Button(role: .destructive) { store.delete(id: t.id) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { target in
            TemplateEditorView(store: store, templateID: target.id, isBuiltin: target.isBuiltin,
                               cameras: cameras, screens: screens, previewSessionDir: previewSessionDir,
                               name: target.name, doc: target.doc)
        }
    }

    private func newTemplate() {
        let n = store.makeNew()
        editing = EditTarget(id: n.id, name: n.name, doc: n.doc, isBuiltin: false)
    }

    private func edit(_ row: TemplateRow) {
        editing = EditTarget(id: row.id, name: row.name, doc: store.doc(for: row), isBuiltin: row.isBuiltin)
    }
}

#Preview {
    ContentView()
}
