import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var recorder = RecordingCoordinator()

    var body: some View {
        VStack(spacing: 20) {
            Text(Config.productName)
                .font(.largeTitle.bold())
            Text("Phase 1 — native-Retina capture")
                .foregroundStyle(.secondary)

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
        .padding(28)
        .frame(minWidth: 460, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
