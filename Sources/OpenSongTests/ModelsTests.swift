import Foundation
import OpenSongCore

func registerModelsTests() {
    t.test("effectiveAlbumArtist prefers albumArtist, falls back") {
        let comp = TrackIdentity(title: "T", artist: "Various", albumArtist: "Various Artists",
                                 album: "Comp", durationSec: 100)
        try t.expectEqual(effectiveAlbumArtist(comp), "Various Artists", "prefers albumArtist")
        let noAA = TrackIdentity(title: "T", artist: "Solo", durationSec: 100)
        try t.expectEqual(effectiveAlbumArtist(noAA), "Solo", "falls back to artist")
        let empty = TrackIdentity(title: "T", artist: "", durationSec: 100)
        try t.expectEqual(effectiveAlbumArtist(empty), "Unknown Artist", "empty -> Unknown Artist")
    }
    t.test("effectiveAlbum falls back") {
        let none = TrackIdentity(title: "T", artist: "A", durationSec: 100)
        try t.expectEqual(effectiveAlbum(none), "Unknown Album", "nil -> Unknown Album")
        let has = TrackIdentity(title: "T", artist: "A", album: "Real", durationSec: 100)
        try t.expectEqual(effectiveAlbum(has), "Real", "keeps album")
    }
    t.test("TrackIdentity Codable round-trips") {
        let orig = TrackIdentity(id: 5, title: "Vordhosbn", artist: "Aphex Twin",
                                 albumArtist: "Aphex Twin", album: "Drukqs", trackNumber: 2,
                                 discNumber: 1, genre: "Electronic", year: 2001, durationSec: 291,
                                 provenance: .itunesResolved, artworkPath: "/tmp/a.jpg")
        let data = try JSONEncoder().encode(orig)
        let back = try JSONDecoder().decode(TrackIdentity.self, from: data)
        try t.expectEqual(back, orig, "round-trip")
    }
    t.test("AudioAsset Codable round-trips") {
        let a = AudioAsset(id: 1, identityID: 5, masterPath: "/lib/x.mp3", format: "mp3",
                           bitrateKbps: 320, sampleRate: 44100, sizeBytes: 1234,
                           contentHash: "abc", source: .importedLoose)
        let back = try JSONDecoder().decode(AudioAsset.self, from: try JSONEncoder().encode(a))
        try t.expectEqual(back, a, "round-trip")
    }
}
