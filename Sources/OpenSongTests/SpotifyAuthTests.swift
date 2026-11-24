import Foundation
import OpenSongCore

func registerSpotifyAuthTests() {
    t.test("the redirect URI goes out percent-encoded, and the listener port follows it") {
        // Sent raw, this reads `redirect_uri=http://127.0.0.1:8888/callback` — legal in a query, but
        // the value is compared against a registered string, so it is encoded to leave no room for
        // disagreement. Spotify's only complaint is "redirect_uri: Not matching configuration".
        let raw = SpotifyAuth.authorizeURL(clientID: "abc", state: "st8")?.absoluteString ?? ""
        try t.expect(raw.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback"),
                     "encoded, not raw (\(raw))")
        try t.expect(!raw.contains("redirect_uri=http://"), "definitely not raw")

        // The listener must open the port the redirect actually names, or nothing comes back.
        try t.expectEqual(SpotifyAuth.callbackPort(of: "http://127.0.0.1:8888/callback"), 8888, "default")
        try t.expectEqual(SpotifyAuth.callbackPort(of: "http://127.0.0.1:9000/cb"), 9000, "a custom port")
        try t.expectEqual(SpotifyAuth.callbackPort(of: "nonsense"), 8888, "falls back rather than crashing")
    }

    t.test("the authorize URL asks for exactly what's needed and nothing more") {
        let url = SpotifyAuth.authorizeURL(clientID: "abc123", state: "st8")
        guard let comps = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw TestFailure(message: "no URL built")
        }
        try t.expectEqual(comps.host, "accounts.spotify.com", "Spotify's authorize host")
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        try t.expectEqual(q("client_id"), "abc123", "the app's id")
        try t.expectEqual(q("response_type"), "code", "authorization code flow")
        try t.expectEqual(q("state"), "st8", "state is carried")
        try t.expectEqual(q("redirect_uri"), "http://127.0.0.1:8888/callback",
                          "loopback IP, not localhost — Spotify rejects localhost as insecure")
        let scopes = (q("scope") ?? "").split(separator: " ").map(String.init).sorted()
        try t.expectEqual(scopes, ["playlist-read-collaborative", "playlist-read-private"],
                          "read-only playlist scopes; nothing that can modify the account")
    }

    t.test("the callback is read, and only when it matches the request that started it") {
        let code = try SpotifyAuth.codeFromCallback("/callback?code=AQD123&state=st8",
                                                    expectedState: "st8")
        try t.expectEqual(code, "AQD123", "the code")

        // A callback carrying someone else's state must be discarded, not used.
        do {
            _ = try SpotifyAuth.codeFromCallback("/callback?code=AQD123&state=other", expectedState: "st8")
            throw TestFailure(message: "accepted a mismatched state")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .stateMismatch, "rejected for the right reason")
        }

        // The user pressing Cancel comes back as an error, not a code.
        do {
            _ = try SpotifyAuth.codeFromCallback("/callback?error=access_denied&state=st8",
                                                 expectedState: "st8")
            throw TestFailure(message: "treated a refusal as success")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .denied("access_denied"), "reports what Spotify said")
        }

        do {
            _ = try SpotifyAuth.codeFromCallback("/callback?state=st8", expectedState: "st8")
            throw TestFailure(message: "accepted a callback with no code")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .noCode, "no code is an error")
        }
    }

    t.test("a token response becomes a session with a real expiry") {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = try SpotifyAuth.session(fromTokenJSON: Data(json.utf8), now: now)
        try t.expectEqual(s.accessToken, "AT", "access token")
        try t.expectEqual(s.refreshToken, "RT", "refresh token")
        try t.expectEqual(s.expiresAt, now.addingTimeInterval(3600), "expiry is now + expires_in")
        try t.expect(s.isFresh(at: now), "fresh right away")
        try t.expect(!s.isFresh(at: now.addingTimeInterval(3600)), "not at the expiry instant")
        // The margin exists because a token that dies mid-import fails the rest of the requests.
        try t.expect(!s.isFresh(at: now.addingTimeInterval(3570)), "nor within the safety margin")
    }

    t.test("a refresh that omits the refresh token keeps the one we have") {
        // Spotify usually returns only a new access token; dropping the old refresh token here
        // would sign the user out an hour later for no reason.
        let json = #"{"access_token":"AT2","expires_in":3600}"#
        let s = try SpotifyAuth.session(fromTokenJSON: Data(json.utf8), existingRefresh: "RT")
        try t.expectEqual(s.accessToken, "AT2", "new access token")
        try t.expectEqual(s.refreshToken, "RT", "existing refresh token carried forward")

        // …but a rotated one replaces it.
        let rotated = #"{"access_token":"AT3","refresh_token":"RT2","expires_in":3600}"#
        try t.expectEqual(try SpotifyAuth.session(fromTokenJSON: Data(rotated.utf8),
                                                  existingRefresh: "RT").refreshToken,
                          "RT2", "a rotated refresh token wins")
    }

    t.test("an error response is reported rather than parsed into a broken session") {
        let json = #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#
        do {
            _ = try SpotifyAuth.session(fromTokenJSON: Data(json.utf8), existingRefresh: "RT")
            throw TestFailure(message: "built a session from an error")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .denied("Refresh token revoked"), "passes Spotify's reason through")
        }
        do {
            _ = try SpotifyAuth.session(fromTokenJSON: Data("not json".utf8))
            throw TestFailure(message: "accepted junk")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .badTokenResponse("not JSON"), "junk is rejected")
        }
        // No refresh token anywhere means the session couldn't be renewed, so it isn't stored.
        do {
            _ = try SpotifyAuth.session(fromTokenJSON: Data(#"{"access_token":"AT"}"#.utf8))
            throw TestFailure(message: "stored a session that can never refresh")
        } catch let e as SpotifyAuth.AuthError {
            try t.expectEqual(e, .badTokenResponse("no refresh_token"), "refused")
        }
    }

    t.test("the token request bodies are form-encoded as Spotify expects") {
        let exchange = String(decoding: SpotifyAuth.exchangeBody(code: "AQD/123"), as: UTF8.self)
        try t.expect(exchange.contains("grant_type=authorization_code"), "the grant")
        try t.expect(exchange.contains("code=AQD%2F123"), "the code is percent-encoded")
        try t.expect(exchange.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback"),
                     "the redirect URI is encoded, and must match the one registered")
        let refresh = String(decoding: SpotifyAuth.refreshBody(refreshToken: "RT"), as: UTF8.self)
        try t.expectEqual(refresh, "grant_type=refresh_token&refresh_token=RT", "refresh body")
    }

    t.test("state values differ between sign-ins") {
        let a = SpotifyAuth.randomState(), b = SpotifyAuth.randomState()
        try t.expect(a != b, "otherwise the check would be worthless")
        try t.expect(a.count >= 16, "long enough not to be guessed (\(a.count))")
    }
}
