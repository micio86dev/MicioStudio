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

    @Published private(set) var state: State = .idle
    @Published private(set) var status = ""
    @Published private(set) var lastOutputDir: URL?

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
            guard let display = content.displays.first else {
                throw Self.err("No display available — grant Screen Recording for this build in System Settings, then relaunch.")
            }

            let dir = try makeOutputDir()
            currentDir = dir

            let screen = try ScreenCapturer(display: display, outputDir: dir)
            let camera = try? CameraCapturer(outputDir: dir)
            let mic = try? AudioCapturer(outputDir: dir)

            // Fix t0 as late as possible — right before capture starts (SPEC §5.2).
            let clock = RecordingClock()
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
        await screen?.stop()
        await camera?.stop()
        await mic?.stop()

        let dir = currentDir
        screen = nil; camera = nil; mic = nil; events = nil
        lastOutputDir = dir

        // The app writes ONLY the canonical separate streams (SPEC §5.1). The throwaway
        // side-by-side preview (combined.mov) is derived by scripts/verify-phase1.sh.
        state = .idle
        status = dir.map { "Saved to \($0.path)" } ?? "Saved."
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
