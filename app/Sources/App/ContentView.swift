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

            if let dir = recorder.lastOutputDir {
                Button("Reveal last recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 440)
        .task { await perms.refresh() }
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
