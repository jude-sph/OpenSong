import Foundation

/// A track from a Spotify playlist. Spotify gives no downloadable audio (DRM), so this is only
/// a *source of truth for the track list* — acquisition still happens via yt-dlp. ISRC (the
/// recording's unique code) is captured for potential exact matching later.
public struct SpotifyTrack: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationSec: Double
    public var isrc: String?
    public init(title: String, artist: String, album: String, durationSec: Double, isrc: String? = nil) {
        self.title = title; self.artist = artist; self.album = album
        self.durationSec = durationSec; self.isrc = isrc
    }
    public var wishItem: WishItem {
        WishItem(title: title, artist: artist, album: album.isEmpty ? nil : album,
                 durationSec: durationSec, source: .spotify, state: .wishlist)
    }
}

public struct SpotifyPlaylist: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var owner: String
    public var imageURL: URL?
    public var trackCount: Int      // total per Spotify (may exceed loaded tracks until drilled in)
    public var tracks: [SpotifyTrack]
    public init(id: String, name: String, owner: String, imageURL: URL? = nil,
                trackCount: Int, tracks: [SpotifyTrack] = []) {
        self.id = id; self.name = name; self.owner = owner; self.imageURL = imageURL
        self.trackCount = trackCount; self.tracks = tracks
    }
}

/// What a pasted Spotify URL/URI/ID refers to.
public enum SpotifyRef: Sendable, Equatable {
    case playlist(String)
    case user(String)
}

