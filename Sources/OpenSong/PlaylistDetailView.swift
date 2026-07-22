import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: Int64
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var playlist: PlaylistRow? { store.playlists.first { $0.id == playlistID } }
    private var songs: [SongRow] { (playlist?.songIDs ?? []).compactMap { store.song($0) } }

    var body: some View {
        VStack(spacing: 0) {
            if let pl = playlist {
                header(pl)
                Divider().overlay(theme.sep)
                ScrollOrStack {
                    VStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                            HStack(spacing: 10) {
                                ArtworkThumbnail(path: song.path, seed: song.album, size: 24, corner: 3)
                                Text(song.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                                Spacer()
                                Text(song.artist).font(.system(size: 12)).foregroundStyle(theme.text3).lineLimit(1)
                                Text(song.timeLabel).font(.system(size: 12)).foregroundStyle(theme.text3).monospacedDigit()
                            }
                            .padding(.horizontal, 20).frame(height: 40)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.player.play(song, in: songs) }
                            .contextMenu {
                                Button("Play") { store.player.play(song, in: songs) }
                                if idx > 0 { Button("Move Up") { move(idx, to: idx - 1) } }
                                if idx < songs.count - 1 { Button("Move Down") { move(idx, to: idx + 1) } }
                                Divider()
                                Button("Remove from Playlist", role: .destructive) {
                                    store.removeFromPlaylist(playlistID, song.id)
                                }
                            }
                            Divider().overlay(theme.sep)
                        }
                    }
                }
            } else {
                Text("Playlist not found").foregroundStyle(theme.text3)
            }
        }
    }

    private func move(_ from: Int, to: Int) {
        var ids = songs.map { $0.id }
        guard from >= 0, from < ids.count, to >= 0, to < ids.count else { return }
        let m = ids.remove(at: from)
        ids.insert(m, at: to)
        store.reorderPlaylist(playlistID, ids)
    }

    private func header(_ pl: PlaylistRow) -> some View {
        @Bindable var store = store
        let totalSec = songs.reduce(0.0) { $0 + $1.durationSec }
        return HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8).fill(placeholderGradient(pl.name)).frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAYLIST").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
                Text(pl.name).font(.system(size: 23, weight: .heavy)).foregroundStyle(theme.text)
                Text("\(songs.count) songs · \(Int(totalSec) / 60) min").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Sync to device").font(.system(size: 12)).foregroundStyle(theme.text2)
                    SwitchToggle(isOn: Binding(
                        get: { pl.syncToDevice },
                        set: { _ in store.togglePlaylistDeviceSync(pl.id) }))
                }
                HStack(spacing: 8) {
                    Button("Rename") { store.openSheet = .renamePlaylist(pl.id) }.buttonStyle(SoftButton())
                    Button("Delete") { store.deletePlaylist(pl.id) }.buttonStyle(SoftButton())
                }
            }
        }
        .padding(20)
        .background(theme.header)
    }
}
