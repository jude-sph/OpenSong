import SwiftUI
import OpenSongCore

struct PlaylistDetailView: View {
    let playlistID: Int64
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    /// Reordering is a plain drag gesture, not drag-and-drop.
    ///
    /// The first version used `onDrag`/`onDrop`, and it was temperamental: the drop targets are hit
    /// tested, so a fast drag skips row-enter callbacks entirely, and straying outside the list
    /// fired `dropExited`, which threw away the state the drop then needed — so the row sprang back.
    /// A gesture answers to nothing but the pointer: the target index is arithmetic on how far it
    /// has moved, so overshooting, changing direction, pausing, or wandering off to the side all
    /// behave the same, and the reorder is committed when the mouse comes up wherever that happens.
    /// Crucially, the list does *not* reorder while you drag: only the dragged row moves, with a
    /// line showing where it will land. Reflowing the list under the pointer made every row flicker,
    /// because the dragged row slid out from under the cursor, SwiftUI ended the gesture on the view
    /// that had moved, `onEnded` committed, `reload()` rebuilt the library, and the whole thing
    /// started again — dozens of times a second.
    @State private var draggingID: Int64?
    /// How far the dragged row has been pulled, and where it started.
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartOrder: [Int64] = []
    @State private var dragStartIndex = 0
    /// Measured, not assumed: row height plus its divider decides how far a drag has to travel to
    /// move one place.
    @State private var rowStride: CGFloat = 41

    private var playlist: PlaylistRow? { store.playlists.first { $0.id == playlistID } }
    private var songs: [SongRow] { (playlist?.songIDs ?? []).compactMap { store.song($0) } }

