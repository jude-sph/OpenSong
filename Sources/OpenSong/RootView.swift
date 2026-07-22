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
            let shot = ProcessInfo.processInfo.environment["OPENSONG_SCREENSHOT"] == "1"
            if shot {
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.level = .floating
                w.setFrame(NSRect(x: 120, y: 120, width: 1180, height: 770), display: true)
            }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            FileHandle.standardError.write("WindowConfigurator: configured window shot=\(shot) frame=\(w.frame)\n".data(using: .utf8)!)
        }
        DispatchQueue.main.async { configure(0) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var player = PreviewPlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Divider().overlay(theme.sep)
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 222)
                    .background(theme.sidebar)
                Divider().overlay(theme.sep)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.content)
            }
            Divider().overlay(theme.sep)
            PreviewPlayerBar(model: player)
            Divider().overlay(theme.sep)
            ActivityBar()
        }
        .background(theme.content)
        .background(WindowConfigurator())
        .sheet(item: Binding(get: { store.openSheet }, set: { store.openSheet = $0 })) { sheet in
            switch sheet {
            case .metadata(let id): MetadataEditorView(songID: id)
                    .environment(store).environment(\.theme, theme)
            case .settings: SettingsView().environment(store).environment(\.theme, theme)
            case .importReview: ImportReviewView().environment(store).environment(\.theme, theme)
            case .addWish: AddWishView().environment(store).environment(\.theme, theme)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.activeView {
        case .allSongs, .albums, .artists: LibraryView()
        case .device: DeviceView()
        case .wishlist: WishlistView()
        case .appleMusic: AppleMusicView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .match(let id): MatchReviewView(wishID: id)
        }
    }
}
