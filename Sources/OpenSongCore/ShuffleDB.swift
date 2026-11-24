import Foundation
import CryptoKit

/// A track as it will appear on the iPod Shuffle: an on-device absolute path (e.g.
/// "/iPod_Control/Music/0001.mp3"), the codec, and the text VoiceOver should speak.
public struct ShuffleTrack: Sendable, Equatable {
    public var devicePath: String
    public var filetype: Int          // 1 = MP3/MPEG, 2 = AAC/M4A
    public var voiceover: String
    public init(devicePath: String, filetype: Int, voiceover: String) {
        self.devicePath = devicePath; self.filetype = filetype; self.voiceover = voiceover
    }
}

/// A playlist as indices into the track array. The master playlist (all songs) is added
/// automatically by the writer, so callers pass only their real playlists.
public struct ShufflePlaylist: Sendable, Equatable {
    public var name: String
    public var trackIndices: [Int]
    public init(name: String, trackIndices: [Int]) { self.name = name; self.trackIndices = trackIndices }
}

/// Builds the iPod Shuffle 3rd/4th-gen `iTunesSD` database, byte-for-byte per the
/// reverse-engineered format (little-endian; magic tags bdhs/hths/rths/hphs/lphs). Verified
/// against nims11/IPod-Shuffle-4g. Pure and deterministic so it's fully unit-testable.
public enum ShuffleDB {
    static let bdhsLen = 64
    static let rthsLen = 372          // 0x174
    static let hthsFixed = 20         // header before the per-track offset table
    static let hphsFixed = 20
    static let lphsFixed = 44

