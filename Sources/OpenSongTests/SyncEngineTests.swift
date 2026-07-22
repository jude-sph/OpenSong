import Foundation
import OpenSongCore

private struct SyncFixture {
    let store: LibraryStore
    let engine: SyncEngine
    let volume: TempVolume
    let libraryRoot: URL
}

private func makeSyncFixture() throws -> SyncFixture {
    let dbDir = try TestSupport.tempDir("sync-db")
    let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
    let root = try TestSupport.tempDir("sync-dev")
    let volume = try TempVolume(root: root)
    let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
    let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
    let device = DeviceManager(volume: volume)
    let engine = SyncEngine(store: store, transcoder: transcoder, device: device,
                            settings: TranscodeSettings(bitrateKbps: 192, loudnessNormalize: false),
                            deviceUUID: volume.uuid)
    return SyncFixture(store: store, engine: engine, volume: volume,
                       libraryRoot: try TestSupport.tempDir("sync-lib"))
}

/// Import a master mp3 into the store+tree, return its asset.
private func addMaster(_ f: SyncFixture, title: String, artist: String, album: String,
                       bitrate: Int = 320) throws -> AudioAsset {
    let src = try TestSupport.tempDir("m").appendingPathComponent("\(title).mp3")
    try TestSupport.makeMP3(at: src, title: title, artist: artist, album: album, bitrateKbps: bitrate, seconds: 1)
    let importer = Importer(store: f.store, probe: AudioProbe(ffprobePath: TestSupport.ffprobe),
                            tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg),
                            resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                            libraryRoot: f.libraryRoot)
    return try importer.commit(try importer.scanLoose(src.deletingLastPathComponent()))[0]
}

func registerSyncEngineTests() {
    t.test("plan adds desired assets; apply then idempotent") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs")
        let a2 = try addMaster(f, title: "Avril 14th", artist: "Aphex Twin", album: "Drukqs")
        let pl = try f.store.createPlaylist(name: "drukqs", syncToDevice: true)
        try f.store.addToPlaylist(playlistID: pl, assetID: a1.id!, position: 0)
        try f.store.addToPlaylist(playlistID: pl, assetID: a2.id!, position: 1)

        let plan1 = try f.engine.plan()
        try t.expectEqual(plan1.toAdd.count, 2, "both to add")
        try t.expectEqual(plan1.toRemove.count, 0, "nothing to remove")
        try t.expect(plan1.projectedUsedBytes > (plan1.totalBytes - plan1.freeBytes), "projected grows")

        try f.engine.apply(plan1)
        // Files present + playlist written.
        let musicFile = f.volume.musicDir.appendingPathComponent("Aphex Twin/Drukqs/Vordhosbn.mp3")
        try t.expect(FileManager.default.fileExists(atPath: musicFile.path), "track pushed")
        let m3u8 = f.volume.musicDir.appendingPathComponent("drukqs.m3u8")
        try t.expect(FileManager.default.fileExists(atPath: m3u8.path), "playlist written")
        // Playlist parses back to 2 entries.
        try t.expectEqual(M3U8Parser.parse(try Data(contentsOf: m3u8)).count, 2, "m3u8 has 2 entries")

        let plan2 = try f.engine.plan()
        try t.expectEqual(plan2.toAdd.count, 0, "idempotent: nothing to add")
        try t.expectEqual(plan2.toRemove.count, 0, "idempotent: nothing to remove")
        try t.expectEqual(plan2.upToDate.count, 2, "both up to date")
    }

    t.test("removing from desired set queues managed removal; foreign files preserved") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Keep", artist: "A", album: "Alb")
        let a2 = try addMaster(f, title: "Drop", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.store.pin(assetID: a2.id!, true)
        try f.engine.apply(try f.engine.plan())

        // Plant a foreign file the app never wrote.
        let foreign = f.volume.musicDir.appendingPathComponent("foreign/x.mp3")
        try TestSupport.makeMP3(at: foreign, title: "Foreign", artist: "Someone", seconds: 1)

        // Unpin one → it should be queued for removal.
        try f.store.pin(assetID: a2.id!, false)
        let plan = try f.engine.plan()
        try t.expectEqual(plan.toRemove, ["A\\Alb\\Drop.mp3"], "only the un-desired managed track")
        try t.expect(!plan.toRemove.contains(where: { $0.contains("foreign") }), "foreign not in removals")

        try f.engine.apply(plan)
        try t.expect(!FileManager.default.fileExists(atPath:
            f.volume.musicDir.appendingPathComponent("A/Alb/Drop.mp3").path), "dropped removed")
        try t.expect(FileManager.default.fileExists(atPath: foreign.path), "foreign file preserved")
    }

    t.test("lossless master is transcoded to mp3 on sync") {
        let f = try makeSyncFixture()
        // Import a FLAC master.
        let src = try TestSupport.tempDir("m").appendingPathComponent("Song.flac")
        try TestSupport.makeFLAC(at: src, title: "Song", artist: "A", seconds: 1)
        let importer = Importer(store: f.store, probe: AudioProbe(ffprobePath: TestSupport.ffprobe),
                                tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg),
                                resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                                libraryRoot: f.libraryRoot)
        let asset = try importer.commit(try importer.scanLoose(src.deletingLastPathComponent()))[0]
        try f.store.pin(assetID: asset.id!, true)
        try f.engine.apply(try f.engine.plan())

        let onDevice = f.volume.musicDir.appendingPathComponent("A/Unknown Album/Song.mp3")
        try t.expect(FileManager.default.fileExists(atPath: onDevice.path), "flac became mp3 on device")
        let probed = try AudioProbe(ffprobePath: TestSupport.ffprobe).probe(onDevice)
        try t.expectEqual(probed.codec, "mp3", "device copy is mp3")
    }
}
