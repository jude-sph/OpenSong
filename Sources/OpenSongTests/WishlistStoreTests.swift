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
}
