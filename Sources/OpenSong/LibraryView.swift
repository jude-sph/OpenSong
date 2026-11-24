import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    // Detail modes (a single album's tracks, or a single artist's albums). filterAlbumID takes
    // priority so an album opened from within an artist still shows, and backing out of it
    // returns to that artist.
    private var detailAlbum: AlbumRow? { store.filterAlbumID.flatMap { id in store.albums.first { $0.id == id } } }
    private var artistDetail: String? { (store.activeView == .artists && store.filterAlbumID == nil) ? store.filterArtist : nil }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.sep)
            content
        }
    }

    @ViewBuilder private var header: some View {
        if let album = detailAlbum {
            let dev = store.albumDeviceState(album)
            detailHeader(title: album.name, subtitle: "\(album.songIDs.count) songs · \(album.artist)",
                         back: { store.filterAlbumID = nil }) {
                shuffleButton { store.shuffle(store.filteredSongs) }
                Button { store.findArtwork(for: album) } label: { Label("Replace artwork", systemImage: "photo") }
                    .buttonStyle(SoftButton())
                Button { store.backfillTrackNumbers(for: album) } label: {
                    Label(store.trackBackfilling ? "Fixing…" : "Fix track numbers", systemImage: "list.number")
                }.buttonStyle(SoftButton()).disabled(store.trackBackfilling)
                Button {
                    store.addToAppleMusic(album.songIDs, label: "Adding “\(album.name)” to Apple Music…")
                } label: {
                    Label(store.addingToAppleMusic ? "Adding…" : "Add to Apple Music", systemImage: "music.note.house")
                }.buttonStyle(SoftButton()).disabled(store.addingToAppleMusic)
                if dev.onDevice < dev.total {
                    Button { store.pinAlbum(album, true) } label: { Label("Send album to device", systemImage: "ipod") }
                        .buttonStyle(AccentButton())
                } else {
                    Button { store.pinAlbum(album, false) } label: { Label("On device — remove", systemImage: "ipod") }
                        .buttonStyle(SoftButton())
                }
            }
        } else if let name = artistDetail {
            detailHeader(title: name, subtitle: "\(store.albums.filter { $0.artist == name }.count) albums",
                         back: { store.filterArtist = nil }) {
                shuffleButton { store.shuffle(store.songsForArtist(name)) }
            }
        } else {
            @Bindable var store = store
            ContentHeader(title: normalTitle, subtitle: normalSubtitle) {
                HStack(spacing: 10) {
                    if store.activeView == .allSongs && !store.filteredSongs.isEmpty {
                        shuffleButton { store.shuffle(store.filteredSongs) }
                    }
                    if store.activeView == .albums && !store.albums.isEmpty {
                        SegmentedControl(options: AlbumSort.allCases.map { ($0.rawValue, $0) },
                                         selection: $store.albumSort)
                    }
                    Button { store.openSheet = .addURL } label: {
                        Label("Paste URL", systemImage: "link")
                    }.buttonStyle(SoftButton())
                    Button { store.beginImport() } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }.buttonStyle(SoftButton())
                    SearchField(text: $store.search)
                }
            }
        }
    }

    private func shuffleButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(SoftButton())
    }

    @ViewBuilder private var content: some View {
        if detailAlbum != nil {
            SongsTable()
        } else if let name = artistDetail {
            AlbumsGrid(artistFilter: name)
        } else {
            switch store.activeView {
            case .albums: AlbumsGrid()
            case .artists: ArtistsList()
            default: SongsTable()
            }
        }
    }

    private func detailHeader<A: View>(title: String, subtitle: String, back: @escaping () -> Void,
                                       @ViewBuilder actions: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold)).tracking(-0.2).foregroundStyle(theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
        .background(theme.header)
    }

    private var normalTitle: String {
        switch store.activeView {
        case .albums: return "Albums"
        case .artists: return "Artists"
        default: return "All Songs"
        }
    }
    private var normalSubtitle: String {
        switch store.activeView {
        case .albums: return "\(store.albums.count) albums"
        case .artists: return "\(store.artists.count) artists"
        default: return "\(store.filteredSongs.count) songs"
        }
    }
}

