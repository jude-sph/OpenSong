import Foundation
import OpenSongCore

private let cannedYtDlp = """
{"id":"abc123","title":"Aphex Twin - Vordhosbn (Official Video)","channel":"WARP","duration":291,"view_count":1200000,"url":"https://www.youtube.com/watch?v=abc123","thumbnail":"https://i.ytimg.com/vi/abc123/hq.jpg"}
{"id":"def456","title":"Vordhosbn (Live)","uploader":"Fan Channel","duration":400,"url":"https://www.youtube.com/watch?v=def456"}
""".data(using: .utf8)!

/// Stub source used across acquisition tests: returns fixed candidates and "downloads"
/// by copying a pre-made file.
struct StubYouTubeSource: YouTubeSource {
    var candidates: [Candidate]
    var fileToServe: URL?
    func search(_ term: String, limit: Int) async throws -> [Candidate] { candidates }
    func download(_ url: URL, to dst: URL) async throws {
        guard let src = fileToServe else { throw NSError(domain: "stub", code: 1) }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

func registerYouTubeSourceTests() {
    t.test("stream URL waits out YouTube's initial 403s") {
        let calls = Counter()
        let ok = await YtDlpSource.waitUntilServed(URL(string: "https://x")!, timeout: 5, interval: 0.01) { _ in
            calls.next() < 3 ? 403 : 206
        }
        try t.expect(ok, "became playable")
        try t.expectEqual(calls.value, 4, "probed until the 206")
    }
    t.test("stream URL wait gives up after the timeout") {
        let ok = await YtDlpSource.waitUntilServed(URL(string: "https://x")!, timeout: 0.05, interval: 0.01) { _ in 403 }
        try t.expect(!ok, "never playable")
    }
    t.test("parses yt-dlp dump-json lines into candidates") {
        let c = YtDlpSource.parseSearchJSON(cannedYtDlp)
        try t.expectEqual(c.count, 2, "two candidates")
        try t.expectEqual(c[0].videoID, "abc123", "id")
        try t.expectEqual(c[0].channel, "WARP", "channel")
        try t.expect(abs(c[0].durationSec - 291) < 0.5, "duration")
        try t.expectEqual(c[0].viewCount, 1_200_000, "views")
        try t.expectEqual(c[1].channel, "Fan Channel", "uploader fallback")
        try t.expect(c[1].thumbnailURL == nil, "no thumb on 2nd")
    }
    t.test("extracts playlist title from flat-playlist entries") {
        let data = """
        {"id":"a","title":"Song A","playlist_title":"lo-fi beats","duration":200,"url":"https://youtu.be/a"}
        {"id":"b","title":"Song B","playlist_title":"lo-fi beats","duration":210,"url":"https://youtu.be/b"}
        """.data(using: .utf8)!
        try t.expectEqual(YtDlpSource.playlistTitle(data), "lo-fi beats", "title from entries")
        try t.expectEqual(YtDlpSource.parseSearchJSON(data).count, 2, "entries parse")
    }
    t.test("LIVE: real yt-dlp search returns candidates") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 for live yt-dlp search")
        }
        let source = YtDlpSource(ytDlpPath: "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp")
        let results = try awaitSync { try await source.search("Aphex Twin Avril 14th", limit: 3) }
        try t.expect(!results.isEmpty, "got live candidates")
    }
    t.test("LIVE: a pasted Mix link previews just its own video, quickly") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 for live yt-dlp stream resolve")
        }
        // `&list=RD…` is a YouTube Mix (thousands of entries); without --no-playlist yt-dlp
        // resolves every one and the preview never starts.
        let source = YtDlpSource(ytDlpPath: "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp")
        let url = URL(string: "https://www.youtube.com/watch?v=EogQotDVGo4&list=RDEogQotDVGo4&start_radio=1")!
        let t0 = Date()
        let stream = try await source.streamURL(url)
        let secs = Date().timeIntervalSince(t0)
        try t.expect(stream.host?.contains("googlevideo") == true, "direct stream URL")
        try t.expect(secs < 20, "resolved in \(secs)s")
        try t.expectEqual(await YtDlpSource.probeStatus(stream), 206, "served")
    }
}

/// Bridge async to the sync harness for the occasional non-t.test async call.
func awaitSync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task { do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }; sem.signal() }
    sem.wait()
    return try box.get()
}
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var r: Result<T, Error>?
    func set(_ v: Result<T, Error>) { lock.lock(); r = v; lock.unlock() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try r!.get() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { n += 1; lock.unlock() }; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

func registerPastedLinkTests() {
    t.test("pasted links: SoundCloud tracks vs sets/profiles vs YouTube") {
        try t.expectEqual(PastedLink.classify("https://soundcloud.com/forss/flickermood"), .soundcloudTrack, "track")
        try t.expectEqual(PastedLink.classify(" https://m.soundcloud.com/forss/flickermood?si=abc&utm_source=clipboard "), .soundcloudTrack, "mobile + tracking params")
        try t.expectEqual(PastedLink.classify("https://soundcloud.com/forss/flickermood/s-AbCdE"), .soundcloudTrack, "private track")
        try t.expectEqual(PastedLink.classify("https://on.soundcloud.com/xyz123"), .soundcloudTrack, "short link")
        try t.expectEqual(PastedLink.classify("https://soundcloud.com/forss/sets/soulhunt"), .soundcloudCollection, "set")
        try t.expectEqual(PastedLink.classify("https://soundcloud.com/forss"), .soundcloudCollection, "profile")
        try t.expectEqual(PastedLink.classify("https://soundcloud.com/forss/likes"), .soundcloudCollection, "likes")
        try t.expectEqual(PastedLink.classify("https://www.youtube.com/watch?v=abc"), .youtube, "youtube")
        try t.expectEqual(PastedLink.classify("https://youtu.be/abc"), .youtube, "youtu.be")
        try t.expectEqual(PastedLink.classify("not a link"), .other, "junk")
    }
    t.test("pasted links: SoundCloud artist falls back to tag, then uploader") {
        let a = PastedLink.suggestedMeta(rawTitle: "Flickermood", artistTag: "NA", uploader: "Forss", link: .soundcloudTrack)
        try t.expectEqual(a.title, "Flickermood", "title"); try t.expectEqual(a.artist, "Forss", "uploader")
        let b = PastedLink.suggestedMeta(rawTitle: "Flickermood", artistTag: "Forss Real", uploader: "forss-uploads", link: .soundcloudTrack)
        try t.expectEqual(b.artist, "Forss Real", "artist tag wins over uploader")
        let c = PastedLink.suggestedMeta(rawTitle: "Burial - Archangel", artistTag: "", uploader: "someone", link: .soundcloudTrack)
        try t.expectEqual(c.artist, "Burial", "title's own artist wins")
        let d = PastedLink.suggestedMeta(rawTitle: "Archangel", artistTag: "", uploader: "SomeChannel", link: .youtube)
        try t.expectEqual(d.artist, "", "YouTube keeps old behaviour (channel isn't the artist)")
    }
}
