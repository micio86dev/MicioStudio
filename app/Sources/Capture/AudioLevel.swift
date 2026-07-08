import AVFoundation

/// Thread-safe float, written from an audio callback queue and read on the main actor
/// by the UI ticker (a meter tolerates a torn read, but this keeps Swift 6 happy).
final class AtomicFloat: @unchecked Sendable {
    private var value: Float = 0
    private let lock = NSLock()
    func set(_ v: Float) { lock.lock(); value = v; lock.unlock() }
    func get() -> Float { lock.lock(); defer { lock.unlock() }; return value }
}

/// Computes a 0..1 loudness level from a PCM audio sample buffer, for the UI meters.
/// Handles the two formats capture delivers: 32-bit float and 16-bit integer.
enum AudioLevel {
    static func rms(from sb: CMSampleBuffer) -> Float {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }

        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let ptr = dataPtr, length > 0 else { return 0 }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let raw = UnsafeRawPointer(ptr)
        var sumSquares = 0.0
        var n = 0

        if isFloat && bits == 32 {
            n = length / MemoryLayout<Float>.size
            let p = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<n { let v = Double(p[i]); sumSquares += v * v }
        } else if bits == 16 {
            n = length / MemoryLayout<Int16>.size
            let p = raw.assumingMemoryBound(to: Int16.self)
            for i in 0..<n { let v = Double(p[i]) / 32768.0; sumSquares += v * v }
        } else {
            return 0
        }
        guard n > 0 else { return 0 }
        let rms = (sumSquares / Double(n)).squareRoot()
        return Float(min(1.0, rms * 4.0)) // headroom boost so normal speech is visible
    }
}
