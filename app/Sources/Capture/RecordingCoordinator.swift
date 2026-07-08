import Foundation
import ScreenCaptureKit
import AVFoundation

/// Orchestrates a recording session: fixes t0, starts the screen/camera/mic/event
/// capturers, and finalizes every writer on stop. UI-facing state lives on the main
/// actor; sample buffers are never touched here (they stay on capturer queues).
@MainActor
final class RecordingCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, preparing, recording, finishing, failed(String)
    }

    struct DisplayOption: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let label: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status = ""
    @Published private(set) var lastOutputDir: URL?
    @Published private(set) var displays: [DisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    private var screen: ScreenCapturer?
    private var camera: CameraCapturer?
    private var mic: AudioCapturer?
    private var events: EventTap?
    private var currentDir: URL?

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .preparing || state == .finishing }

    func toggle() {
        switch state {
        case .recording: Task { await stop() }
        case .idle, .failed: Task { await start() }
        default: break
        }
    }

    func start() async {
        state = .preparing
        status = "Preparing…"
        do {
            // TCC prompts on first use; grants apply immediately for camera/mic.
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)

            // Acquire the display FIRST — if Screen Recording isn't granted for THIS
            // build (ad-hoc signing invalidates the grant on every rebuild), this throws
            // and we bail out WITHOUT leaving an empty session folder behind.
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                    ?? content.displays.first else {
                throw Self.err("No display available — grant Screen Recording for this build in System Settings, then relaunch.")
            }

            let dir = try makeOutputDir()
            currentDir = dir

            // Fix t0 (the single shared origin, SPEC §5.2) right before building the
            // capturers, so every writer anchors at the same real instant.
            let clock = RecordingClock()
            let screen = try ScreenCapturer(display: display, clock: clock, outputDir: dir)
            let camera = try? CameraCapturer(clock: clock, outputDir: dir)
            let mic = try? AudioCapturer(clock: clock, outputDir: dir)
            let events = EventTap(clock: clock, displayID: screen.displayID, outputDir: dir)

            try await screen.start()
            camera?.start()
            mic?.start()
            let tapOK = events?.start() ?? false

            self.screen = screen
            self.camera = camera
            self.mic = mic
            self.events = events
            state = .recording
            status = summary(camera: camera != nil, mic: mic != nil, tapOK: tapOK)
        } catch {
            NSLog("[RecordingCoordinator] start failed: \(error)")
            state = .failed(error.localizedDescription)
            status = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stop() async {
        state = .finishing
        status = "Finishing…"
        events?.stop()

        // Stop ALL capture delivery together BEFORE finalizing any writer. Stopping
        // sequentially (await each stop+flush) let the mic keep recording during the
        // others' finalization → seconds of extra audio and duration drift.
        camera?.stopCapture()
        mic?.stopCapture()
        await screen?.stopCapture()
        await screen?.finishWriting()
        await camera?.finishWriting()
        await mic?.finishWriting()

        let dir = currentDir
        screen = nil; camera = nil; mic = nil; events = nil
        lastOutputDir = dir

        // The app writes ONLY the canonical separate streams (SPEC §5.1). The throwaway
        // side-by-side preview (combined.mov) is derived by scripts/verify-phase1.sh.
        state = .idle
        status = dir.map { "Saved to \($0.path)" } ?? "Saved."
    }

    /// Populate the display picker. Requires Screen Recording permission; silently
    /// no-ops until it's granted (the permissions panel prompts for it).
    func refreshDisplays() async {
        guard let content = try? await SCShareableContent.current else { return }
        let main = CGMainDisplayID()
        displays = content.displays.enumerated().map { index, d in
            let mode = CGDisplayCopyDisplayMode(d.displayID)
            let w = mode?.pixelWidth ?? d.width
            let h = mode?.pixelHeight ?? d.height
            let tag = d.displayID == main ? " (main)" : ""
            return DisplayOption(id: d.displayID, label: "Monitor \(index + 1) — \(w)×\(h)\(tag)")
        }
        if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: { $0.id == main })?.id ?? displays.first?.id
        }
    }

    // MARK: - Helpers

    private func makeOutputDir() throws -> URL {
        let movies = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let dir = movies
            .appendingPathComponent(Config.recordingsFolderName, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func summary(camera: Bool, mic: Bool, tapOK: Bool) -> String {
        var parts = ["screen", "system-audio"]
        if camera { parts.append("camera") }
        if mic { parts.append("mic") }
        parts.append(tapOK ? "events" : "events(grant Accessibility + relaunch)")
        return "Recording: " + parts.joined(separator: " + ")
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "RecordingCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
