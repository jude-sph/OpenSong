import Foundation
import OpenSongCore

func registerM3U8ParserTests() {
    t.test("parses device golden playlist into 9 entries") {
        let data = try Data(contentsOf: fixtureURL("device-brazil.m3u8"))
        let entries = M3U8Parser.parse(data)
        try t.expectEqual(entries.count, 9, "entry count")
        let first = entries[0]
        try t.expectEqual(first.artist, "Sérgio Mendes", "artist")
        try t.expectEqual(first.album, "Unknown Album", "album")
        try t.expectEqual(first.titleFromPath, "Triste", "title from path")
        try t.expectEqual(first.durationSec, 127, "duration")
        try t.expectEqual(first.title, "Triste", "extinf title")
        try t.expectEqual(first.relativePath, "Sérgio Mendes\\Unknown Album\\Triste.mp3", "relative path")
    }
    t.test("parse then re-write round-trips to the same bytes") {
        let golden = try Data(contentsOf: fixtureURL("device-brazil.m3u8"))
        let entries = M3U8Parser.parse(golden)
        let rebuilt = M3U8Writer.data(entries: entries.map { e in
            (TrackIdentity(title: e.title ?? e.titleFromPath, artist: e.artist,
                           albumArtist: e.artist, album: e.album,
                           durationSec: Double(e.durationSec ?? 0)), e.durationSec ?? 0)
        })
        try t.expect(rebuilt == golden, "round-trip mismatch: \(rebuilt.count) vs \(golden.count)")
    }
    t.test("round-trips a REAL device playlist byte-for-byte (Aphex Twin.m3u8)") {
        // Captured directly from the physical NW-E394 on 2026-07-22.
        let golden = try Data(contentsOf: fixtureURL("device-aphex-real.m3u8"))
        let entries = M3U8Parser.parse(golden)
        try t.expect(entries.count > 20, "parsed \(entries.count) entries")
        let rebuilt = M3U8Writer.data(entries: entries.map { e in
            (TrackIdentity(title: e.title ?? e.titleFromPath, artist: e.artist,
                           albumArtist: e.artist, album: e.album,
                           durationSec: Double(e.durationSec ?? 0)), e.durationSec ?? 0)
        })
        try t.expect(rebuilt == golden, "real-device round-trip mismatch: \(rebuilt.count) vs \(golden.count)")
    }
    t.test("handles LF-only and missing EXTINF") {
        let text = "#EXTM3U\nArtist\\Album\\Song.mp3\n"
        let entries = M3U8Parser.parse(Data(text.utf8))
        try t.expectEqual(entries.count, 1, "one entry")
        try t.expectEqual(entries[0].titleFromPath, "Song", "title")
        try t.expect(entries[0].durationSec == nil, "no duration")
    }
}
