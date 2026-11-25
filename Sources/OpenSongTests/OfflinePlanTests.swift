import Foundation
import OpenSongCore

/// The offline plan: what the Device screen shows while the player is unplugged. It trusts the
/// `device_track` rows as the device's contents and the remembered capacity, and needs no mount,
/// no ffmpeg and no audio files — so these tests insert library rows directly.
private struct OfflineFixture {
    let store: LibraryStore
    let settings = TranscodeSettings(bitrateKbps: 192, loudnessNormalize: false)
    let uuid = "OFFLINE-WALKMAN"
}

private func makeOfflineFixture() throws -> OfflineFixture {
    let dir = try TestSupport.tempDir("offline-db")
    return OfflineFixture(store: try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite")))
}

/// A library song (identity + FLAC asset) with no file behind it — the planner never opens it.
private func addSong(_ f: OfflineFixture, _ title: String, hash: String? = nil) throws -> (AudioAsset, TrackIdentity) {
    var ident = TrackIdentity(title: title, artist: "Artist", album: "Album", durationSec: 200)
    ident.id = try f.store.upsertIdentity(ident)
    var asset = AudioAsset(identityID: ident.id!, masterPath: "/nowhere/\(title).flac", format: "flac",
                           bitrateKbps: 1000, sampleRate: 44100, sizeBytes: 25_000_000,
                           contentHash: hash ?? "hash-\(title)", source: .importedLoose)
    asset.id = try f.store.insertAsset(asset)
    return (asset, ident)
}

/// Record a song as already on the device, the way a completed sync would.
private func recordOnDevice(_ f: OfflineFixture, _ song: (AudioAsset, TrackIdentity),
                            path: String? = nil, recipe: String? = nil) throws {
    try f.store.setDeviceTrack(DeviceTrackRow(
        deviceUUID: f.uuid, relativePath: path ?? DeviceRelativePath.backslashPath(for: song.1),
        assetID: song.0.id!, transcodedBitrate: 192, contentHash: song.0.contentHash,
        sizeBytes: 4_800_000, recipe: recipe ?? f.settings.deviceRecipe))
}

private func walkmanOffline(_ f: OfflineFixture, total: Int64 = 8_000_000_000,
                            free: Int64 = 6_000_000_000) throws -> SyncPlan {
    try SyncEngine.offlinePlan(store: f.store, transcoder: Transcoder(), settings: f.settings,
                               deviceUUID: f.uuid, totalBytes: total, freeBytes: free)
}

func registerOfflinePlanTests() {
    t.test("offline plan: pinned-not-on-device adds, recorded-not-desired removes, recorded+desired is up to date") {
        let f = try makeOfflineFixture()
        let newPin = try addSong(f, "Pinned New")
        let stale = try addSong(f, "Unwanted")
        let kept = try addSong(f, "Kept")
        try f.store.pin(assetID: newPin.0.id!, true)
        try f.store.pin(assetID: kept.0.id!, true)
        try recordOnDevice(f, stale)
        try recordOnDevice(f, kept)

        let plan = try walkmanOffline(f)
        try t.expectEqual(plan.toAdd.map { $0.id }, [newPin.0.id], "the pinned song not on the device is added")
        try t.expectEqual(plan.upToDate.map { $0.id }, [kept.0.id], "the desired, recorded song is up to date")
        try t.expectEqual(plan.toRemove, [DeviceRelativePath.backslashPath(for: stale.1)],
                          "the recorded song nobody wants is removed")
        try t.expectEqual(plan.removals.map { $0.assetID }, [stale.0.id!],
                          "each removal maps back to its asset, so the UI can undo it")
    }

    t.test("offline plan uses the remembered capacity and projects usage from the rows") {
        let f = try makeOfflineFixture()
        let newPin = try addSong(f, "Pinned New")
        let stale = try addSong(f, "Unwanted")
        try f.store.pin(assetID: newPin.0.id!, true)
        try recordOnDevice(f, stale)

        let plan = try walkmanOffline(f, total: 8_000_000_000, free: 6_000_000_000)
        try t.expectEqual(plan.totalBytes, 8_000_000_000, "remembered total")
        try t.expectEqual(plan.freeBytes, 6_000_000_000, "remembered free")
        // FLAC → 192k MP3 over 200 s = 4.8 MB added; the recorded row's 4.8 MB removed.
        try t.expectEqual(plan.projectedUsedBytes, 2_000_000_000, "add and remove cancel out")
    }

    t.test("offline plan: unticking a device playlist queues its songs for removal; a stale recipe re-sends") {
        let f = try makeOfflineFixture()
        let a = try addSong(f, "In Playlist")
        let b = try addSong(f, "Old Recipe")
        let pl = try f.store.createPlaylist(name: "late night", syncToDevice: true)
        try f.store.addToPlaylist(playlistID: pl, assetID: a.0.id!, position: 0)
        try f.store.addToPlaylist(playlistID: pl, assetID: b.0.id!, position: 1)
        try recordOnDevice(f, a)
        try recordOnDevice(f, b, recipe: "v0/old")

        let before = try walkmanOffline(f)
        try t.expectEqual(before.upToDate.map { $0.id }, [a.0.id], "synced via the playlist")
        try t.expectEqual(before.toAdd.map { $0.id }, [b.0.id], "an out-of-date copy is re-sent")
        try t.expect(before.toRemove.isEmpty, "nothing removed while the playlist syncs")

        try f.store.setPlaylistSync(pl, false)
        let after = try walkmanOffline(f)
        try t.expectEqual(Set(after.removals.map { $0.assetID }), [a.0.id!, b.0.id!],
                          "both leave with the playlist")
        try t.expect(after.toAdd.isEmpty && after.upToDate.isEmpty, "nothing else desired")
    }

    t.test("offline plan with no rows recorded adds everything desired") {
        let f = try makeOfflineFixture()
        let a = try addSong(f, "One"); let b = try addSong(f, "Two")
        try f.store.pin(assetID: a.0.id!, true); try f.store.pin(assetID: b.0.id!, true)
        let plan = try walkmanOffline(f)
        try t.expectEqual(plan.toAdd.count, 2, "both added")
        try t.expect(plan.toRemove.isEmpty && plan.upToDate.isEmpty, "nothing else")
    }

    t.test("shuffle offline plan: same three outcomes, keyed by asset id") {
        let f = try makeOfflineFixture()
        var settings = f.settings; settings.embedArtwork = false
        let newPin = try addSong(f, "Pinned New")
        let stale = try addSong(f, "Unwanted")
        let kept = try addSong(f, "Kept")
        try f.store.pin(assetID: newPin.0.id!, true)
        try f.store.pin(assetID: kept.0.id!, true)
        for s in [stale, kept] {
            try f.store.setDeviceTrack(DeviceTrackRow(
                deviceUUID: f.uuid, relativePath: "iPod_Control/Music/\(s.0.id!).mp3", assetID: s.0.id!,
                transcodedBitrate: 192, contentHash: s.0.contentHash, sizeBytes: 4_800_000,
                recipe: settings.deviceRecipe))
        }
        let plan = try ShuffleSyncEngine.offlinePlan(store: f.store, settings: settings, deviceUUID: f.uuid,
                                                     totalBytes: 2_000_000_000, freeBytes: 1_000_000_000)
        try t.expectEqual(plan.toAdd.map { $0.id }, [newPin.0.id], "pinned, not on the iPod → add")
        try t.expectEqual(plan.upToDate.map { $0.id }, [kept.0.id], "pinned and recorded → up to date")
        try t.expectEqual(plan.removals.map { $0.assetID }, [stale.0.id!], "recorded, not desired → remove")
        try t.expectEqual(plan.toRemove, ["iPod_Control/Music/\(stale.0.id!).mp3"], "by its device path")
        try t.expectEqual(plan.totalBytes, 2_000_000_000, "remembered capacity")
    }
}
