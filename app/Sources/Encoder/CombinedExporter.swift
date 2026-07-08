import Foundation

/// Builds the side-by-side preview `combined.mov` (16:9, screen + camera PiP, mixed
/// audio) with noise-reduced + loudness-normalized mic, reporting 0..1 progress.
///
/// DEV BRIDGE: shells out to ffmpeg (a dev dependency). The shippable native composite
/// + export with real-time progress is the compositor (Phase 3); this gives an
/// immediate, watchable preview with a progress bar in the meantime.
actor CombinedExporter {
    struct NotFound: Error {}

    private static func tool(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the export. `onProgress` is called on the main actor with 0..1.
    func export(sessionDir: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let ffmpeg = Self.tool("ffmpeg"), let ffprobe = Self.tool("ffprobe") else { throw NotFound() }
        let screen = sessionDir.appendingPathComponent("screen.mov")
        let camera = sessionDir.appendingPathComponent("camera.mov")
        let mic = sessionDir.appendingPathComponent("mic.caf")
        let system = sessionDir.appendingPathComponent("system.caf")
        let out = sessionDir.appendingPathComponent("combined.mov")
        try? FileManager.default.removeItem(at: out)

        let total = Self.duration(of: screen, ffprobe: ffprobe) ?? 1
        let hasCamera = FileManager.default.fileExists(atPath: camera.path)
        let hasMic = FileManager.default.fileExists(atPath: mic.path)
        let hasSystem = FileManager.default.fileExists(atPath: system.path)

        // Video: screen fit into 1920x1080, camera as PiP bottom-right.
        var inputs = ["-i", screen.path]
        var vf = "[0:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[bg]"
        var vmap = "[bg]"
        var idx = 1
        if hasCamera {
            inputs += ["-i", camera.path]
            vf += ";[\(idx):v]scale=480:-2,setsar=1[cam];[bg][cam]overlay=W-w-32:H-h-32[v]"
            vmap = "[v]"; idx += 1
        }
        // Audio: mic (high-pass + FFT denoise + loudness normalize) mixed with system.
        var afLabels: [String] = []
        var af = ""
        if hasMic {
            inputs += ["-i", mic.path]
            af += ";[\(idx):a]highpass=f=90,afftdn=nf=-25,loudnorm=I=-18:TP=-2[mic]"
            afLabels.append("[mic]"); idx += 1
        }
        if hasSystem {
            inputs += ["-i", system.path]
            afLabels.append("[\(idx):a]"); idx += 1
        }
        var maps = ["-map", vmap]
        if afLabels.count == 1 {
            af += ";\(afLabels[0])aresample=48000[a]"; maps += ["-map", "[a]"]
        } else if afLabels.count == 2 {
            af += ";\(afLabels[0])\(afLabels[1])amix=inputs=2:normalize=0[a]"; maps += ["-map", "[a]"]
        }

        var args = ["-y", "-nostats"] + inputs
        args += ["-filter_complex", vf + af] + maps
        args += ["-c:v", "h264_videotoolbox", "-b:v", "10M", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-movflags", "+faststart", "-shortest",
                 "-progress", "pipe:1", out.path]

        try await Self.run(ffmpeg, args, totalSeconds: total, onProgress: onProgress)
        onProgress(1.0)
        return out
    }

    private static func duration(of url: URL, ffprobe: String) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nk=1:nw=1", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ tool: String, _ args: [String], totalSeconds: Double,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)), totalSeconds > 0 {
                    onProgress(min(0.99, (us / 1_000_000) / totalSeconds))
                }
            }
        }
        try p.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in cont.resume() }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
    }
}
