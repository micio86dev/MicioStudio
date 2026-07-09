import ScreenCaptureKit
import AppKit

/// Periodic low-res screenshot of a display (or window) for the live layout preview —
/// shows what the screen layer is capturing without a full continuous stream. ~2 fps.
@MainActor
final class ScreenSnapshot: ObservableObject {
    @Published private(set) var image: NSImage?

    private var task: Task<Void, Never>?
    private var key: String = ""

    /// Start (or retarget) the snapshot loop. No-op if already running for this source.
    func start(displayID: CGDirectDisplayID?, windowID: CGWindowID?) {
        let newKey = "\(displayID.map(String.init) ?? "d")-\(windowID.map(String.init) ?? "w")"
        if newKey == key, task != nil { return }
        key = newKey
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.capture(displayID: displayID, windowID: windowID)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        key = ""
    }

    private func capture(displayID: CGDirectDisplayID?, windowID: CGWindowID?) async {
        guard let content = try? await SCShareableContent.current else { return }
        let filter: SCContentFilter
        if let wid = windowID, let win = content.windows.first(where: { $0.windowID == wid }) {
            filter = SCContentFilter(desktopIndependentWindow: win)
        } else if let did = displayID, let display = content.displays.first(where: { $0.displayID == did }) {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if let display = content.displays.first {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            return
        }
        let config = SCStreamConfiguration()
        config.width = 1280
        config.height = 720
        config.showsCursor = true
        if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
