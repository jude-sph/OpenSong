import Foundation
import OpenSongCore

private let cannedITunes = """
{"resultCount":2,"results":[
  {"collectionName":"Blonde","artistName":"Frank Ocean","artworkUrl100":"https://is1.mzstatic.com/image/thumb/abc/100x100bb.jpg"},
  {"collectionName":"Channel Orange","artistName":"Frank Ocean","artworkUrl100":"https://is1.mzstatic.com/image/thumb/def/100x100bb.jpg"},
  {"collectionName":"No Art Here","artistName":"Nobody"}
]}
""".data(using: .utf8)!

/// Serves a fixed body regardless of URL (for the search happy-path test).
private struct StubHTTP: HTTPClient {
    let body: Data
    func get(_ url: URL) async throws -> Data { body }
}

/// Mimics iTunes' real behaviour for a self-titled album: the plain search returns the artist's
/// popular records and never the album asked for, while the artist's discography lookup has it.
private actor RouteStub: HTTPClient {
    private(set) var requested: [String] = []
    func get(_ url: URL) async throws -> Data {
        requested.append(url.absoluteString)
        let s = url.absoluteString
        if s.contains("entity=musicArtist") {
            return Data("""
            {"results":[{"wrapperType":"artist","artistId":567072,"artistName":"Gorillaz"}]}
            """.utf8)
        }
        if s.contains("/lookup") {
            return Data("""
            {"results":[
              {"wrapperType":"artist","artistId":567072,"artistName":"Gorillaz"},
              {"collectionName":"Gorillaz","artistName":"Gorillaz","releaseDate":"2001-03-26T07:00:00Z",
               "artworkUrl100":"https://is1.mzstatic.com/image/thumb/self/100x100bb.jpg"},
              {"collectionName":"Gorillaz - Single","artistName":"Tenampa Brass Band","releaseDate":"2024-01-01T07:00:00Z",
               "artworkUrl100":"https://is1.mzstatic.com/image/thumb/other/100x100bb.jpg"},
              {"collectionName":"Gorillaz (Gorillaz 20 Mix) - Single","artistName":"Gorillaz","releaseDate":"2021-01-01T07:00:00Z",
               "artworkUrl100":"https://is1.mzstatic.com/image/thumb/mix/100x100bb.jpg"}
            ]}
            """.utf8)
        }
        return Data("""
        {"results":[
          {"collectionName":"Demon Days","artistName":"Gorillaz","releaseDate":"2005-05-11T07:00:00Z",
           "artworkUrl100":"https://is1.mzstatic.com/image/thumb/demon/100x100bb.jpg"},
          {"collectionName":"Plastic Beach","artistName":"Gorillaz","releaseDate":"2010-03-03T08:00:00Z",
           "artworkUrl100":"https://is1.mzstatic.com/image/thumb/plastic/100x100bb.jpg"}
        ]}
        """.utf8)
    }
}

func registerArtworkFinderTests() {
    t.test("upscales iTunes 100x100 artwork URL to a larger square") {
        let up = ArtworkFinder.upscale("https://is1.mzstatic.com/image/thumb/abc/100x100bb.jpg", to: 600)
        try t.expectEqual(up?.absoluteString, "https://is1.mzstatic.com/image/thumb/abc/600x600bb.jpg", "600px")
        // Non-100 default sizes also rewrite.
        let up2 = ArtworkFinder.upscale("https://x/thumb/y/64x64bb.png", to: 200)
        try t.expectEqual(up2?.absoluteString, "https://x/thumb/y/200x200bb.png", "handles other sizes + ext")
    }
    t.test("parses iTunes search results, skipping entries without artwork") {
        let cands = ArtworkFinder.parse(cannedITunes)
        try t.expectEqual(cands.count, 2, "two with artwork (No Art Here dropped)")
        try t.expectEqual(cands[0].collection, "Blonde", "album name")
        try t.expectEqual(cands[0].artist, "Frank Ocean", "artist")
        try t.expect(cands[0].thumbURL.absoluteString.contains("200x200bb"), "thumb upscaled to 200")
        try t.expect(cands[0].fullURL.absoluteString.contains("600x600bb"), "full upscaled to 600")
    }
    t.test("search builds a term and returns parsed candidates") {
        let finder = ArtworkFinder(http: StubHTTP(body: cannedITunes))
        let cands = try await finder.search(artist: "Frank Ocean", album: "Blonde")
        try t.expectEqual(cands.count, 2, "stubbed results parsed")
    }
    t.test("a self-titled album falls back to the artist's discography and ranks first") {
        let stub = RouteStub()
        let cands = try await ArtworkFinder(http: stub).search(artist: "Gorillaz", album: "Gorillaz")
        try t.expect(!cands.isEmpty, "got candidates")
        try t.expectEqual(cands[0].collection, "Gorillaz", "the album asked for wins")
        try t.expectEqual(cands[0].artist, "Gorillaz", "…by the right artist")
        try t.expectEqual(cands[0].year, 2001, "release year carried through")
        // The other act's single and the remix single must rank below the album itself.
        let titles = cands.map { "\($0.collection) — \($0.artist)" }
        try t.expect(titles.firstIndex(of: "Gorillaz — Gorillaz")! <
                     titles.firstIndex(of: "Gorillaz - Single — Tenampa Brass Band")!,
                     "album above another artist's single")
        try t.expect(cands.contains { $0.collection == "Demon Days" }, "term-search hits still offered")
        let urls = await stub.requested
        try t.expectEqual(urls.count, 3, "term search + artist id + discography (\(urls.count))")
    }
    t.test("a normal album needs only the plain search") {
        let stub = RouteStub()
        let cands = try await ArtworkFinder(http: stub).search(artist: "Gorillaz", album: "Demon Days")
        try t.expectEqual(cands.first?.collection, "Demon Days", "exact match first")
        try t.expectEqual(await stub.requested.count, 1, "no discography fallback needed")
    }
    t.test("decorated titles match, singles are demoted") {
        try t.expectEqual(ArtworkFinder.titleScore("Demon Days", "demon days"), 100, "exact")
        try t.expect(ArtworkFinder.titleScore("Demon Days (Deluxe Edition)", "demon days") > 50,
                     "deluxe edition still matches strongly")
        try t.expectEqual(ArtworkFinder.titleScore("Cracker Island", "demon days"), 0, "unrelated")
        try t.expect(ArtworkFinder.titleScore("Demon Days", "days") > 0, "partial match counts")
    }
    t.test("LIVE: iTunes finds a self-titled album") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 to hit the real iTunes Search API")
        }
        for (artist, album) in [("Gorillaz", "Gorillaz"), ("Weezer", "Weezer"), ("Gorillaz", "Demon Days")] {
            let hits = try await ArtworkFinder().search(artist: artist, album: album)
            let top = hits.prefix(3).map { "\($0.collection) [\($0.artist), \($0.year.map(String.init) ?? "?")]" }
            print("      \(artist) — \(album): \(top.joined(separator: " / "))")
            try t.expect(hits.contains { ArtworkFinder.titleScore($0.collection, ArtworkFinder.fold(album)) >= 90
                                         && ArtworkFinder.fold($0.artist).contains(ArtworkFinder.fold(artist)) },
                         "\(album) by \(artist) is offered")
        }
    }
    t.test("search with all-blank terms returns empty without a request") {
        let finder = ArtworkFinder(http: StubHTTP(body: Data()))
        let cands = try await finder.search(artist: "  ", album: "")
        try t.expectEqual(cands.count, 0, "no term → no candidates")
    }
}
