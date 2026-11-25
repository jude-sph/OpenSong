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

    t.test("reordering a playlist rewrites the device .m3u8, with no files moved") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs")
        let a2 = try addMaster(f, title: "Avril 14th", artist: "Aphex Twin", album: "Drukqs")
        let a3 = try addMaster(f, title: "Nannou", artist: "Aphex Twin", album: "Drukqs")
        let pl = try f.store.createPlaylist(name: "drukqs", syncToDevice: true)
        for (i, a) in [a1, a2, a3].enumerated() {
            try f.store.addToPlaylist(playlistID: pl, assetID: a.id!, position: i)
        }
        try f.engine.apply(try f.engine.plan())

        let m3u8 = f.volume.musicDir.appendingPathComponent("drukqs.m3u8")
        func deviceOrder() throws -> [String] {
            M3U8Parser.parse(try Data(contentsOf: m3u8)).map { $0.title ?? $0.titleFromPath }
        }
        try t.expectEqual(try deviceOrder(), ["Vordhosbn", "Avril 14th", "Nannou"], "as first synced")

        // Drag the last track to the front — the only change; no file is added or removed.
        try f.store.setPlaylistOrder(pl, assetIDs: [a3.id!, a1.id!, a2.id!])
        let plan = try f.engine.plan()
        try t.expectEqual(plan.toAdd.count, 0, "a reorder moves no audio")
        try t.expectEqual(plan.toRemove.count, 0, "and deletes none")

        // Playlists are rewritten on every sync, so an otherwise empty plan still carries the order
        // across. This is what makes "reorder now, plug in later" work.
        try f.engine.apply(plan)
        try t.expectEqual(try deviceOrder(), ["Nannou", "Vordhosbn", "Avril 14th"],
                          "the device playlist follows the library order")
    }

    t.test("a replaced file is re-sent even though nothing else changed") {
        let f = try makeSyncFixture()
        let old = try addMaster(f, title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs")
        let pl = try f.store.createPlaylist(name: "drukqs", syncToDevice: true)
        try f.store.addToPlaylist(playlistID: pl, assetID: old.id!, position: 0)
        try f.store.pin(assetID: old.id!, true)
        try f.engine.apply(try f.engine.plan())
        try t.expectEqual(try f.engine.plan().toAdd.count, 0, "settled before the replacement")

        // The new version: same track, a different (and deliberately *lower* bitrate) file — the
        // user asked for it because the old one was wrong, so quality is not the deciding factor.
        let replacement = try TestSupport.tempDir("repl").appendingPathComponent("new.mp3")
        try TestSupport.makeMP3(at: replacement, title: "Vordhosbn", artist: "Aphex Twin",
                                album: "Drukqs", bitrateKbps: 128, seconds: 2)
        let importer = Importer(store: f.store, probe: AudioProbe(ffprobePath: TestSupport.ffprobe),
                                tagger: Transcoder(ffmpegPath: TestSupport.ffmpeg),
                                resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                                libraryRoot: f.libraryRoot)
        var identity = try f.store.identity(old.identityID)!
        identity.id = nil
        let new = try importer.importOne(replacement, identity: identity, source: .downloaded,
                                         replacing: old.id!)
        // Same track, so it keeps its asset id — nothing pointing at it has to move.
        try t.expectEqual(new.id, old.id, "the replacement takes over the same library entry")
        try t.expect(new.contentHash != old.contentHash, "but it really is a different file")
        try t.expectEqual(try f.store.playlistItems(pl).count, 1, "still in the playlist")

        // Marking the device copy stale is what makes the next sync re-send it.
        try t.expectEqual(try f.store.invalidateDeviceTracks(uuid: f.volume.uuid,
                                                             assetIDs: [new.id!]), 1,
                          "the device copy is marked stale")
        let plan = try f.engine.plan()
        try t.expectEqual(plan.toAdd.count, 1, "the replacement is queued even though the path is the same")
        try t.expectEqual(plan.toAdd.first?.id, new.id, "and it is the new file, not the old one")
        try f.engine.apply(plan)

        // The file on the device is now the new master, and the playlist still points at it.
        let onDevice = f.volume.musicDir.appendingPathComponent("Aphex Twin/Drukqs/Vordhosbn.mp3")
        try t.expect(FileManager.default.fileExists(atPath: onDevice.path), "still on the device")
        let rows = try f.store.deviceTracks(f.volume.uuid)
        try t.expectEqual(rows.count, 1, "one device row, not two")
        try t.expectEqual(rows.first?.assetID, new.id, "the device row tracks the new file")
        try t.expectEqual(rows.first?.contentHash, new.contentHash, "and its hash is the new one")
        try t.expect(rows.first?.contentHash != old.contentHash, "not the hash of the file it replaced")
        try t.expectEqual(try f.engine.plan().toAdd.count, 0, "settled again afterwards")
    }

    t.test("a replacement under a different title removes the old file from the device") {
        let f = try makeSyncFixture()
        let old = try addMaster(f, title: "Windowlicker", artist: "Aphex Twin", album: "Singles")
        try f.store.pin(assetID: old.id!, true)
        try f.engine.apply(try f.engine.plan())
        let oldFile = f.volume.musicDir.appendingPathComponent("Aphex Twin/Singles/Windowlicker.mp3")
        try t.expect(FileManager.default.fileExists(atPath: oldFile.path), "the old version is on the device")

        // A replacement whose tags differ lands at a different device path, so the old file has to
        // be deleted rather than left behind as an orphan.
        let new = try addMaster(f, title: "Windowlicker (Original Mix)", artist: "Aphex Twin",
                                album: "Singles")
        try f.store.replaceAsset(old: old.id!, with: new.id!)

        let plan = try f.engine.plan()
        try t.expectEqual(plan.toAdd.count, 1, "the new version is queued")
        try t.expectEqual(plan.toRemove.count, 1, "and the old path is queued for removal")
        try f.engine.apply(plan)
        try t.expect(!FileManager.default.fileExists(atPath: oldFile.path),
                     "the old version is off the device")
        let newFile = f.volume.musicDir
            .appendingPathComponent("Aphex Twin/Singles/Windowlicker (Original Mix).mp3")
        try t.expect(FileManager.default.fileExists(atPath: newFile.path), "the new version is on it")
        try t.expectEqual(try f.store.deviceTracks(f.volume.uuid).count, 1, "no orphan device row")
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
        try t.expectEqual(plan.removals.map { $0.assetID }, [a2.id!], "the removal maps back to its asset")

        // With the device untouched since the sync, the offline plan (rows + remembered capacity)
        // must say exactly what the live one (a walk of the volume) says.
        let offline = try SyncEngine.offlinePlan(store: f.store, transcoder: f.engine.transcoder,
                                                 settings: f.engine.settings, deviceUUID: f.volume.uuid,
                                                 totalBytes: plan.totalBytes, freeBytes: plan.freeBytes)
        try t.expectEqual(offline.toRemove, plan.toRemove, "offline agrees on removals")
        try t.expectEqual(offline.toAdd.map { $0.id }, plan.toAdd.map { $0.id }, "offline agrees on additions")
        try t.expectEqual(offline.upToDate.map { $0.id }, plan.upToDate.map { $0.id }, "offline agrees on up to date")
        try t.expectEqual(offline.projectedUsedBytes, plan.projectedUsedBytes, "and on projected usage")

        try f.engine.apply(plan)
        try t.expect(!FileManager.default.fileExists(atPath:
            f.volume.musicDir.appendingPathComponent("A/Alb/Drop.mp3").path), "dropped removed")
        try t.expect(FileManager.default.fileExists(atPath: foreign.path), "foreign file preserved")
    }

    t.test("a changed recipe (bitrate / artwork fix) rebuilds files already on the device") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Recipe", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.engine.apply(try f.engine.plan())
        try t.expectEqual(try f.engine.plan().upToDate.count, 1, "up to date right after a sync")

        // Same master, different target bitrate → the device copy no longer matches how it would
        // be produced now, so it must be rebuilt (this used to be silently skipped).
        var other = f.engine
        other.settings = TranscodeSettings(bitrateKbps: 320, loudnessNormalize: false)
        try t.expectEqual(try other.plan().toAdd.count, 1, "re-encodes at the new bitrate")

        // The artwork fix works the same way: rows written before it carry an empty recipe.
        let rows = try f.store.deviceTracks(f.volume.uuid)
        try t.expectEqual(rows.first?.recipe, f.engine.settings.deviceRecipe, "recipe recorded")
        var stale = rows[0]; stale.recipe = ""
        try f.store.setDeviceTrack(stale)
        try t.expectEqual(try f.engine.plan().toAdd.count, 1, "legacy row rebuilt on next sync")
    }

    t.test("device id is seeded from the volume UUID, then read back from the marker") {
        let root = try TestSupport.tempDir("devid")
        let first = DeviceIdentity.stableID(mountPoint: root, fallback: "VOL-UUID-1")
        try t.expectEqual(first, "VOL-UUID-1", "seeded from the volume UUID")
        try t.expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(DeviceIdentity.markerName).path), "marker written")
        // Volume UUID changes on the next mount; the marker keeps the id stable.
        try t.expectEqual(DeviceIdentity.stableID(mountPoint: root, fallback: "VOL-UUID-2"), "VOL-UUID-1",
                          "marker wins over a changed volume UUID")
    }

    t.test("a changed volume UUID re-adopts the tracks already on the device") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Keep", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.engine.apply(try f.engine.plan())
        try t.expectEqual(try f.store.deviceTracks(f.volume.uuid).count, 1, "one managed track")

        // FAT32 remount: same files, brand-new UUID → the rows look orphaned.
        let newUUID = "NEW-UUID-1234"
        try t.expectEqual(try f.store.deviceTracks(newUUID).count, 0, "nothing keyed to the new id")
        let present = Set(try DeviceManager(volume: f.volume).listManagedTracks())
        try t.expectEqual(try f.store.adoptDeviceTracks(uuid: newUUID, presentPaths: present), 1, "row adopted")
        try t.expectEqual(try f.store.deviceTracks(newUUID).count, 1, "re-keyed to the new id")
        try t.expectEqual(try f.store.deviceTracks(f.volume.uuid).count, 0, "stale row gone")

        // A sync under the new id therefore has nothing to do (instead of recopying everything).
        let engine = SyncEngine(store: f.store, transcoder: f.engine.transcoder, device: DeviceManager(volume: f.volume),
                                settings: TranscodeSettings(bitrateKbps: 192, loudnessNormalize: false),
                                deviceUUID: newUUID)
        let plan = try engine.plan()
        try t.expectEqual(plan.toAdd.count, 0, "nothing to re-copy")
        try t.expectEqual(plan.toRemove.count, 0, "nothing wrongly removed")

        // Rows for files that are NOT on this device are left alone.
        try f.store.setDeviceTrack(DeviceTrackRow(deviceUUID: "other-device", relativePath: "X\\Y\\Z.mp3",
                                                  assetID: a1.id!, transcodedBitrate: 192,
                                                  contentHash: "h", sizeBytes: 1))
        try t.expectEqual(try f.store.adoptDeviceTracks(uuid: newUUID, presentPaths: present), 0, "no false adoption")
        try t.expectEqual(try f.store.deviceTracks("other-device").count, 1, "other device untouched")
    }

    t.test("editing a master's tags/art re-sends it (content hash drives the diff)") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "Tagged", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.engine.apply(try f.engine.plan())
        try t.expectEqual(try f.engine.plan().toAdd.count, 0, "up to date after syncing")

        // Rewrite the master the way "Replace artwork" / "Fix track numbers" do, then re-hash it
        // exactly as the app does. Genre changes don't move the device path, so the hash is the
        // only thing that can tell the sync the file is different.
        var asset = try f.store.asset(a1.id!)!
        var ident = try f.store.identity(asset.identityID)!
        ident.genre = "Ambient"
        try f.store.upsertIdentity(ident)
        let master = URL(fileURLWithPath: asset.masterPath)
        try Transcoder(ffmpegPath: TestSupport.ffmpeg).writeTags(master, ident)
        asset.contentHash = try Importer.contentHash(of: master)
        try f.store.updateAsset(asset)

        let plan = try f.engine.plan()
        try t.expectEqual(plan.toAdd.count, 1, "rewritten master is re-sent")
        try t.expectEqual(plan.toRemove.count, 0, "same path, so nothing is removed")
    }

    t.test("playlists removed from the device stop leaving .m3u8 files behind") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "One", artist: "A", album: "Alb")
        let keep = try f.store.createPlaylist(name: "keep", syncToDevice: true)
        let drop = try f.store.createPlaylist(name: "drop", syncToDevice: true)
        try f.store.addToPlaylist(playlistID: keep, assetID: a1.id!, position: 0)
        try f.store.addToPlaylist(playlistID: drop, assetID: a1.id!, position: 0)
        try f.engine.apply(try f.engine.plan())
        let m3u8 = { (n: String) in f.volume.musicDir.appendingPathComponent("\(n).m3u8").path }
        try t.expect(FileManager.default.fileExists(atPath: m3u8("keep")), "keep written")
        try t.expect(FileManager.default.fileExists(atPath: m3u8("drop")), "drop written")

        // A playlist made on the device itself must survive the cleanup.
        let foreign = f.volume.musicDir.appendingPathComponent("device-made.m3u8")
        try Data("#EXTM3U\n".utf8).write(to: foreign)

        try f.store.setPlaylistSync(drop, false)
        try f.engine.apply(try f.engine.plan())
        try t.expect(FileManager.default.fileExists(atPath: m3u8("keep")), "still-synced playlist kept")
        try t.expect(!FileManager.default.fileExists(atPath: m3u8("drop")), "unsynced playlist removed")
        try t.expect(FileManager.default.fileExists(atPath: foreign.path), "device's own playlist untouched")
    }

    t.test("apply reports progress that advances to 100%") {
        let f = try makeSyncFixture()
        let a1 = try addMaster(f, title: "One", artist: "A", album: "Alb")
        let a2 = try addMaster(f, title: "Two", artist: "A", album: "Alb")
        try f.store.pin(assetID: a1.id!, true)
        try f.store.pin(assetID: a2.id!, true)

        var reports: [SyncProgress] = []
        try f.engine.apply(try f.engine.plan()) { reports.append($0) }
        try t.expect(reports.count >= 4, "reported per step (got \(reports.count))")
        try t.expectEqual(reports.map { $0.total }.max(), 2, "two steps in the run")
        try t.expect(reports.first!.fraction < 0.5, "starts near empty")
        try t.expectEqual(reports.last!.fraction, 1.0, "ends full")
        try t.expect(zip(reports, reports.dropFirst()).allSatisfy { $0.fraction <= $1.fraction },
                     "fraction never goes backwards")
        try t.expectEqual(reports.last!.done, 2, "both steps counted")

        // A no-op sync still completes the bar rather than sitting at zero.
        var second: [SyncProgress] = []
        try f.engine.apply(try f.engine.plan()) { second.append($0) }
        try t.expectEqual(second.last?.fraction, 1.0, "idempotent run reaches 100%")
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
