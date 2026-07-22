import Foundation
import OpenSongCore

/// Real end-to-end test against the physically connected NW-E394. Gated behind
/// OPENSONG_DEVICE_TEST=1 so it never runs by accident. Self-cleaning: it writes two
/// tracks + a playlist under distinctive "OpenSong SelfTest" names, verifies them on the
/// device, then removes them — leaving the device exactly as it was.
func registerDeviceHardwareTests() {
    t.test("HARDWARE: real import -> sync -> device -> cleanup (NW-E394)") {
        guard ProcessInfo.processInfo.environment["OPENSONG_DEVICE_TEST"] == "1" else {
            try t.skip("set OPENSONG_DEVICE_TEST=1 (with the Walkman plugged in) to run")
        }
        guard let vol = DeviceDetector.connectedWalkman() else {
            try t.skip("no Walkman detected under /Volumes")
        }
        let device = DeviceManager(volume: vol)

        // Build a small library from real generated audio.
        let dbDir = try TestSupport.tempDir("hw-db")
        let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
        let libraryRoot = try TestSupport.tempDir("hw-lib")
        let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
        let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
        let importer = Importer(store: store, probe: probe, tagger: transcoder,
                                resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                                libraryRoot: libraryRoot)

        let loose = try TestSupport.tempDir("hw-loose")
        try TestSupport.makeMP3(at: loose.appendingPathComponent("a.mp3"),
                                title: "SelfTest One", artist: "OpenSong SelfTest", album: "Verify", bitrateKbps: 192, seconds: 1, tone: true)
        try TestSupport.makeMP3(at: loose.appendingPathComponent("b.mp3"),
                                title: "SelfTest Two", artist: "OpenSong SelfTest", album: "Verify", bitrateKbps: 320, seconds: 1, tone: true)
        let assets = try importer.commit(try importer.scanLoose(loose))
        try t.expectEqual(assets.count, 2, "2 imported")

        let pl = try store.createPlaylist(name: "OpenSong SelfTest", syncToDevice: true)
        for (i, a) in assets.enumerated() { try store.addToPlaylist(playlistID: pl, assetID: a.id!, position: i) }

        let engine = SyncEngine(store: store, transcoder: transcoder, device: device,
                                settings: TranscodeSettings(bitrateKbps: 192, loudnessNormalize: true),
                                deviceUUID: vol.uuid)

        // Sync to the REAL device.
        let plan = try engine.plan()
        try t.expectEqual(plan.toAdd.count, 2, "both queued to add")
        try engine.apply(plan)

        // Verify on the physical device.
        let one = vol.musicDir.appendingPathComponent("OpenSong SelfTest/Verify/SelfTest One.mp3")
        let two = vol.musicDir.appendingPathComponent("OpenSong SelfTest/Verify/SelfTest Two.mp3")
        let m3u8 = vol.musicDir.appendingPathComponent("OpenSong SelfTest.m3u8")
        try t.expect(FileManager.default.fileExists(atPath: one.path), "track 1 on device")
        try t.expect(FileManager.default.fileExists(atPath: two.path), "track 2 on device")
        try t.expect(FileManager.default.fileExists(atPath: m3u8.path), "playlist on device")
        // The 320k one got transcoded down to ~192k on the FAT volume.
        try t.expect(try probe.probe(two).bitrateKbps <= 210, "track 2 transcoded to ~192k on device")
        // Playlist has both, in device format.
        let entries = M3U8Parser.parse(try Data(contentsOf: m3u8))
        try t.expectEqual(entries.count, 2, "playlist lists both tracks")
        try t.expectEqual(entries[0].relativePath, "OpenSong SelfTest\\Verify\\SelfTest One.mp3", "backslash rel path on device")

        // CLEANUP — remove exactly what we added; leave the device untouched.
        try device.remove(relative: "OpenSong SelfTest\\Verify\\SelfTest One.mp3")
        try device.remove(relative: "OpenSong SelfTest\\Verify\\SelfTest Two.mp3")
        try device.removePlaylist(name: "OpenSong SelfTest")
        try t.expect(!FileManager.default.fileExists(atPath: one.path), "track 1 cleaned up")
        try t.expect(!FileManager.default.fileExists(atPath: two.path), "track 2 cleaned up")
        try t.expect(!FileManager.default.fileExists(atPath: m3u8.path), "playlist cleaned up")
        try t.expect(!FileManager.default.fileExists(atPath: vol.musicDir.appendingPathComponent("OpenSong SelfTest").path),
                     "empty artist folder pruned")
    }
}
