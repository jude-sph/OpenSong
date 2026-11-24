import SwiftUI
import AppKit

/// Configures the hosting NSWindow the moment it exists: brings it to the front, and
/// (under the screenshot flag) joins all Spaces so automated capture can see it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        func configure(_ attempt: Int) {
            guard let w = v.window else {
                if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { configure(attempt + 1) } }
                return
            }
            w.isOpaque = true
            w.backgroundColor = NSColor.windowBackgroundColor
            w.hasShadow = true
            // Clear any square aspect-ratio left over from the art window (setting
            // resizeIncrements to (1,1) is the documented way to remove an aspect ratio — setting
            // aspectRatio to .zero installs an INVALID 0:0 ratio that crashes on live resize), and
            // restore the traffic-light buttons (the art window hides them on hover-out).
            w.resizeIncrements = NSSize(width: 1, height: 1)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = false
            }
            // Pull content under the title bar so our custom 44px TitleBar sits at the very
            // top (traffic lights float over its left gutter) — no empty native strip above.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            let shot = ProcessInfo.processInfo.environment["OPENSONG_SCREENSHOT"] == "1"
            if shot {
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.level = .floating
                w.setFrame(NSRect(x: 120, y: 120, width: 1180, height: 770), display: true)
            }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { configure(0) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Transient in-app ribbon notification (e.g. "Download complete"). Auto-dismisses; also has a
/// close button. Slides in from the top.
struct ToastRibbon: View {
    let toast: AppStore.Toast
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(toast.isError ? theme.red : theme.accent)
            Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.text).lineLimit(2)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(theme.sheet, in: Capsule())
        .overlay(Capsule().stroke(theme.sepStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        mainLayout
        // The album-art view is a SEPARATE square panel (its own window) so it can have its own
        // small min-size + 1:1 shape without fighting the main window's larger min.
        .background(ArtPanelPresenter(show: store.player.showArtWindow, model: store.player, theme: theme))
        // The visualiser is a second, independent window — both can be open at once.
        .background(VisualiserPresenter(show: store.player.showVisualiser, model: store.player, theme: theme))
        .onAppear {
            // Debug harness: open the visualiser on a real track so its frame rate can be measured
            // from a terminal run (the offscreen renderer doesn't reflect the live path).
            if ScopeView.debug {
                let playable = store.songs.first {
                    FileManager.default.fileExists(atPath: ($0.path as NSString).expandingTildeInPath)
                }
                let line = "[vis] songs=\(store.songs.count) playable=\(playable?.title ?? "none")\n"
                FileHandle.standardError.write(Data(line.utf8))
                if let playable { store.player.play(playable, in: store.songs) }
                store.player.showVisualiser = true
                Task {
                    for _ in 0..<8 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let s = "[vis] state: playing=\(store.player.isPlaying) "
                            + "sampler=\(store.player.sampler != nil) "
                            + "t=\(String(format: "%.1f", store.player.audioTime))\n"
                        FileHandle.standardError.write(Data(s.utf8))
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastRibbon(toast: toast) { store.toast = nil }
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
        .sheet(item: Binding(get: { store.openSheet }, set: { store.openSheet = $0 })) { sheet in
            switch sheet {
            case .metadata(let id): MetadataEditorView(songID: id)
                    .environment(store).environment(\.theme, theme)
            case .settings: SettingsView().environment(store).environment(\.theme, theme)
            case .importReview: ImportReviewView().environment(store).environment(\.theme, theme)
            case .addWish: AddWishView().environment(store).environment(\.theme, theme)
            case .addURL: AddURLView().environment(store).environment(\.theme, theme)
            case .newPlaylist(let ids): NewPlaylistView(songIDs: ids).environment(store).environment(\.theme, theme)
            case .renamePlaylist(let id): RenamePlaylistView(playlistID: id).environment(store).environment(\.theme, theme)
            case .findArt: FindArtworkView().environment(store).environment(\.theme, theme)
            }
        }
        .confirmationDialog("Delete from library?",
                            isPresented: Binding(get: { store.deleteConfirm != nil },
                                                 set: { if !$0 { store.deleteConfirm = nil } }),
                            presenting: store.deleteConfirm) { ids in
            Button("Delete \(ids.count) song(s) (move files to Trash)", role: .destructive) {
                store.deleteSongs(ids, trashFiles: true); store.deleteConfirm = nil
            }
            Button("Remove from library only (keep files)") {
                store.deleteSongs(ids, trashFiles: false); store.deleteConfirm = nil
            }
            Button("Cancel", role: .cancel) { store.deleteConfirm = nil }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            TitleBar()
            Divider().overlay(theme.sep)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Sidebar().frame(maxHeight: .infinity)
                    Divider().overlay(theme.sep)
                    SidebarFooter()
                }
                .frame(width: 222)
                .background(theme.sidebar)
                Divider().overlay(theme.sep)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.content)
            }
            Divider().overlay(theme.sep)
            PreviewPlayerBar(model: store.player)
        }
        .background(theme.content)
        .background(WindowConfigurator())
    }

    @ViewBuilder private var content: some View {
        switch store.activeView {
        case .allSongs, .albums, .artists: LibraryView()
        case .health: HealthView()
        case .device: DeviceView()
        case .wishlist: WishlistView()
        case .appleMusic: AppleMusicView()
        case .appleMusicDetail: AppleMusicDetailView()
        case .spotify: SpotifyView()
        case .spotifyDetail: SpotifyDetailView()
        case .youtube: YouTubeView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .match(let id): MatchReviewView(wishID: id)
        }
    }
}
