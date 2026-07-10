import SwiftUI
@preconcurrency import AVFoundation
import AppKit

/// Live preview of the selected webcam. Runs its own capture session, and STOPS while
/// recording (`active == false`) so the recorder can take exclusive access to the
/// camera device. Reconfigures when the selected device changes.
struct WebcamPreview: NSViewRepresentable {
    let deviceID: String?
    let active: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.apply(deviceID: deviceID, active: active)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.apply(deviceID: deviceID, active: active)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.teardown()
    }

    final class PreviewView: NSView {
        private let session = AVCaptureSession()
        private let previewLayer = AVCaptureVideoPreviewLayer()
        private let queue = DispatchQueue(label: "dev.miciodev.preview")
        private var currentDeviceID: String?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            layer = host
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            host.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }

        func apply(deviceID: String?, active: Bool) {
            if deviceID != currentDeviceID {
                currentDeviceID = deviceID
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                if let id = deviceID, let device = AVCaptureDevice(uniqueID: id),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            let s = session
            if active && !s.inputs.isEmpty {
                if !s.isRunning { queue.async { s.startRunning() } }
            } else if s.isRunning {
                queue.async { s.stopRunning() }
            }
        }

        func teardown() {
            let s = session
            queue.async { if s.isRunning { s.stopRunning() } }
        }
    }
}
