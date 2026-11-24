import Foundation
import OpenSongCore

func registerWishlistStoreTests() {
    t.test("wishlist CRUD + state transitions") {
        let dir = try TestSupport.tempDir("wish-db")
        let store = try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite"))
        let id = try store.addWish(WishItem(title: "Avril 14th", artist: "Aphex Twin",
                                            album: "Drukqs", durationSec: 125, source: .custom))
        try t.expectEqual(try store.allWishes().count, 1, "one wish")
        var w = try store.allWishes()[0]
        try t.expectEqual(w.state, .wishlist, "starts as wishlist")
        w.state = .matching
        try store.updateWish(w)
        try t.expectEqual(try store.allWishes()[0].state, .matching, "-> matching")
        w.state = .downloaded; w.assetID = 42
        try store.updateWish(w)
        let done = try store.allWishes()[0]
        try t.expectEqual(done.state, .downloaded, "-> downloaded")
        try t.expectEqual(done.assetID, 42, "linked asset")
        try store.deleteWish(id)
        try t.expectEqual(try store.allWishes().count, 0, "deleted")
    }
    t.test("wish identity carries provenance") {
        let am = WishItem(title: "T", artist: "A", source: .appleMusic)
        try t.expectEqual(am.identity.provenance, .appleMusic, "apple music -> authoritative")
        let custom = WishItem(title: "T", artist: "A", source: .custom)
        try t.expectEqual(custom.identity.provenance, .userEdited, "custom -> userEdited")
    }

    t.test("a replacement wish remembers the track it supersedes") {
        let dir = try TestSupport.tempDir("wish-replace")
        let store = try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite"))
        let plain = WishItem(title: "Xtal", artist: "Aphex Twin")
        let replacing = WishItem(title: "Vordhosbn", artist: "Aphex Twin", replacesAssetID: 42)
        _ = try store.addWish(plain)
        _ = try store.addWish(replacing)

        let all = try store.allWishes()
        let back = all.first { $0.title == "Vordhosbn" }
        try t.expectEqual(back?.replacesAssetID, 42, "the asset being replaced survives a round trip")
        try t.expect(back?.isReplacement == true, "and reads as a replacement")
        try t.expect(all.first { $0.title == "Xtal" }?.isReplacement == false,
                     "an ordinary wish is not one")
    }

    t.test("replacing an asset moves playlists, the pin and the device row across") {
        let dir = try TestSupport.tempDir("replace-asset")
        let store = try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite"))
        func makeAsset(_ title: String, hash: String) throws -> Int64 {
            let identID = try store.upsertIdentity(
                TrackIdentity(title: title, artist: "Aphex Twin", durationSec: 100, provenance: .userEdited))
            return try store.insertAsset(AudioAsset(identityID: identID, masterPath: "/tmp/\(hash).mp3",
                format: "mp3", bitrateKbps: 320, sampleRate: 44100, sizeBytes: 1000,
                contentHash: hash, source: .downloaded))
        }
        let oldID = try makeAsset("Vordhosbn", hash: "old")
        let newID = try makeAsset("Vordhosbn (2)", hash: "new")
        let keepID = try makeAsset("Avril 14th", hash: "keep")
        let pl = try store.createPlaylist(name: "drukqs", syncToDevice: true)
        try store.addToPlaylist(playlistID: pl, assetID: oldID, position: 0)
        try store.addToPlaylist(playlistID: pl, assetID: keepID, position: 1)
        try store.pin(assetID: oldID, true)
        try store.setDeviceTrack(DeviceTrackRow(deviceUUID: "UUID", relativePath: "A\\B\\old.mp3",
            assetID: oldID, transcodedBitrate: 192, contentHash: "old", sizeBytes: 10, recipe: "r1"))

        let result = try store.replaceAsset(old: oldID, with: newID)
        try t.expectEqual(result.playlists, 1, "one playlist entry moved")
        try t.expect(result.wasPinned, "the pin moved")
        try t.expectEqual(result.deviceRows, 1, "one device row re-pointed")

        let items = try store.playlistItems(pl)
        try t.expectEqual(items.count, 2, "the playlist is the same length")
        try t.expectEqual(items.first?.id, newID, "the new file took the old one's place")
        try t.expect(try store.pinnedAssets().contains { $0.id == newID }, "the new file is pinned")
        try t.expect(!(try store.pinnedAssets().contains { $0.id == oldID }), "the old one isn't")
        let row = try store.deviceTracks("UUID").first
        try t.expectEqual(row?.assetID, newID, "the device row points at the new file")
        try t.expectEqual(row?.contentHash, LibraryStore.staleHash, "and is stale, so it re-sends")
        try t.expect(try store.asset(oldID) == nil, "the old asset is gone")
        try t.expect(try store.asset(keepID) != nil, "other tracks are untouched")
    }

    t.test("replacing a track that is in a playlist twice over doesn't duplicate it") {
        let dir = try TestSupport.tempDir("replace-dupe")
        let store = try LibraryStore(dbURL: dir.appendingPathComponent("lib.sqlite"))
        func makeAsset(_ title: String) throws -> Int64 {
            let identID = try store.upsertIdentity(
                TrackIdentity(title: title, artist: "A", durationSec: 10, provenance: .userEdited))
            return try store.insertAsset(AudioAsset(identityID: identID, masterPath: "/tmp/\(title).mp3",
                format: "mp3", bitrateKbps: 320, sampleRate: 44100, sizeBytes: 1,
                contentHash: title, source: .downloaded))
        }
        // The user already owns the version they are replacing the old file with, and both are in
        // the same playlist: the old entry has to go rather than leaving the track listed twice.
        let oldID = try makeAsset("old"), newID = try makeAsset("new")
        let pl = try store.createPlaylist(name: "p", syncToDevice: false)
        try store.addToPlaylist(playlistID: pl, assetID: oldID, position: 0)
        try store.addToPlaylist(playlistID: pl, assetID: newID, position: 1)

        _ = try store.replaceAsset(old: oldID, with: newID)
        let items = try store.playlistItems(pl)
        try t.expectEqual(items.count, 1, "one entry, not two")
        try t.expectEqual(items.first?.id, newID, "and it is the surviving file")
    }
}