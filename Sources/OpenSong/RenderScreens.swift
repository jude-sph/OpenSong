import SwiftUI
import AppKit

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

    // Library — Songs (light + dark)
    write("01-library-songs-light", dark: false, size: winSize) { RootShot(view: .allSongs) }
    write("02-library-songs-dark", dark: true, size: winSize) { RootShot(view: .allSongs) }
    // Albums grid
    write("03-albums-light", dark: false, size: winSize) { RootShot(view: .albums) }
    // Artists
    write("04-artists-dark", dark: true, size: winSize) { RootShot(view: .artists) }
    // Device (simulated, with sync diff)
    write("05-device-light", dark: false, size: winSize) { RootShot(view: .device, simulateDevice: true) }
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
    // Match review (Phase 2)
    write("10-match-dark", dark: true, size: winSize) { RootShot(view: .match, seedWishes: true) }
    // Apple Music compare (Phase 3)
    write("11-applemusic-light", dark: false, size: winSize) { RootShot(view: .appleMusic) }
}

/// Renders RootView with a pre-set active view (and optional simulated device).
private struct RootShot: View {
    enum Which { case allSongs, albums, artists, device, firstPlaylist, wishlist, match, appleMusic }
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
        case .wishlist: store.activeView = .wishlist
        case .appleMusic: store.seedAppleMusicForRender(); store.activeView = .appleMusic
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
