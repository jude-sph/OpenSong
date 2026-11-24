import Foundation

public enum MatchConfidence: String, Sendable { case high, medium, low }

public struct RankedCandidate: Sendable, Identifiable {
    public var id: String { candidate.id }
    public var candidate: Candidate
    public var durationDelta: Double     // seconds vs the known length (inf if unknown)
    public var confidence: MatchConfidence
    public init(candidate: Candidate, durationDelta: Double, confidence: MatchConfidence) {
        self.candidate = candidate; self.durationDelta = durationDelta; self.confidence = confidence
    }
}

public struct VerifyResult: Sendable {
    public var durationOK: Bool
    public var spectralCutoffHz: Double
    public var spectralVerdict: SpectralVerdict
    public var overall: MatchConfidence
}

public struct AcquireSettings: Sendable {
    public var searchLimit: Int
    public init(searchLimit: Int = 8) { self.searchLimit = searchLimit }
}

/// Orchestrates acquisition: search → (user picks) → download → stamp known metadata + art
/// → import as a `.downloaded` master → verify (duration + spectral).
public struct AcquireCoordinator: Sendable {
    public var store: LibraryStore
    public var source: YouTubeSource
    public var importer: Importer
    public var artwork: ArtworkResolver
    public var spectral: SpectralAnalyzer
    public var probe: AudioProbe
    public var settings: AcquireSettings

    public init(store: LibraryStore, source: YouTubeSource, importer: Importer,
                artwork: ArtworkResolver, spectral: SpectralAnalyzer,
                probe: AudioProbe, settings: AcquireSettings) {
        self.store = store; self.source = source; self.importer = importer; self.artwork = artwork
        self.spectral = spectral
        self.probe = probe; self.settings = settings
    }

    /// Search YouTube for a wish item and rank candidates by duration match.
    public func candidates(for wish: WishItem) async throws -> [RankedCandidate] {
        let query = "\(wish.artist) \(wish.title)".trimmingCharacters(in: .whitespaces)
        let cands = try await source.search(query, limit: settings.searchLimit)
        let known = wish.durationSec ?? 0
        let titleTokens = Set("\(wish.artist) \(wish.title)".lowercased().split(separator: " ").map(String.init))
        return cands.map { c in
            let delta = known > 0 ? abs(c.durationSec - known) : Double.infinity
            let titleMatch = titleTokens.isSubset(of: Set(c.title.lowercased().split(separator: " ").map(String.init)))
                || titleTokens.filter { c.title.lowercased().contains($0) }.count >= max(1, titleTokens.count - 1)
            let conf: MatchConfidence
            if delta <= 2 && titleMatch { conf = .high }
            else if delta <= 6 { conf = .medium }
            else { conf = .low }
            return RankedCandidate(candidate: c, durationDelta: delta, confidence: conf)
        }.sorted { $0.durationDelta < $1.durationDelta }
    }

    /// Download the chosen candidate and fulfill the wish. Metadata comes from the wish
    /// identity (known/authoritative) — never re-derived from the video title.
    public func acquire(_ wish: WishItem, chosen: Candidate, art: URL?, downloadDir: URL)
        async throws -> (asset: AudioAsset, verify: VerifyResult) {
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let dl = downloadDir.appendingPathComponent("\(UUID().uuidString).m4a")
        try await source.download(chosen.url, to: dl)

        let identity = wish.identity
        // A replacement wish carries the asset it supersedes, so the importer overrides its dedup
        // rules — otherwise a same-titled replacement is silently discarded as "already have it".
        let asset = try importer.importOne(dl, identity: identity, source: .downloaded,
                                           replacing: wish.replacesAssetID)
        let masterURL = URL(fileURLWithPath: asset.masterPath)
        if let art { try? artwork.embed(art, into: masterURL) }
        squareCropEmbeddedArt(masterURL, scratch: downloadDir)
        // Some uploads carry no usable thumbnail (or the embed step is skipped): guarantee a cover
        // by pulling the official one from iTunes when the file still has none.
        await ensureArtwork(masterURL, identity: identity, scratch: downloadDir)

        let verify = try await verifyAudio(masterURL, expected: identity)

        var w = wish
        w.state = .downloaded
        w.assetID = asset.id
        w.chosenURL = chosen.url.absoluteString
        try store.updateWish(w)
        return (asset, verify)
    }

    /// Crop the embedded cover to a centered square (YouTube thumbnails are often 16:9), so all
    /// library art is square. No-op if the file has no embedded art or crop fails.
    private func squareCropEmbeddedArt(_ audio: URL, scratch: URL) {
        let extracted = scratch.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? artwork.extractEmbedded(from: audio, to: extracted)) == true else { return }
        defer { try? FileManager.default.removeItem(at: extracted) }
        let squared = scratch.appendingPathComponent("\(UUID().uuidString)-sq.png")
        defer { try? FileManager.default.removeItem(at: squared) }
        guard (try? ArtworkCrop.squareCrop(of: extracted, to: squared, ffmpegPath: artwork.ffmpegPath)) != nil,
              FileManager.default.fileExists(atPath: squared.path) else { return }
        try? artwork.embed(squared, into: audio)
    }

    /// Guarantee the master has a cover: if it already has embedded art, leave it (YouTube
    /// thumbnails are usually the real cover). Otherwise fetch the official cover from iTunes,
    /// square-crop it, and embed. Silent no-op on any failure (offline, no match, etc.).
    private func ensureArtwork(_ audio: URL, identity: TrackIdentity, scratch: URL) async {
        let probe = scratch.appendingPathComponent("\(UUID().uuidString)-chk.png")
        if (try? artwork.extractEmbedded(from: audio, to: probe)) == true {
            try? FileManager.default.removeItem(at: probe); return   // already has art
        }
        let album = (identity.album?.isEmpty == false) ? identity.album! : identity.title
        let finder = ArtworkFinder(http: artwork.http)
        guard let cands = try? await finder.search(artist: identity.artist, album: album, limit: 1),
              let best = cands.first else { return }
        let raw = scratch.appendingPathComponent("\(UUID().uuidString)-it.img")
        defer { try? FileManager.default.removeItem(at: raw) }
        guard (try? await artwork.download(best.fullURL, to: raw)) != nil,
              FileManager.default.fileExists(atPath: raw.path) else { return }
        let squared = scratch.appendingPathComponent("\(UUID().uuidString)-itsq.png")
        defer { try? FileManager.default.removeItem(at: squared) }
        let art = ((try? ArtworkCrop.squareCrop(of: raw, to: squared, ffmpegPath: artwork.ffmpegPath)) != nil
                   && FileManager.default.fileExists(atPath: squared.path)) ? squared : raw
        try? artwork.embed(art, into: audio)
    }

    public func verifyAudio(_ url: URL, expected: TrackIdentity) async throws -> VerifyResult {
        let pr = try probe.probe(url)
        let durationOK = expected.durationSec > 0 ? abs(pr.durationSec - expected.durationSec) <= 5 : true
        let cutoff = (try? spectral.cutoffHz(url)) ?? 0
        let verdict = spectral.verdict(cutoffHz: cutoff, bitrateKbps: pr.bitrateKbps)

        // Confidence from what we can actually measure: the length matches what the catalogue says,
        // and the spectrum looks like a genuine encode at the claimed bitrate.
        let overall: MatchConfidence = (durationOK && verdict.isGood) ? .high : (durationOK ? .medium : .low)
        return VerifyResult(durationOK: durationOK, spectralCutoffHz: cutoff,
                            spectralVerdict: verdict, overall: overall)
    }
}
