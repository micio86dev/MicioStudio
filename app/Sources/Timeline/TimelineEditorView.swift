import SwiftUI
import AVKit

/// TikTok-style timeline editor: trim/split/delete clips of a recording and put
/// fade/slide/swipe transitions between the cuts, with a live preview and zoom.
struct TimelineEditorView: View {
    @ObservedObject var model: TimelineModel
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var status = ""

    var body: some View {
        VStack(spacing: 10) {
            VideoPlayer(player: player)
                .frame(minHeight: 260)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            transport
            transitionRow
            timeline
            exportRow
        }
        .padding()
        .frame(minWidth: 720, minHeight: 640)
        .task { await rebuild(seekTo: 0) }
        .onChange(of: model.clips) { _, _ in Task { await rebuild(seekTo: model.playhead) } }
        .onAppear {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
                    if isPlaying { model.playhead = min(t.seconds, model.totalDuration) }
                }
        }
        .onDisappear { if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil } }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { togglePlay() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
            Button(role: .destructive) { if let s = model.selection { model.delete(s) } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection == nil || model.clips.count <= 1)
            Text(timeLabel(model.playhead) + " / " + timeLabel(model.totalDuration))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
            Slider(value: $model.pixelsPerSecond, in: 20...260).frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
        }
    }

    @ViewBuilder private var transitionRow: some View {
        if let sel = model.selection, let i = model.clips.firstIndex(where: { $0.id == sel }), i > 0 {
            HStack {
                Text("Transition into clip \(i + 1):").font(.caption)
                Picker("", selection: Binding(
                    get: { model.clips[i].transitionIn },
                    set: { model.setTransition(sel, $0) })) {
                    Text("Cut").tag("cut"); Text("Fade").tag("fade")
                    Text("Slide").tag("slide"); Text("Swipe").tag("swipe")
                }
                .labelsHidden().frame(width: 220)
                Spacer()
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        clipBlock(index, clip)
                    }
                }
                Rectangle().fill(.red).frame(width: 2, height: 96)
                    .offset(x: model.playhead * model.pixelsPerSecond)
                    .allowsHitTesting(false)
            }
            .frame(height: 100)
            .padding(.trailing, 200)
        }
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func clipBlock(_ index: Int, _ clip: Clip) -> some View {
        let width = max(clip.duration * model.pixelsPerSecond, 8)
        let selected = model.selection == clip.id
        return RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.35))
            .frame(width: width, height: 80)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .secondary.opacity(0.4),
                                                              lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topLeading) {
                Text("clip \(index + 1)").font(.caption2).padding(3).foregroundStyle(.white)
            }
            .overlay(alignment: .leading) {
                if index > 0, clip.transitionIn != "cut" {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2).padding(2).background(.black.opacity(0.5)).clipShape(Circle())
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .trailing) { if selected { trimHandle(clip, .end) } }
            .overlay(alignment: .leading) { if selected { trimHandle(clip, .start) } }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection = clip.id
                model.playhead = model.start(of: index)
                Task { await seek(model.playhead) }
            }
    }

    private func trimHandle(_ clip: Clip, _ edge: TimelineModel.Edge) -> some View {
        Rectangle().fill(Color.white.opacity(0.9)).frame(width: 8, height: 80)
            .gesture(DragGesture()
                .onEnded { v in
                    model.trim(clip.id, edge: edge, bySeconds: Double(v.translation.width) / model.pixelsPerSecond)
                })
    }

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
                .buttonStyle(.borderedProminent).disabled(isExporting)
        }
    }

    // MARK: - Playback

    private func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
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
        isExporting = true
        exportProgress = 0
        let out = model.sourceURL.deletingLastPathComponent().appendingPathComponent("edited.mov")
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
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}
