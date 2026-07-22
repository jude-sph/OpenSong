import Foundation
import OpenSongCore

private func makeImporter(libraryRoot: URL, resolverData: Data = Data("{\"results\":[]}".utf8)) throws -> (Importer, LibraryStore) {
    let dbDir = try TestSupport.tempDir("imp-db")
    let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
    let importer = Importer(
        store: store,
        probe: AudioProbe(ffprobePath: TestSupport.ffprobe),
        tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: AudioProbe(ffprobePath: TestSupport.ffprobe)),
        resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: resolverData)),
        libraryRoot: libraryRoot)
    return (importer, store)
}

func registerImporterTests() {
    t.test("scanLoose builds candidates; untagged falls back to filename") {
        let src = try TestSupport.tempDir("loose")
        try TestSupport.makeMP3(at: src.appendingPathComponent("tagged.mp3"),
                                title: "Real Title", artist: "Real Artist", album: "Album", seconds: 1)
        // Untitled file: strip tags by not setting them (ffmpeg still writes encoder tag, but no title)
        let untagged = src.appendingPathComponent("My Filename Song.mp3")
        let r = try Shell.run(TestSupport.ffmpeg, ["-y", "-f", "lavfi", "-i",
            "anullsrc=r=44100:cl=stereo", "-t", "1", "-c:a", "libmp3lame", "-b:a", "192k",
            "-map_metadata", "-1", untagged.path])
        try t.expectEqual(r.status, 0, "made untagged mp3")

        let lib = try TestSupport.tempDir("lib")
        let (importer, _) = try makeImporter(libraryRoot: lib)
        let candidates = try importer.scanLoose(src)
        try t.expectEqual(candidates.count, 2, "two candidates")
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sourceURL.lastPathComponent, $0) })
        try t.expectEqual(byName["tagged.mp3"]?.original.title, "Real Title", "tag title")
        try t.expectEqual(byName["My Filename Song.mp3"]?.original.title, "My Filename Song", "filename fallback")
    }

    t.test("commit places files in tree, indexes, dedups identical hashes") {
        let src = try TestSupport.tempDir("loose")
        let a = src.appendingPathComponent("a.mp3")
        try TestSupport.makeMP3(at: a, title: "Song", artist: "Artist", album: "Album", seconds: 1)
        // exact duplicate bytes
        let b = src.appendingPathComponent("b.mp3")
        try FileManager.default.copyItem(at: a, to: b)

        let lib = try TestSupport.tempDir("lib")
        let (importer, store) = try makeImporter(libraryRoot: lib)
        let candidates = try importer.scanLoose(src)
        let assets = try importer.commit(candidates)
        try t.expectEqual(assets.count, 2, "returns two (second maps to the dup)")
        let indexed = try store.allAssetsWithIdentity()
        try t.expectEqual(indexed.count, 1, "only one asset indexed (deduped)")
        let expected = lib.appendingPathComponent("Artist/Album/Song.mp3")
        try t.expect(FileManager.default.fileExists(atPath: expected.path),
                     "file at \(expected.path)")
    }

    t.test("commit never downgrades: higher-bitrate original wins over lower") {
        let src = try TestSupport.tempDir("loose")
        let lo = src.appendingPathComponent("lo.mp3")
        let hi = src.appendingPathComponent("hi.mp3")
        try TestSupport.makeMP3(at: lo, title: "Dup", artist: "A", album: "Alb", bitrateKbps: 128, seconds: 1)
        try TestSupport.makeMP3(at: hi, title: "Dup", artist: "A", album: "Alb", bitrateKbps: 320, seconds: 1)

        let lib = try TestSupport.tempDir("lib")
        let (importer, store) = try makeImporter(libraryRoot: lib)
        // import low first, then high
        _ = try importer.commit(try importer.scanLoose(src).filter { $0.sourceURL.lastPathComponent == "lo.mp3" })
        _ = try importer.commit(try importer.scanLoose(src).filter { $0.sourceURL.lastPathComponent == "hi.mp3" })
        let indexed = try store.allAssetsWithIdentity()
        try t.expectEqual(indexed.count, 1, "single asset kept")
        try t.expect(indexed[0].0.bitrateKbps >= 256, "kept the 320k (got \(indexed[0].0.bitrateKbps))")
    }

    t.test("adopt imports device tracks and reconstructs playlist from m3u8") {
        // Simulate a device MUSIC/ dir.
        let music = try TestSupport.tempDir("MUSIC")
        let t1 = music.appendingPathComponent("Aphex Twin/Drukqs/Vordhosbn.mp3")
        let t2 = music.appendingPathComponent("Aphex Twin/Drukqs/Avril 14th.mp3")
        try TestSupport.makeMP3(at: t1, title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs", seconds: 1)
        try TestSupport.makeMP3(at: t2, title: "Avril 14th", artist: "Aphex Twin", album: "Drukqs", seconds: 1)
        // Write a playlist referencing both, in the device format.
        let entries: [(identity: TrackIdentity, durationSec: Int)] = [
            (TrackIdentity(title: "Vordhosbn", artist: "Aphex Twin", albumArtist: "Aphex Twin", album: "Drukqs", durationSec: 1), 1),
            (TrackIdentity(title: "Avril 14th", artist: "Aphex Twin", albumArtist: "Aphex Twin", album: "Drukqs", durationSec: 1), 1),
        ]
        try M3U8Writer.data(entries: entries).write(to: music.appendingPathComponent("drukqs picks.m3u8"))

        let lib = try TestSupport.tempDir("lib")
        let (importer, store) = try makeImporter(libraryRoot: lib)
        let (assets, playlists) = try importer.adopt(musicDir: music)
        try t.expectEqual(assets.count, 2, "two adopted assets")
        try t.expectEqual(playlists.count, 1, "one reconstructed playlist")
        let items = try store.playlistItems(playlists[0].id!)
        try t.expectEqual(items.count, 2, "playlist mapped to both assets")
        try t.expectEqual(playlists[0].name, "drukqs picks", "playlist name from filename")
    }
}
