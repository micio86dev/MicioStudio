import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var recorder = RecordingCoordinator()
    @StateObject private var perms = PermissionManager()

    var body: some View {
        VStack(spacing: 18) {
            Text(Config.productName)
                .font(.largeTitle.bold())
            Text("Phase 1 — native-Retina capture")
                .foregroundStyle(.secondary)

            PermissionsPanel(perms: perms)
            SourcesPanel(recorder: recorder)

            if recorder.isRecording || recorder.elapsed > 0 {
                HStack(spacing: 8) {
                    if recorder.isRecording {
                        Circle().fill(.red).frame(width: 10, height: 10)
                    }
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)

            if recorder.isExporting {
                VStack(spacing: 4) {
                    ProgressView(value: recorder.exportProgress)
                    Text("Building preview… \(Int(recorder.exportProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 320)
            }

            if let combined = recorder.combinedURL {
                Button {
                    NSWorkspace.shared.open(combined)
                } label: {
                    Label("Open preview (combined.mov)", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.bordered)
            }

            if let dir = recorder.lastOutputDir {
                Button("Reveal recording folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .task {
            await perms.refresh()
            await recorder.refreshDisplays()
            recorder.refreshAudioDevices()
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Capture sources: which monitor, which microphone, and live input level meters.
private struct SourcesPanel: View {
    @ObservedObject var recorder: RecordingCoordinator

    var body: some View {
        GroupBox("Sources") {
            VStack(alignment: .leading, spacing: 10) {
                if recorder.displays.count > 1 {
                    Picker("Monitor", selection: $recorder.selectedDisplayID) {
                        ForEach(recorder.displays) { d in Text(d.label).tag(Optional(d.id)) }
                    }
                    .disabled(recorder.isRecording || recorder.isBusy)
                }
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

#Preview {
    ContentView()
}