struct ContentHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold)).tracking(-0.2).foregroundStyle(theme.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
        .background(theme.header)
    }
}

struct SearchField: View {
    @Binding var text: String
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.text3)
            if renderMode {
                Text(text.isEmpty ? "Search" : text)
                    .font(.system(size: 12)).foregroundStyle(text.isEmpty ? theme.text3 : theme.text)
                    .frame(width: 150, alignment: .leading)
            } else {
                TextField("Search", text: $text).textFieldStyle(.plain).font(.system(size: 12))
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
    }
}

/// Custom pure-SwiftUI table (renders offscreen via ImageRenderer and matches the
/// design's custom table look). Columns: on-device dot, artwork, Title, Artist, Album,
/// Time (right), Kind (right).
struct SongsTable: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var anchor: Int? = nil

    /// Songs a context action applies to: the multi-selection if the clicked song is part
    /// of it, otherwise just the clicked song.
    private func targetIDs(_ song: SongRow) -> Set<Int64> {
        (store.selection.contains(song.id) && store.selection.count > 1) ? store.selection : [song.id]
    }

    /// The given ids in the table's current display order (so Play/Play-Next queue correctly).
    private func orderedIDs(_ ids: Set<Int64>) -> [Int64] {
        store.filteredSongs.map { $0.id }.filter { ids.contains($0) }
    }

    /// Click / ⇧-click (range) / ⌘-click (toggle) selection, like the Apple Music detail list.
    private func handleTap(_ idx: Int, _ song: SongRow) {
        let mods = NSEvent.modifierFlags
        let rows = store.filteredSongs
        if mods.contains(.shift), let a = anchor, a < rows.count {
            let lo = min(a, idx), hi = max(a, idx)
            store.selection.formUnion(rows[lo...hi].map { $0.id })
        } else if mods.contains(.command) {
            if store.selection.contains(song.id) { store.selection.remove(song.id) } else { store.selection.insert(song.id) }
            anchor = idx
        } else {
            store.selection = [song.id]; anchor = idx
        }
    }

    var body: some View {
        if store.songs.isEmpty {
            emptyLibrary
        } else if store.filteredSongs.isEmpty {
            emptyState(icon: "magnifyingglass", title: "No matches", subtitle: "Nothing matches “\(store.search)”.")
        } else {
            table
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(theme.text3)
            Text("Your library is empty").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text("Import your loose music folders — OpenSong will organize them and suggest clean metadata.")
                .font(.system(size: 12)).foregroundStyle(theme.text3).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button { store.beginImport() } label: { Label("Import music…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(AccentButton())
                Button { store.adoptFromDevice() } label: { Label("Import from Walkman", systemImage: "ipod") }
                    .buttonStyle(SoftButton())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(theme.text3)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.text3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().overlay(theme.sep)
            ScrollOrStack(alignment: .leading) {
                ForEach(Array(store.filteredSongs.enumerated()), id: \.element.id) { idx, song in
                    rowView(song, striped: idx % 2 == 1)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.player.play(song, in: store.filteredSongs) }
                        .onTapGesture { handleTap(idx, song) }
                        .contextMenu {
                            let ids = targetIDs(song)
                            let n = ids.count
                            Button(n > 1 ? "Play \(n)" : "Play") { store.playNow(orderedIDs(ids)) }
                            Button(n > 1 ? "Play \(n) Next" : "Play Next") { store.playNext(orderedIDs(ids)) }
                            if n == 1 {
                                Button("Edit Metadata…") { store.openSheet = .metadata(song.id) }
                                Button("Replace artwork…") { store.findArtwork(forSong: song) }
                            }
                            if ids.contains(where: { store.replacementWish(for: $0) != nil }) {
                                Button("Keep This Version") {
                                    for id in ids { store.cancelReplacement(id) }
                                }
                            } else {
                                Button(n > 1 ? "Find New Versions of \(n)…" : "Find a New Version…") {
                                    store.markForReplacement(ids)
                                }
                            }
                            Menu("Add to Playlist") {
                                ForEach(store.playlists, id: \.id) { pl in
                                    Button(pl.name) { store.addSongsToPlaylist(pl.id, Array(ids)) }
                                }
                                if !store.playlists.isEmpty { Divider() }
                                Button("New Playlist…") { store.openSheet = .newPlaylist(Array(ids)) }
                            }
                            Button(n > 1 ? "Add \(n) to Apple Music" : "Add to Apple Music") {
                                store.addToAppleMusic(orderedIDs(ids),
                                                      label: n > 1 ? "Adding \(n) songs to Apple Music…" : "Adding “\(song.title)” to Apple Music…")
                            }
                            let anyOffDevice = orderedIDs(ids).contains { store.song($0)?.onDevice == false }
                            Button(anyOffDevice ? "Send to Device" : "Remove from Device") {
                                store.pin(Array(ids), anyOffDevice)
                            }
                            Divider()
                            if n == 1 {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile((song.path as NSString).expandingTildeInPath,
                                                                  inFileViewerRootedAtPath: "")
                                }
                            }
                            Button(n > 1 ? "Delete \(n) from Library" : "Delete from Library",
                                   role: .destructive) { store.deleteConfirm = ids }
                        }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            // Spans the on-device dot + artwork columns (neither is labelled) so there's a
            // usable target for sorting on-device tracks to the top.
            deviceHeaderCell
            cell("TITLE", .title, width: nil, align: .leading)
            cell("ARTIST", .artist, width: 175, align: .leading)
            cell("ALBUM", .album, width: 175, align: .leading)
            cell("ADDED", .dateAdded, width: 84, align: .trailing)
            cell("TIME", .time, width: 50, align: .trailing)
            cell("KIND", .kind, width: 78, align: .trailing)
        }
        .padding(.horizontal, 20).frame(height: 26)
        .background(theme.header)
    }
    /// Sort-by-device header: an iPod glyph over the dot/artwork columns.
    private var deviceHeaderCell: some View {
        let active = store.songSort.column == .device
        return HStack(spacing: 3) {
            Image(systemName: "ipod").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? theme.text : theme.text3)
            if active {
                Image(systemName: store.songSort.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(theme.text2)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 41, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { store.songSort.toggle(.device) }
        .help("Sort by on-device")
    }

    /// A clickable column header: sorts by its column, toggling direction on repeat clicks.
    private func cell(_ s: String, _ col: SongSort.Column, width: CGFloat?, align: Alignment) -> some View {
        let active = store.songSort.column == col
        return HStack(spacing: 3) {
            if align == .trailing { Spacer(minLength: 0) }
            Text(s).font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(active ? theme.text : theme.text3)
            if active {
                Image(systemName: store.songSort.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(theme.text2)
            }
            if align == .leading { Spacer(minLength: 0) }
        }
        .frame(width: width, alignment: align)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
        .contentShape(Rectangle())
        .onTapGesture { store.songSort.toggle(col) }
    }

    private func rowView(_ song: SongRow, striped: Bool) -> some View {
        let selected = store.selection.contains(song.id)
        let playing = store.player.current?.id == song.id
        return HStack(spacing: 10) {
            Circle().fill(song.onDevice ? theme.accent : Color.clear)
                .overlay(Circle().stroke(selected ? theme.selText : theme.text3, lineWidth: song.onDevice ? 0 : 1.2))
                .frame(width: 9, height: 9)
            ArtworkThumbnail(path: song.path, seed: song.album, size: 22, corner: 3, version: store.artVersion)
                .overlay { if playing { NowPlayingBadge(size: 22, playing: store.player.isPlaying) } }
            Text(song.title).foregroundStyle(playing ? theme.accent : (selected ? theme.selText : theme.text))
                .fontWeight(playing ? .semibold : .regular).lineLimit(1)
            // Why this track is sitting in Pending, said on the row itself rather than only there.
            if store.replacementWish(for: song.id) != nil {
                Text("finding a new version")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? theme.selText : theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        Capsule().stroke(selected ? theme.selText.opacity(0.6) : theme.accent,
                                         lineWidth: 1))
                    .help("Marked for replacement — pick a new version in Pending.")
            }
            Spacer(minLength: 8)
            Text(song.artist).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text2).lineLimit(1).frame(width: 175, alignment: .leading)
            Text(song.album).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text2).lineLimit(1).frame(width: 175, alignment: .leading)
            Text(song.addedLabel).font(.system(size: 12)).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text3).monospacedDigit().frame(width: 84, alignment: .trailing)
            Text(song.timeLabel).foregroundStyle(selected ? theme.selText : theme.text2).monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(song.kindLabel).font(.system(size: 11)).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text3).frame(width: 78, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).frame(height: 32)
        .background(selected ? theme.accent : (striped ? theme.stripe : Color.clear))
    }
}

