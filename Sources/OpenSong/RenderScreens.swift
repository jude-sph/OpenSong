import SwiftUI
import AppKit
import OpenSongCore

/// Offscreen rendering of key screens to PNGs via ImageRenderer — display/Space/window
/// independent, so the UI can be visually verified headlessly. Enabled by OPENSONG_RENDER=1.
@MainActor
func renderScreens() {
    let outDir = ProcessInfo.processInfo.environment["OPENSONG_RENDER_DIR"] ?? "/tmp/opensong-shots"
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    func write(_ name: String, dark: Bool, size: CGSize, @ViewBuilder _ content: () -> some View) {
        let store = AppStore()
        store.dark = dark
        let themed = content()
            .environment(store)
            .environment(\.theme, Theme(dark: dark))
            .frame(width: size.width, height: size.height)
            .background(Theme(dark: dark).content)
        let renderer = ImageRenderer(content: themed)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("render FAILED: \(name)\n".data(using: .utf8)!); return
        }
        let path = "\(outDir)/\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("rendered \(name) -> \(path)")
    }

    let winSize = CGSize(width: 1180, height: 770)

    // The player bar's repeat button in each of its three states.
    write("00-repeat-modes-dark", dark: true, size: CGSize(width: 1180, height: 200)) {
        RepeatModesShot()
    }

    // Library — Songs (light + dark)
    write("01-library-songs-light", dark: false, size: winSize) { RootShot(view: .allSongs) }
    write("02-library-songs-dark", dark: true, size: winSize) { RootShot(view: .allSongs) }
    // Albums grid
    write("03-albums-light", dark: false, size: winSize) { RootShot(view: .albums) }
    // Artists
    write("04-artists-dark", dark: true, size: winSize) { RootShot(view: .artists) }
    // Device (simulated, with sync diff)
    write("05-device-light", dark: false, size: CGSize(width: 1180, height: 1100)) { RootShot(view: .device, simulateDevice: true) }
    // Device unplugged but remembered: on-device list, queued adds/removes, inert Sync button
    write("05c-device-offline-dark", dark: true, size: CGSize(width: 1180, height: 1100)) { RootShot(view: .deviceOffline) }
    // Device mid-sync (progress bar + time left)
    write("05b-device-syncing-dark", dark: true, size: winSize) { RootShot(view: .deviceSyncing, simulateDevice: true) }
    // Playlist detail
    write("06-playlist-dark", dark: true, size: winSize) { RootShot(view: .firstPlaylist) }
    // Settings sheet
    write("07-settings-light", dark: false, size: CGSize(width: 520, height: 560)) {
        SheetShot { SettingsView() }
    }
    // Metadata editor sheet
    write("08-metadata-dark", dark: true, size: CGSize(width: 560, height: 460)) {
        SheetShot { MetadataEditorFirst() }
    }
    // Wishlist (Phase 2)
    write("09-wishlist-light", dark: false, size: winSize) { RootShot(view: .wishlist, seedWishes: true) }
    // A library with a track marked for replacement, so the badge and the Pending tag are visible.
    write("09b-library-replacing-dark", dark: true, size: winSize) {
        RootShot(view: .allSongs, seedWishes: true)
    }
    // Match review (Phase 2)
    write("10-match-dark", dark: true, size: winSize) { RootShot(view: .match, seedWishes: true) }
    // Apple Music compare (Phase 3)
    write("11-applemusic-light", dark: false, size: winSize) { RootShot(view: .appleMusic) }
    // Spotify import — list + detail
    write("12-spotify-list-dark", dark: true, size: winSize) { RootShot(view: .spotify) }
    write("13-spotify-detail-light", dark: false, size: winSize) { RootShot(view: .spotifyDetail, seedWishes: true) }
    // YouTube playlist import
    write("14-youtube-dark", dark: true, size: winSize) { RootShot(view: .youtube) }
    // Library health
    write("15-health-light", dark: false, size: winSize) { RootShot(view: .health) }
    // Album detail (self-contained, back button) + artist detail + art window
    write("16-album-detail-dark", dark: true, size: winSize) { RootShot(view: .albumDetail) }
    write("17-artist-detail-light", dark: false, size: winSize) { RootShot(view: .artistDetail) }
    write("18-art-window-dark", dark: true, size: winSize) { RootShot(view: .artWindow) }
    // Visualiser window contents (its own window, so rendered directly rather than via RootShot).
    write("19-visualiser-dark", dark: true, size: CGSize(width: 620, height: 420)) {
        ScopeView(sampler: .synthetic(), playhead: { 0.42 }, isPlaying: false)
    }
}