/// Reads Spotify data. Uses the signed-in user's token when there is one, and falls back to an
/// app-only (Client Credentials) token otherwise.
///
/// The distinction matters since February 2026: search and album lookups work with app credentials,
/// but a playlist's contents come back empty — every track field of Get Playlist returns `{}` and
/// `/items` answers "Valid user authentication required". So importing a playlist needs a sign-in.
public actor SpotifyClient {
    public let clientID: String
    public let clientSecret: String
    private let http: HTTPClient
    private let userTokens: SpotifyUserTokens?
    private var token: String?
    private var tokenExpiry: Date = .distantPast

    public init(clientID: String, clientSecret: String, http: HTTPClient = URLSessionHTTPClient(),
                userTokens: SpotifyUserTokens? = nil) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.http = http
        self.userTokens = userTokens
    }

    // MARK: URL / URI / ID parsing

    /// Accepts an open.spotify.com URL, a `spotify:` URI, or a bare ID and classifies it.
    public static func parse(_ input: String) -> SpotifyRef? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // spotify:playlist:ID  /  spotify:user:ID
        if s.hasPrefix("spotify:") {
            let parts = s.split(separator: ":")
            if parts.count >= 3, let kind = parts.dropFirst().first {
                let id = String(parts[2])
                if kind == "playlist" { return .playlist(id) }
                if kind == "user" { return .user(id) }
            }
            return nil
        }
        // https://open.spotify.com/playlist/ID?...  /  /user/ID  /  /embed/playlist/ID
        if let comps = URLComponents(string: s), let host = comps.host, host.contains("spotify.com") {
            let segs = comps.path.split(separator: "/").map(String.init)
            if let i = segs.firstIndex(of: "playlist"), i + 1 < segs.count { return .playlist(segs[i + 1]) }
            if let i = segs.firstIndex(of: "user"), i + 1 < segs.count { return .user(segs[i + 1]) }
            return nil
        }
        // Bare token: 22-char base62 IDs are playlists here.
        if s.range(of: "^[A-Za-z0-9]{16,}$", options: .regularExpression) != nil { return .playlist(s) }
        return nil
    }

    // MARK: Auth

    private func validToken() async throws -> String {
        // A user token, when signed in: it can read playlist contents, which the app-only one can't.
        if let user = await userTokens?.userAccessToken() { return user }
        if let t = token, Date() < tokenExpiry { return t }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        let creds = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let data = try await http.send(req)
        struct TokenResp: Decodable { let access_token: String; let expires_in: Double }
        let tr = try JSONDecoder().decode(TokenResp.self, from: data)
        token = tr.access_token
        tokenExpiry = Date().addingTimeInterval(max(30, tr.expires_in - 60))   // refresh a minute early
        return tr.access_token
    }

    private func authedGET(_ url: URL) async throws -> Data {
        let t = try await validToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        do {
            return try await http.send(req)
        } catch {
            // Spotify's own message for these is the single word "Forbidden", which tells the user
            // nothing about a restriction they can't do anything about from here.
            if let explained = Self.explain(error.localizedDescription, path: url.path) {
                throw AccessError(message: explained)
            }
            throw error
        }
    }

    public struct AccessError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Turn an HTTP failure into something that says what is actually going on.
    ///
    /// Spotify progressively closed its Web API to app-only (client credentials) tokens: playlist
    /// contents, user profiles and artist top-tracks now answer 403 however valid the credentials
    /// are, and its own editorial playlists answer 404. None of that is fixable by retrying or by
    /// pasting a different link, so the message has to say so.
    public static func explain(_ description: String, path: String) -> String? {
        if description.contains("HTTP 403") {
            if path.contains("/users/") {
                return "Spotify removed this endpoint in February 2026 — listing a user's public "
                    + "playlists is no longer possible for any app, signed in or not. Use a link to "
                    + "an individual playlist instead."
            }
            return "Spotify refused this (403). Its February 2026 changes replaced the old playlist "
                + "endpoints; reading a playlist's contents now needs a Spotify sign-in, which "
                + "OpenSong doesn't do yet."
        }
        if description.contains("HTTP 401"), path.contains("/playlists/") {
            return "Spotify says this needs a signed-in Spotify account (401). Since February 2026 "
                + "a playlist's contents can't be read with app credentials alone. Search and album "
                + "lookups still work."
        }
        if description.contains("HTTP 404"), path.contains("/playlists/") {
            return "Spotify reports this playlist as not found (404), which is what it returns for "
                + "its own editorial and algorithmic playlists (Discover Weekly, Today's Top Hits "
                + "and so on). Only playlists made by people are visible to apps."
        }
        if description.contains("HTTP 401") {
            return "Spotify rejected the credentials (401). Check the Client ID and Secret in "
                + "Settings."
        }
        return nil
    }

    // MARK: Public API

    /// Fetch a playlist's metadata and *all* its items (following pagination).
    ///
    /// Contents come from `/items`, not `/tracks`: Spotify removed the `/tracks` endpoints in
    /// February 2026 and replaced them with `/items`. The metadata response no longer carries the
    /// track list either, so this is always two calls.
    public func playlist(id: String) async throws -> SpotifyPlaylist {
        let metaURL = URL(string: "https://api.spotify.com/v1/playlists/\(id)")!
        let meta = try await SpotifyJSON.playlistMeta(authedGET(metaURL))
        var tracks = meta.firstPage
        // Metadata no longer carries the track list, so the contents come from `/items`. Only fall
        // back to it when nothing came inline: fetching it *as well* would duplicate the first page
        // of any playlist short enough to arrive whole.
        var next: String? = meta.next
            ?? (meta.firstPage.isEmpty ? "https://api.spotify.com/v1/playlists/\(id)/items?limit=100" : nil)
        while let n = next, let nurl = URL(string: n) {
            let page = try await SpotifyJSON.trackPage(authedGET(nurl))
            tracks.append(contentsOf: page.tracks)
            next = page.next
        }
        return SpotifyPlaylist(id: id, name: meta.name, owner: meta.owner, imageURL: meta.imageURL,
                               trackCount: meta.total > 0 ? meta.total : tracks.count, tracks: tracks)
    }

    /// The signed-in user's own playlists — the replacement for browsing by profile link.
    ///
    /// `/me/playlists` survived the February 2026 cull that removed `/users/{id}/playlists`, and
    /// needs the `playlist-read-private` scope, which the sign-in already asks for.
    public func myPlaylists() async throws -> [SpotifyPlaylist] {
        var out: [SpotifyPlaylist] = []
        var url: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!
        while let u = url {
            let (items, next) = try await SpotifyJSON.playlistList(authedGET(u))
            out.append(contentsOf: items)
            url = next.flatMap(URL.init)
        }
        return out
    }

    /// The signed-in account's display name, for the header.
    public func myDisplayName() async throws -> String? {
        let data = try await authedGET(URL(string: "https://api.spotify.com/v1/me")!)
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (o?["display_name"] as? String) ?? (o?["id"] as? String)
    }

    /// List a user's *public* playlists.
    ///
    /// Spotify removed `GET /users/{id}/playlists` in February 2026 with no replacement, so this
    /// can no longer work for anyone — signing in wouldn't bring it back. Kept so a saved profile
    /// still reports something honest rather than a raw HTTP error.
    public func userPlaylists(userID: String) async throws -> [SpotifyPlaylist] {
        throw AccessError(message: "Spotify removed the endpoint that lists a user's playlists "
            + "(February 2026) and published no replacement, so profile links can't be imported by "
            + "any app. Individual playlist links are the way in — those need a Spotify sign-in, "
            + "which OpenSong doesn't do yet.")
    }
}

