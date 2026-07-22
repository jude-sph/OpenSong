import Foundation
import OpenSongCore

private func makeCoordinator(_ source: YouTubeSource, libraryRoot: URL) throws -> (AcquireCoordinator, LibraryStore) {
    let dbDir = try TestSupport.tempDir("acq-db")
    let store = try LibraryStore(dbURL: dbDir.appendingPathComponent("lib.sqlite"))
    let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
    let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
    let importer = Importer(store: store, probe: probe, tagger: transcoder,
                            resolver: MetadataResolver(http: TestSupport.StubHTTPClient(data: Data("{\"results\":[]}".utf8))),
                            libraryRoot: libraryRoot)
    let coord = AcquireCoordinator(
        store: store, source: source, importer: importer,
        artwork: ArtworkResolver(ffmpegPath: TestSupport.ffmpeg),
        spectral: SpectralAnalyzer(ffmpegPath: TestSupport.ffmpeg),
        fingerprinter: Fingerprinter(fpcalcPath: "/opt/homebrew/bin/fpcalc"),
        acoustid: AcoustIDClient(http: TestSupport.StubHTTPClient(data: Data("{}".utf8))),
        probe: probe, settings: AcquireSettings(acoustidAPIKey: "", searchLimit: 5))
    return (coord, store)
}

func registerAcquireCoordinatorTests() {
    t.test("candidates ranked by duration match with confidence") {
        let cands = [
            Candidate(videoID: "live", url: URL(string: "https://y/live")!, title: "Avril 14th (Live)", channel: "x", durationSec: 200),
            Candidate(videoID: "studio", url: URL(string: "https://y/studio")!, title: "Aphex Twin Avril 14th", channel: "x", durationSec: 125),
        ]
        let (coord, _) = try makeCoordinator(StubYouTubeSource(candidates: cands, fileToServe: nil), libraryRoot: try TestSupport.tempDir("lib"))
        let wish = WishItem(title: "Avril 14th", artist: "Aphex Twin", durationSec: 125)
        let ranked = try awaitSync { try await coord.candidates(for: wish) }
        try t.expectEqual(ranked.first?.candidate.videoID, "studio", "closest duration first")
        try t.expectEqual(ranked.first?.confidence, .high, "high confidence (duration + title)")
    }

    t.test("acquire downloads, stamps KNOWN metadata, imports, verifies") {
        // The stub 'downloads' by serving a generated m4a whose own tags are WRONG,
        // proving we stamp the wish identity, not the file/video title.
        let served = try TestSupport.tempDir("served").appendingPathComponent("wrong.m4a")
        let r = try Shell.run(TestSupport.ffmpeg, ["-y", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=44100", "-t", "3", "-c:a", "aac", "-b:a", "160k",
            "-metadata", "title=WRONG TITLE", "-metadata", "artist=WRONG ARTIST", served.path])
        try t.expectEqual(r.status, 0, "made served m4a")

        let cand = Candidate(videoID: "v", url: URL(string: "https://y/v")!, title: "Aphex Twin - Avril 14th", channel: "WARP", durationSec: 3)
        let source = StubYouTubeSource(candidates: [cand], fileToServe: served)
        let lib = try TestSupport.tempDir("lib")
        let (coord, store) = try makeCoordinator(source, libraryRoot: lib)
        let wish = WishItem(title: "Avril 14th", artist: "Aphex Twin", album: "Drukqs", durationSec: 3, source: .appleMusic)
        let wishID = try store.addWish(wish)
        var wtmp = wish; wtmp.id = wishID
        let w = wtmp
        let dlDir = try TestSupport.tempDir("dl")
        let (asset, verify) = try awaitSync { try await coord.acquire(w, chosen: cand, art: nil, downloadDir: dlDir) }
        // Master placed under the KNOWN identity, not "WRONG ARTIST".
        try t.expect(asset.masterPath.contains("Aphex Twin/Drukqs/Avril 14th"), "placed by known identity (got \(asset.masterPath))")
        try t.expectEqual(asset.source, .downloaded, "source = downloaded")
        // Indexed identity is correct.
        let indexed = try store.allAssetsWithIdentity()
        try t.expectEqual(indexed.first?.1.title, "Avril 14th", "stamped known title")
        // Wish marked downloaded + linked.
        let doneWish = try store.allWishes().first { $0.id == wishID }
        try t.expectEqual(doneWish?.state, .downloaded, "wish -> downloaded")
        try t.expectEqual(doneWish?.assetID, asset.id, "wish linked to asset")
        // Verify populated (duration matches; no AcoustID key so acoustid nil).
        try t.expect(verify.durationOK, "duration verified")
        try t.expect(verify.acoustidScore == nil, "acoustid skipped without key")
    }
}
