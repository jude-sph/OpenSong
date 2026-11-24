import Foundation

/// A signed-in Spotify session: the token used for requests, and the one used to renew it.
public struct SpotifySession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }

    /// Usable for a bit longer. The margin matters: a token that expires mid-request fails the
    /// request, and a playlist import is many requests in a row.
    public func isFresh(at now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        now < expiresAt.addingTimeInterval(-margin)
    }
}

/// The Authorization Code flow, in the parts that are pure functions — building the URL the browser
/// is sent to, reading what comes back, and turning Spotify's token JSON into a session.
///
/// Needed because Spotify's February 2026 changes put playlist contents behind a *user* token:
/// app-only credentials get `{}` for every track field, and the `/items` endpoint answers
/// "Valid user authentication required".
public enum SpotifyAuth {
    /// Loopback, not `localhost` — Spotify rejects the latter as an insecure redirect URI, and
    /// accepts `http://127.0.0.1` with a port for native apps.
    public static let defaultRedirectURI = "http://127.0.0.1:8888/callback"

    /// Enough to read the signed-in user's own playlists, including collaborative ones. Nothing is
    /// requested that would let the app modify anything.
    public static let scopes = ["playlist-read-private", "playlist-read-collaborative"]

    public enum AuthError: LocalizedError, Equatable {
        case denied(String)          // the user said no, or Spotify refused
        case stateMismatch
        case noCode
        case badTokenResponse(String)
        public var errorDescription: String? {
            switch self {
            case .denied(let why): return "Spotify sign-in was refused: \(why)"
            case .stateMismatch:
                return "Spotify sign-in didn't match the request that started it, so it was "
                    + "discarded. Try again."
            case .noCode: return "Spotify didn't return an authorization code."
            case .badTokenResponse(let d): return "Spotify's token response couldn't be read: \(d)"
            }
        }
    }

    /// Where to send the browser.
    ///
    /// The query is built by hand rather than with `URLComponents.queryItems`, which leaves `:` and
    /// `/` unescaped — it would send `redirect_uri=http://127.0.0.1:8888/callback` raw. That is legal
    /// in a query string, but the value is compared against a registered URI, so it goes out fully
    /// percent-encoded where there is nothing to disagree about.
    public static func authorizeURL(clientID: String, redirectURI: String = defaultRedirectURI,
                                    state: String) -> URL? {
        let query = form([
            "client_id": clientID,
            "response_type": "code",
            "redirect_uri": redirectURI,
            "scope": scopes.joined(separator: " "),
            "state": state,
        ])
        return URL(string: "https://accounts.spotify.com/authorize?" + query)
    }

    /// The port the callback listener must open, taken from the redirect URI so the two can't drift.
    public static func callbackPort(of redirectURI: String) -> UInt16 {
        UInt16(URLComponents(string: redirectURI)?.port ?? 8888)
    }

    /// An unguessable value tying the callback to the request that started it.
    public static func randomState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Read the authorization code out of the callback the browser was redirected to.
    ///
    /// `requestTarget` is the path+query from the HTTP request line, e.g. `/callback?code=…&state=…`.
    public static func codeFromCallback(_ requestTarget: String, expectedState: String) throws -> String {
        var comps = URLComponents(string: requestTarget)
        if comps?.queryItems == nil, let q = requestTarget.split(separator: "?", maxSplits: 1).last {
            comps = URLComponents(string: "/?" + q)
        }
        let items = comps?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let err = value("error") { throw AuthError.denied(err) }
        guard value("state") == expectedState else { throw AuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw AuthError.noCode }
        return code
    }

    /// Turn Spotify's token JSON into a session.
    ///
    /// A refresh response often omits `refresh_token`, meaning "keep using the one you have" — so
    /// the existing one is carried forward rather than lost, which would silently sign the user out
    /// an hour later.
    public static func session(fromTokenJSON data: Data, existingRefresh: String? = nil,
                               now: Date = Date()) throws -> SpotifySession {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.badTokenResponse("not JSON")
        }
        if let err = o["error"] as? String {
            let desc = (o["error_description"] as? String) ?? err
            throw AuthError.denied(desc)
        }
        guard let access = o["access_token"] as? String, !access.isEmpty else {
            throw AuthError.badTokenResponse("no access_token")
        }
        let refresh = (o["refresh_token"] as? String) ?? existingRefresh ?? ""
        guard !refresh.isEmpty else { throw AuthError.badTokenResponse("no refresh_token") }
        let seconds = (o["expires_in"] as? Double) ?? Double((o["expires_in"] as? Int) ?? 3600)
        return SpotifySession(accessToken: access, refreshToken: refresh,
                              expiresAt: now.addingTimeInterval(seconds))
    }

    /// Form body for exchanging the authorization code for tokens.
    public static func exchangeBody(code: String, redirectURI: String = defaultRedirectURI) -> Data {
        Data(form(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI]).utf8)
    }

    /// Form body for renewing an expired access token.
    public static func refreshBody(refreshToken: String) -> Data {
        Data(form(["grant_type": "refresh_token", "refresh_token": refreshToken]).utf8)
    }

    /// The unreserved set from RFC 3986: everything else is escaped. `.alphanumerics` alone was
    /// wrong — it escapes the underscore, so `grant_type` arrived as `authorization%5Fcode`.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func form(_ pairs: [String: String]) -> String {
        pairs.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v)"
        }.joined(separator: "&")
    }
}

/// Supplies a user access token to `SpotifyClient`, renewing it as needed. Nil means "not signed
/// in", and the client falls back to app-only credentials (which still serve search and albums).
public protocol SpotifyUserTokens: Sendable {
    func userAccessToken() async -> String?
}
