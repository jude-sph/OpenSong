import Foundation
import OpenSongCore

private let cannedAM = """
{"collections":[
  {"name":"chill","kind":"playlist","tracks":[
    {"name":"Ivy","artist":"Frank Ocean","album":"Blonde","duration":249,"location":"/Users/me/Music/Ivy.m4a","cloud":false},
    {"name":"Nikes (feat. Someone)","artist":"Frank Ocean","album":"Blonde","duration":314,"location":null,"cloud":true},
    {"name":"White Ferrari","artist":"Frank Ocean","album":"Blonde","duration":248,"location":null,"cloud":true}
  ]}
]}
""".data(using: .utf8)!

func registerAppleMusicTests() {
    t.test("parses Apple Music JSON incl. cloud + local location") {
        let cols = AppleMusicParser.parse(cannedAM)
        try t.expectEqual(cols.count, 1, "one collection")
        try t.expectEqual(cols[0].kind, .playlist, "kind")
        try t.expectEqual(cols[0].tracks.count, 3, "three tracks")
        let ivy = cols[0].tracks[0]
        try t.expectEqual(ivy.location, "/Users/me/Music/Ivy.m4a", "local path")
        try t.expect(ivy.isImportableLocal, "ivy is local importable")
        try t.expect(cols[0].tracks[1].isCloud, "nikes is cloud")
        try t.expect(!cols[0].tracks[1].isImportableLocal, "cloud not importable")
    }
    t.test("normalize strips feat/remaster/punctuation/case") {
        try t.expectEqual(AppleMusicCompare.normalize("Nikes (feat. Someone)"), "nikes", "feat stripped")
        try t.expectEqual(AppleMusicCompare.normalize("Ivy (2016 Remaster)"), "ivy", "remaster stripped")
        try t.expectEqual(AppleMusicCompare.normalize("Águà de Beber!"), "águà de beber", "punct stripped, accents kept")
    }
    t.test("ownership: owned vs missing with fuzzy matching") {
        let cols = AppleMusicParser.parse(cannedAM)
        let library = [
            AppleMusicCompare.LibraryTrack(title: "Ivy", artist: "Frank Ocean", album: "Blonde", durationSec: 249),
            // Nikes present but titled slightly differently + no album match, duration matches:
            AppleMusicCompare.LibraryTrack(title: "Nikes", artist: "Frank Ocean", album: "", durationSec: 314),
        ]
        let (owned, missing) = AppleMusicCompare.ownership(of: cols[0].tracks, in: library)
        try t.expectEqual(owned, 2, "Ivy + Nikes owned (fuzzy)")
        try t.expectEqual(missing.count, 1, "White Ferrari missing")
        try t.expectEqual(missing.first?.name, "White Ferrari", "the missing one")
    }
    t.test("missing track converts to an Apple Music wish item") {
        let track = AppleMusicTrack(name: "White Ferrari", artist: "Frank Ocean", album: "Blonde", durationSec: 248, isCloud: true)
        try t.expectEqual(track.wishItem.source, .appleMusic, "source")
        try t.expectEqual(track.identity.provenance, .appleMusic, "authoritative identity")
    }
    t.test("LIVE: reads real Apple Music playlists") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 (Music.app + Automation permission) to run")
        }
        let bridge = AppleMusicBridge()
        let cols = try bridge.playlists(limit: 3, tracksPerPlaylist: 5)
        try t.expect(cols.count >= 0, "call succeeded (\(cols.count) playlists)")
    }
}
