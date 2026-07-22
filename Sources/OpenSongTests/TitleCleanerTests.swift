import OpenSongCore

func registerTitleCleanerTests() {
    t.test("cleans Artist - Title (Official Video)") {
        let r = TitleCleaner.parse("Aphex Twin - Vordhosbn (Official Video)")
        try t.expectEqual(r.artist, "Aphex Twin", "artist")
        try t.expectEqual(r.title, "Vordhosbn", "title")
        try t.expectEqual(r.query, "Aphex Twin Vordhosbn", "query")
    }
    t.test("strips brackets, HD/4K, remaster") {
        let r = TitleCleaner.parse("Gorillaz - Feel Good Inc. [HD] (Official Music Video) 4K Remaster 2020")
        try t.expectEqual(r.artist, "Gorillaz", "artist")
        try t.expect(r.title.contains("Feel Good Inc."), "title kept (got \(r.title))")
        try t.expect(!r.title.lowercased().contains("remaster"), "remaster stripped")
        try t.expect(!r.title.contains("["), "brackets stripped")
    }
    t.test("drops trailing | channel segment") {
        let r = TitleCleaner.parse("Frank Ocean - Ivy | Blonded Radio")
        try t.expectEqual(r.artist, "Frank Ocean", "artist")
        try t.expectEqual(r.title, "Ivy", "title")
    }
    t.test("keeps feat in title") {
        let r = TitleCleaner.parse("Stan Getz - Retrato Em Branco e Preto (feat. Stan Getz)")
        try t.expect(r.title.contains("feat. Stan Getz"), "feat kept (got \(r.title))")
    }
    t.test("no hyphen -> whole thing is the title") {
        let r = TitleCleaner.parse("some random song title")
        try t.expect(r.artist == nil, "no artist")
        try t.expectEqual(r.title, "some random song title", "title = whole")
    }
}
