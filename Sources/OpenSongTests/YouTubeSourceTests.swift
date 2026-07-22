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
    t.test("LIVE: real yt-dlp search returns candidates") {
        guard ProcessInfo.processInfo.environment["OPENSONG_LIVE"] == "1" else {
            try t.skip("set OPENSONG_LIVE=1 for live yt-dlp search")
        }
        let source = YtDlpSource(ytDlpPath: "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp")
        let results = try awaitSync { try await source.search("Aphex Twin Avril 14th", limit: 3) }
        try t.expect(!results.isEmpty, "got live candidates")
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
