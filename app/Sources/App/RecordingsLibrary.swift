import SwiftUI
import AppKit

/// Lists past recording sessions (~/Movies/MicioStudio/<timestamp>/) that produced a
/// composite, so they can be re-opened, edited in the timeline, or deleted (whole folder)
/// without going through Finder.
@MainActor
final class RecordingsLibrary: ObservableObject {
    struct Item: Identifiable {
        let id: URL          // the session folder
        let name: String
        let video: URL       // composed.mov (preferred) or combined.mov
    }

    @Published private(set) var items: [Item] = []

    private var root: URL {
        let movies = (try? FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent(Config.productName, isDirectory: true)
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { dir -> Item? in
            let composed = dir.appendingPathComponent("composed.mov")
            let combined = dir.appendingPathComponent("combined.mov")
            let video: URL? = FileManager.default.fileExists(atPath: composed.path) ? composed
                : (FileManager.default.fileExists(atPath: combined.path) ? combined : nil)
            guard let video else { return nil }
            return Item(id: dir, name: dir.lastPathComponent, video: video)
        }
        .sorted { $0.name > $1.name }   // timestamp folder names → newest first
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.id)
        reload()
    }
}

struct RecordingsPanel: View {
    @ObservedObject var library: RecordingsLibrary
    var onEdit: (URL) -> Void
    @State private var pendingDelete: RecordingsLibrary.Item?

    var body: some View {
        GroupBox("Recordings") {
            VStack(alignment: .leading, spacing: 6) {
                if library.items.isEmpty {
                    Text("No recordings yet.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(library.items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "film")
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { NSWorkspace.shared.open(item.video) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless).help("Open")
                            Button { onEdit(item.video) } label: { Image(systemName: "scissors") }
                                .buttonStyle(.borderless).help("Edit in timeline")
                            Button(role: .destructive) { pendingDelete = item } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete folder")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Delete this recording?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete { library.delete(item) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes the whole session folder and every file in it. This can't be undone.")
        }
    }
}
