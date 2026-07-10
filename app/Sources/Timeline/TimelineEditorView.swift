import SwiftUI
import AVKit
import AppKit

// MARK: - PlayerView

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.player = player; v.controlsStyle = .none; return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - Diamond

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
        }
    }
}

// MARK: - TimelineEditorView

// Holds AVPlayer + its time observer so deinit guarantees cleanup regardless of
// SwiftUI view lifecycle ordering (onDisappear is unreliable in NSHostingController windows).
@MainActor
private final class PlayerCoordinator: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    // nonisolated(unsafe): accessed from nonisolated deinit and @Sendable AVPlayer callback.
    nonisolated(unsafe) private var timeObserver: Any?

    func start(model: TimelineModel) {
        guard timeObserver == nil else { return }
        // Delivered on the main queue → safe to update MainActor state synchronously.
        // With zero display overlap, preview time == timeline time, so t.seconds IS the playhead.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.033, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak model] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, let model else { return }
                model.playhead = min(t.seconds, model.totalDuration)
            }
        }
    }

    func stop() {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
        player.pause()
    }
}

struct TimelineEditorView: View {
    @ObservedObject var model: TimelineModel
    @Environment(\.undoManager) private var undoManager
    @StateObject private var coordinator = PlayerCoordinator()

    @State private var isExporting    = false
    @State private var exportProgress = 0.0
    @State private var status         = ""
    @State private var filmFrames: [UUID: [NSImage]] = [:]
    @State private var toast: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil
    @State private var seekTask: Task<Void, Never>? = nil
    @State private var undoTick       = 0

    private var player: AVPlayer { coordinator.player }

    private enum DragOp {
        case seek
        case trim(clipID: UUID, edge: TimelineModel.Edge, lastX: CGFloat, startSnapshot: TimelineModel.EditSnapshot)
        case transitionBadge(clipIndex: Int)
    }
    @State private var dragOp: DragOp? = nil

    private func closeWindow() {
        coordinator.stop()
        DispatchQueue.main.async { NSApp.keyWindow?.close() }
    }

    // MARK: - Body

