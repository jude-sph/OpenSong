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
    public var acoustidScore: Double?     // nil if not checked (no key)
    public var acoustidMatched: Bool?
    public var overall: MatchConfidence
}

public struct AcquireSettings: Sendable {
    public var acoustidAPIKey: String
    public var searchLimit: Int
    public init(acoustidAPIKey: String = "", searchLimit: Int = 8) {
        self.acoustidAPIKey = acoustidAPIKey; self.searchLimit = searchLimit
    }
}

/// Orchestrates acquisition: search → (user picks) → download → stamp known metadata + art
/// → import as a `.downloaded` master → verify (duration + spectral + AcoustID if keyed).
public struct AcquireCoordinator: Sendable {
    public var store: LibraryStore
    public var source: YouTubeSource
    public var importer: Importer
    public var artwork: ArtworkResolver
    public var spectral: SpectralAnalyzer
    public var fingerprinter: Fingerprinter
    public var acoustid: AcoustIDClient
    public var probe: AudioProbe
    public var settings: AcquireSettings

    public init(store: LibraryStore, source: YouTubeSource, importer: Importer,
                artwork: ArtworkResolver, spectral: SpectralAnalyzer, fingerprinter: Fingerprinter,
                acoustid: AcoustIDClient, probe: AudioProbe, settings: AcquireSettings) {
        self.store = store; self.source = source; self.importer = importer; self.artwork = artwork
        self.spectral = spectral; self.fingerprinter = fingerprinter; self.acoustid = acoustid
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
        let asset = try importer.importOne(dl, identity: identity, source: .downloaded)
        let masterURL = URL(fileURLWithPath: asset.masterPath)
        if let art { try? artwork.embed(art, into: masterURL) }

        let verify = try await verifyAudio(masterURL, expected: identity)

        var w = wish
        w.state = .downloaded
        w.assetID = asset.id
        w.chosenURL = chosen.url.absoluteString
        try store.updateWish(w)
        return (asset, verify)
    }

    public func verifyAudio(_ url: URL, expected: TrackIdentity) async throws -> VerifyResult {
        let pr = try probe.probe(url)
        let durationOK = expected.durationSec > 0 ? abs(pr.durationSec - expected.durationSec) <= 5 : true
        let cutoff = (try? spectral.cutoffHz(url)) ?? 0
        let verdict = spectral.verdict(cutoffHz: cutoff, bitrateKbps: pr.bitrateKbps)

        var acoustidScore: Double? = nil
        var acoustidMatched: Bool? = nil
        if !settings.acoustidAPIKey.isEmpty {
            if let fp = try? fingerprinter.fingerprint(url),
               let recs = try? await acoustid.lookup(fp, apiKey: settings.acoustidAPIKey) {
                let wantArtist = expected.artist.lowercased()
                let wantTitle = expected.title.lowercased()
                let best = recs.max(by: { $0.score < $1.score })
                acoustidScore = best?.score
                acoustidMatched = recs.contains { r in
                    r.title.lowercased().contains(wantTitle) || wantTitle.contains(r.title.lowercased())
                        || r.artist.lowercased().contains(wantArtist)
                }
            }
        }

        // Combine into an overall confidence.
        let overall: MatchConfidence
        if let matched = acoustidMatched {
            overall = (matched && durationOK && verdict.isGood) ? .high : (matched || durationOK ? .medium : .low)
        } else {
            overall = (durationOK && verdict.isGood) ? .high : (durationOK ? .medium : .low)
        }
        return VerifyResult(durationOK: durationOK, spectralCutoffHz: cutoff, spectralVerdict: verdict,
                            acoustidScore: acoustidScore, acoustidMatched: acoustidMatched, overall: overall)
    }
}
