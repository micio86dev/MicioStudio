import SwiftUI
import AVKit
import AppKit

// MARK: - PlayerView

/// Direct NSViewRepresentable wrapper — avoids a SwiftUI/AVKit getSuperclassMetadata
/// fatal error triggered by VideoPlayer on macOS 26 when presented inside a sheet.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - TimelineEditorView

struct TimelineEditorView: View {
    @ObservedObject var model: TimelineModel
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var status = ""

    /// Film strip: multiple frames per clip (one every ~2s or up to 8 frames).
    @State private var filmFrames: [UUID: [NSImage]] = [:]

    /// Toast notification
    @State private var toast: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil

    /// Captures model.playhead at drag start; reset by @GestureState.
    @GestureState private var phDragStart: Double? = nil

    /// Tracks the last cumulative DragGesture translation per clip, so trim receives
    /// an incremental delta rather than the full cumulative displacement each frame.
    @State private var lastTrimTranslation: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(spacing: 0) {
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(Color.black.opacity(0.8))
                            )
                            .padding(.bottom, 22)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

            Divider()
            transportBar.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            timelineArea
            Divider()
            exportRow.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 860, minHeight: 740)
        .task { await rebuild(seekTo: 0) }
        .task { await generateFilmStrip() }
        .onChange(of: model.clips) { _, _ in
            Task { await rebuild(seekTo: model.playhead) }
            Task { await generateFilmStrip() }
        }
        .onAppear {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main
            ) { t in
                let s = t.seconds
                Task { @MainActor in
                    if self.isPlaying { self.model.playhead = min(s, self.model.totalDuration) }
                }
            }
        }
        .onDisappear {
            if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        }
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 8) {
            Button { seekTo(0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.borderless)
                .help("Back to start")

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause  ·  Space")

            Divider().frame(height: 20)

            Button { cut() } label: {
                Label("✂ Cut at \(timeLabel(model.playhead))", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [])
            .help("Cut clip at playhead  ·  C")

            if let sel = model.selection,
               let idx = model.clips.firstIndex(where: { $0.id == sel }) {
                Button(role: .destructive) {
                    model.delete(sel)
                } label: {
                    Label("Remove Clip \(idx + 1)", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.clips.count <= 1)
                .help("Remove selected clip  ·  ⌦")

                Text("Clip \(idx + 1) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
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
            Slider(value: $model.pixelsPerSecond, in: 20...320).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline Area

    private var timelineArea: some View {
        let pps = model.pixelsPerSecond
        let totalW = (model.totalDuration + 4) * pps + 32

        return ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {

                // Layer 0: seek background — catches all taps/drags
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(seekDragGesture(pps: pps))

                // Layer 1: ruler (24px) + clips (108px)
                VStack(spacing: 0) {
                    timeRuler(pps: pps).frame(height: 24)
                    clipsRow(pps: pps).frame(height: 108)
                }

                // Layer 2: playhead with time label + handle
                playheadView(pps: pps)
            }
            .frame(width: totalW, height: 140)
        }
        .frame(height: 140)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Seek Gestures

    /// Tolerant seek during drag, exact seek on release.
    private func seekDragGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let t = max(0, min(model.totalDuration, (v.location.x - 16) / pps))
                model.playhead = t
                if isPlaying { player.pause(); isPlaying = false }
                if let (i, _) = model.clipIndex(atTimelineTime: t), i < model.clips.count {
                    model.selection = model.clips[i].id
                }
                scrubSeek(t)
            }
            .onEnded { v in
                let t = max(0, min(model.totalDuration, (v.location.x - 16) / pps))
                model.playhead = t
                Task { await exactSeek(t) }
            }
    }

    /// Fast tolerant seek (0.1s tolerance) — used during drag for low latency.
    private func scrubSeek(_ t: Double) {
        Task {
            await player.seek(
                to: CMTime(seconds: t, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                toleranceAfter:  CMTime(seconds: 0.1, preferredTimescale: 600)
            )
        }
    }

    /// Exact seek (zero tolerance) — used on mouseUp / drag end.
    private func exactSeek(_ t: Double) async {
        await player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Time Ruler

    private func timeRuler(pps: Double) -> some View {
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
        [0.25, 0.5, 1, 2, 5, 10, 30, 60].first { $0 * 5 * pps >= 50 } ?? 60
    }

    // MARK: - Clips Row

    private func clipsRow(pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            // Clips
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                clipBlock(index: index, clip: clip, pps: pps)
                    .offset(x: model.start(of: index) * pps + 16)
            }
            // Transition badges between clips
            ForEach(Array(model.clips.enumerated().dropFirst()), id: \.element.id) { index, clip in
                transitionBadge(index: index, clip: clip, pps: pps)
                    .offset(x: model.start(of: index) * pps + 16 - 15, y: (108 - 44) / 2)
            }
        }
        .frame(width: (model.totalDuration + 4) * pps + 32, height: 108)
    }

    // MARK: - Clip Block

    private func clipBlock(index: Int, clip: Clip, pps: Double) -> some View {
        let w = max(clip.duration * pps, 20)
        let selected = model.selection == clip.id

        return ZStack(alignment: .topLeading) {
            // Film strip thumbnails
            filmStrip(clip: clip, w: w)
                .frame(width: w, height: 100)
                .clipped()

            // Tint overlay
            RoundedRectangle(cornerRadius: 5)
                .fill(selected
                      ? Color.accentColor.opacity(0.3)
                      : Color.gray.opacity(0.25))

            // Border — bright when selected
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.2),
                        lineWidth: selected ? 2.5 : 1)

            // Clip label top-left
            Text("Clip \(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .padding(4)

            // Duration label bottom-right
            Text(timeLabel(clip.duration))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.8))
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // Trim handles — ALWAYS visible, drag-active only when selected
            trimHandleView(.start, clip: clip, pps: pps, active: selected)
            trimHandleView(.end,   clip: clip, pps: pps, active: selected)
        }
        .frame(width: w, height: 100)
        // No clipShape — would clip the trim handles
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = clip.id
        }
    }

    // MARK: - Film Strip

    private func filmStrip(clip: Clip, w: CGFloat) -> some View {
        let count = max(1, Int(w / 50))
        let frames = filmFrames[clip.id] ?? []

        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let img: NSImage? = frames.isEmpty ? nil : frames[i % frames.count]
                Group {
                    if let img = img {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 100)
                            .clipped()
                            .opacity(0.55)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 40, height: 100)
                    }
                }
            }
        }
    }

    // MARK: - Trim Handles

    private func trimHandleView(_ edge: TimelineModel.Edge, clip: Clip, pps: Double, active: Bool) -> some View {
        let alignment: Alignment = edge == .start ? .leading : .trailing
        if active {
            return AnyView(
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 10, height: 100)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .highPriorityGesture(
                        DragGesture()
                            .onChanged { v in
                                let last = lastTrimTranslation[clip.id] ?? 0
                                let delta = Double(v.translation.width - last) / pps
                                lastTrimTranslation[clip.id] = v.translation.width
                                model.trim(clip.id, edge: edge, bySeconds: delta)
                            }
                            .onEnded { _ in lastTrimTranslation.removeValue(forKey: clip.id) }
                    )
            )
        } else {
            return AnyView(
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 10, height: 100)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            )
        }
    }

    // MARK: - Transition Badge

    private func transitionBadge(index: Int, clip: Clip, pps: Double) -> some View {
        let kind = clip.transitionIn
        return Button { cycleTransition(clip.id, current: kind) } label: {
            VStack(spacing: 2) {
                Image(systemName: transitionIcon(kind)).font(.system(size: 11, weight: .semibold))
                Text(kind == "cut" ? "cut" : kind).font(.system(size: 8))
            }
            .foregroundStyle(.white)
            .frame(width: 30, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(kind == "cut"
                          ? AnyShapeStyle(Color.gray.opacity(0.55))
                          : AnyShapeStyle(Color.accentColor.opacity(0.85)))
            )
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Transition: \(kind)  —  click to change")
    }

    private func transitionIcon(_ kind: String) -> String {
        switch kind {
        case "fade":  return "circle.lefthalf.filled"
        case "slide": return "arrow.right"
        case "swipe": return "hand.draw"
        default:      return "scissors"
        }
    }

    private func cycleTransition(_ id: UUID, current: String) {
        let order = ["cut", "fade", "slide", "swipe"]
        let next = ((order.firstIndex(of: current) ?? 0) + 1) % order.count
        model.setTransition(id, order[next])
    }

    // MARK: - Playhead View

    private func playheadView(pps: Double) -> some View {
        ZStack(alignment: .top) {
            // Wide invisible hit area
            Rectangle()
                .fill(Color.clear)
                .frame(width: 24)
                .contentShape(Rectangle())

            // Visual red line
            Rectangle()
                .fill(Color.red)
                .frame(width: 2)

            // Diamond cap
            Diamond()
                .fill(Color.red)
                .frame(width: 12, height: 8)

            // Time bubble above diamond
            Text(timeLabel(model.playhead))
                .font(.system(size: 9, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.black.opacity(0.85))
                )
                .offset(y: -18)
        }
        .frame(height: 140)
        .offset(x: model.playhead * pps + 16 - 1)
        .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .updating($phDragStart) { _, state, _ in
                    if state == nil { state = model.playhead }
                }
                .onChanged { v in
                    let base = phDragStart ?? model.playhead
                    let t = max(0, min(model.totalDuration,
                                       base + Double(v.translation.width) / pps))
                    model.playhead = t
                    if isPlaying { player.pause(); isPlaying = false }
                    if let (i, _) = model.clipIndex(atTimelineTime: t), i < model.clips.count {
                        model.selection = model.clips[i].id
                    }
                    scrubSeek(t)
                }
                .onEnded { v in
                    let base = phDragStart ?? model.playhead
                    let t = max(0, min(model.totalDuration,
                                       base + Double(v.translation.width) / pps))
                    model.playhead = t
                    Task { await exactSeek(t) }
                }
        )
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
            Button("Done") { dismiss() }
            Button("Export edited.mov") { export() }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
        }
    }

    // MARK: - Playback

    private func togglePlay() {
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    private func seekTo(_ t: Double) {
        if isPlaying { player.pause(); isPlaying = false }
        model.playhead = t
        Task { await exactSeek(t) }
    }

    private func rebuild(seekTo time: Double) async {
        guard let (comp, vc) = try? await TimelineExporter.build(model) else { return }
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vc
        player.replaceCurrentItem(with: item)
        await exactSeek(time)
    }

    // MARK: - Cut with feedback

    private func cut() {
        let before = model.clips.count
        model.splitAtPlayhead()
        if model.clips.count > before {
            showToast("Clip split")
        } else {
            showToast("Too close to edge")
        }
    }

    // MARK: - Export

    private func export() {
        isExporting = true; exportProgress = 0
        let out = model.sourceURL.deletingLastPathComponent()
            .appendingPathComponent("edited.mov")
        Task {
            do {
                let url = try await TimelineExporter.export(model, to: out) { p in
                    Task { @MainActor in exportProgress = p }
                }
                status = "Saved \(url.lastPathComponent)"
                NSWorkspace.shared.open(url)
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
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: - Film Strip Generation

    private func generateFilmStrip() async {
        let asset = AVURLAsset(url: model.sourceURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 100, height: 60)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)

        for clip in model.clips {
            if filmFrames[clip.id] != nil { continue }  // already generated
            let interval = max(2.0, clip.duration / 8)  // max 8 frames per clip
            var frames: [NSImage] = []
            var t = clip.sourceStart
            while t < clip.sourceStart + clip.duration {
                let ct = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? await gen.image(at: ct).image {
                    frames.append(NSImage(cgImage: cg, size: NSSize(width: 100, height: 60)))
                }
                t += interval
            }
            if !frames.isEmpty { filmFrames[clip.id] = frames }
        }
    }

    // MARK: - Helpers

    private func timeLabel(_ t: Double) -> String {
        let v = max(0, t)
        return String(format: "%d:%05.2f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Diamond Shape (playhead cap)

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
