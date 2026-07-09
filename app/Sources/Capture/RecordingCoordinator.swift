import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

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

    struct WindowOption: Identifiable, Hashable {
        let id: CGWindowID
        let label: String
    }

    struct AudioDeviceOption: Identifiable, Hashable {
        let id: String   // AVCaptureDevice.uniqueID
        let label: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status = ""
    @Published private(set) var lastOutputDir: URL?
    @Published private(set) var displays: [DisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var windows: [WindowOption] = []
    @Published var selectedWindowID: CGWindowID?   // nil = capture the whole display
    @Published private(set) var audioDevices: [AudioDeviceOption] = []
    @Published var selectedAudioDeviceID: String?
    @Published private(set) var cameraDevices: [AudioDeviceOption] = []
    @Published var selectedCameraDeviceID: String?
    @Published private(set) var micLevel: Float = 0        // 0..1 for the meter
    @Published private(set) var systemLevel: Float = 0     // 0..1 for the meter
    @Published var micVolume: Float = 1                    // applied in the export mix
    @Published var systemVolume: Float = 1
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0  // 0..1
    @Published private(set) var combinedURL: URL?

    private let exporter = CombinedExporter()

    /// Distinct camera device IDs to capture this session (from the active template's
    /// camera layers). Empty → just the selected webcam. Enables multi-camera capture.
    var activeCameraDeviceIDs: [String] = []
    /// If set, stop() renders the real composited video (composed.mov) via the Phase 3
    /// compositor; otherwise it builds the quick ffmpeg side-by-side preview.
    var activeTemplateDoc: TemplateDoc?

    /// A scene switch during recording (relative to t0), applied with `transition` in the
    /// export. `transition` ∈ cut | fade | slide | swipe.
    struct SceneSwitch: Codable { let tMs: Int; let sceneIndex: Int; let transition: String }
    private(set) var sceneTimeline: [SceneSwitch] = []

    /// Called by the UI (scene chip / number-key shortcut) while recording; records when
    /// the user switched scenes so the export can reproduce it with a transition.
    func recordSceneSwitch(to index: Int, transition: String) {
        guard isRecording, let start = startDate else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        sceneTimeline.append(SceneSwitch(tMs: ms, sceneIndex: index, transition: transition))
    }

    private var screen: ScreenCapturer?
    private var cameras: [CameraCapturer] = []
    private var mic: AudioCapturer?
    private var events: EventTap?
    private var currentDir: URL?

    private let micLevelHolder = AtomicFloat()
    private let systemLevelHolder = AtomicFloat()
    private var startDate: Date?
    private var ticker: Task<Void, Never>?

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
            let screen: ScreenCapturer
            if let wid = selectedWindowID, let win = content.windows.first(where: { $0.windowID == wid }) {
                screen = try ScreenCapturer(window: win, clock: clock, outputDir: dir)
            } else {
                screen = try ScreenCapturer(display: display, clock: clock, outputDir: dir)
            }

            // One CameraCapturer per distinct camera device (multi-camera capture).
            var deviceIDs = activeCameraDeviceIDs.filter { AVCaptureDevice(uniqueID: $0) != nil }
            if deviceIDs.isEmpty, let sel = selectedCameraDeviceID { deviceIDs = [sel] }
            var cameras: [CameraCapturer] = []
            for (i, id) in deviceIDs.enumerated() {
                guard let device = AVCaptureDevice(uniqueID: id) else { continue }
                let filename = i == 0 ? "camera.mov" : "camera-\(i).mov"
                if let cap = try? CameraCapturer(clock: clock, device: device, outputDir: dir, filename: filename) {
                    cameras.append(cap)
                }
            }
            writeSourcesManifest(dir: dir, cameraIDs: deviceIDs)

            let mic = selectedMicDevice().flatMap { try? AudioCapturer(clock: clock, device: $0, outputDir: dir) }
            let events = EventTap(clock: clock, displayID: screen.displayID, outputDir: dir)

            // Level meters: capturers write to thread-safe holders; the ticker publishes.
            screen.onSystemLevel = { [systemLevelHolder] in systemLevelHolder.set($0) }
            mic?.onLevel = { [micLevelHolder] in micLevelHolder.set($0) }

            try await screen.start()
            cameras.forEach { $0.start() }
            mic?.start()
            let tapOK = events?.start() ?? false

            self.screen = screen
            self.cameras = cameras
            self.mic = mic
            self.events = events
            state = .recording
            status = summary(cameras: cameras.count, mic: mic != nil, tapOK: tapOK)
            startTicker()
            sceneTimeline = [SceneSwitch(tMs: 0, sceneIndex: activeTemplateDoc?.activeSceneIndex ?? 0, transition: "cut")]
        } catch {
            NSLog("[RecordingCoordinator] start failed: \(error)")
            state = .failed(error.localizedDescription)
            status = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stop() async {
        state = .finishing
        status = "Finishing…"
        ticker?.cancel(); ticker = nil
        micLevel = 0; systemLevel = 0
        events?.stop()

        // Stop ALL capture delivery together BEFORE finalizing any writer. Stopping
        // sequentially (await each stop+flush) let the mic keep recording during the
        // others' finalization → seconds of extra audio and duration drift.
        cameras.forEach { $0.stopCapture() }
        mic?.stopCapture()
        await screen?.stopCapture()
        await screen?.finishWriting()
        for cam in cameras { await cam.finishWriting() }
        await mic?.finishWriting()

        let dir = currentDir
        screen = nil; cameras = []; mic = nil; events = nil
        lastOutputDir = dir
        combinedURL = nil
        state = .idle

        // Build + open the side-by-side preview with a progress bar. Failure here does
        // NOT lose the recording — the canonical separate streams are already saved.
        guard let dir else { status = "Saved."; return }
        isExporting = true
        exportProgress = 0
        let timeline = sceneTimeline
        do {
            let url: URL
            if let template = activeTemplateDoc {
                status = "Composing video…"
                url = try await TemplateVideoExporter.export(sessionDir: dir, template: template, timeline: timeline,
                                                             micVolume: micVolume, systemVolume: systemVolume) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
            } else {
                status = "Building preview…"
                url = try await exporter.export(sessionDir: dir) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
            }
            combinedURL = url
            status = "Saved to \(dir.path)"
        } catch {
            status = "Saved to \(dir.path) (export failed: \(error))"
        }
        isExporting = false
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
        // On-screen, titled, reasonably sized app windows — for window capture.
        windows = content.windows
            .filter { $0.isOnScreen && ($0.title?.isEmpty == false) && $0.frame.width > 200 && $0.frame.height > 150 }
            .map { w in
                let app = w.owningApplication?.applicationName ?? "App"
                return WindowOption(id: w.windowID, label: "\(app) — \(w.title ?? "")")
            }
        if let wid = selectedWindowID, !windows.contains(where: { $0.id == wid }) { selectedWindowID = nil }
    }

    /// Populate the microphone picker with the available audio input devices.
    func refreshAudioDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        audioDevices = discovery.devices.map { AudioDeviceOption(id: $0.uniqueID, label: $0.localizedName) }
        if selectedAudioDeviceID == nil || !audioDevices.contains(where: { $0.id == selectedAudioDeviceID }) {
            selectedAudioDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? audioDevices.first?.id
        }
    }

    /// Populate the webcam picker with the available video capture devices.
    func refreshCameraDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        cameraDevices = discovery.devices.map { AudioDeviceOption(id: $0.uniqueID, label: $0.localizedName) }
        if selectedCameraDeviceID == nil || !cameraDevices.contains(where: { $0.id == selectedCameraDeviceID }) {
            selectedCameraDeviceID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameraDevices.first?.id
        }
    }

    // MARK: - Helpers

    private func selectedMicDevice() -> AVCaptureDevice? {
        if let id = selectedAudioDeviceID, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: .audio)
    }

    private func selectedCameraDevice() -> AVCaptureDevice? {
        if let id = selectedCameraDeviceID, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: .video)
    }

    private func startTicker() {
        startDate = Date()
        elapsed = 0
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if let start = self.startDate { self.elapsed = Date().timeIntervalSince(start) }
                self.micLevel = self.micLevelHolder.get()
                self.systemLevel = self.systemLevelHolder.get()
            }
        }
    }

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

    private func summary(cameras: Int, mic: Bool, tapOK: Bool) -> String {
        var parts = ["screen", "system-audio"]
        if cameras == 1 { parts.append("camera") } else if cameras > 1 { parts.append("\(cameras) cameras") }
        if mic { parts.append("mic") }
        parts.append(tapOK ? "events" : "events(grant Accessibility + relaunch)")
        return "Recording: " + parts.joined(separator: " + ")
    }

    /// Records which camera device maps to which file, for the compositor (Phase 3).
    private func writeSourcesManifest(dir: URL, cameraIDs: [String]) {
        let cams = cameraIDs.enumerated().map { i, id -> [String: String] in
            ["deviceId": id, "file": i == 0 ? "camera.mov" : "camera-\(i).mov"]
        }
        let manifest: [String: Any] = ["cameras": cams, "screen": "screen.mov"]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("sources.json"))
        }
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
