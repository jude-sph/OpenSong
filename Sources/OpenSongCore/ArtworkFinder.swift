import Foundation

/// Finds candidate album cover art from Apple's public iTunes Search API (keyless, no signup).
/// Used to replace missing or low-quality embedded artwork. Returns ranked candidates with a
/// small thumbnail URL (for the picker grid) and a high-resolution URL (embedded on apply).
public struct ArtworkFinder: Sendable {
    public var http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    public struct Candidate: Sendable, Equatable, Identifiable {
        public var collection: String   // album name from iTunes
        public var artist: String
        public var thumbURL: URL        // ~200px (grid)
        public var fullURL: URL         // ~600px (embedded)
        public var year: Int?           // release year — tells reissues and remixes apart
        public var id: String { fullURL.absoluteString }

        public init(collection: String, artist: String, thumbURL: URL, fullURL: URL, year: Int? = nil) {
            self.collection = collection; self.artist = artist
            self.thumbURL = thumbURL; self.fullURL = fullURL; self.year = year
        }
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            var wrapperType: String?
            var collectionName: String?
            var artistName: String?
            var artistId: Int?
            var artworkUrl100: String?
            var releaseDate: String?
        }
        var results: [Result]
    }

    /// Rewrite an iTunes artwork URL (`…/100x100bb.jpg`) to a different pixel size. iTunes serves
    /// arbitrary square sizes by swapping the `NNNxNNNbb` segment, so this upscales the tiny
    /// default the API returns to a usable cover.
    public static func upscale(_ urlString: String, to px: Int) -> URL? {
        let scaled = urlString.replacingOccurrences(
            of: #"/\d+x\d+bb\."#, with: "/\(px)x\(px)bb.", options: .regularExpression)
        return URL(string: scaled)
    }

    /// Search iTunes for album artwork matching `artist` + `album`. Either term may be blank
    /// (e.g. search by album only). Returns [] when nothing matches.
    ///
    /// Two passes, because the plain search is a popularity ranking, not a title match: searching
    /// "Gorillaz Gorillaz" returns *Demon Days*, *Plastic Beach*, singles… and never the
    /// self-titled debut, however high the limit. So when nothing in the first pass actually has
    /// the requested title, the artist's full discography is fetched and title-matched instead —
    /// which is where self-titled and low-profile albums live.
    public func search(artist: String, album: String, limit: Int = 12) async throws -> [Candidate] {
        var found = try await termSearch(artist: artist, album: album)
        let wanted = Self.fold(album)
        if !wanted.isEmpty, !artist.isEmpty,
           !found.contains(where: { Self.titleScore($0.collection, wanted) >= Self.exactScore }) {
            found = try await discography(artist: artist) + found
        }
        return Self.rank(found, artist: artist, album: album, limit: limit)
    }

    /// One plain search request ("artist album", ranked by iTunes' own relevance).
    private func termSearch(artist: String, album: String) async throws -> [Candidate] {
        let term = [artist, album].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return [] }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "25"),
        ]
        guard let url = comps.url else { return [] }
        return Self.parse(try await http.get(url))
    }

    /// Every album iTunes lists for the artist (resolved by id, so the titles are exhaustive).
    private func discography(artist: String) async throws -> [Candidate] {
        var artistSearch = URLComponents(string: "https://itunes.apple.com/search")!
        artistSearch.queryItems = [
            .init(name: "term", value: artist),
            .init(name: "entity", value: "musicArtist"),
            .init(name: "limit", value: "1"),
        ]
        guard let aURL = artistSearch.url,
              let artistID = Self.firstArtistID(try await http.get(aURL)) else { return [] }
        var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
        lookup.queryItems = [
            .init(name: "id", value: String(artistID)),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "200"),
        ]
        guard let lURL = lookup.url else { return [] }
        return Self.parse(try await http.get(lURL))
    }

    /// Parse the iTunes Search response into candidates (pure; unit-tested with canned JSON).
    public static func parse(_ data: Data) -> [Candidate] {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return resp.results.compactMap { r in
            guard let art = r.artworkUrl100,
                  let thumb = upscale(art, to: 200),
                  let full = upscale(art, to: 600) else { return nil }
            return Candidate(collection: r.collectionName ?? "",
                             artist: r.artistName ?? "",
                             thumbURL: thumb, fullURL: full,
                             year: r.releaseDate.flatMap { Int($0.prefix(4)) })
        }
    }

    /// The `artistId` of a `musicArtist` search's first hit.
    public static func firstArtistID(_ data: Data) -> Int? {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return resp.results.first(where: { $0.artistId != nil })?.artistId
    }

    // MARK: ranking

    public static let exactScore = 100

    /// Order candidates so the album actually asked for comes first: exact title match, then a
    /// title that contains (or is contained by) it, with a bonus for the right artist and a
    /// penalty for singles/EPs — a "Gorillaz - Single" by another act shouldn't outrank the album.
    public static func rank(_ candidates: [Candidate], artist: String, album: String, limit: Int) -> [Candidate] {
        let wantedAlbum = fold(album), wantedArtist = fold(artist)
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        let scored = unique.enumerated().map { (i, c) -> (Candidate, Int, Int) in
            var score = titleScore(c.collection, wantedAlbum)
            if !wantedArtist.isEmpty, fold(c.artist) == wantedArtist { score += 15 }
            else if !wantedArtist.isEmpty, fold(c.artist).contains(wantedArtist) { score += 5 }
            if score > 0, isSingleOrEP(c.collection) { score -= 30 }
            return (c, score, i)
        }
        return scored.sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }.prefix(limit).map { $0.0 }
    }

    /// How well a candidate's title matches the wanted one (0 = not at all).
    public static func titleScore(_ candidate: String, _ wanted: String) -> Int {
        guard !wanted.isEmpty else { return 0 }
        let c = fold(candidate)
        if c == wanted { return exactScore }
        // "Demon Days (Deluxe)" / "Humanz (Gorillaz 20 Mix)" — same album, decorated title. The
        // decoration has to come off before folding, which flattens the brackets away.
        let bare = fold(candidate.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression))
        if bare == wanted { return exactScore - 10 }
        if c.contains(wanted) || wanted.contains(c) { return 50 }
        return 0
    }

    private static func isSingleOrEP(_ title: String) -> Bool {
        title.range(of: #"(?:\s[-–]\s|\s)(single|ep)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Comparison form: lowercased, punctuation-light, whitespace-collapsed.
    public static func fold(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
