import SwiftUI
import AppKit
import OpenSongCore

/// A playlist cover fetched from Music.app (raw artwork data via osascript), cached on disk.
/// Falls back to a gradient when a playlist has no artwork.
struct AppleMusicArt: View {
    let name: String
    var kind: AppleMusicKind = .playlist
    var artist: String = ""
    var size: CGFloat
    var corner: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(placeholderGradient(name + artist)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: name + "␟" + artist) { await load() }
    }

    private func load() async {
        image = nil
        if renderMode { return }
        let prefix = kind == .album ? "amalb" : "am"
        let cacheKey = kind == .album ? name + "␟" + artist : name
        let cache = ArtworkCache.dir().appendingPathComponent("\(prefix)-\(ArtworkCache.key(cacheKey)).img")
        if !FileManager.default.fileExists(atPath: cache.path) {
            let n = name, a = artist, k = kind
            let ok = await Task.detached {
                k == .album ? AppleMusicBridge().writeAlbumArtwork(album: n, artist: a, to: cache.path)
                            : AppleMusicBridge().writePlaylistArtwork(named: n, to: cache.path)
            }.value
            if !ok { FileManager.default.createFile(atPath: cache.path, contents: Data()); return }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int) ?? 0
        if (size ?? 0) > 0 { image = NSImage(contentsOf: cache) }
    }
}

struct AppleMusicView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var browsingAlbums: Bool { store.appleMusicBrowse == .albums }
    private var collections: [AppleMusicCollection] {
        browsingAlbums ? store.sortedAppleMusicAlbums : store.sortedAppleMusic
    }
    private var isLoading: Bool {
        browsingAlbums ? store.appleMusicAlbumsLoading : store.appleMusicLoading
    }

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            ContentHeader(title: "Apple Music",
                          subtitle: "\(collections.count) \(browsingAlbums ? "albums" : "playlists")") {
                HStack(spacing: 10) {
                    SegmentedControl(options: AMBrowse.allCases.map { ($0.rawValue, $0) },
                                     selection: $store.appleMusicBrowse)
                    if !browsingAlbums && !store.appleMusic.isEmpty {
                        SegmentedControl(options: AMSort.allCases.map { ($0.rawValue, $0) },
                                         selection: $store.appleMusicSort)
                    }
                    Button { store.updateCloudLibrary() } label: {
                        Label(store.updatingCloudLibrary ? "Updating…" : "Update Cloud Library", systemImage: "icloud.and.arrow.up")
                    }.buttonStyle(SoftButton()).disabled(store.updatingCloudLibrary)
                    Button { refresh() } label: {
                        Label(isLoading ? "Loading…" : "Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(SoftButton()).disabled(isLoading)
                }
            }
            Divider().overlay(theme.sep)
            if isLoading {
                loadingState
            } else if collections.isEmpty {
                emptyState
            } else {
                ScrollOrStack(alignment: .leading) {
                    ForEach(collections) { col in row(col) }
                }
            }
        }
        .onAppear { if store.appleMusic.isEmpty && !store.appleMusicLoading && !renderMode { store.loadAppleMusic() } }
        .onChange(of: store.appleMusicBrowse) { _, mode in
            if mode == .albums && !renderMode { store.loadAppleMusicAlbums() }
        }
    }

    private func refresh() {
        if browsingAlbums { store.loadAppleMusicAlbums(force: true) } else { store.loadAppleMusic() }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Loading your Apple Music library…").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text("This can take a while the first time for large libraries — reading every playlist's tracks from Music.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: browsingAlbums ? "square.stack" : "square.on.square").font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Compare with Apple Music").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.appleMusicError ?? (browsingAlbums
                 ? "Load your Apple Music library albums to see which you already own and mark the rest to acquire."
                 : "Load your Apple Music playlists to see what you already own and mark the rest to acquire."))
                .font(.system(size: 12)).foregroundStyle(store.appleMusicError == nil ? theme.text3 : theme.red)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Grant access & load") { refresh() }.buttonStyle(AccentButton())
            Text("First use asks macOS for permission to control Music.")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ col: AppleMusicCollection) -> some View {
        let own = store.ownership(col)
        let frac = own.total > 0 ? Double(own.owned) / Double(own.total) : 0
        return HStack(spacing: 12) {
            AppleMusicArt(name: col.name, kind: col.kind, artist: col.albumArtist, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(col.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    if let tag = col.originTag {
                        Text(tag).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(hex: 0x2e7bd6).opacity(0.16), in: Capsule())
                            .foregroundStyle(Color(hex: 0x2e7bd6))
                    }
                }
                Text(col.kind == .album
                     ? "\(col.albumArtist) · owned \(own.owned) of \(own.total)"
                     : "owned \(own.owned) of \(own.total)\(col.isUserMade ? "" : " · not yours")")
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                ProgressBar(value: frac).frame(width: 260)
            }
            Spacer()
            if own.missing.isEmpty {
                Label("Complete", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.green)
            } else {
                Button("Mark \(own.missing.count) missing") { store.markMissing(col) }.buttonStyle(AccentButton())
            }
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 20)
        .frame(height: 66)   // fixed row height (avoids LazyVStack gaps from variable content)
        .contentShape(Rectangle())
        .onTapGesture { store.openAMDetail(col) }
    }
}