    /// MD5(text)[:8] — the track/playlist unique id (also names its VoiceOver file).
    public static func dbid(_ text: String) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(text.utf8)).prefix(8))
    }

    /// VoiceOver filename for a dbid: the 8 bytes reversed, lowercase hex, + ".wav".
    public static func voiceoverFilename(_ dbid: [UInt8]) -> String {
        dbid.reversed().map { String(format: "%02x", $0) }.joined() + ".wav"
    }

    /// Build the complete iTunesSD bytes. `voiceover` toggles the header flag (files themselves
    /// are written separately by the caller).
    public static func build(tracks: [ShuffleTrack], playlists: [ShufflePlaylist],
                             voiceover: Bool = true) -> Data {
        // Master playlist (all songs, in order) is always playlist 0.
        let allIndices = Array(tracks.indices)
        let masters = [ShufflePlaylist(name: "All Songs", trackIndices: allIndices)]
        let userLists = playlists
        let playlistCount = masters.count + userLists.count

        // --- Compute section offsets ---
        let hthsOffset = bdhsLen
        let hthsLen = hthsFixed + tracks.count * 4
        let tracksStart = hthsOffset + hthsLen
        let hphsOffset = tracksStart + tracks.count * rthsLen
        let hphsLen = hphsFixed + playlistCount * 4
        let playlistsStart = hphsOffset + hphsLen

        // --- bdhs (main header, 64 bytes) ---
        var out = Buffer()
        out.ascii("bdhs")                       // 0
        out.u32(0x02000003)                     // 4  version
        out.u32(UInt32(bdhsLen))                // 8  header length
        out.u32(UInt32(tracks.count))           // 12 total tracks
        out.u32(UInt32(playlistCount))          // 16 total playlists
        out.pad(8)                              // 20
        out.u8(0)                               // 28 max volume (0 = unlimited)
        out.u8(voiceover ? 1 : 0)               // 29 voiceover enabled
        out.pad(2)                              // 30
        out.u32(UInt32(tracks.count))           // 32 tracks excl. podcasts/audiobooks
        out.u32(UInt32(hthsOffset))             // 36 track header offset
        out.u32(UInt32(hphsOffset))             // 40 playlist header offset
        out.pad(20)                             // 44
        assert(out.count == bdhsLen)

        // --- hths (tracks header) ---
        out.ascii("hths")
        out.u32(UInt32(hthsLen))
        out.u32(UInt32(tracks.count))
        out.pad(8)
        for i in tracks.indices { out.u32(UInt32(tracksStart + i * rthsLen)) }

        // --- rths (one per track, 372 bytes) ---
        for track in tracks {
            let start = out.count
            out.ascii("rths")                   // 0
            out.u32(UInt32(rthsLen))            // 4  header length 0x174
            out.u32(0)                          // 8  start_at_pos_ms
            out.u32(0)                          // 12 stop_at_pos_ms
            out.u32(0)                          // 16 volume gain
            out.u32(UInt32(track.filetype))     // 20 filetype
            out.fixedString(track.devicePath, 256) // 24 filename (UTF-8, null-padded)
            out.u32(0)                          // 280 bookmark
            out.u8(1)                           // 284 dont_skip_on_shuffle
            out.u8(0)                           // 285 remember_playing_pos
            out.u8(0)                           // 286 part_of_uninterruptable_album
            out.pad(1)                          // 287
            out.u32(0)                          // 288 pregap
            out.u32(0)                          // 292 postgap
            out.u32(0)                          // 296 number_of_samples
            out.u32(0)                          // 300
            out.u32(0)                          // 304 gapless
            out.u32(0)                          // 308
            out.u32(0)                          // 312 album_id
            out.u16(0)                          // 316 track_number
            out.u16(0)                          // 318 disc_number
            out.pad(8)                          // 320
            out.bytes(dbid(track.voiceover))    // 328 dbid (8)
            out.u32(0)                          // 336 artist_id
            out.pad(32)                         // 340
            assert(out.count - start == rthsLen)
        }

        // --- hphs (playlists header) ---
        assert(out.count == hphsOffset)
        out.ascii("hphs")
        out.u32(UInt32(hphsLen))
        out.u32(UInt32(playlistCount))
        out.u16(0xFFFF)                         // non-podcast lists
        out.u16(UInt16(masters.count))          // master lists
        out.u16(0xFFFF)                         // non-audiobook lists
        out.pad(2)
        // Offsets to each lphs (masters first, then user playlists).
        var cursor = playlistsStart
        let ordered = masters + userLists
        var offsets: [Int] = []
        for pl in ordered {
            offsets.append(cursor)
            cursor += lphsFixed + pl.trackIndices.count * 4
        }
        for off in offsets { out.u32(UInt32(off)) }

        // --- lphs (one per playlist) ---
        for (i, pl) in ordered.enumerated() {
            let isMaster = i < masters.count
            let start = out.count
            out.ascii("lphs")                                   // 0
            out.u32(UInt32(lphsFixed + pl.trackIndices.count * 4)) // 4 total length
            out.u32(UInt32(pl.trackIndices.count))              // 8  number_of_songs
            out.u32(UInt32(pl.trackIndices.count))              // 12 number_of_songs2
            out.bytes(isMaster ? [UInt8](repeating: 0, count: 8) : dbid(pl.name)) // 16 dbid
            out.u32(isMaster ? 1 : 2)                           // 24 type
            out.pad(16)                                         // 28
            for idx in pl.trackIndices { out.u32(UInt32(idx)) } // 44 track indices
            assert(out.count - start == lphsFixed + pl.trackIndices.count * 4)
        }

        return out.data
    }
}

/// Minimal little-endian byte builder.
private struct Buffer {
    private(set) var data = Data()
    var count: Int { data.count }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func pad(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    /// Write a UTF-8 string into a fixed-width, null-padded field (truncating if too long).
    mutating func fixedString(_ s: String, _ width: Int) {
        var b = Array(s.utf8)
        if b.count > width { b = Array(b.prefix(width)) }
        b.append(contentsOf: [UInt8](repeating: 0, count: width - b.count))
        data.append(contentsOf: b)
    }
}