    var body: some View {
        let canUndo = undoTick >= 0 && (undoManager?.canUndo ?? false)
        let canRedo = undoTick >= 0 && (undoManager?.canRedo ?? false)
        VStack(spacing: 0) {
            previewPane
            Divider()
            transportBar(canUndo: canUndo, canRedo: canRedo)
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            timelineArea
            Divider()
            exportRow.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 1200, minHeight: 900)
        .task { await rebuild(seekTo: 0) }
        .task { await generateFilmStrip() }
        .onChange(of: model.clips) { _, _ in
            Task { await rebuild(seekTo: model.playhead) }
            Task { await generateFilmStrip() }
        }
        .onAppear {
            coordinator.start(model: model)
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        PlayerView(player: player)
            .frame(minHeight: 280)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(14)
            .overlay(alignment: .bottom) {
                if let msg = toast {
                    Text(msg)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 22)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
    }

    // MARK: - Transport Bar

    private func transportBar(canUndo: Bool, canRedo: Bool) -> some View {
        HStack(spacing: 10) {
            Button { seekTo(0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.borderless)

            Button { togglePlay() } label: {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            Divider().frame(height: 20)

            Button { cut() } label: {
                Label("Cut at \(timeLabel(model.playhead))", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [])
            .help("Split clip at playhead · C")

            Divider().frame(height: 20)

            Button {
                undoManager?.undo()
                undoTick += 1
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!canUndo)
            .help("Undo · ⌘Z")

            Button {
                undoManager?.redo()
                undoTick += 1
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!canRedo)
            .help("Redo · ⇧⌘Z")

            if let sel = model.selection,
               let idx = model.clips.firstIndex(where: { $0.id == sel }) {
                Divider().frame(height: 20)

                Text("Clip \(idx + 1) / \(model.clips.count)")
                    .font(.caption).foregroundStyle(.secondary)

                if idx > 0 {
                    let kind = model.clips[idx].transitionIn
                    Menu {
                        ForEach(["cut", "fade", "slide", "swipe"], id: \.self) { t in
                            Button {
                                model.setTransition(sel, t, undoManager: undoManager)
                                undoTick += 1
                            } label: {
                                Label(t.capitalized, systemImage: transitionIcon(t))
                            }
                        }
                    } label: {
                        Label("→ \(kind)", systemImage: transitionIcon(kind))
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Transition entering this clip")
                }

                Button(role: .destructive) {
                    model.delete(sel, undoManager: undoManager)
                    undoTick += 1
                } label: {
                    Label("Delete Clip", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.clips.count <= 1)
                .keyboardShortcut(.delete, modifiers: [])
                .help("Delete selected clip · ⌦")
            }

            Spacer()

            Text(timeLabel(model.playhead))
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Text("/").foregroundStyle(.secondary)
            Text(timeLabel(model.totalDuration))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $model.pixelsPerSecond, in: 20...320).frame(width: 120)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline Area

    private var timelineArea: some View {
        let pps = model.pixelsPerSecond
        let totalW = (model.totalDuration + 4) * pps + 32

        return ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    rulerView(pps: pps).frame(height: 24)
                    clipsLayer(pps: pps).frame(height: 108)
                }
                ForEach(Array(model.clips.enumerated().dropFirst()), id: \.element.id) { i, clip in
                    transitionBadgeView(clip: clip, index: i, pps: pps)
                }
                playheadLayer(pps: pps)
            }
            .frame(width: totalW, height: 140)
            .contentShape(Rectangle())
            .gesture(timelineGesture(pps: pps))
        }
        .frame(height: 140)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Transition Badge View (visual only; taps handled by parent gesture)

    private func transitionBadgeView(clip: Clip, index i: Int, pps: Double) -> some View {
        let x = model.start(of: i) * pps + 16
        let y = 24.0 + 54.0
        let kind = clip.transitionIn
        return ZStack {
            Circle()
                .fill(transitionColor(kind))
                .frame(width: 26, height: 26)
                .shadow(radius: 3)
            Image(systemName: transitionIcon(kind))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .offset(x: x - 13, y: y - 13)
        .allowsHitTesting(false)
    }

    // MARK: - Unified Timeline Gesture

    private func timelineGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if dragOp == nil {
                    if coordinator.isPlaying { player.pause(); coordinator.isPlaying = false }
                    dragOp = resolveIntent(at: v.location, pps: pps)
                }
                applyDrag(v.location, pps: pps)
            }
            .onEnded { v in
                switch dragOp {
                case .seek, .none:
                    Task { await exactSeek(previewTime(forTimelineTime: model.playhead)) }
                case .trim(_, _, _, let startSnapshot):
                    model.commitTrimUndo(before: startSnapshot, undoManager: undoManager)
                    undoTick += 1
                case .transitionBadge(let clipIndex):
                    if clipIndex < model.clips.count {
                        model.cycleTransition(model.clips[clipIndex].id, undoManager: undoManager)
                        undoTick += 1
                        let kind = model.clips[clipIndex].transitionIn
                        showToast("Transition: \(kind.capitalized)")
                    }
                }
                dragOp = nil
            }
    }

    private func resolveIntent(at pt: CGPoint, pps: Double) -> DragOp {
        // Check transition badges first (small circles at clip junctions)
        let badgeCenterY: CGFloat = 24 + 54
        for i in 1..<model.clips.count {
            let badgeCenterX = CGFloat(model.start(of: i) * pps + 16)
            let dist = sqrt(pow(pt.x - badgeCenterX, 2) + pow(pt.y - badgeCenterY, 2))
            if dist < 20 { return .transitionBadge(clipIndex: i) }
        }

        let yInClips = pt.y - 24
        guard yInClips >= 0, yInClips <= 108 else { return .seek }

        if let selID = model.selection,
           let i = model.clips.firstIndex(where: { $0.id == selID }) {
            let clipLeft  = CGFloat(model.start(of: i) * pps) + 16
            let clipRight = clipLeft + CGFloat(model.clips[i].duration * pps)
            let snap = model.takeSnapshot()
            if abs(pt.x - clipLeft)  < 18 { return .trim(clipID: selID, edge: .start, lastX: pt.x, startSnapshot: snap) }
            if abs(pt.x - clipRight) < 18 { return .trim(clipID: selID, edge: .end,   lastX: pt.x, startSnapshot: snap) }
        }
        return .seek
    }

    private func applyDrag(_ pt: CGPoint, pps: Double) {
        switch dragOp {
        case .seek, .none:
            let t = clamped(Double(pt.x - 16) / pps)
            model.playhead = t
            if let (i, _) = model.clipIndex(atTimelineTime: t), i < model.clips.count {
                model.selection = model.clips[i].id
            }
            scrubSeek(previewTime(forTimelineTime: t))

        case .trim(let clipID, let edge, let lastX, let startSnapshot):
            let delta = Double(pt.x - lastX) / pps
            model.trim(clipID, edge: edge, bySeconds: delta)
            dragOp = .trim(clipID: clipID, edge: edge, lastX: pt.x, startSnapshot: startSnapshot)

        case .transitionBadge:
            break
        }
    }

    private func clamped(_ t: Double) -> Double { max(0, min(model.totalDuration, t)) }

    // MARK: - Timeline ↔ Preview Time

    private func previewTime(forTimelineTime t: Double) -> Double {
        guard let (i, offset) = model.clipIndex(atTimelineTime: t) else { return t }
        var cursor = 0.0
        for j in 0..<i { cursor += model.clips[j].duration }
        return cursor + offset
    }

    private func timelineTime(forPreviewTime compT: Double) -> Double {
        var cursor = 0.0
        for i in model.clips.indices {
            let end = cursor + model.clips[i].duration
            if compT < end || i == model.clips.count - 1 {
                return model.start(of: i) + (compT - cursor)
            }
            cursor = end
        }
        return compT
    }

    // MARK: - Ruler

    private func rulerView(pps: Double) -> some View {
        Canvas { ctx, size in
            let step = rulerStep(pps: pps)
            var t = 0.0
            while t <= model.totalDuration + step {
                let x = t * pps + 16
                let major = t.truncatingRemainder(dividingBy: step * 5) < step * 0.01
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: size.height - (major ? 10 : 5)))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                if major {
                    ctx.draw(
                        Text(timeLabel(t)).font(.system(size: 9)).foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: size.height - 12),
                        anchor: .bottomLeading)
                }
                t += step
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }

    private func rulerStep(pps: Double) -> Double {
        [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0].first { $0 * 5 * pps >= 50 } ?? 60
    }

    // MARK: - Clips Layer

    private func clipsLayer(pps: Double) -> some View {
        let w = (model.totalDuration + 4) * pps + 32
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: w, height: 100)
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, _ in
                clipView(index: i, pps: pps)
                    .offset(x: model.start(of: i) * pps + 16)
            }
        }
    }

    private func clipView(index i: Int, pps: Double) -> some View {
        let clip     = model.clips[i]
        let w        = max(clip.duration * pps, 24)
        let selected = model.selection == clip.id
        let frames   = filmFrames[clip.id] ?? []
        let nFrames  = max(1, Int(ceil(w / 40.0)))

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<nFrames, id: \.self) { fi in
                    Group {
                        if frames.isEmpty {
                            Rectangle().fill(Color.gray.opacity(0.15))
                        } else {
                            Image(nsImage: frames[fi % frames.count])
                                .resizable().scaledToFill().clipped().opacity(0.52)
                        }
                    }
                    .frame(width: 40, height: 100)
                }
            }
            .frame(width: w, height: 100).clipped()

            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.10))

            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.22),
                        lineWidth: selected ? 2.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Clip \(i + 1)").font(.caption2.bold()).foregroundStyle(.white)
                    .shadow(color: .black, radius: 1)
            }
            .padding(5)

            Text(timeLabel(clip.duration))
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.8))
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            trimHandles(selected: selected).frame(width: w, height: 100)
        }
        .frame(width: w, height: 100)
    }

    @ViewBuilder
    private func trimHandles(selected: Bool) -> some View {
        if selected {
            HStack {
                VStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 12, height: 36)
                        .cornerRadius(3)
                }
                .frame(maxHeight: .infinity)
                Spacer()
                VStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 12, height: 36)
                        .cornerRadius(3)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Playhead Layer

    private func playheadLayer(pps: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 2)
            VStack(spacing: 2) {
                Text(timeLabel(model.playhead))
                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .fixedSize()
                Diamond().fill(Color.red).frame(width: 14, height: 10)
            }
        }
        .frame(width: 2, height: 140)
        .offset(x: model.playhead * pps + 16)
        .allowsHitTesting(false)
    }

    // MARK: - Export Row

    private var exportRow: some View {
        HStack {
            if isExporting {
                ProgressView(value: exportProgress).frame(width: 160)
                Text("\(Int(exportProgress * 100))%").font(.caption)
            } else if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { closeWindow() }
            Button("Export edited.mov") { exportVideo() }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
        }
    }

    // MARK: - Playback

    private func togglePlay() {
        coordinator.isPlaying ? player.pause() : player.play()
        coordinator.isPlaying.toggle()
    }

    private func seekTo(_ timelineTime: Double) {
        if coordinator.isPlaying { player.pause(); coordinator.isPlaying = false }
        model.playhead = timelineTime
        Task { await exactSeek(previewTime(forTimelineTime: timelineTime)) }
    }

    private func scrubSeek(_ compTime: Double) {
        seekTask?.cancel()
        seekTask = Task {
            await player.seek(
                to: CMTime(seconds: compTime, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                toleranceAfter:  CMTime(seconds: 0.1, preferredTimescale: 600))
        }
    }

    private func exactSeek(_ compTime: Double) async {
        seekTask?.cancel()
        seekTask = nil
        await player.seek(
            to: CMTime(seconds: compTime, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Rebuild Preview

    private func rebuild(seekTo timelineTime: Double) async {
        guard let comp = try? await TimelineExporter.buildPreview(model) else { return }
        let item = AVPlayerItem(asset: comp)
        player.replaceCurrentItem(with: item)
        await exactSeek(previewTime(forTimelineTime: timelineTime))
    }

    // MARK: - Cut

    private func cut() {
        let time = timeLabel(model.playhead)
        if model.splitAtPlayhead(undoManager: undoManager) {
            undoTick += 1
            showToast("Split at \(time) · ⌦ to delete selected clip · ⌘Z to undo")
        } else {
            showToast("Too close to clip edge")
        }
    }

    // MARK: - Export

    private func exportVideo() {
        isExporting = true; exportProgress = 0
        let out = model.sourceURL.deletingLastPathComponent().appendingPathComponent("edited.mov")
        Task {
            do {
                let url = try await TimelineExporter.export(model, to: out) { p in
                    Task { @MainActor in exportProgress = p }
                }
                status = "Saved \(url.lastPathComponent)"
                // Open Finder with the exported file selected so it's easy to find.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    // MARK: - Toast

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: - Film Strip

    private func generateFilmStrip() async {
        let asset = AVURLAsset(url: model.sourceURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 100, height: 60)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)
        for clip in model.clips {
            if filmFrames[clip.id] != nil { continue }
            let interval = max(2.0, clip.duration / 8)
            var frames: [NSImage] = []
            var t = clip.sourceStart
            while t < clip.sourceStart + clip.duration {
                if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                    frames.append(NSImage(cgImage: cg, size: NSSize(width: 100, height: 60)))
                }
                t += interval
            }
            if !frames.isEmpty { filmFrames[clip.id] = frames }
        }
    }

    // MARK: - Helpers

    private func transitionIcon(_ kind: String) -> String {
        switch kind {
        case "fade":  return "circle.lefthalf.filled"
        case "slide": return "arrow.right"
        case "swipe": return "hand.draw"
        default:      return "scissors"
        }
    }

    private func transitionColor(_ kind: String) -> Color {
        switch kind {
        case "fade":  return .purple
        case "slide": return .blue
        case "swipe": return .orange
        default:      return Color(NSColor.systemGray)
        }
    }

    private func timeLabel(_ t: Double) -> String {
        let v = max(0, t)
        return String(format: "%d:%05.2f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }
}
