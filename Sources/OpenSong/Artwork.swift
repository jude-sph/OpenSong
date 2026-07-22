import SwiftUI
import AppKit
import OpenSongCore

/// Extracts + caches embedded cover art from master files (self-healing: any displayed
/// song extracts its art once, then loads from cache). Falls back to a gradient.
enum ArtworkCache {
    static func dir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenSong/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Deterministic (process-independent) key so the cache survives relaunches.
    static func key(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h << 5 &+ h) &+ UInt64(b) }
        return String(h, radix: 16)
    }
    static func cacheURL(forMaster path: String) -> URL {
        dir().appendingPathComponent("\(key(path)).png")
    }
    /// Ensure art is extracted to `cache`. Returns true if a cover exists. Writes a 0-byte
    /// sentinel when there's no embedded art so we don't re-run ffmpeg every time.
    static func ensure(master: String, cache: URL, ffmpegPath: String) async -> Bool {
        if FileManager.default.fileExists(atPath: cache.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int) ?? 0
            return (size ?? 0) > 0
        }
        return await Task.detached {
            let ok = (try? ArtworkResolver(ffmpegPath: ffmpegPath)
                .extractEmbedded(from: URL(fileURLWithPath: master), to: cache)) ?? false
            if !ok { FileManager.default.createFile(atPath: cache.path, contents: Data()) }
            return ok
        }.value
    }
}

/// A square artwork view: shows embedded cover art if present, else a gradient placeholder.
struct ArtworkThumbnail: View {
    let path: String       // master file path (may start with ~)
    let seed: String       // gradient seed (album name) when no art
    var size: CGFloat
    var corner: CGFloat = 3
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(placeholderGradient(seed))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { return }
        let cache = ArtworkCache.cacheURL(forMaster: expanded)
        if await ArtworkCache.ensure(master: expanded, cache: cache, ffmpegPath: ffmpegPath) {
            image = NSImage(contentsOf: cache)
        }
    }
}
