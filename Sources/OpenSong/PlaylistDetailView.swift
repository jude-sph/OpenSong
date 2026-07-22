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
                                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(theme.text3)
                                RoundedRectangle(cornerRadius: 3).fill(placeholderGradient(song.album)).frame(width: 24, height: 24)
                                Text(song.title).font(.system(size: 13)).foregroundStyle(theme.text)
                                Spacer()
                                Text(song.artist).font(.system(size: 12)).foregroundStyle(theme.text3)
                                Text(song.timeLabel).font(.system(size: 12)).foregroundStyle(theme.text3).monospacedDigit()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 7)
                            if idx < songs.count - 1 { Divider().overlay(theme.sep) }
                        }
                    }
                }
            } else {
                Text("Playlist not found").foregroundStyle(theme.text3)
            }
        }
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
            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Generate on device (.m3u)", isOn: Binding(
                    get: { pl.syncToDevice },
                    set: { _ in store.togglePlaylistDeviceSync(pl.id) }))
                    .toggleStyle(.switch).tint(theme.accent).font(.system(size: 12))
            }
        }
        .padding(20)
        .background(theme.header)
    }
}
