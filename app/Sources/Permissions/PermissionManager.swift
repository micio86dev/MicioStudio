import AVFoundation
import ScreenCaptureKit
import ApplicationServices
import AppKit

/// Tracks the four TCC permissions Phase 1 needs and offers the actions to grant
/// them. Camera/Mic prompt in-process; Screen Recording and Accessibility are
/// granted in System Settings and require a RELAUNCH to take effect (SPEC §10).
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var camera = false
    @Published private(set) var microphone = false
    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false

    var allReady: Bool { camera && microphone && screenRecording && accessibility }

    func refresh() async {
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        // Probing shareable content reflects (and, if undetermined, triggers) the
        // Screen Recording grant.
        screenRecording = (try? await SCShareableContent.current) != nil
    }

    func requestCameraAndMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await refresh()
    }

    /// Shows the system Accessibility prompt (adds the app to the list). The user
    /// must toggle it on and relaunch.
    func promptAccessibility() {
        // The imported C global `kAXTrustedCheckOptionPrompt` trips Swift 6's
        // concurrency check; its stable documented value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
