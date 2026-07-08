import AVFoundation
import Combine

/// One clip on the timeline: a range of the source video, plus the transition used to
/// enter it from the previous clip.
struct Clip: Identifiable, Equatable {
    let id = UUID()
    var sourceStart: Double        // seconds into the source
    var duration: Double           // seconds shown
    var transitionIn: String       // cut | fade | slide | swipe (from the previous clip)

    var sourceEnd: Double { sourceStart + duration }
}

/// Editable timeline over a single source video: split / trim / delete / reorder clips
/// and choose transitions between them. Pure time math (no AVFoundation objects held),
/// so it drives both the preview and the export.
@MainActor
final class TimelineModel: ObservableObject {
    let sourceURL: URL
    let sourceDuration: Double

    @Published var clips: [Clip]
    @Published var playhead: Double = 0            // seconds on the timeline
    @Published var pixelsPerSecond: Double = 80    // zoom
    @Published var selection: UUID?
    /// Overlap length of non-cut transitions, in seconds.
    @Published var transitionDuration: Double = 0.5

    init(sourceURL: URL, sourceDuration: Double) {
        self.sourceURL = sourceURL
        self.sourceDuration = sourceDuration
        self.clips = [Clip(sourceStart: 0, duration: sourceDuration, transitionIn: "cut")]
    }

    // MARK: - Layout (timeline time)

    /// Overlap applied entering clip `index` (0 for the first clip / cut).
    func overlap(before index: Int) -> Double {
        guard index > 0, clips.indices.contains(index), clips[index].transitionIn != "cut" else { return 0 }
        return min(transitionDuration, min(clips[index - 1].duration, clips[index].duration) / 2)
    }

    /// Timeline start time of clip `index`.
    func start(of index: Int) -> Double {
        var t = 0.0
        for i in 0..<index {
            t += clips[i].duration
            t -= overlap(before: i + 1)
        }
        return max(0, t)
    }

    var totalDuration: Double {
        guard !clips.isEmpty else { return 0 }
        let last = clips.count - 1
        return start(of: last) + clips[last].duration
    }

    /// The clip visible at `timelineTime` and the offset into it.
    func clipIndex(atTimelineTime time: Double) -> (index: Int, offset: Double)? {
        for i in clips.indices {
            let s = start(of: i)
            if time >= s && time < s + clips[i].duration + 0.0001 {
                return (i, time - s)
            }
        }
        return clips.isEmpty ? nil : (clips.count - 1, clips[clips.count - 1].duration)
    }

    /// Source time (for the preview) at a timeline time.
    func sourceTime(atTimelineTime time: Double) -> Double? {
        guard let (i, offset) = clipIndex(atTimelineTime: time) else { return nil }
        return clips[i].sourceStart + offset
    }

    // MARK: - Edits

    /// Split the clip under the playhead into two clips at that point.
    func splitAtPlayhead() {
        guard let (i, offset) = clipIndex(atTimelineTime: playhead), offset > 0.05,
              offset < clips[i].duration - 0.05 else { return }
        var left = clips[i], right = clips[i]
        left.duration = offset
        right.sourceStart = clips[i].sourceStart + offset
        right.duration = clips[i].duration - offset
        right.transitionIn = "cut"
        clips.replaceSubrange(i...i, with: [left, right])
        selection = right.id
    }

    func delete(_ id: UUID) {
        guard clips.count > 1 else { return }
        clips.removeAll { $0.id == id }
        if selection == id { selection = nil }
        playhead = min(playhead, totalDuration)
    }

    /// Trim a clip edge. `edge` = .start moves the in-point; .end moves the out-point.
    enum Edge { case start, end }
    func trim(_ id: UUID, edge: Edge, bySeconds delta: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var c = clips[i]
        let minLen = 0.1
        switch edge {
        case .start:
            let newStart = max(0, min(c.sourceStart + delta, c.sourceEnd - minLen))
            c.duration -= (newStart - c.sourceStart)
            c.sourceStart = newStart
        case .end:
            let newDuration = max(minLen, min(c.duration + delta, sourceDuration - c.sourceStart))
            c.duration = newDuration
        }
        clips[i] = c
    }

    func setTransition(_ id: UUID, _ kind: String) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].transitionIn = kind
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }
}