/// Renders RootView with a pre-set active view (and optional simulated device).
private struct RootShot: View {
    enum Which { case allSongs, albums, artists, device, deviceOffline, deviceSyncing, firstPlaylist, wishlist, match, appleMusic, spotify, spotifyDetail, youtube, health, albumDetail, artistDetail, artWindow }
    let view: Which
    var simulateDevice: Bool = false
    var seedWishes: Bool = false
    @Environment(AppStore.self) private var store
    var body: some View {
        configure()
        return RootView()
    }
    private func configure() {
        if seedWishes { store.seedWishesForRender() }
        switch view {
        case .allSongs: store.activeView = .allSongs
        case .albums: store.activeView = .albums
        case .artists: store.activeView = .artists
        case .device: store.activeView = .device
        case .deviceOffline: store.seedOfflineDeviceForRender(); store.activeView = .device
        case .deviceSyncing: store.activeView = .device; store.seedSyncProgressForRender()
        case .wishlist: store.activeView = .wishlist
        case .appleMusic: store.seedAppleMusicForRender(); store.activeView = .appleMusic
        case .spotify: store.seedSpotifyForRender(); store.activeView = .spotify
        case .spotifyDetail: store.seedSpotifyForRender(); store.activeView = .spotifyDetail
        case .youtube: store.seedYouTubeForRender(); store.activeView = .youtube
        case .health: store.seedHealthForRender(); store.activeView = .health
        case .albumDetail:
            store.activeView = .albums
            if let a = store.albums.first { store.filterAlbumID = a.id }
            // A search term is deliberately left set: it is how you find an album, and it used to
            // keep filtering the tracks inside it — with the search box off screen, so the missing
            // songs had no visible explanation.
            store.search = "nikes"
        case .artistDetail:
            store.activeView = .artists
            if let a = store.artists.first { store.filterArtist = a.name }
        case .artWindow:
            if let s = store.songs.first { store.player.play(s) }
            store.player.showArtWindow = true
        case .match:
            store.seedMatchForRender()
            if let id = store.matchWishID { store.activeView = .match(id) }
        case .firstPlaylist:
            if let pl = store.playlists.first { store.activeView = .playlist(pl.id) }
        }
        if simulateDevice { store.simulateDevice() }
    }
}

private struct SheetShot<C: View>: View {
    @ViewBuilder var content: C
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack { theme.desk; content }
    }
}

private struct MetadataEditorFirst: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let s = store.songs.first { MetadataEditorView(songID: s.id) } else { Color.clear }
    }
}


/// The transport in each repeat mode, side by side, so the three states can be compared.
private struct RepeatModesShot: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            ForEach(RepeatMode.allCases, id: \.rawValue) { mode in
                HStack(spacing: 16) {
                    Text(label(mode)).font(.system(size: 12)).foregroundStyle(theme.text3)
                        .frame(width: 150, alignment: .leading)
                    PreviewPlayerBar(model: player(mode))
                }
                .padding(.horizontal, 16)
            }
        }
    }
    private func label(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return "normal play"
        case .all: return "repeat queue"
        case .one: return "repeat one track"
        }
    }
    /// A model per row: they all shared `store.player` at first, so every row rendered whichever
    /// mode was set last.
    private func player(_ mode: RepeatMode) -> PreviewPlayerModel {
        let m = PreviewPlayerModel()
        m.repeatMode = mode
        return m
    }
}