struct AlbumsGrid: View {
    var artistFilter: String? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    private let cols = [GridItem(.adaptive(minimum: 146, maximum: 200), spacing: 24)]

    private var albumsToShow: [AlbumRow] {
        guard let a = artistFilter else { return store.albums }
        return store.albums.filter { $0.artist == a }
    }

    var body: some View {
        @Bindable var store = store
        if renderMode {
            ScrollOrStack(alignment: .leading) {
                let all = albumsToShow
                let rows = stride(from: 0, to: all.count, by: 5).map {
                    Array(all[$0..<min($0 + 5, all.count)])
                }
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(row) { album in albumCell(album).frame(width: 160) }
                            Spacer(minLength: 0)
                        }
                    }
                }.padding(20)
            }
        } else {
            // Track the top-most album so returning from an album detail restores the scroll
            // position (only the main grid; artist-filtered views start at the top).
            ScrollView {
                LazyVGrid(columns: cols, alignment: .leading, spacing: 20) {
                    ForEach(albumsToShow) { album in albumCell(album).id(album.id) }
                }
                .scrollTargetLayout()
                .padding(20)
            }
            .scrollPosition(id: artistFilter == nil ? $store.albumScrollID : .constant(nil), anchor: .top)
        }
    }

    private func albumCell(_ album: AlbumRow) -> some View {
        let dev = store.albumDeviceState(album)
        return Button {
            store.filterAlbumID = album.id       // stay within Albums/Artists; back button clears it
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkThumbnail(path: album.songIDs.first.flatMap { store.song($0)?.path } ?? "",
                                 seed: album.name, size: 160, corner: 6, version: store.artVersion)
                    .overlay(alignment: .topTrailing) {
                        if dev.onDevice > 0 { albumDeviceBadge(dev) }
                    }
                Text(album.name).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text).lineLimit(1)
                Text("\(album.artist)\(album.year.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Replace artwork…") { store.findArtwork(for: album) }
            Button("Fix track numbers") { store.backfillTrackNumbers(for: album) }
            Button("Add album to Apple Music") {
                store.addToAppleMusic(album.songIDs, label: "Adding “\(album.name)” to Apple Music…")
            }
            Divider()
            if dev.onDevice < dev.total {
                Button("Send album to device") { store.pinAlbum(album, true) }
            }
            if dev.onDevice > 0 {
                Button("Remove album from device", role: .destructive) { store.pinAlbum(album, false) }
            }
        }
    }

    /// Small pill on album art: filled when the whole album is on the device, outline when partial.
    private func albumDeviceBadge(_ dev: (onDevice: Int, total: Int)) -> some View {
        let full = dev.onDevice == dev.total
        return Image(systemName: full ? "ipod" : "ipod")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(full ? theme.accentText : theme.accent)
            .padding(4)
            .background(full ? theme.accent : theme.header, in: Capsule())
            .overlay(Capsule().stroke(theme.accent, lineWidth: full ? 0 : 1))
            .padding(6)
    }
    private func initials(_ s: String) -> String {
        s.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

struct ArtistsList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollOrStack {
            VStack(spacing: 0) {
                ForEach(store.artists) { artist in
                    HStack(spacing: 12) {
                        ArtworkThumbnail(path: store.songs.first { $0.groupArtist == artist.name }?.path ?? "",
                                         seed: artist.name, size: 52, corner: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text)
                            Text("\(artist.albumCount) albums · \(artist.songCount) songs")
                                .font(.system(size: 12)).foregroundStyle(theme.text3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { store.filterArtist = artist.name }
                    Divider().overlay(theme.sep)
                }
            }
        }
    }
}
