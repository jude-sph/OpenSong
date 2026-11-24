import OpenSongCore

func registerAlbumArtistMergeTests() {
    t.test("collaboration credits collapse onto the album's primary artist") {
        let map = AlbumArtistMerge.canonicalArtists(["Gorillaz", "Gorillaz & De La Soul", "Gorillaz & MF DOOM"])
        try t.expectEqual(map["Gorillaz & De La Soul"], "Gorillaz", "& guest merged")
        try t.expectEqual(map["Gorillaz & MF DOOM"], "Gorillaz", "second guest merged")
        try t.expect(map["Gorillaz"] == nil, "primary artist unchanged")
    }
    t.test("an ampersand in the artist's own name survives without evidence") {
        let map = AlbumArtistMerge.canonicalArtists(["Simon & Garfunkel"])
        try t.expect(map.isEmpty, "nothing to merge onto")
        let ewf = AlbumArtistMerge.canonicalArtists(["Earth, Wind & Fire", "Earth, Wind & Fire & The Emotions"])
        try t.expectEqual(ewf["Earth, Wind & Fire & The Emotions"], "Earth, Wind & Fire", "only the guest suffix merges")
        try t.expect(ewf["Earth, Wind & Fire"] == nil, "band name kept")
    }
    t.test("other separators: comma, feat., with, x, and") {
        try t.expectEqual(AlbumArtistMerge.canonicalArtists(["Kanye West", "Kanye West, Jay-Z"])["Kanye West, Jay-Z"],
                          "Kanye West", "comma")
        try t.expectEqual(AlbumArtistMerge.canonicalArtists(["Drake", "Drake feat. Future"])["Drake feat. Future"],
                          "Drake", "feat.")
        try t.expectEqual(AlbumArtistMerge.canonicalArtists(["Burial", "Burial with Four Tet"])["Burial with Four Tet"],
                          "Burial", "with")
        try t.expectEqual(AlbumArtistMerge.canonicalArtists(["Skepta", "Skepta x A$AP Rocky"])["Skepta x A$AP Rocky"],
                          "Skepta", "x")
        try t.expectEqual(AlbumArtistMerge.canonicalArtists(["Florence", "Florence and the Machine"])["Florence and the Machine"],
                          "Florence", "and")
    }
    t.test("only a real separator plus a named guest merges") {
        try t.expect(!AlbumArtistMerge.isCollaboration("Gorillazz", on: "Gorillaz"), "no separator")
        try t.expect(!AlbumArtistMerge.isCollaboration("Gorillaz &", on: "Gorillaz"), "no guest named")
        try t.expect(!AlbumArtistMerge.isCollaboration("Gorillaz", on: "Gorillaz"), "same credit")
        try t.expect(!AlbumArtistMerge.isCollaboration("Gorilla", on: "Gorillaz"), "shorter credit")
        try t.expect(AlbumArtistMerge.isCollaboration("gorillaz & de la soul", on: "Gorillaz"), "case-insensitive")
    }
    t.test("chains collapse to the shortest primary credit") {
        let map = AlbumArtistMerge.canonicalArtists(["A", "A & B", "A & B & C"])
        try t.expectEqual(map["A & B"], "A", "one hop")
        try t.expectEqual(map["A & B & C"], "A", "two hops resolve to the root")
    }
}
