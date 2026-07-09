import AVFoundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SoundKind: String { case music, effects }

/// Background music + one-shot sound effects (TikTok-studio style). Files live in
/// Application Support/<product>/Audio/{music,effects} and are imported/persisted there.
/// Playback goes through the system output, so the recording's system-audio capture
/// (SCK, `excludesCurrentProcessAudio = false`) records it into the export automatically.
@MainActor
final class Soundboard: ObservableObject {
    enum LoopMode: String, CaseIterable, Identifiable {
        case stopAtEnd, repeatOne, repeatAll, autoNext
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stopAtEnd: return "Stop at end"
            case .repeatOne: return "Repeat one"
            case .repeatAll: return "Repeat all"
            case .autoNext: return "Auto next"
            }
        }
    }

    @Published private(set) var music: [URL] = []
    @Published private(set) var effects: [URL] = []
    @Published private(set) var playingIndex: Int?
    @Published private(set) var isPlaying = false
    @Published var loopMode: LoopMode = .stopAtEnd
    @Published var musicVolume: Float = 0.7 { didSet { musicPlayer?.volume = musicVolume } }
    @Published var effectsVolume: Float = 0.9

    private var musicPlayer: AVAudioPlayer?
    private var effectPlayers: [AVAudioPlayer] = []
    private let delegate = PlayerDelegate()

    init() {
        delegate.board = self
        reload()
    }

    var musicDir: URL { Self.dir(.music) }
    var effectsDir: URL { Self.dir(.effects) }

    func reload() {
        music = Self.list(musicDir)
        effects = Self.list(effectsDir)
    }

    func importFiles(_ urls: [URL], into kind: SoundKind) {
        let dir = kind == .music ? musicDir : effectsDir
        for u in urls {
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        reload()
    }

    func playMusic(at index: Int) {
        guard music.indices.contains(index) else { return }
        guard let player = try? AVAudioPlayer(contentsOf: music[index]) else { return }
        player.delegate = delegate
        player.numberOfLoops = loopMode == .repeatOne ? -1 : 0
        player.volume = musicVolume
        player.play()
        musicPlayer = player
        playingIndex = index
        isPlaying = true
    }

    func playEffect(_ url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = effectsVolume
        player.play()
        effectPlayers.append(player)
        effectPlayers.removeAll { !$0.isPlaying }   // prune finished one-shots
    }

    func togglePlayPause() {
        guard let player = musicPlayer else {
            if !music.isEmpty { playMusic(at: playingIndex ?? 0) }
            return
        }
        if player.isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
    }

    func stop() {
        musicPlayer?.stop()
        musicPlayer = nil
        isPlaying = false
        playingIndex = nil
    }

    func next() {
        guard !music.isEmpty else { return }
        playMusic(at: ((playingIndex ?? -1) + 1) % music.count)
    }

    fileprivate func trackFinished() {
        switch loopMode {
        case .stopAtEnd: stop()
        case .repeatOne: break // handled by numberOfLoops = -1
        case .repeatAll, .autoNext:
            guard let i = playingIndex else { return }
            let nextIndex = i + 1
            if nextIndex < music.count { playMusic(at: nextIndex) }
            else if loopMode == .repeatAll, !music.isEmpty { playMusic(at: 0) }
            else { stop() }
        }
    }

    static func dir(_ kind: SoundKind) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("\(Config.productName)/Audio/\(kind.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let audio = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac"]
        return items.filter { audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    weak var board: Soundboard?
    // AVAudioPlayer delivers this on the thread that started playback — the main thread
    // here, since play() is called from the @MainActor Soundboard.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let target = board   // local avoids capturing nonisolated self in the MainActor closure
        MainActor.assumeIsolated { target?.trackFinished() }
    }
}

/// Soundboard UI: background-music transport + loop mode, and a grid of one-shot effects.
struct SoundboardPanel: View {
    @ObservedObject var board: Soundboard

    var body: some View {
        GroupBox("Soundboard") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { board.togglePlayPause() } label: {
                        Image(systemName: board.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { board.stop() } label: { Image(systemName: "stop.fill") }
                    Button { board.next() } label: { Image(systemName: "forward.fill") }
                    Picker("", selection: $board.loopMode) {
                        ForEach(Soundboard.LoopMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Spacer()
                    Button("Add music") { importFiles(.music) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "music.note").font(.caption2)
                    Slider(value: $board.musicVolume, in: 0...1)
                    Image(systemName: "speaker.wave.2.fill").font(.caption2)
                    Slider(value: $board.effectsVolume, in: 0...1)
                }
                .help("Music volume · Effects volume")

                if board.music.isEmpty {
                    Text("No music yet — add royalty-free tracks (Pixabay, YouTube Audio Library…).")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(board.music.enumerated()), id: \.element) { index, url in
                        HStack {
                            Image(systemName: index == board.playingIndex ? "music.note" : "music.note.list")
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Play") { board.playMusic(at: index) }.buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                }

                Divider()
                HStack {
                    Text("Effects").font(.caption.bold())
                    Spacer()
                    Button("Add SFX") { importFiles(.effects) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                    ForEach(board.effects, id: \.self) { url in
                        Button { board.playEffect(url) } label: {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1).font(.caption2).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func importFiles(_ kind: SoundKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        if panel.runModal() == .OK { board.importFiles(panel.urls, into: kind) }
    }
}
