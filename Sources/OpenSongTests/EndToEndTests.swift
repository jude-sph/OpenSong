import Foundation
import OpenSongCore

func registerEndToEndTests() {
    t.test("E2E: import loose -> playlist -> sync -> device correct + idempotent") {
        // Library + device.
        let dbDir = try TestSupport.tempDir("e2e-db")
        let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
        let libraryRoot = try TestSupport.tempDir("e2e-lib")
        let volume = try TempVolume(root: try TestSupport.tempDir("e2e-dev"))

        let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
        let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
        let importer = Importer(store: store, probe: probe, tagger: transcoder,
                                resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                                libraryRoot: libraryRoot)
        let engine = SyncEngine(store: store, transcoder: transcoder,
                                device: DeviceManager(volume: volume),
                                settings: TranscodeSettings(bitrateKbps: 192, loudnessNormalize: false),
                                deviceUUID: volume.uuid)

        // 3 loose files, varied bitrate incl. a 320k.
        let loose = try TestSupport.tempDir("e2e-loose")
        try TestSupport.makeMP3(at: loose.appendingPathComponent("1.mp3"), title: "One", artist: "Band", album: "Alb", bitrateKbps: 320, seconds: 1)
        try TestSupport.makeMP3(at: loose.appendingPathComponent("2.mp3"), title: "Two", artist: "Band", album: "Alb", bitrateKbps: 192, seconds: 1)
        try TestSupport.makeMP3(at: loose.appendingPathComponent("3.mp3"), title: "Three", artist: "Band", album: "Alb", bitrateKbps: 128, seconds: 1)
        let assets = try importer.commit(try importer.scanLoose(loose))
        try t.expectEqual(assets.count, 3, "3 imported")

        // Playlist with two of them, flagged for the device.
        let byTitle = try assetsByTitle(store)
        let pl = try store.createPlaylist(name: "set", syncToDevice: true)
        try store.addToPlaylist(playlistID: pl, assetID: byTitle["One"]!.id!, position: 0)
        try store.addToPlaylist(playlistID: pl, assetID: byTitle["Three"]!.id!, position: 1)

        try engine.apply(try engine.plan())

        // Two files present at expected backslash paths; "Two" absent.
        let one = volume.musicDir.appendingPathComponent("Band/Alb/One.mp3")
        let three = volume.musicDir.appendingPathComponent("Band/Alb/Three.mp3")
        let two = volume.musicDir.appendingPathComponent("Band/Alb/Two.mp3")
        try t.expect(FileManager.default.fileExists(atPath: one.path), "One on device")
        try t.expect(FileManager.default.fileExists(atPath: three.path), "Three on device")
        try t.expect(!FileManager.default.fileExists(atPath: two.path), "Two not on device")

        // 320k master was transcoded down.
        try t.expect(try probe.probe(one).bitrateKbps <= 210, "One transcoded to ~192")

        // Playlist parses back to 2 entries.
        let m3u8 = volume.musicDir.appendingPathComponent("set.m3u8")
        try t.expectEqual(M3U8Parser.parse(try Data(contentsOf: m3u8)).count, 2, "playlist has 2")

        // Idempotent.
        let plan2 = try engine.plan()
        try t.expect(plan2.toAdd.isEmpty && plan2.toRemove.isEmpty, "second sync is a no-op")
    }

    t.test("E2E: never downgrade a master with a lower-quality device copy") {
        let dbDir = try TestSupport.tempDir("e2e2-db")
        let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
        let libraryRoot = try TestSupport.tempDir("e2e2-lib")
        let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
        let importer = Importer(store: store, probe: probe,
                                tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe),
                                resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                                libraryRoot: libraryRoot)

        // Simulate a device MUSIC dir holding a 192k copy; adopt it first.
        let music = try TestSupport.tempDir("e2e2-MUSIC")
        try TestSupport.makeMP3(at: music.appendingPathComponent("Band/Alb/Song.mp3"),
                                title: "Song", artist: "Band", album: "Alb", bitrateKbps: 192, seconds: 1)
        _ = try importer.adopt(musicDir: music)

        // Now a 320k loose original of the same track arrives.
        let loose = try TestSupport.tempDir("e2e2-loose")
        try TestSupport.makeMP3(at: loose.appendingPathComponent("hq.mp3"),
                                title: "Song", artist: "Band", album: "Alb", bitrateKbps: 320, seconds: 1)
        _ = try importer.commit(try importer.scanLoose(loose))

        let indexed = try store.allAssetsWithIdentity()
        try t.expectEqual(indexed.count, 1, "single deduped asset")
        try t.expect(indexed[0].0.bitrateKbps >= 256, "kept the 320k master (got \(indexed[0].0.bitrateKbps))")
    }
}

private func assetsByTitle(_ store: LibraryStore) throws -> [String: AudioAsset] {
    var out: [String: AudioAsset] = [:]
    for (asset, ident) in try store.allAssetsWithIdentity() { out[ident.title] = asset }
    return out
}
