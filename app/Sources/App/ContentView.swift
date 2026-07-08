import SwiftUI
// The UniFFI-generated MicioCore.swift is compiled into this same app target, so
// its types (InputEvent, appendEventLine, …) are available without an import.

struct ContentView: View {
    @State private var coreCheck = "…"

    var body: some View {
        VStack(spacing: 16) {
            Text(Config.productName)
                .font(.largeTitle.bold())
            Text("Phase 1 — capture scaffold")
                .foregroundStyle(.secondary)

            GroupBox("Rust core link check") {
                Text(coreCheck)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 260)
        .task { coreCheck = Self.verifyCoreRoundTrip() }
    }

    /// Proves the UniFFI binding links and runs: build an event in Swift, have the
    /// Rust core serialize it, parse it back, and confirm the round-trip.
    private static func verifyCoreRoundTrip() -> String {
        let event = InputEvent(tMs: 1234, x: 0.51, y: 0.42, kind: .click)
        let line = appendEventLine(event: event)
        do {
            let parsed = try parseEventsJsonl(text: line)
            let ok = parsed.first == event
            return "\(ok ? "✅" : "❌") core round-trip\n\(line)"
        } catch {
            return "❌ core error: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
