import Foundation

/// A canonical catalog match resolved from the iTunes Search API.
public struct CatalogMatch: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?
    public var year: Int?
    public var durationSec: Double
    public var artworkURL: URL?
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
    /// Send an arbitrary request (needed for POST + auth headers, e.g. the Spotify token/API).
    func send(_ request: URLRequest) async throws -> Data
}

public extension HTTPClient {
    /// Default: fall back to a plain GET of the request's URL (test stubs that only implement
    /// `get` keep working). URLSessionHTTPClient overrides this to honor method/headers/body.
    func send(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else {
            throw NSError(domain: "HTTPClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Request has no URL"])
        }
        return try await get(url)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    /// `timeout` bounds BOTH the request and the resource (URLSession's resource timeout
    /// otherwise defaults to 7 days, which can hang a lookup indefinitely on a stalled network).
    public init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }
    public func get(_ url: URL) async throws -> Data {
        try await send(URLRequest(url: url))
    }
    public func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "HTTPClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
        return data
    }
}

/// Resolves canonical metadata (title/artist/album/track#/disc#/genre/year/art) from the
/// iTunes catalog, disambiguated by duration. Used only when identity is unresolved;
/// Apple Music items arrive authoritative and bypass this.
public struct MetadataResolver: Sendable {
    public var http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    private struct ITunesResponse: Decodable {
        struct Result: Decodable {
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var trackNumber: Int?
            var discNumber: Int?
            var primaryGenreName: String?
            var releaseDate: String?
            var trackTimeMillis: Int?
            var artworkUrl100: String?
        }
        var results: [Result]
    }

    /// Upgrade the 100×100 thumbnail URL to a high-resolution square cover.
    static func upgradeArtwork(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let hi = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: hi)
    }

    public func search(term: String, limit: Int = 10) async throws -> [CatalogMatch] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "term", value: term),
        ]
        let data = try await http.get(comps.url!)
        let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return decoded.results.compactMap { r in
            guard let title = r.trackName, let artist = r.artistName else { return nil }
            let year = r.releaseDate.flatMap { Int($0.prefix(4)) }
            return CatalogMatch(
                title: title, artist: artist, album: r.collectionName ?? "",
                trackNumber: r.trackNumber, discNumber: r.discNumber,
                genre: r.primaryGenreName, year: year,
                durationSec: Double(r.trackTimeMillis ?? 0) / 1000.0,
                artworkURL: Self.upgradeArtwork(r.artworkUrl100))
        }
    }

    /// Best match for a known duration: smallest absolute duration delta.
    public func bestMatch(term: String, durationSec: Double, limit: Int = 15) async throws -> CatalogMatch? {
        let matches = try await search(term: term, limit: limit)
        guard durationSec > 0 else { return matches.first }
        return matches.min(by: { abs($0.durationSec - durationSec) < abs($1.durationSec - durationSec) })
    }
}
