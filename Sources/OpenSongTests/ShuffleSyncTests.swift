import Foundation
import OpenSongCore

/// VoiceOver stub: writes a marker file instead of invoking macOS `say`, so the sync is fast
/// and hardware/TTS-independent.
private struct StubVoiceOver: ShuffleVoiceOver {
    func speak(_ text: String, to dest: URL) -> Bool {
        try? Data("VO:\(text)".utf8).write(to: dest); return true
    }
}

private struct ShuffleFixture {
    let store: LibraryStore
    let engine: ShuffleSyncEngine
    let layout: ShuffleLayout
    let libraryRoot: URL
}

private func makeShuffleFixture() throws -> ShuffleFixture {
    let dbDir = try TestSupport.tempDir("shuffle-db")
    let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
    let mount = try TestSupport.tempDir("shuffle-dev")
    // Mark it as an iPod so it's shaped like a real mount.
    try FileManager.default.createDirectory(at: mount.appendingPathComponent("iPod_Control"), withIntermediateDirectories: true)
    let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
    let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
    let layout = ShuffleLayout(mountPoint: mount)
    let engine = ShuffleSyncEngine(store: store, transcoder: transcoder, layout: layout,
                                   settings: TranscodeSettings(format: "mp3", bitrateKbps: 320, loudnessNormalize: false),
                                   deviceUUID: "SHUFFLE-TEST", voiceover: StubVoiceOver())
    return ShuffleFixture(store: store, engine: engine, layout: layout,
                          libraryRoot: try TestSupport.tempDir("shuffle-lib"))
}

private func addMaster(_ f: ShuffleFixture, title: String, artist: String, album: String) throws -> AudioAsset {
    let src = try TestSupport.tempDir("m").appendingPathComponent("\(title).mp3")
    try TestSupport.makeMP3(at: src, title: title, artist: artist, album: album, bitrateKbps: 320, seconds: 1)
    let importer = Importer(store: f.store, probe: AudioProbe(ffprobePath: TestSupport.ffprobe),
                            tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg),
                            resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                            libraryRoot: f.libraryRoot)
    return try importer.commit(try importer.scanLoose(src.deletingLastPathComponent()))[0]
}

private func u32(_ d: Data, _ off: Int) -> UInt32 {
    var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(d[d.startIndex + off + i]) << (8 * i) }; return v
}

func registerShuffleSyncTests() {
    t.test("syncs files, builds iTunesSD + VoiceOver, then is idempotent") {
        let f = try makeShuffleFixture()
        let a1 = try addMaster(f, title: "Nights", artist: "Frank Ocean", album: "Blonde")
        let a2 = try addMaster(f, title: "Xtal", artist: "Aphex Twin", album: "SAW")
        let pl = try f.store.createPlaylist(name: "roadtrip", syncToDevice: true)
        try f.store.addToPlaylist(playlistID: pl, assetID: a1.id!, position: 0)
        try f.store.addToPlaylist(playlistID: pl, assetID: a2.id!, position: 1)

        let plan = try f.engine.plan()
        try t.expectEqual(plan.toAdd.count, 2, "both queued")

        try f.engine.apply()
        let fm = FileManager.default

        // Music files landed under iPod_Control/Music as <assetID>.mp3
        try t.expect(fm.fileExists(atPath: f.layout.musicDir.appendingPathComponent("\(a1.id!).mp3").path), "track1 on device")
        try t.expect(fm.fileExists(atPath: f.layout.musicDir.appendingPathComponent("\(a2.id!).mp3").path), "track2 on device")

        // iTunesSD exists and is a real shuffle DB (bdhs magic, 2 tracks, 2 playlists incl master)
        let db = try Data(contentsOf: f.layout.iTunesSD)
        try t.expectEqual(String(decoding: db[db.startIndex..<db.startIndex+4], as: UTF8.self), "bdhs", "db magic")
        try t.expectEqual(u32(db, 12), 2, "db track count")
        try t.expectEqual(u32(db, 16), 2, "db playlist count (master + roadtrip)")

        // VoiceOver clips generated for both tracks + the playlist name.
        let voTracks = try fm.contentsOfDirectory(atPath: f.layout.speakableTracks.path)
        try t.expectEqual(voTracks.count, 2, "two track voiceovers")
        let voPls = try fm.contentsOfDirectory(atPath: f.layout.speakablePlaylists.path)
        try t.expectEqual(voPls.count, 1, "one playlist voiceover")
        let plVOName = ShuffleDB.voiceoverFilename(ShuffleDB.dbid("roadtrip"))
        try t.expect(voPls.contains(plVOName), "playlist voiceover named by dbid")

        // Idempotent: nothing to add on a second plan.
        try t.expectEqual(try f.engine.plan().toAdd.count, 0, "idempotent")
        try t.expectEqual(try f.engine.plan().upToDate.count, 2, "both up to date")
    }

    t.test("unpinning removes the managed file and updates the db") {
        let f = try makeShuffleFixture()
        let a1 = try addMaster(f, title: "Keep", artist: "A", album: "Alb")
        let a2 = try addMaster(f, title: "Drop", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.store.pin(assetID: a2.id!, true)
        try f.engine.apply()

        // Foreign file the app never wrote must survive.
        let foreign = f.layout.musicDir.appendingPathComponent("foreign.mp3")
        try Data("x".utf8).write(to: foreign)

        try f.store.pin(assetID: a2.id!, false)
        let plan = try f.engine.plan()
        try t.expectEqual(plan.toRemove, ["iPod_Control/Music/\(a2.id!).mp3"], "only un-desired queued")
        try f.engine.apply()

        let fm = FileManager.default
        try t.expect(!fm.fileExists(atPath: f.layout.musicDir.appendingPathComponent("\(a2.id!).mp3").path), "dropped removed")
        try t.expect(fm.fileExists(atPath: foreign.path), "foreign preserved")
        // DB now has a single track.
        let db = try Data(contentsOf: f.layout.iTunesSD)
        try t.expectEqual(u32(db, 12), 1, "db down to 1 track")
    }
}
