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
    /// Sidecar marking "this master has no embedded art"; its contents are the master's byte size
    /// at the time we checked, so the sentinel self-invalidates once the file changes (e.g. art
    /// gets embedded later). Kept separate from the `.png` so a real cover is always a valid image.
    private static func sentinelURL(forMaster path: String) -> URL {
        dir().appendingPathComponent("\(key(path)).noart")
    }
    private static func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let s = attrs[.size] as? Int else { return 0 }
        return s
    }
    /// Ensure art is extracted to `cache`. Returns true if a cover exists. When there's no embedded
    /// art we record a size-stamped sentinel so ffmpeg isn't re-run every time — but we re-extract
    /// whenever the master file has changed since (art embedded later), which self-heals stale
    /// "no art" results, including legacy 0-byte sentinels from older builds.
    static func ensure(master: String, cache: URL, ffmpegPath: String) async -> Bool {
        let fm = FileManager.default
        // A real cover is already cached (non-empty image).
        if fm.fileExists(atPath: cache.path), fileSize(cache.path) > 0 { return true }
        let masterSize = fileSize(master)
        let sentinel = sentinelURL(forMaster: master)
        // Confirmed "no art" and the file is unchanged since → skip ffmpeg.
        if let recorded = try? String(contentsOf: sentinel, encoding: .utf8),
           let n = Int(recorded.trimmingCharacters(in: .whitespacesAndNewlines)),
           n == masterSize, masterSize > 0 {
            return false
        }
        // No/stale sentinel (or a legacy 0-byte .png sentinel) → (re-)extract.
        try? fm.removeItem(at: cache)   // drop any legacy empty .png so a real cover can replace it
        return await Task.detached {
            let ok = (try? ArtworkResolver(ffmpegPath: ffmpegPath)
                .extractEmbedded(from: URL(fileURLWithPath: master), to: cache)) ?? false
            if ok { try? fm.removeItem(at: sentinel) }
            else { try? "\(masterSize)".write(to: sentinel, atomically: true, encoding: .utf8) }
            return ok
        }.value
    }
}

/// Downloads + caches remote thumbnails (YouTube search-result images) keyed by URL. Small
/// in-memory + on-disk cache; a handful of thumbnails per match screen.
@MainActor
enum RemoteImageCache {
    private static var memory: [String: NSImage] = [:]

    static func cached(_ url: URL) -> NSImage? { memory[url.absoluteString] }

    static func load(_ url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let img = memory[key] { return img }
        let file = ArtworkCache.dir().appendingPathComponent("yt-\(ArtworkCache.key(key)).jpg")
        if let img = NSImage(contentsOf: file) { memory[key] = img; return img }
        let data: Data? = await Task.detached {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            return try? await URLSession.shared.data(for: req).0
        }.value
        guard let data, let img = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        memory[key] = img
        return img
    }
}

/// A thumbnail for a remote image URL (e.g. a YouTube video still). Gradient placeholder while
/// loading or in render mode (no network during offscreen render).
struct RemoteThumbnail: View {
    let url: URL?
    let seed: String
    var width: CGFloat
    var height: CGFloat
    var corner: CGFloat = 4
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(placeholderGradient(seed))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard !renderMode, let url else { return }
        image = await RemoteImageCache.load(url)
    }
}

/// A small overlay marking the currently-playing track on its artwork (waveform when playing,
/// pause glyph when it's the current track but paused).
struct NowPlayingBadge: View {
    var size: CGFloat
    var playing: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.5))
            Image(systemName: playing ? "waveform" : "pause.fill")
                .font(.system(size: max(9, size * 0.45), weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// A square artwork view: shows embedded cover art if present, else a gradient placeholder.
struct ArtworkThumbnail: View {
    let path: String       // master file path (may start with ~)
    let seed: String       // gradient seed (album name) when no art
    var size: CGFloat
    var corner: CGFloat = 3
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    var version: Int = 0   // bump (AppStore.artVersion) to force a re-read after art is replaced
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
        .task(id: "\(path)#\(version)") { await load() }
    }

    private func load() async {
        let expanded = (path as NSString).expandingTildeInPath
        // Decoded at the size it's drawn (×2 for Retina), and remembered: scrolling a row back
        // into view is then a memory lookup, not a full-size PNG decode plus several file checks.
        let pixels = Int(size * 2)
        let memKey = "\(expanded)#\(version)#\(pixels)" as NSString
        if let hit = ThumbnailMemory.cache.object(forKey: memKey) { image = hit; return }
        image = nil
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { return }
        let cache = ArtworkCache.cacheURL(forMaster: expanded)
        guard await ArtworkCache.ensure(master: expanded, cache: cache, ffmpegPath: ffmpegPath) else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            ThumbnailMemory.downsample(cache, maxPixel: pixels)
        }.value
        guard !Task.isCancelled, let decoded else { return }
        let img = NSImage(cgImage: decoded, size: NSSize(width: size, height: size))
        ThumbnailMemory.cache.setObject(img, forKey: memKey)
        image = img
    }
}

/// In-memory thumbnails, keyed by master path + art version + pixel size. NSCache evicts under
/// memory pressure, and the count limit keeps a long scroll through a big library bounded.
enum ThumbnailMemory {
    @MainActor static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000
        return c
    }()

    /// Decode straight to a small bitmap via ImageIO (never materialises the full-size cover).
    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 16),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
