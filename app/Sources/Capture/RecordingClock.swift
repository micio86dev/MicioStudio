import Foundation
import CoreMedia

/// Single-clock authority (SPEC §5.2). Every event timestamp is a millisecond
/// offset from ONE origin fixed at record start. SCK/AVFoundation sample-buffer
/// PTS and CGEvent timestamps share the mach host-time timebase, so only unit
/// conversion is required — never cross-clock correlation. Getting this wrong is
/// the "zooms fire off-time" bug the spec warns about.
struct RecordingClock: Sendable {
    /// Origin on the CoreMedia host-time clock (for CMSampleBuffer PTS).
    let t0Host: CMTime
    /// Origin in mach ticks (for CGEvent timestamps and the 60Hz cursor sampler).
    let t0Mach: UInt64
    private let numer: UInt64
    private let denom: UInt64

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(tb.denom)
        // Capture both origins back-to-back. The host-time clock IS the mach
        // timebase, so the two origins differ by <1 tick — negligible at ms.
        t0Mach = mach_absolute_time()
        t0Host = CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// ms offset for a sample-buffer PTS (host-time clock). May be negative for
    /// buffers that predate t0; callers needing an unsigned value clamp to 0.
    func offsetMs(pts: CMTime) -> Int64 {
        Int64(((pts.seconds - t0Host.seconds) * 1000.0).rounded())
    }

    /// ms offset for a CGEvent timestamp (mach ticks). Clamps to 0 on underflow.
    func offsetMs(machTicks: UInt64) -> Int64 {
        let eventNanos = machTicks &* numer / denom
        let originNanos = t0Mach &* numer / denom
        return eventNanos >= originNanos ? Int64((eventNanos - originNanos) / 1_000_000) : 0
    }

    /// ms offset for "now" — used by the 60Hz cursor sampler.
    func offsetMsNow() -> Int64 { offsetMs(machTicks: mach_absolute_time()) }
}