    /// Where the dragged row would land, as an index into the unchanged list.
    private var dropTarget: Int? {
        guard draggingID != nil, !dragStartOrder.isEmpty else { return nil }
        return RowDrag.targetIndex(startIndex: dragStartIndex, translation: dragTranslation,
                                   rowStride: rowStride, count: dragStartOrder.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pl = playlist {
                header(pl)
                Divider().overlay(theme.sep)
                ScrollOrStack {
                    VStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                            let playing = store.player.current?.id == song.id
                            HStack(spacing: 10) {
                                ArtworkThumbnail(path: song.path, seed: song.album, size: 24, corner: 3)
                                    .overlay { if playing { NowPlayingBadge(size: 24, playing: store.player.isPlaying) } }
                                Text(song.title).font(.system(size: 13))
                                    .foregroundStyle(playing ? theme.accent : theme.text)
                                    .fontWeight(playing ? .semibold : .regular).lineLimit(1)
                                Spacer()
                                Text(song.artist).font(.system(size: 12)).foregroundStyle(theme.text3).lineLimit(1)
                                Text(song.timeLabel).font(.system(size: 12)).foregroundStyle(theme.text3).monospacedDigit()
                            }
                            .padding(.horizontal, 20).frame(height: 40)
                            .contentShape(Rectangle())
                            // Only the dragged row moves; everything else stays put.
                            .background(draggingID == song.id ? theme.stripe : Color.clear)
                            .offset(y: draggingID == song.id ? dragTranslation : 0)
                            .zIndex(draggingID == song.id ? 1 : 0)
                            .shadow(color: .black.opacity(draggingID == song.id ? 0.25 : 0), radius: 6)
                            .onTapGesture(count: 2) { store.player.play(song, in: songs) }
                            .gesture(reorderGesture(song: song, index: idx))
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
                    // The line showing where the row will land, drawn at the slot boundary: above
                    // the target row when moving up, below it when moving down.
                    .overlay(alignment: .top) {
                        if let target = dropTarget, target != dragStartIndex {
                            Rectangle().fill(theme.accent).frame(height: 2)
                                .offset(y: CGFloat(target > dragStartIndex ? target + 1 : target) * rowStride)
                        }
                    }
                    // One row's height including its divider, taken from the list itself so the
                    // arithmetic stays right if the row layout ever changes.
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: RowStrideKey.self,
                                               value: songs.isEmpty ? 41 : geo.size.height / CGFloat(songs.count))
                    })
                    .onPreferenceChange(RowStrideKey.self) { stride in
                        // The preference callback is not main-actor isolated, so hop back.
                        Task { @MainActor in rowStride = max(1, stride) }
                    }
                }
            } else {
                Text("Playlist not found").foregroundStyle(theme.text3)
            }
        }
        .onDisappear { endDrag() }
    }

    /// Drag a row to a new place. `minimumDistance` keeps ordinary clicks and double-clicks working.
    private func reorderGesture(song: SongRow, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = song.id
                    dragStartOrder = songs.map(\.id)
                    dragStartIndex = index
                }
                // The only state that changes per mouse move: one CGFloat, so the list itself is
                // not rebuilt and nothing but the dragged row and the target line redraws.
                dragTranslation = value.translation.height
            }
            .onEnded { _ in commitOrder() }
    }

    /// Write the dragged order to the library. Device playlists are rewritten in full on every
    /// sync, so the order reaches the Walkman the next time it is synced — which is worth saying,
    /// since a reorder adds and removes no files and so shows up nowhere in the sync preview.
    private func commitOrder() {
        defer { endDrag() }
        guard draggingID != nil, let target = dropTarget, target != dragStartIndex else { return }
        let order = RowDrag.reorder(dragStartOrder, from: dragStartIndex, to: target)
        guard order != playlist?.songIDs else { return }
        store.reorderPlaylist(playlistID, order)
    }

    private func endDrag() {
        draggingID = nil
        dragTranslation = 0
        dragStartOrder = []
    }

    private func move(_ from: Int, to: Int) {
        var ids = songs.map { $0.id }
        guard from >= 0, from < ids.count, to >= 0, to < ids.count else { return }
        let m = ids.remove(at: from)
        ids.insert(m, at: to)
        store.reorderPlaylist(playlistID, ids)
    }

    /// The cover, chosen by where the playlist came from — never by name alone. Asking Music.app
    /// for "the playlist called X" gave a Spotify import the artwork of an unrelated Apple Music
    /// playlist that happened to share its name.
    @ViewBuilder private func playlistArt(_ pl: PlaylistRow) -> some View {
        if let url = pl.artworkURL.flatMap(URL.init) {
            RemoteThumbnail(url: url, seed: pl.name, width: 74, height: 74, corner: 8)
        } else if pl.source == .appleMusic || pl.source == .manual {
            // `.manual` also covers playlists made before the source column existed, where asking
            // Music.app by name is the behaviour they already had. Spotify and YouTube imports never
            // do this — that borrowing is the bug.
            AppleMusicArt(name: pl.name, size: 74, corner: 8)
        } else {
            RoundedRectangle(cornerRadius: 8).fill(placeholderGradient(pl.name))
                .frame(width: 74, height: 74)
        }
    }

    private func header(_ pl: PlaylistRow) -> some View {
        @Bindable var store = store
        let totalSec = songs.reduce(0.0) { $0 + $1.durationSec }
        return HStack(spacing: 16) {
            playlistArt(pl)
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAYLIST").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
                Text(pl.name).font(.system(size: 23, weight: .heavy)).foregroundStyle(theme.text)
                let pending = store.pendingCount(forPlaylist: pl.name)
                HStack(spacing: 8) {
                    Text("\(songs.count) songs · \(Int(totalSec) / 60) min").font(.system(size: 12)).foregroundStyle(theme.text3)
                    if pending > 0 {
                        Label("\(pending) still downloading", systemImage: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accent)
                    }
                }
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
                    if !songs.isEmpty {
                        Button { store.player.playAll(songs) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(AccentButton())
                        Button { store.shuffle(songs) } label: { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(SoftButton())
                    }
                    Button("Rename") { store.openSheet = .renamePlaylist(pl.id) }.buttonStyle(SoftButton())
                    Button("Delete") { store.deletePlaylist(pl.id) }.buttonStyle(SoftButton())
                }
            }
        }
        .padding(20)
        .background(theme.header)
    }
}


/// One row's height including its divider, measured from the rendered list.
private struct RowStrideKey: PreferenceKey {
    static let defaultValue: CGFloat = 41
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
