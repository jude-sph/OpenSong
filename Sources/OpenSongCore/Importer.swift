import Foundation
import CryptoKit

/// One row in the import review table: the source file, its probed audio, the metadata
/// derived from existing tags (`original`), an optional iTunes `suggested` metadata, and
/// the `chosen` metadata that `commit` will actually write.
public struct ImportCandidate: Sendable {
    public var sourceURL: URL
    public var probe: ProbeResult
    public var original: TrackIdentity
    public var suggested: TrackIdentity?
    public var chosen: TrackIdentity
    public init(sourceURL: URL, probe: ProbeResult, original: TrackIdentity,
                suggested: TrackIdentity? = nil, chosen: TrackIdentity) {
        self.sourceURL = sourceURL; self.probe = probe; self.original = original
        self.suggested = suggested; self.chosen = chosen
    }
}

/// Brings audio into the master library: loose-file import (with a review step) and
/// adopt-from-device (importing device tracks + reconstructing playlists from `.m3u8`).
public struct Importer: Sendable {
    public var store: LibraryStore
    public var probe: AudioProbe
    public var tagger: Transcoder
    public var resolver: MetadataResolver
    public var libraryRoot: URL

    public init(store: LibraryStore, probe: AudioProbe, tagger: Transcoder,
                resolver: MetadataResolver, libraryRoot: URL) {
        self.store = store; self.probe = probe; self.tagger = tagger
        self.resolver = resolver; self.libraryRoot = libraryRoot
    }

