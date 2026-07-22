import Foundation
import OpenSongCore

private func makeStore() throws -> LibraryStore {
    let dir = try TestSupport.tempDir("libstore")
    return try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite"))
}

private func sampleAsset(identityID: Int64, hash: String, bitrate: Int = 320,
                         path: String = "/lib/x.mp3") -> AudioAsset {
    AudioAsset(identityID: identityID, masterPath: path, format: "mp3", bitrateKbps: bitrate,
               sampleRate: 44100, sizeBytes: 1000, contentHash: hash, source: .importedLoose)
}

func registerLibraryStoreTests() {
    t.test("insert identity + asset and read back") {
        let store = try makeStore()
        let idID = try store.upsertIdentity(TrackIdentity(title: "Song", artist: "Artist",
                                                          album: "Album", durationSec: 100,
                                                          provenance: .itunesResolved))
        let assetID = try store.insertAsset(sampleAsset(identityID: idID, hash: "h1"))
        try t.expect(assetID > 0, "asset id assigned")
        let all = try store.allAssetsWithIdentity()
        try t.expectEqual(all.count, 1, "one asset")
        try t.expectEqual(all[0].1.title, "Song", "identity joined")
        try t.expectEqual(all[0].0.contentHash, "h1", "asset hash")
    }
    t.test("playlist items keep position order") {
        let store = try makeStore()
        let idA = try store.upsertIdentity(TrackIdentity(title: "A", artist: "X", durationSec: 10))
        let idB = try store.upsertIdentity(TrackIdentity(title: "B", artist: "X", durationSec: 10))
        let a1 = try store.insertAsset(sampleAsset(identityID: idA, hash: "a"))
        let a2 = try store.insertAsset(sampleAsset(identityID: idB, hash: "b"))
        let pl = try store.createPlaylist(name: "Mix", syncToDevice: true)
        try store.addToPlaylist(playlistID: pl, assetID: a2, position: 1)
        try store.addToPlaylist(playlistID: pl, assetID: a1, position: 0)
        let items = try store.playlistItems(pl)
        try t.expectEqual(items.map { $0.contentHash }, ["a", "b"], "ordered by position")
        try t.expectEqual(try store.devicePlaylists().count, 1, "device playlist listed")
    }
    t.test("findAssetByHash hit and miss") {
        let store = try makeStore()
        let idID = try store.upsertIdentity(TrackIdentity(title: "S", artist: "A", durationSec: 10))
        _ = try store.insertAsset(sampleAsset(identityID: idID, hash: "hello"))
        try t.expect(try store.findAssetByHash("hello") != nil, "hit")
        try t.expect(try store.findAssetByHash("nope") == nil, "miss")
    }
    t.test("pin and unpin reflected in pinnedAssets") {
        let store = try makeStore()
        let idID = try store.upsertIdentity(TrackIdentity(title: "S", artist: "A", durationSec: 10))
        let a = try store.insertAsset(sampleAsset(identityID: idID, hash: "p"))
        try store.pin(assetID: a, true)
        try t.expectEqual(try store.pinnedAssets().count, 1, "pinned")
        try store.pin(assetID: a, true) // idempotent
        try t.expectEqual(try store.pinnedAssets().count, 1, "still one")
        try store.pin(assetID: a, false)
        try t.expectEqual(try store.pinnedAssets().count, 0, "unpinned")
    }
    t.test("upsertDevice is idempotent by UUID") {
        let store = try makeStore()
        let d1 = try store.upsertDevice(DeviceRecord(volumeUUID: "UUID-1", name: "WALKMAN"))
        let d2 = try store.upsertDevice(DeviceRecord(volumeUUID: "UUID-1", name: "WALKMAN renamed",
                                                     targetBitrateKbps: 256))
        try t.expectEqual(d1, d2, "same device row reused")
    }
}
