import Foundation

public struct Candidate: Sendable, Equatable, Identifiable {
    public var id: String { videoID }
    public var videoID: String
    public var url: URL
    public var title: String
    public var channel: String
    public var durationSec: Double
    public var viewCount: Int?
    public var thumbnailURL: URL?
    public init(videoID: String, url: URL, title: String, channel: String, durationSec: Double,
                viewCount: Int? = nil, thumbnailURL: URL? = nil) {
        self.videoID = videoID; self.url = url; self.title = title; self.channel = channel
        self.durationSec = durationSec; self.viewCount = viewCount; self.thumbnailURL = thumbnailURL
    }
}

/// Abstracts YouTube search + download so the acquisition pipeline is testable without
/// hitting the network (tests inject a stub; production uses `YtDlpSource`).
public protocol YouTubeSource: Sendable {
    func search(_ term: String, limit: Int) async throws -> [Candidate]
    func download(_ url: URL, to dst: URL) async throws
}

public struct YtDlpSource: YouTubeSource {
    public var ytDlpPath: String
    public init(ytDlpPath: String = "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp") {
        self.ytDlpPath = ytDlpPath
    }

    public func search(_ term: String, limit: Int) async throws -> [Candidate] {
        // One compact JSON object per result (no full playlist extraction).
        let r = try Shell.run(ytDlpPath, [
            "--dump-json", "--flat-playlist", "--no-warnings",
            "ytsearch\(limit):\(term)"
        ])
        guard r.status == 0 else {
            throw NSError(domain: "YtDlp", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
        return Self.parseSearchJSON(r.stdout)
    }

    public func download(_ url: URL, to dst: URL) async throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let r = try Shell.run(ytDlpPath, [
            "-f", "bestaudio", "-x", "--audio-format", "m4a", "--audio-quality", "0",
            "--no-warnings", "-o", dst.path, url.absoluteString
        ])
        guard r.status == 0 else {
            throw NSError(domain: "YtDlp", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
    }

    /// Parse yt-dlp `--dump-json` output (one JSON object per line) into candidates.
    public static func parseSearchJSON(_ data: Data) -> [Candidate] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Candidate] = []
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            let title = (obj["title"] as? String) ?? id
            let channel = (obj["channel"] as? String) ?? (obj["uploader"] as? String) ?? ""
            let duration = (obj["duration"] as? Double) ?? Double((obj["duration"] as? Int) ?? 0)
            let views = (obj["view_count"] as? Int)
            let url = (obj["url"] as? String).flatMap(URL.init) ?? URL(string: "https://www.youtube.com/watch?v=\(id)")!
            let thumb = (obj["thumbnail"] as? String).flatMap(URL.init)
            out.append(Candidate(videoID: id, url: url, title: title, channel: channel,
                                 durationSec: duration, viewCount: views, thumbnailURL: thumb))
        }
        return out
    }
}
