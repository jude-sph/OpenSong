import SwiftUI
import AppKit
import OpenSongCore

/// A playlist cover fetched from Music.app (raw artwork data via osascript), cached on disk.
/// Falls back to a gradient when a playlist has no artwork.
struct AppleMusicArt: View {
    let name: String
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(placeholderGradient(name)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: name) { await load() }
    }

    private func load() async {
        image = nil
        if renderMode { return }
        let cache = ArtworkCache.dir().appendingPathComponent("am-\(ArtworkCache.key(name)).img")
        if !FileManager.default.fileExists(atPath: cache.path) {
            let ok = await Task.detached { AppleMusicBridge().writePlaylistArtwork(named: name, to: cache.path) }.value
            if !ok { FileManager.default.createFile(atPath: cache.path, contents: Data()); return }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int) ?? 0
        if (size ?? 0) > 0 { image = NSImage(contentsOf: cache) }
    }
}

struct AppleMusicView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Apple Music", subtitle: "\(store.appleMusic.count) playlists") {
                Button { store.loadAppleMusic() } label: {
                    Label(store.appleMusicLoading ? "Loading…" : "Refresh", systemImage: "arrow.clockwise")
                }.buttonStyle(SoftButton()).disabled(store.appleMusicLoading)
            }
            Divider().overlay(theme.sep)
            if store.appleMusicLoading {
                loadingState
            } else if store.appleMusic.isEmpty {
                emptyState
            } else {
                ScrollOrStack(alignment: .leading) {
                    ForEach(store.appleMusic) { col in row(col) }
                }
            }
        }
        .onAppear { if store.appleMusic.isEmpty && !store.appleMusicLoading && !renderMode { store.loadAppleMusic() } }
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
            Image(systemName: "square.on.square").font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Compare with Apple Music").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.appleMusicError ?? "Load your Apple Music playlists to see what you already own and mark the rest to acquire.")
                .font(.system(size: 12)).foregroundStyle(store.appleMusicError == nil ? theme.text3 : theme.red)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Grant access & load") { store.loadAppleMusic() }.buttonStyle(AccentButton())
            Text("First use asks macOS for permission to control Music.")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ col: AppleMusicCollection) -> some View {
        let own = store.ownership(col)
        let frac = own.total > 0 ? Double(own.owned) / Double(own.total) : 0
        return HStack(spacing: 12) {
            AppleMusicArt(name: col.name, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(col.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    Text(col.kind.rawValue.capitalized).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.chip, in: Capsule()).foregroundStyle(theme.text3)
                }
                Text("owned \(own.owned) of \(own.total)").font(.system(size: 11)).foregroundStyle(theme.text3)
                ProgressBar(value: frac).frame(width: 260)
            }
            Spacer()
            if own.missing.isEmpty {
                Label("Complete", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.green)
            } else {
                Button("Mark \(own.missing.count) missing") { store.markMissing(col) }.buttonStyle(AccentButton())
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}
