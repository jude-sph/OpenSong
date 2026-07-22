import SwiftUI

struct NewPlaylistView: View {
    let songIDs: [Int64]
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Playlist").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            if !songIDs.isEmpty {
                Text("\(songIDs.count) song(s) will be added.").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            TextField("Playlist name", text: $name).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 30)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Create") {
                    if let id = store.newPlaylist(name: name, songIDs: songIDs) {
                        store.openSheet = nil
                        store.activeView = .playlist(id)
                    }
                }.buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 380)
        .background(theme.sheet)
    }
}

struct RenamePlaylistView: View {
    let playlistID: Int64
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Playlist").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            TextField("Playlist name", text: $name).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 30)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Save") { store.renamePlaylist(playlistID, name); store.openSheet = nil }
                    .buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 380)
        .background(theme.sheet)
        .onAppear { name = store.playlists.first { $0.id == playlistID }?.name ?? "" }
    }
}
