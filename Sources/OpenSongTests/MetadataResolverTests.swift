import Foundation
import OpenSongCore

/// Stub HTTP client returning canned bytes (offline unit tests).
private struct StubHTTP: HTTPClient {
    let data: Data
    func get(_ url: URL) async throws -> Data { data }
}

private let cannedITunes = """
{
  "resultCount": 2,
  "results": [
    {
      "trackName": "Vordhosbn", "artistName": "Aphex Twin", "collectionName": "Drukqs",
      "trackNumber": 2, "discNumber": 1, "primaryGenreName": "Electronic",
      "releaseDate": "2001-10-22T07:00:00Z", "trackTimeMillis": 291000,
      "artworkUrl100": "https://example.com/a/100x100bb.jpg"
    },
    {
      "trackName": "Vordhosbn (Live)", "artistName": "Aphex Twin", "collectionName": "Live",
      "trackNumber": 5, "trackTimeMillis": 400000,
      "artworkUrl100": "https://example.com/b/100x100bb.jpg"
    }
  ]
}
""".data(using: .utf8)!

func registerMetadataResolverTests() {
    t.test("decodes iTunes fields incl. year and hi-res art") {
        let resolver = MetadataResolver(http: StubHTTP(data: cannedITunes))
        let matches = try await resolver.search(term: "aphex vordhosbn")
        try t.expectEqual(matches.count, 2, "two results")
        let m = matches[0]
        try t.expectEqual(m.title, "Vordhosbn", "title")
        try t.expectEqual(m.album, "Drukqs", "album")
        try t.expectEqual(m.trackNumber, 2, "track number")
        try t.expectEqual(m.discNumber, 1, "disc number")
        try t.expectEqual(m.year, 2001, "year from releaseDate")
        try t.expectEqual(m.genre, "Electronic", "genre")
        try t.expect(abs(m.durationSec - 291) < 0.01, "duration seconds")
        try t.expectEqual(m.artworkURL?.absoluteString, "https://example.com/a/600x600bb.jpg", "hi-res art")
    }
    t.test("bestMatch picks closest duration") {
        let resolver = MetadataResolver(http: StubHTTP(data: cannedITunes))
        let best = try await resolver.bestMatch(term: "aphex vordhosbn", durationSec: 291)
        try t.expectEqual(best?.album, "Drukqs", "studio (291s) beats live (400s)")
    }
    t.test("LIVE: resolves Aphex Twin against real iTunes API") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 to run live-network tests")
        }
        let resolver = MetadataResolver()
        let best = try await resolver.bestMatch(term: "Aphex Twin Vordhosbn", durationSec: 291)
        try t.expect(best != nil, "got a live match")
        try t.expect(best!.album.lowercased().contains("drukqs"), "album ~ Drukqs (got \(best!.album))")
    }
}
