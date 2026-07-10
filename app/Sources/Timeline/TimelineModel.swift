import AVFoundation
import Combine

struct Clip: Identifiable, Equatable {
    let id = UUID()
    var sourceStart: Double
    var duration: Double
    var transitionIn: String  // cut | fade | slide | swipe

    var sourceEnd: Double { sourceStart + duration }
}

@MainActor
final class TimelineModel: ObservableObject {
    let sourceURL: URL
    let sourceDuration: Double

    @Published var clips: [Clip]
    @Published var playhead: Double = 0
    @Published var pixelsPerSecond: Double = 80
    @Published var selection: UUID?
    @Published var transitionDuration: Double = 0.5

    init(sourceURL: URL, sourceDuration: Double) {
        self.sourceURL = sourceURL
        self.sourceDuration = sourceDuration
        self.clips = [Clip(sourceStart: 0, duration: sourceDuration, transitionIn: "cut")]
    }

    // MARK: - Layout

    func overlap(before index: Int) -> Double {
        guard index > 0, clips.indices.contains(index), clips[index].transitionIn != "cut" else { return 0 }
        return min(transitionDuration, min(clips[index - 1].duration, clips[index].duration) / 2)
    }

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

    func clipIndex(atTimelineTime time: Double) -> (index: Int, offset: Double)? {
        for i in clips.indices {
            let s = start(of: i)
            if time >= s && time < s + clips[i].duration + 0.0001 {
                return (i, time - s)
            }
        }
        return clips.isEmpty ? nil : (clips.count - 1, clips[clips.count - 1].duration)
    }

    func sourceTime(atTimelineTime time: Double) -> Double? {
        guard let (i, offset) = clipIndex(atTimelineTime: time) else { return nil }
        return clips[i].sourceStart + offset
    }

    // MARK: - Undo / Redo

    struct EditSnapshot {
        var clips: [Clip]
        var selection: UUID?
        var playhead: Double
    }

    func takeSnapshot() -> EditSnapshot {
        EditSnapshot(clips: clips, selection: selection, playhead: playhead)
    }

    func applySnapshot(_ snap: EditSnapshot) {
        clips = snap.clips
        selection = snap.selection
        playhead = snap.playhead
    }

    func registerChange(before: EditSnapshot, after: EditSnapshot, undoManager: UndoManager?, name: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.applySnapshot(before)
            target.registerChange(before: after, after: before, undoManager: undoManager, name: name)
        }
        undoManager?.setActionName(name)
    }

    // MARK: - Edits

    @discardableResult
    func splitAtPlayhead(undoManager: UndoManager? = nil) -> Bool {
        guard let (i, offset) = clipIndex(atTimelineTime: playhead),
              offset > 0.01, offset < clips[i].duration - 0.01 else { return false }
        let before = takeSnapshot()
        var left = clips[i], right = clips[i]
        left.duration = offset
        right.sourceStart = clips[i].sourceStart + offset
        right.duration = clips[i].duration - offset
        right.transitionIn = "cut"
        clips.replaceSubrange(i...i, with: [left, right])
        selection = right.id
        registerChange(before: before, after: takeSnapshot(), undoManager: undoManager, name: "Split Clip")
        return true
    }

    func delete(_ id: UUID, undoManager: UndoManager? = nil) {
        guard clips.count > 1 else { return }
        let before = takeSnapshot()
        clips.removeAll { $0.id == id }
        if selection == id { selection = clips.first?.id }
        playhead = min(playhead, totalDuration)
        registerChange(before: before, after: takeSnapshot(), undoManager: undoManager, name: "Delete Clip")
    }

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

    func commitTrimUndo(before: EditSnapshot, undoManager: UndoManager?) {
        registerChange(before: before, after: takeSnapshot(), undoManager: undoManager, name: "Trim Clip")
    }

    func setTransition(_ id: UUID, _ kind: String, undoManager: UndoManager? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let before = takeSnapshot()
        clips[i].transitionIn = kind
        registerChange(before: before, after: takeSnapshot(), undoManager: undoManager, name: "Change Transition")
    }

    func cycleTransition(_ id: UUID, undoManager: UndoManager? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let kinds = ["cut", "fade", "slide", "swipe"]
        let current = clips[i].transitionIn
        let currentIndex = kinds.firstIndex(of: current) ?? 0
        let next = kinds[(currentIndex + 1) % kinds.count]
        setTransition(id, next, undoManager: undoManager)
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }
}
