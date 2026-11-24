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
    t.test("groups library tracks into albums (feat. artists don't split; album artist wins)") {
        let tracks = [
            AppleMusicTrack(name: "Nikes", artist: "Frank Ocean", album: "Blonde", albumArtist: "Frank Ocean", durationSec: 314),
            AppleMusicTrack(name: "Pink + White (feat. Beyoncé)", artist: "Frank Ocean feat. Beyoncé", album: "Blonde", albumArtist: "Frank Ocean", durationSec: 184),
            // Same album name, different artist → distinct album.
            AppleMusicTrack(name: "Something", artist: "Some Band", album: "Blonde", albumArtist: "Some Band", durationSec: 200),
            // No album artist → falls back to track artist for grouping.
            AppleMusicTrack(name: "Redbone", artist: "Childish Gambino", album: "Awaken, My Love!", durationSec: 327),
            // Blank album is dropped.
            AppleMusicTrack(name: "Voice Memo", artist: "Me", album: "  ", durationSec: 12),
        ]
        let albums = AppleMusicAlbums.group(tracks)
        try t.expectEqual(albums.count, 3, "Blonde×2 (different artists) + Awaken; blank dropped")
        try t.expect(albums.allSatisfy { $0.kind == .album }, "all albums")
        let blondeFO = albums.first { $0.name == "Blonde" && $0.albumArtist == "Frank Ocean" }
        try t.expect(blondeFO != nil, "Frank Ocean's Blonde exists")
        try t.expectEqual(blondeFO?.tracks.count, 2, "Nikes + Pink+White grouped despite feat.")
        let blondeSB = albums.first { $0.name == "Blonde" && $0.albumArtist == "Some Band" }
        try t.expect(blondeSB != nil, "Some Band's Blonde is a separate album")
        try t.expect(blondeFO?.id != blondeSB?.id, "same-named albums have distinct ids")
        let awaken = albums.first { $0.name == "Awaken, My Love!" }
        try t.expectEqual(awaken?.albumArtist, "Childish Gambino", "album artist falls back to track artist")
    }
    t.test("parses track/disc numbers (0 → nil) and carries them into identity + wish") {
        let json = """
        {"collections":[{"name":"a","kind":"album","tracks":[
          {"name":"One","artist":"X","album":"A","track":3,"disc":2,"duration":100},
          {"name":"Two","artist":"X","album":"A","track":0,"duration":100}
        ]}]}
        """.data(using: .utf8)!
        let cols = AppleMusicParser.parse(json)
        let t0 = cols[0].tracks[0], t1 = cols[0].tracks[1]
        try t.expectEqual(t0.trackNumber, 3, "track parsed")
        try t.expectEqual(t0.discNumber, 2, "disc parsed")
        try t.expect(t1.trackNumber == nil, "0 track → nil")
        try t.expectEqual(t0.identity.trackNumber, 3, "identity carries track")
        try t.expectEqual(t0.wishItem.trackNumber, 3, "wish carries track")
        try t.expectEqual(t0.wishItem.identity.trackNumber, 3, "wish→identity carries track")
    }
    t.test("LIVE: reads real Apple Music playlists") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 (Music.app + Automation permission) to run")
        }
        let bridge = AppleMusicBridge()
        let cols = try bridge.playlists(limit: 3, tracksPerPlaylist: 5)
        try t.expect(cols.count >= 0, "call succeeded (\(cols.count) playlists)")
    }

    t.test("date added is parsed per track and rolls up to the album") {
        let json = """
        {"collections":[{"name":"Library","kind":"album","tracks":[
          {"name":"A","artist":"X","album":"Rec","duration":100,"added":1700000000},
          {"name":"B","artist":"X","album":"Rec","duration":100,"added":1700086400},
          {"name":"C","artist":"X","album":"Rec","duration":100}
        ]}]}
        """
        let cols = AppleMusicParser.parse(Data(json.utf8))
        try t.expectEqual(cols.count, 1, "one collection")
        let tracks = cols[0].tracks
        try t.expectEqual(tracks[0].addedAt, 1700000000, "epoch seconds come through")
        try t.expect(tracks[2].addedAt == nil, "a track with no date stays undated, not zero")
        // An album added over two sessions should sort by when it was finished.
        try t.expectEqual(cols[0].addedAt, 1700086400, "the album takes its most recent track")
    }

    t.test("an album with no dated tracks has no date at all") {
        let json = """
        {"collections":[{"name":"Old","kind":"album","tracks":[
          {"name":"A","artist":"X","album":"Old","duration":100},
          {"name":"B","artist":"X","album":"Old","duration":100,"added":0}
        ]}]}
        """
        let cols = AppleMusicParser.parse(Data(json.utf8))
        // Music really does report 0 for some tracks; treating that as 1970 would file the album
        // at the very bottom of a date sort as though it were genuinely the oldest thing there.
        try t.expect(cols[0].addedAt == nil, "no date rather than the epoch")
    }

    t.test("grouping keeps each track's date so albums can be sorted by it") {
        let tracks = [
            AppleMusicTrack(name: "1", artist: "A", album: "First", durationSec: 10, addedAt: 100),
            AppleMusicTrack(name: "2", artist: "B", album: "Second", durationSec: 10, addedAt: 300),
            AppleMusicTrack(name: "3", artist: "B", album: "Second", durationSec: 10, addedAt: 200),
        ]
        let albums = AppleMusicAlbums.group(tracks)
        try t.expectEqual(albums.count, 2, "two albums")
        let second = albums.first { $0.name == "Second" }
        try t.expectEqual(second?.addedAt, 300, "the newer of its two tracks")
        try t.expectEqual(albums.first { $0.name == "First" }?.addedAt, 100, "and the other's own")
    }
}
func registerAppleMusicExportTests() {
    typealias Item = AppleMusicExport.Item
    t.test("export plan skips songs Music already has (same file or fuzzy match)") {
        let existing = [
            AppleMusicTrack(name: "Ivy", artist: "Frank Ocean", album: "Blonde", durationSec: 249),
            AppleMusicTrack(name: "Other", artist: "X", album: "", durationSec: 100,
                            location: "/Users/me/OpenSong Library/x/song.mp3"),
            // Same title/artist but a different album AND length — a different recording.
            AppleMusicTrack(name: "Solo", artist: "Frank Ocean", album: "Live", durationSec: 400),
        ]
        let items = [
            Item(path: "/a/ivy.m4a", title: "Ivy (2016 Remaster)", artist: "frank ocean", album: "Blonde", durationSec: 250),
            Item(path: "/Users/me/OpenSong Library/x/song.mp3", title: "Renamed", artist: "Y", album: "", durationSec: 1),
            Item(path: "/a/solo.m4a", title: "Solo", artist: "Frank Ocean", album: "Blonde", durationSec: 257),
            Item(path: "/a/new.mp3", title: "New", artist: "Z", album: "", durationSec: 200),
            Item(path: "/a/new.mp3", title: "New", artist: "Z", album: "", durationSec: 200),   // dup selection
        ]
        let (toAdd, already) = AppleMusicExport.plan(items, existing: existing)
        try t.expectEqual(already.map(\.path), ["/a/ivy.m4a", "/Users/me/OpenSong Library/x/song.mp3"], "already in Music")
        try t.expectEqual(toAdd.map(\.path), ["/a/solo.m4a", "/a/new.mp3"], "to add, deduped")
        let viaKnown = AppleMusicExport.plan([items[3]], existing: [], knownPaths: ["/a/./new.mp3"])
        try t.expectEqual(viaKnown.alreadyIn.count, 1, "known file path counts as already in Music")
    }
    t.test("export converts only formats Music can't add; lossless stays lossless") {
        try t.expect(AppleMusicExport.isNative("/a/b.MP3"), "mp3 native")
        try t.expect(AppleMusicExport.isNative("/a/b.m4a"), "m4a native")
        try t.expect(!AppleMusicExport.isNative("/a/b.flac"), "flac needs convert")
        try t.expect(!AppleMusicExport.isNative("/a/b.opus"), "opus needs convert")
        try t.expect(AppleMusicExport.convertArgs(src: "/a/b.flac", dst: "/o.m4a").contains("alac"), "flac → alac")
        try t.expect(AppleMusicExport.convertArgs(src: "/a/b.opus", dst: "/o.m4a").contains("256k"), "opus → aac 256k")
    }
}

func registerCloudLibraryUpdateTests() {
    t.test("cloud library update: script output maps to outcomes") {
        try t.expectEqual(CloudLibraryUpdate.parse(status: 0, stdout: "clicked\n", stderr: ""), .triggered, "clicked")
        try t.expectEqual(CloudLibraryUpdate.parse(status: 0, stdout: "disabled", stderr: ""), .unavailable, "disabled")
        try t.expectEqual(CloudLibraryUpdate.parse(status: 0, stdout: "missing", stderr: ""), .unavailable, "missing")
        try t.expectEqual(CloudLibraryUpdate.parse(status: 1, stdout: "",
            stderr: "System Events got an error: osascript is not allowed assistive access. (-25211)"),
            .needsAccessibility, "no AX permission")
        try t.expectEqual(CloudLibraryUpdate.parse(status: 1, stdout: "", stderr: "boom"), .failed("boom"), "other error")
    }
}
