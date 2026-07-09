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
    @State private var thumbnails: [UUID: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: player)
                .frame(minHeight: 300)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(14)

            Divider()
            transportBar.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            timelineArea
            Divider()
            exportRow.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 820, minHeight: 720)
        .task { await rebuild(seekTo: 0) }
        .task { await generateThumbnails() }
        .onChange(of: model.clips) { _, _ in
            Task { await rebuild(seekTo: model.playhead) }
            Task { await generateThumbnails() }
        }
        .onAppear {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
                    let seconds = t.seconds
                    Task { @MainActor in
                        if isPlaying { model.playhead = min(seconds, model.totalDuration) }
                    }
                }
        }
        .onDisappear {
            if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        }
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 8) {
            // Back to start
            Button { seekAndPause(0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.borderless)
                .help("Back to start")

            // Play / Pause  (Space)
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause  ·  Space")

            Divider().frame(height: 20)

            // Cut at playhead  (C)
            Button { model.splitAtPlayhead() } label: {
                Label("Cut", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [])
            .help("Cut clip at playhead  ·  C")

            // Delete selected clip
            Button(role: .destructive) {
                if let s = model.selection { model.delete(s) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(model.selection == nil || model.clips.count <= 1)
            .help("Remove selected clip")

            Spacer()

            // Time counter
            Group {
                Text(timeLabel(model.playhead))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text("/")
                    .foregroundStyle(.secondary)
                Text(timeLabel(model.totalDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Zoom
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $model.pixelsPerSecond, in: 20 ... 320).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline

    private var timelineArea: some View {
        let pps = model.pixelsPerSecond
        let totalW = (model.totalDuration + 5) * pps + 32

        return ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Seek target (whole background)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            let t = max(0, min(model.totalDuration, (v.location.x - 16) / pps))
                            model.playhead = t
                            if isPlaying { player.pause(); isPlaying = false }
                            Task { await seek(t) }
                        })

                VStack(spacing: 0) {
                    timeRuler(pps: pps).frame(height: 22)
                    clipsRow(pps: pps).frame(height: 88)
                }

                playheadView(pps: pps)
            }
            .frame(width: totalW, height: 116)
        }
        .frame(height: 116)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Ruler

    private func timeRuler(pps: Double) -> some View {
        Canvas { ctx, size in
            let step = rulerStep(pps: pps)
            var t = 0.0
            while t <= model.totalDuration + step {
                let x = t * pps + 16
                let major = t.truncatingRemainder(dividingBy: step * 5) < step * 0.01
                let h: CGFloat = major ? 10 : 5
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: size.height - h))
                        p.addLine(to: CGPoint(x: x, y: size.height)) },
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

    // MARK: Clips row

    private func clipsRow(pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                clipBlock(index: index, clip: clip, pps: pps)
                    .offset(x: model.start(of: index) * pps + 16)
            }
            ForEach(Array(model.clips.enumerated().dropFirst()), id: \.element.id) { index, clip in
                transitionBadge(index: index, clip: clip, pps: pps)
                    .offset(x: model.start(of: index) * pps + 16 - 15,
                            y: (88 - 42) / 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clipBlock(index: Int, clip: Clip, pps: Double) -> some View {
        let w = max(clip.duration * pps, 16)
        let selected = model.selection == clip.id
        return ZStack(alignment: .topLeading) {
            // Thumbnail
            if let img = thumbnails[clip.id] {
                Image(nsImage: img)
                    .resizable().scaledToFill()
                    .frame(width: w, height: 80).clipped().opacity(0.55)
            }
            // Tint
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.3))
            // Border
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: selected ? 2 : 1)
            // Label
            Text("Clip \(index + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .padding([.leading, .top], 5)
        }
        .frame(width: w, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Trim handles
        .overlay(alignment: .leading) {
            if selected { trimHandle(clip, .start, pps: pps) }
        }
        .overlay(alignment: .trailing) {
            if selected { trimHandle(clip, .end, pps: pps) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let t = model.start(of: index)
            model.selection = clip.id
            model.playhead = t
            Task { await seek(t) }
        }
    }

    private func trimHandle(_ clip: Clip, _ edge: TimelineModel.Edge, pps: Double) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 8, height: 80)
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture().onChanged { v in
                model.trim(clip.id, edge: edge,
                           bySeconds: Double(v.translation.width) / pps)
            })
    }

    // MARK: Transition badge

    private func transitionBadge(index: Int, clip: Clip, pps: Double) -> some View {
        let kind = clip.transitionIn
        return Button { cycleTransition(clip.id, current: kind) } label: {
            VStack(spacing: 2) {
                Image(systemName: transitionIcon(kind)).font(.system(size: 11, weight: .semibold))
                Text(kind == "cut" ? "cut" : kind).font(.system(size: 8))
            }
            .foregroundStyle(.white)
            .frame(width: 30, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(kind == "cut"
                          ? AnyShapeStyle(Color.gray.opacity(0.55))
                          : AnyShapeStyle(Color.accentColor.opacity(0.85)))
            )
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
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
        let next = (order.firstIndex(of: current) ?? 0 + 1) % order.count
        model.setTransition(id, order[next])
    }

    // MARK: Playhead

    private func playheadView(pps: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 2)
            Diamond()
                .fill(Color.red)
                .frame(width: 12, height: 8)
        }
        .frame(height: 116)
        .offset(x: model.playhead * pps + 16 - 1)
        .allowsHitTesting(false)
    }

    // MARK: Export

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

    // MARK: - Playback helpers

    private func togglePlay() {
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    private func seekAndPause(_ t: Double) {
        if isPlaying { player.pause(); isPlaying = false }
        model.playhead = t
        Task { await seek(t) }
    }

    private func rebuild(seekTo time: Double) async {
        guard let (comp, vc) = try? await TimelineExporter.build(model) else { return }
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vc
        player.replaceCurrentItem(with: item)
        await seek(time)
    }

    private func seek(_ time: Double) async {
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

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

    private func timeLabel(_ t: Double) -> String {
        let v = max(0, t)
        return String(format: "%d:%05.2f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Thumbnails

    private func generateThumbnails() async {
        let asset = AVURLAsset(url: model.sourceURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 120)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
        for clip in model.clips {
            let t = CMTime(seconds: clip.sourceStart + min(clip.duration * 0.15, 0.5),
                           preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                thumbnails[clip.id] = NSImage(cgImage: cg, size: NSSize(width: 200, height: 120))
            }
        }
    }
}

// MARK: - Diamond shape (playhead cap)

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