    static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "alac", "ogg", "opus"]

    // MARK: loose import

    /// Scan a folder for audio files and build review candidates from their existing tags.
    public func scanLoose(_ folder: URL) throws -> [ImportCandidate] {
        let files = try audioFiles(under: folder)
        var candidates: [ImportCandidate] = []
        for file in files {
            let pr = try probe.probe(file)
            let original = identity(from: pr, fallbackTitle: file.deletingPathExtension().lastPathComponent)
            candidates.append(ImportCandidate(sourceURL: file, probe: pr,
                                              original: original, chosen: original))
        }
        return candidates
    }

    /// Fill in iTunes suggestions (duration-matched) for each candidate.
    public func resolveSuggestions(_ candidates: inout [ImportCandidate]) async {
        for idx in candidates.indices {
            let c = candidates[idx]
            let term = "\(c.original.artist) \(c.original.title)"
            if let match = try? await resolver.bestMatch(term: term, durationSec: c.probe.durationSec) {
                var suggested = c.original
                suggested.title = match.title
                suggested.artist = match.artist
                suggested.albumArtist = match.artist
                suggested.album = match.album.isEmpty ? suggested.album : match.album
                suggested.trackNumber = match.trackNumber ?? suggested.trackNumber
                suggested.discNumber = match.discNumber ?? suggested.discNumber
                suggested.genre = match.genre ?? suggested.genre
                suggested.year = match.year ?? suggested.year
                suggested.provenance = .itunesResolved
                candidates[idx].suggested = suggested
            }
        }
    }

    /// Copy chosen candidates into the master tree, dedup, backfill tags, and index.
    @discardableResult
    public func commit(_ chosen: [ImportCandidate]) throws -> [AudioAsset] {
        try importAll(chosen.map { ($0.sourceURL, $0.probe, $0.chosen) }, source: .importedLoose)
    }

    // MARK: adopt from device

    /// Import the device's tracks as masters and reconstruct playlists from its `.m3u8`.
    public func adopt(musicDir: URL) throws -> (assets: [AudioAsset], playlists: [Playlist]) {
        // 1. Import all device audio (never clobbering a higher-quality master).
        let files = try audioFiles(under: musicDir)
        var inputs: [(URL, ProbeResult, TrackIdentity)] = []
        for file in files {
            let pr = try probe.probe(file)
            var ident = identity(from: pr, fallbackTitle: file.deletingPathExtension().lastPathComponent)
            // Fall back to path structure (MUSIC/Artist/Album/Title) if tags are thin.
            let parts = file.pathComponents
            if parts.count >= 3 {
                let albumSeg = parts[parts.count - 2]
                let artistSeg = parts[parts.count - 3]
                if ident.artist == "Unknown Artist" && artistSeg != musicDir.lastPathComponent { ident.artist = artistSeg }
                if ident.album == nil && albumSeg != musicDir.lastPathComponent { ident.album = albumSeg }
            }
            inputs.append((file, pr, ident))
        }
        let assets = try importAll(inputs, source: .adoptedFromDevice)

        // 2. Reconstruct playlists from the device .m3u8 files.
        var playlists: [Playlist] = []
        let m3u8s = try FileManager.default.contentsOfDirectory(at: musicDir,
            includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "m3u8" }
        for playlistFile in m3u8s.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: playlistFile)
            let entries = M3U8Parser.parse(data)
            let name = playlistFile.deletingPathExtension().lastPathComponent
            let playlistID = try store.createPlaylist(name: name, syncToDevice: true)
            var position = 0
            for entry in entries {
                let title = entry.title ?? entry.titleFromPath
                if let ident = try store.findIdentity(title: title, artist: entry.artist,
                                                      album: entry.album),
                   let identID = ident.id,
                   let asset = try store.assetsForIdentity(identID).first,
                   let assetID = asset.id {
                    try store.addToPlaylist(playlistID: playlistID, assetID: assetID, position: position)
                    position += 1
                }
            }
            playlists.append(Playlist(id: playlistID, name: name, syncToDevice: true))
        }
        return (assets, playlists)
    }

    // MARK: shared internals

    private func importAll(_ inputs: [(URL, ProbeResult, TrackIdentity)],
                           source: AudioSource) throws -> [AudioAsset] {
        var results: [AudioAsset] = []
        for (url, pr, chosen) in inputs {
            let hash = try Self.sha256(of: url)

            // Exact-duplicate: same bytes already imported.
            if let existing = try store.findAssetByHash(hash) { results.append(existing); continue }

            // Identity-level dedup: keep the higher-bitrate master, never downgrade.
            if let ident = try store.findIdentity(title: chosen.title, artist: chosen.artist, album: chosen.album),
               let identID = ident.id,
               let existingAsset = try store.assetsForIdentity(identID).first {
                if existingAsset.bitrateKbps >= pr.bitrateKbps {
                    results.append(existingAsset); continue   // keep existing (>= quality)
                } else {
                    // New file is higher quality — replace the master in place.
                    let replaced = try placeAndIndex(url: url, pr: pr, chosen: chosen,
                                                      identityID: identID, hash: hash,
                                                      source: source, replacing: existingAsset)
                    results.append(replaced); continue
                }
            }

            // Fresh import.
            let identityID = try store.upsertIdentity(chosen)
            let asset = try placeAndIndex(url: url, pr: pr, chosen: chosen,
                                          identityID: identityID, hash: hash,
                                          source: source, replacing: nil)
            results.append(asset)
        }
        return results
    }

    private func placeAndIndex(url: URL, pr: ProbeResult, chosen: TrackIdentity,
                               identityID: Int64, hash: String, source: AudioSource,
                               replacing existing: AudioAsset?) throws -> AudioAsset {
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        var identForPath = chosen; identForPath.id = identityID
        let dest = DeviceRelativePath.masterURL(under: libraryRoot, for: identForPath, ext: ext)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        // Backfill tags (mp3 supported; other formats best-effort).
        if ext == "mp3" { try? tagger.writeTags(dest, chosen) }
        var sizeBytes: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let s = attrs[.size] as? Int { sizeBytes = Int64(s) }
        var asset = AudioAsset(id: existing?.id, identityID: identityID, masterPath: dest.path,
                               format: pr.codec, bitrateKbps: pr.bitrateKbps,
                               sampleRate: pr.sampleRate, sizeBytes: sizeBytes,
                               contentHash: hash, source: source)
        if let existing, existing.masterPath != dest.path {
            try? FileManager.default.removeItem(atPath: existing.masterPath)
        }
        if existing != nil {
            try store.updateAsset(asset)
        } else {
            let assetID = try store.insertAsset(asset); asset.id = assetID
        }
        return asset
    }

    private func identity(from pr: ProbeResult, fallbackTitle: String) -> TrackIdentity {
        let title = pr.tags["title"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let artist = pr.tags["artist"].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Artist"
        let album = pr.tags["album"].flatMap { $0.isEmpty ? nil : $0 }
        let track = pr.tags["track"].flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }
        let year = pr.tags["date"].flatMap { Int($0.prefix(4)) }
        return TrackIdentity(title: title, artist: artist, albumArtist: artist, album: album,
                             trackNumber: track, genre: pr.tags["genre"], year: year,
                             durationSec: pr.durationSec, provenance: .unresolved)
    }

    private func audioFiles(under folder: URL) throws -> [URL] {
        guard let en = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en {
            if Self.audioExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        return files.sorted(by: { $0.path < $1.path })
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
