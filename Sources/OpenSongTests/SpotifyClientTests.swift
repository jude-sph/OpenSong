import Foundation
import OpenSongCore

/// Stub HTTP client that returns canned responses keyed by URL substring, so the Spotify
/// client's auth + pagination can be tested without network.
private struct StubHTTP: HTTPClient {
    /// Ordered (needle, data): first match wins, so list more-specific needles first.
    let routes: [(String, Data)]
    func get(_ url: URL) async throws -> Data { try route(url) }
    func send(_ request: URLRequest) async throws -> Data { try route(request.url!) }
    private func route(_ url: URL) throws -> Data {
        for (needle, data) in routes where url.absoluteString.contains(needle) { return data }
        throw NSError(domain: "stub", code: 404, userInfo: [NSLocalizedDescriptionKey: "no route for \(url)"])
    }
}

private func d(_ s: String) -> Data { s.data(using: .utf8)! }

func registerSpotifyClientTests() {
    t.test("parses Spotify URLs / URIs / IDs") {
        try t.expectEqual(SpotifyClient.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=x"),
                          .playlist("37i9dQZF1DXcBWIGoYBM5M"), "playlist url")
        try t.expectEqual(SpotifyClient.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
                          .playlist("37i9dQZF1DXcBWIGoYBM5M"), "playlist uri")
        try t.expectEqual(SpotifyClient.parse("https://open.spotify.com/user/spotify"),
                          .user("spotify"), "user url")
        try t.expectEqual(SpotifyClient.parse("spotify:user:jude"), .user("jude"), "user uri")
        try t.expectEqual(SpotifyClient.parse("37i9dQZF1DXcBWIGoYBM5M"),
                          .playlist("37i9dQZF1DXcBWIGoYBM5M"), "bare id")
        try t.expect(SpotifyClient.parse("not a spotify thing") == nil, "garbage rejected")
    }

    t.test("fetches a playlist and follows track pagination") {
        let token = d(#"{"access_token":"tok123","token_type":"Bearer","expires_in":3600}"#)
        // Playlist meta: 3 total, first page has 2 tracks + a `next` pointer.
        let meta = d(#"""
        {"name":"blonde faves","owner":{"display_name":"jude"},
         "images":[{"url":"https://img/cover.jpg"}],
         "tracks":{"total":3,"next":"https://api.spotify.com/v1/playlists/PL/tracks?offset=2",
           "items":[
             {"track":{"name":"Nights","artists":[{"name":"Frank Ocean"}],"album":{"name":"Blonde"},"duration_ms":307000,"external_ids":{"isrc":"USUM71600001"}}},
             {"track":{"name":"White Ferrari","artists":[{"name":"Frank Ocean"}],"album":{"name":"Blonde"},"duration_ms":248000}}
           ]}}
        """#)
        // Second page: 1 track, no next. Also exercises a null track (skipped).
        let page2 = d(#"""
        {"next":null,"items":[
          {"track":null},
          {"track":{"name":"Ivy","artists":[{"name":"Frank Ocean"},{"name":"X"}],"album":{"name":"Blonde"},"duration_ms":249000}}
        ]}
        """#)
        let http = StubHTTP(routes: [
            ("accounts.spotify.com/api/token", token),
            ("/playlists/PL/tracks", page2),        // most-specific first
            ("/playlists/PL", meta),
        ])
        let client = SpotifyClient(clientID: "id", clientSecret: "secret", http: http)
        let pl = try awaitSync { try await client.playlist(id: "PL") }
        try t.expectEqual(pl.name, "blonde faves", "name")
        try t.expectEqual(pl.owner, "jude", "owner")
        try t.expectEqual(pl.trackCount, 3, "total")
        try t.expectEqual(pl.tracks.count, 3, "all pages loaded, null skipped")
        try t.expectEqual(pl.tracks[0].title, "Nights", "first track")
        try t.expectEqual(pl.tracks[0].isrc, "USUM71600001", "isrc captured")
        try t.expect(abs(pl.tracks[0].durationSec - 307) < 0.5, "ms→sec")
        try t.expectEqual(pl.tracks[2].title, "Ivy", "second page track")
        try t.expectEqual(pl.tracks[2].artist, "Frank Ocean", "primary artist only")
    }

    t.test("listing a user's playlists reports that Spotify removed the endpoint") {
        // Was a working feature; `GET /users/{id}/playlists` was removed in February 2026 with no
        // replacement, so the client must say so rather than issue a doomed request.
        let client = SpotifyClient(clientID: "id", clientSecret: "secret",
                                   http: TestSupport.StubHTTPClient(data: Data("{}".utf8)))
        do {
            _ = try await client.userPlaylists(userID: "emilie.mlx")
            throw TestFailure(message: "expected it to refuse")
        } catch let e as SpotifyClient.AccessError {
            try t.expect(e.message.contains("removed"), "explains that it is gone")
            try t.expect(e.message.contains("playlist links"), "and what to use instead")
        }
    }

    t.test("LIVE: real Spotify playlist fetch") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1",
              let id = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"],
              let secret = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] else {
            try t.skip("set OPENSONG_LIVE=1 + SPOTIFY_CLIENT_ID/SECRET for live Spotify")
        }
        let client = SpotifyClient(clientID: id, clientSecret: secret)
        // Spotify's "Today's Top Hits" — a stable public playlist.
        let pl = try awaitSync { try await client.playlist(id: "37i9dQZF1DXcBWIGoYBM5M") }
        try t.expect(!pl.tracks.isEmpty, "got live tracks")
    }

    t.test("Spotify's restrictions are explained rather than dumped as JSON") {
        // What the user saw was: Spotify: HTTP 403: {"error": {"status": 403, "message": "Forbidden"}}
        let raw = #"HTTP 403: {"error": {"status": 403, "message": "Forbidden" } }"#
        let user = SpotifyClient.explain(raw, path: "/v1/users/emilie.mlx/playlists")
        // Spotify *removed* this endpoint in February 2026, so the message must not suggest that
        // signing in would help — it wouldn't.
        try t.expect(user?.contains("removed") == true, "says the endpoint is gone")
        try t.expect(user?.contains("individual playlist") == true, "and points at what does work")

        let tracks = SpotifyClient.explain(raw, path: "/v1/playlists/abc/items")
        try t.expect(tracks?.contains("sign-in") == true, "the playlist case says a sign-in is needed")

        let editorial = SpotifyClient.explain("HTTP 404: {}", path: "/v1/playlists/37i9dQZF1DXcBWIGoYBM5M")
        try t.expect(editorial?.contains("editorial") == true, "404 on a playlist means an Apple/Spotify-made one")

        // A 401 from the new /items endpoint means "sign in", not "your credentials are wrong".
        try t.expect(SpotifyClient.explain("HTTP 401: {}", path: "/v1/playlists/x/items")?
                        .contains("signed-in") == true,
                     "401 on a playlist means a user token is needed")
        try t.expect(SpotifyClient.explain("HTTP 401: {}", path: "/v1/search")?.contains("Settings") == true,
                     "401 elsewhere still points at the credentials, which the user *can* fix")
        // Anything unrecognised must fall through, not be papered over with a wrong explanation.
        try t.expect(SpotifyClient.explain("HTTP 500: boom", path: "/v1/playlists/x") == nil,
                     "a server error is left alone")
        try t.expect(SpotifyClient.explain("HTTP 404: {}", path: "/v1/albums/x") == nil,
                     "404 elsewhere isn't the editorial case")
    }
}
func registerSpotifyBookmarkTests() {
    t.test("saving a user keeps the list newest-first and free of duplicates") {
        var list = SpotifyBookmarks.add("emilie.mlx", to: [])
        list = SpotifyBookmarks.add("glennpmcdonald", to: list)
        try t.expectEqual(list, ["glennpmcdonald", "emilie.mlx"], "most recently saved first")

        // Saving someone already there moves them up rather than listing them twice.
        list = SpotifyBookmarks.add("emilie.mlx", to: list)
        try t.expectEqual(list, ["emilie.mlx", "glennpmcdonald"], "no duplicate, moved to the top")

        // Spotify ids are case-insensitive, so these are the same person.
        list = SpotifyBookmarks.add("EMILIE.MLX", to: list)
        try t.expectEqual(list.count, 2, "still two people")
        try t.expectEqual(list.first, "EMILIE.MLX", "and the spelling just pasted is the one kept")
    }

    t.test("blank input is ignored and whitespace is trimmed") {
        try t.expectEqual(SpotifyBookmarks.add("   ", to: ["a"]), ["a"], "nothing to save")
        try t.expectEqual(SpotifyBookmarks.add("  bob\n", to: []), ["bob"], "trimmed")
    }

    t.test("removing and testing membership ignore case") {
        let list = ["Emilie.MLX", "bob"]
        try t.expectEqual(SpotifyBookmarks.remove("emilie.mlx", from: list), ["bob"], "removed")
        try t.expect(SpotifyBookmarks.contains("BOB", in: list), "found whatever the case")
        try t.expect(!SpotifyBookmarks.contains("carol", in: list), "and not someone unsaved")
    }

    t.test("the list is capped so it can't grow without limit") {
        var list: [String] = []
        for i in 0..<(SpotifyBookmarks.maximum + 10) { list = SpotifyBookmarks.add("user\(i)", to: list) }
        try t.expectEqual(list.count, SpotifyBookmarks.maximum, "capped")
        try t.expectEqual(list.first, "user\(SpotifyBookmarks.maximum + 9)", "keeping the newest")
    }

    t.test("a pasted profile link resolves to the id that gets saved") {
        // What the user actually pastes.
        guard case .user(let id)? = try? SpotifyClient.parse("https://open.spotify.com/user/emilie.mlx") else {
            throw TestFailure(message: "profile URL didn't parse to a user")
        }
        try t.expectEqual(id, "emilie.mlx", "the id, not the whole URL")
        try t.expectEqual(SpotifyBookmarks.add(id, to: []), ["emilie.mlx"], "that is what is stored")
    }

    t.test("a playlist's track count is read from `items`, not the deprecated `tracks`") {
        // February 2026 renamed this collection on the playlist object and stopped populating the
        // old name — which made every playlist in the list show "0 tracks".
        let json = """
        {"items":[
          {"id":"p1","name":"New shape","owner":{"display_name":"emilie"},
           "items":{"href":"https://api.spotify.com/v1/playlists/p1/items","total":42}},
          {"id":"p2","name":"Old shape","owner":{"display_name":"emilie"},
           "tracks":{"href":"https://api.spotify.com/v1/playlists/p2/tracks","total":7}},
          {"id":"p3","name":"Neither","owner":{"display_name":"emilie"}}
        ],"next":null}
        """
        let (items, next) = try SpotifyJSON.playlistList(Data(json.utf8))
        try t.expectEqual(items.count, 3, "all three parsed")
        try t.expectEqual(items[0].trackCount, 42, "reads the current `items.total`")
        try t.expectEqual(items[1].trackCount, 7, "still reads the deprecated `tracks.total`")
        try t.expectEqual(items[2].trackCount, 0, "and copes when there is neither")
        try t.expect(next == nil, "no further page")
    }

    t.test("playlist metadata takes its total and first page from `items` too") {
        let json = """
        {"name":"Mix","owner":{"display_name":"emilie"},
         "items":{"total":2,"next":"https://api.spotify.com/v1/playlists/x/items?offset=100",
           "items":[{"track":{"name":"One","duration_ms":1000,"artists":[{"name":"A"}],"album":{"name":"Al"}}}]}}
        """
        let meta = try SpotifyJSON.playlistMeta(Data(json.utf8))
        try t.expectEqual(meta.name, "Mix", "name")
        try t.expectEqual(meta.total, 2, "total from items")
        try t.expectEqual(meta.firstPage.count, 1, "the inline first page is used")
        try t.expectEqual(meta.firstPage.first?.title, "One", "and parsed")
        try t.expect(meta.next?.hasSuffix("offset=100") == true, "pagination continues")
    }

    t.test("a playlist entry's track is read from `item`, not the deprecated `track`") {
        // The rename went all the way down: /playlists/{id}/items entries hold the track under
        // `item` now. Reading only `track` skipped every entry and the playlist opened empty.
        let json = """
        {"items":[
          {"added_at":"2024-01-01T00:00:00Z",
           "item":{"name":"New shape","duration_ms":210000,
                   "artists":[{"name":"Air"}],"album":{"name":"Moon Safari"},
                   "external_ids":{"isrc":"FR1234500001"}}},
          {"added_at":"2024-01-02T00:00:00Z",
           "track":{"name":"Old shape","duration_ms":120000,
                    "artists":[{"name":"Nujabes"}],"album":{"name":"Modal Soul"}}},
          {"added_at":"2024-01-03T00:00:00Z","item":{"description":"a podcast episode"}}
        ],"next":null}
        """
        let (tracks, next) = try SpotifyJSON.trackPage(Data(json.utf8))
        try t.expectEqual(tracks.count, 2, "both real tracks, and nothing for the episode")
        try t.expectEqual(tracks[0].title, "New shape", "from `item`")
        try t.expectEqual(tracks[0].artist, "Air", "artist")
        try t.expectEqual(tracks[0].album, "Moon Safari", "album")
        try t.expectEqual(tracks[0].durationSec, 210, "milliseconds become seconds")
        try t.expectEqual(tracks[0].isrc, "FR1234500001", "ISRC survives for exact matching later")
        try t.expectEqual(tracks[1].title, "Old shape", "the deprecated `track` still works")
        try t.expect(next == nil, "last page")
    }

    t.test("opening a playlist fetches its items and doesn't ask twice") {
        // The whole path that showed "0 tracks": metadata no longer carries the track list, so the
        // contents have to come from a second call to /items.
        let token = #"{"access_token":"T","expires_in":3600}"#
        let meta = """
        {"id":"p1","name":"Jude ^^","owner":{"display_name":"emilie"},
         "items":{"href":"https://api.spotify.com/v1/playlists/p1/items","total":2}}
        """
        let page = """
        {"items":[
          {"item":{"name":"One","duration_ms":1000,"artists":[{"name":"A"}],"album":{"name":"Al"}}},
          {"item":{"name":"Two","duration_ms":2000,"artists":[{"name":"B"}],"album":{"name":"Bl"}}}
        ],"next":null}
        """
        let http = TestSupport.ScriptedHTTPClient([token, meta, page])
        let client = SpotifyClient(clientID: "id", clientSecret: "secret", http: http)
        let pl = try await client.playlist(id: "p1")

        try t.expectEqual(pl.name, "Jude ^^", "name from metadata")
        try t.expectEqual(pl.trackCount, 2, "count from items.total")
        try t.expectEqual(pl.tracks.map(\.title), ["One", "Two"], "tracks from the items call")
        let urls = http.urls().filter { $0.contains("/playlists/") }
        try t.expectEqual(urls.count, 2, "metadata then items — nothing fetched twice (\(urls))")
        try t.expect(urls.last?.contains("/items") == true, "the second call is the items endpoint")
    }
}