/// Pure JSON decoding for Spotify responses (kept separate so it's unit-testable without network).
public enum SpotifyJSON {
    public struct Meta: Sendable {
        public var name: String; public var owner: String; public var imageURL: URL?
        public var total: Int; public var firstPage: [SpotifyTrack]; public var next: String?
    }

    /// The `{href, total}` collection describing a playlist's contents.
    ///
    /// February 2026 renamed this from `tracks` to `items` on the playlist object and stopped
    /// populating the old name — which is why every playlist reported "0 tracks" until this looked
    /// at both. The array-valued `items` of a *paged* response is a different shape, and the cast
    /// declines it safely.
    static func itemsCollection(of playlist: [String: Any]) -> [String: Any]? {
        (playlist["items"] as? [String: Any]) ?? (playlist["tracks"] as? [String: Any])
    }

    static func track(from entry: [String: Any]) -> SpotifyTrack? {
        // February 2026 renamed this too: an entry's track now lives under `item`, with `track`
        // deprecated. Reading only the old name skipped every entry, so a playlist opened empty.
        // `item` may also hold a podcast episode, which has no artists and is simply ignored.
        let holder = (entry["item"] as? [String: Any]) ?? (entry["track"] as? [String: Any])
        guard let t = holder, let name = t["name"] as? String else { return nil }
        let artists = (t["artists"] as? [[String: Any]]) ?? []
        let artist = (artists.first?["name"] as? String) ?? ""
        let album = ((t["album"] as? [String: Any])?["name"] as? String) ?? ""
        let ms = (t["duration_ms"] as? Double) ?? Double((t["duration_ms"] as? Int) ?? 0)
        let isrc = ((t["external_ids"] as? [String: Any])?["isrc"] as? String)
        return SpotifyTrack(title: name, artist: artist, album: album, durationSec: ms / 1000.0, isrc: isrc)
    }

    public static func playlistMeta(_ data: Data) throws -> Meta {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Spotify", code: -3, userInfo: [NSLocalizedDescriptionKey: "Bad playlist JSON"])
        }
        let name = (o["name"] as? String) ?? "Playlist"
        let owner = ((o["owner"] as? [String: Any])?["display_name"] as? String) ?? "Spotify"
        let imageURL = ((o["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init)
        let contents = itemsCollection(of: o) ?? [:]
        let total = (contents["total"] as? Int) ?? 0
        let firstPage = (contents["items"] as? [[String: Any]]) ?? []
        return Meta(name: name, owner: owner, imageURL: imageURL, total: total,
                    firstPage: firstPage.compactMap(track(from:)), next: contents["next"] as? String)
    }

    public static func trackPage(_ data: Data) throws -> (tracks: [SpotifyTrack], next: String?) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Spotify", code: -4, userInfo: [NSLocalizedDescriptionKey: "Bad track page JSON"])
        }
        let items = (o["items"] as? [[String: Any]]) ?? []
        return (items.compactMap(track(from:)), o["next"] as? String)
    }

    public static func playlistList(_ data: Data) throws -> (items: [SpotifyPlaylist], next: String?) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Spotify", code: -5, userInfo: [NSLocalizedDescriptionKey: "Bad playlist list JSON"])
        }
        let items = ((o["items"] as? [[String: Any]]) ?? []).compactMap { p -> SpotifyPlaylist? in
            guard let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
            let owner = ((p["owner"] as? [String: Any])?["display_name"] as? String) ?? "Spotify"
            let imageURL = ((p["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init)
            let total = (itemsCollection(of: p)?["total"] as? Int) ?? 0
            return SpotifyPlaylist(id: id, name: name, owner: owner, imageURL: imageURL, trackCount: total)
        }
        return (items, o["next"] as? String)
    }
}

/// The saved-user list: people whose playlists you want to come back to.
///
/// Stored as Spotify user ids, which is what the API and the profile URL both use, so a saved entry
/// survives the person renaming their display name.
public enum SpotifyBookmarks {
    public static let maximum = 30

    /// Add an id, newest first, without duplicating one already saved.
    ///
    /// Ids are compared case-insensitively because Spotify treats them that way, but the spelling
    /// the user pasted is what gets stored — it is what they will recognise in the list.
    public static func add(_ id: String, to list: [String]) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        var out = list.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        out.insert(trimmed, at: 0)
        return Array(out.prefix(maximum))
    }

    public static func remove(_ id: String, from list: [String]) -> [String] {
        list.filter { $0.caseInsensitiveCompare(id) != .orderedSame }
    }

    public static func contains(_ id: String, in list: [String]) -> Bool {
        list.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
}
