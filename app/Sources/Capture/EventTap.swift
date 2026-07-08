import CoreGraphics
import Foundation

/// Global `CGEventTap` (clicks) + a 60Hz cursor sampler → `events.jsonl`.
/// Timestamps are ms offsets from t0 via `RecordingClock`. The Rust core owns the
/// JSONL line format (`appendEventLine`) so the writer here and the future zoom
/// engine can never drift. Requires Accessibility permission — a tap created
/// without trust returns nil, which `start()` reports so the caller can prompt.
///
/// Coordinates are normalized 0..1 on the captured display. Both clicks and cursor
/// samples read positions in the SAME space (CGEvent global, top-left origin,
/// points), normalized against `CGDisplayBounds` — no coordinate-system flip.
final class EventTap: @unchecked Sendable {
    private let clock: RecordingClock
    private let displayBounds: CGRect
    private let fileHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "dev.miciodev.events")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var cursorTimer: DispatchSourceTimer?

    init?(clock: RecordingClock, displayID: CGDirectDisplayID, outputDir: URL) {
        self.clock = clock
        self.displayBounds = CGDisplayBounds(displayID)
        let url = outputDir.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
        self.fileHandle = fh
    }

    /// Starts the click tap and the cursor sampler. Returns false if the tap could
    /// not be created (Accessibility not granted) — the cursor sampler still runs.
    @discardableResult
    func start() -> Bool {
        startCursorSampler()

        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false // Accessibility permission missing
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        // The tap needs a live CFRunLoop; run it on a dedicated thread.
        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource, let tap = self.tap else { return }
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "dev.miciodev.eventtap"
        thread.start()
        return true
    }

    func stop() {
        cursorTimer?.cancel()
        cursorTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = tapRunLoop { CFRunLoopStop(rl) } // exits CFRunLoopRun → thread ends
        writeQueue.sync { try? fileHandle.close() }
    }

    // MARK: - Handlers

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that is slow or on user input — re-enable it
        // or clicks silently stop mid-recording (SPEC §10).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // CGEventTimestamp is mach ticks (mach_absolute_time units) on Apple Silicon.
        let ms = clock.offsetMs(machTicks: event.timestamp)
        append(kind: .click, ms: ms, location: event.location)
    }

    private func startCursorSampler() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60Hz
        timer.setEventHandler { [weak self] in
            guard let self, let loc = CGEvent(source: nil)?.location else { return }
            self.append(kind: .move, ms: self.clock.offsetMsNow(), location: loc)
        }
        timer.resume()
        cursorTimer = timer
    }

    private func append(kind: EventKind, ms: Int64, location: CGPoint) {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return }
        let nx = Float((location.x - displayBounds.minX) / displayBounds.width)
        let ny = Float((location.y - displayBounds.minY) / displayBounds.height)
        let event = InputEvent(tMs: UInt64(max(0, ms)), x: nx, y: ny, kind: kind)
        let data = Data((appendEventLine(event: event) + "\n").utf8)
        writeQueue.async { [weak self] in
            try? self?.fileHandle.write(contentsOf: data)
        }
    }
}
