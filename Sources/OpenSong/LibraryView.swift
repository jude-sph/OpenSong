import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var title: String {
        switch store.activeView {
        case .albums: return "Albums"
        case .artists: return "Artists"
        default: return store.filterAlbumID == nil ? "All Songs" : "Album"
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ContentHeader(title: title, subtitle: subtitle) {
                HStack(spacing: 10) {
                    Button { store.beginImport() } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }.buttonStyle(SoftButton())
                    SegmentedControl(options: [("Songs", ActiveView.allSongs),
                                               ("Albums", .albums), ("Artists", .artists)],
                                     selection: $store.activeView)
                    SearchField(text: $store.search)
                }
            }
            Divider().overlay(theme.sep)
            Group {
                switch store.activeView {
                case .albums: AlbumsGrid()
                case .artists: ArtistsList()
                default: SongsTable()
                }
            }
        }
    }

    private var subtitle: String {
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
            Button { store.beginImport() } label: { Label("Import music…", systemImage: "square.and.arrow.down") }
                .buttonStyle(AccentButton())
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
                        .onTapGesture(count: 2) { store.openSheet = .metadata(song.id) }
                        .onTapGesture { store.selection = [song.id] }
                        .contextMenu {
                            Button("Edit Metadata…") { store.openSheet = .metadata(song.id) }
                            Button(song.onDevice ? "Unpin from Device" : "Pin to Device") {
                                store.pin(song.id, !song.onDevice)
                            }
                            Divider()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile((song.path as NSString).expandingTildeInPath,
                                                              inFileViewerRootedAtPath: "")
                            }
                        }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 9)
            Color.clear.frame(width: 22)
            cell("TITLE", width: nil, align: .leading)
            cell("ARTIST", width: 220, align: .leading)
            cell("ALBUM", width: 220, align: .leading)
            cell("TIME", width: 56, align: .trailing)
            cell("KIND", width: 92, align: .trailing)
        }
        .padding(.horizontal, 20).frame(height: 26)
        .background(theme.header)
    }
    private func cell(_ s: String, width: CGFloat?, align: Alignment) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }

    private func rowView(_ song: SongRow, striped: Bool) -> some View {
        let selected = store.selection.contains(song.id)
        return HStack(spacing: 10) {
            Circle().fill(song.onDevice ? theme.accent : Color.clear)
                .overlay(Circle().stroke(selected ? theme.selText : theme.text3, lineWidth: song.onDevice ? 0 : 1.2))
                .frame(width: 9, height: 9)
            RoundedRectangle(cornerRadius: 3).fill(placeholderGradient(song.album)).frame(width: 22, height: 22)
            Text(song.title).foregroundStyle(selected ? theme.selText : theme.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(song.artist).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text2).lineLimit(1).frame(width: 220, alignment: .leading)
            Text(song.album).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text2).lineLimit(1).frame(width: 220, alignment: .leading)
            Text(song.timeLabel).foregroundStyle(selected ? theme.selText : theme.text2).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(song.kindLabel).font(.system(size: 11)).foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text3).frame(width: 92, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).frame(height: 32)
        .background(selected ? theme.accent : (striped ? theme.stripe : Color.clear))
    }
}

struct AlbumsGrid: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    private let cols = [GridItem(.adaptive(minimum: 146, maximum: 200), spacing: 24)]

    var body: some View {
        ScrollOrStack(alignment: .leading) {
            if renderMode {
                let rows = stride(from: 0, to: store.albums.count, by: 5).map {
                    Array(store.albums[$0..<min($0 + 5, store.albums.count)])
                }
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(row) { album in albumCell(album).frame(width: 160) }
                            Spacer(minLength: 0)
                        }
                    }
                }.padding(20)
            } else {
                LazyVGrid(columns: cols, alignment: .leading, spacing: 20) {
                    ForEach(store.albums) { album in albumCell(album) }
                }.padding(20)
            }
        }
    }

    private func albumCell(_ album: AlbumRow) -> some View {
        Button {
            store.filterAlbumID = album.id
            store.activeView = .allSongs
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6).fill(placeholderGradient(album.name))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(initials(album.name)).font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85)).padding(8)
                    }
                Text(album.name).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text).lineLimit(1)
                Text("\(album.artist)\(album.year.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
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
                        Circle().fill(placeholderGradient(artist.name)).frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text)
                            Text("\(artist.albumCount) albums · \(artist.songCount) songs")
                                .font(.system(size: 12)).foregroundStyle(theme.text3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    Divider().overlay(theme.sep)
                }
            }
        }
    }
}
