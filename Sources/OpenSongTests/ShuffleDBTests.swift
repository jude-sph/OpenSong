import Foundation
import OpenSongCore

private func u32(_ d: Data, _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(d[d.startIndex + off + i]) << (8 * i) }
    return v
}
private func u16(_ d: Data, _ off: Int) -> UInt16 {
    UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
}
private func tag(_ d: Data, _ off: Int) -> String {
    String(decoding: d[(d.startIndex + off)..<(d.startIndex + off + 4)], as: UTF8.self)
}

func registerShuffleDBTests() {
    t.test("dbid is MD5[:8]; voiceover filename is reversed-hex + .wav") {
        // MD5("Nights") = fe3b... verify against known digest.
        let id = ShuffleDB.dbid("Nights")
        try t.expectEqual(id.count, 8, "8 bytes")
        // Independently: first 8 bytes of MD5("Nights")
        let name = ShuffleDB.voiceoverFilename(id)
        try t.expect(name.hasSuffix(".wav"), "wav suffix")
        try t.expectEqual(name.count, 16 + 4, "16 hex chars + .wav")
        // reversed-hex relationship: last hex byte of filename == first dbid byte
        let firstByteHex = String(format: "%02x", id[0])
        try t.expect(name.hasPrefix(String(format: "%02x", id[7])), "filename starts with last dbid byte")
        try t.expect(name.dropLast(4).hasSuffix(firstByteHex), "filename ends (pre-.wav) with first dbid byte")
    }

    t.test("builds a byte-exact iTunesSD with master + one user playlist") {
        let tracks = [
            ShuffleTrack(devicePath: "/iPod_Control/Music/0001.mp3", filetype: 1, voiceover: "Nights - Frank Ocean"),
            ShuffleTrack(devicePath: "/iPod_Control/Music/0002.m4a", filetype: 2, voiceover: "Xtal - Aphex Twin"),
            ShuffleTrack(devicePath: "/iPod_Control/Music/0003.mp3", filetype: 1, voiceover: "Redbone - Childish Gambino"),
        ]
        let playlists = [ShufflePlaylist(name: "roadtrip", trackIndices: [0, 2])]
        let d = ShuffleDB.build(tracks: tracks, playlists: playlists, voiceover: true)

        // Section sizes
        let bdhs = 64, hthsFixed = 20, rths = 372, hphsFixed = 20, lphsFixed = 44
        let hthsLen = hthsFixed + 3 * 4
        let tracksStart = bdhs + hthsLen
        let hphsOffset = tracksStart + 3 * rths
        let playlistCount = 2                      // master + 1 user
        let hphsLen = hphsFixed + playlistCount * 4
        let playlistsStart = hphsOffset + hphsLen
        let masterLphs = lphsFixed + 3 * 4         // master has all 3
        let userLphs = lphsFixed + 2 * 4           // user has 2
        let expectedTotal = playlistsStart + masterLphs + userLphs
        try t.expectEqual(d.count, expectedTotal, "total file size")

        // bdhs header
        try t.expectEqual(tag(d, 0), "bdhs", "root magic")
        try t.expectEqual(u32(d, 4), 0x02000003, "version")
        try t.expectEqual(u32(d, 8), 64, "header length")
        try t.expectEqual(u32(d, 12), 3, "track count")
        try t.expectEqual(u32(d, 16), 2, "playlist count (incl master)")
        try t.expectEqual(d[d.startIndex + 29], 1, "voiceover flag")
        try t.expectEqual(u32(d, 32), 3, "tracks2")
        try t.expectEqual(u32(d, 36), 64, "track header offset")
        try t.expectEqual(u32(d, 40), UInt32(hphsOffset), "playlist header offset")

        // hths
        try t.expectEqual(tag(d, bdhs), "hths", "tracks header magic")
        try t.expectEqual(u32(d, bdhs + 4), UInt32(hthsLen), "hths length")
        try t.expectEqual(u32(d, bdhs + 8), 3, "hths track count")
        // Each track offset points at an rths magic
        for i in 0..<3 {
            let off = Int(u32(d, bdhs + 20 + i * 4))
            try t.expectEqual(off, tracksStart + i * rths, "track \(i) offset value")
            try t.expectEqual(tag(d, off), "rths", "track \(i) points to rths")
        }

        // rths track 1 (index 1): filetype 2, filename, dontskip, dbid
        let r1 = tracksStart + 1 * rths
        try t.expectEqual(u32(d, r1 + 4), 0x174, "rths length 372")
        try t.expectEqual(u32(d, r1 + 20), 2, "filetype m4a")
        let fnameBytes = d[(d.startIndex + r1 + 24)..<(d.startIndex + r1 + 24 + 256)]
        let fname = String(decoding: fnameBytes.prefix { $0 != 0 }, as: UTF8.self)
        try t.expectEqual(fname, "/iPod_Control/Music/0002.m4a", "filename round-trips")
        try t.expectEqual(d[d.startIndex + r1 + 284], 1, "dont_skip_on_shuffle")
        let dbidBytes = Array(d[(d.startIndex + r1 + 328)..<(d.startIndex + r1 + 328 + 8)])
        try t.expectEqual(dbidBytes, ShuffleDB.dbid("Xtal - Aphex Twin"), "dbid = md5[:8] of voiceover text")

        // hphs
        try t.expectEqual(tag(d, hphsOffset), "hphs", "playlist header magic")
        try t.expectEqual(u32(d, hphsOffset + 8), 2, "playlist count")
        try t.expectEqual(u16(d, hphsOffset + 12), 0xFFFF, "non-podcast = ffff")
        try t.expectEqual(u16(d, hphsOffset + 14), 1, "master count = 1")
        try t.expectEqual(u16(d, hphsOffset + 16), 0xFFFF, "non-audiobook = ffff")
        // Playlist offsets → lphs
        let p0 = Int(u32(d, hphsOffset + 20))
        let p1 = Int(u32(d, hphsOffset + 24))
        try t.expectEqual(p0, playlistsStart, "master offset")
        try t.expectEqual(p1, playlistsStart + masterLphs, "user offset")
        try t.expectEqual(tag(d, p0), "lphs", "master magic")
        try t.expectEqual(tag(d, p1), "lphs", "user magic")

        // Master lphs: type 1, dbid zero, all-songs indices 0,1,2
        try t.expectEqual(u32(d, p0 + 8), 3, "master song count")
        try t.expectEqual(u32(d, p0 + 24), 1, "master type = 1")
        try t.expectEqual(Array(d[(d.startIndex + p0 + 16)..<(d.startIndex + p0 + 24)]),
                          [0,0,0,0,0,0,0,0], "master dbid all-zero")
        try t.expectEqual(u32(d, p0 + 44 + 0), 0, "master idx0")
        try t.expectEqual(u32(d, p0 + 44 + 8), 2, "master idx2")

        // User lphs: type 2, dbid md5(name), indices 0,2
        try t.expectEqual(u32(d, p1 + 8), 2, "user song count")
        try t.expectEqual(u32(d, p1 + 24), 2, "user type = 2")
        try t.expectEqual(Array(d[(d.startIndex + p1 + 16)..<(d.startIndex + p1 + 24)]),
                          ShuffleDB.dbid("roadtrip"), "user dbid = md5(name)")
        try t.expectEqual(u32(d, p1 + 44 + 0), 0, "user idx0 = 0")
        try t.expectEqual(u32(d, p1 + 44 + 4), 2, "user idx1 = 2")
    }

    t.test("empty library still yields a valid master playlist") {
        let d = ShuffleDB.build(tracks: [], playlists: [], voiceover: false)
        try t.expectEqual(tag(d, 0), "bdhs", "magic")
        try t.expectEqual(u32(d, 12), 0, "0 tracks")
        try t.expectEqual(u32(d, 16), 1, "1 playlist (master)")
        try t.expectEqual(d[d.startIndex + 29], 0, "voiceover off")
        let hphsOffset = Int(u32(d, 40))
        try t.expectEqual(tag(d, hphsOffset), "hphs", "hphs present")
        let p0 = Int(u32(d, hphsOffset + 20))
        try t.expectEqual(tag(d, p0), "lphs", "master present")
        try t.expectEqual(u32(d, p0 + 8), 0, "master empty")
    }
}
