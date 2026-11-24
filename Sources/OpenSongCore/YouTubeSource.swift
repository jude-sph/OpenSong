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
    /// Resolve a directly-streamable audio URL for a video (used for in-app previews so the
    /// user can listen before committing to a full download). No file is written.
    func streamURL(_ url: URL) async throws -> URL
}

public extension YouTubeSource {
    func streamURL(_ url: URL) async throws -> URL {
        throw NSError(domain: "YouTubeSource", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Streaming preview not supported by this source."])
    }
}

public struct YtDlpSource: YouTubeSource {
    public var ytDlpPath: String
    /// Where yt-dlp should find ffmpeg for audio extraction. Passed via `--ffmpeg-location`
    /// because a GUI app launched from Finder inherits a minimal PATH that excludes
    /// /opt/homebrew/bin — without this, `-x --audio-format m4a` fails and downloads error out.
    public var ffmpegPath: String?
    public init(ytDlpPath: String = "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp",
                ffmpegPath: String? = nil) {
        self.ytDlpPath = ytDlpPath
        self.ffmpegPath = ffmpegPath
    }

    public func search(_ term: String, limit: Int) async throws -> [Candidate] {
        // One compact JSON object per result (no full playlist extraction).
        let r = try await Shell.runAsync(ytDlpPath, [
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
        var args = ["--no-playlist", "-f", "bestaudio", "-x", "--audio-format", "m4a", "--audio-quality", "0",
                    "--no-warnings", "-o", dst.path]
        if let ffmpegPath, !ffmpegPath.isEmpty {
            // yt-dlp accepts either the ffmpeg binary or its directory here. With ffmpeg present
            // we also embed the video's thumbnail as cover art (converted to jpg so the m4a
            // container accepts it) — many uploads carry the real album cover as the thumbnail.
            args.insert(contentsOf: ["--ffmpeg-location", ffmpegPath], at: 0)
            args += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
        }
        args.append(url.absoluteString)
        let r = try await Shell.runAsync(ytDlpPath, args)
        guard r.status == 0 else {
            throw NSError(domain: "YtDlp", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: "yt-dlp download failed: \(r.stderrString)"])
        }
    }

    /// List a YouTube playlist's videos (flat, one JSON object per entry). Returns the playlist
    /// title (from the entries) plus the candidates. Because these are already the source URLs,
    /// selected entries can be downloaded directly without a separate search step.
    public func playlistEntries(_ url: URL) throws -> (title: String, entries: [Candidate]) {
        let r = try Shell.run(ytDlpPath, [
            "--dump-json", "--flat-playlist", "--no-warnings", url.absoluteString
        ])
        guard r.status == 0 else {
            throw NSError(domain: "YtDlp", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
        let title = Self.playlistTitle(r.stdout) ?? "YouTube playlist"
        return (title, Self.parseSearchJSON(r.stdout))
    }

    /// Pull `playlist_title` (or `playlist`) from the first entry line.
    public static func playlistTitle(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }
            if let t = (obj["playlist_title"] as? String) ?? (obj["playlist"] as? String) { return t }
        }
        return nil
    }

    /// Best-audio quality for a video (no download): e.g. "~128k AAC". nil if it can't be read.
    public func audioQuality(_ url: URL) async throws -> String? {
        let r = try await Shell.runAsync(ytDlpPath, [
            "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio/best", "--skip-download", "--no-warnings",
            "--print", "%(abr)s|%(acodec)s", url.absoluteString
        ])
        guard r.status == 0 else { return nil }
        let line = r.stdoutString.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        let abr = parts.first.flatMap { Double($0) }
        let acodec = parts.count > 1 ? parts[1].lowercased() : ""
        let codec: String = acodec.contains("mp4a") || acodec.contains("aac") ? "AAC"
            : acodec.contains("opus") ? "Opus" : acodec.contains("mp3") ? "MP3"
            : acodec.contains("vorbis") ? "Vorbis" : ""
        if let abr, abr > 0 {
            return codec.isEmpty ? "~\(Int(abr.rounded()))k" : "~\(Int(abr.rounded()))k \(codec)"
        }
        return codec.isEmpty ? nil : codec
    }

    /// Resolve a direct audio stream URL via `yt-dlp -g` (get-url) with no download. The
    /// returned googlevideo URL is short-lived but fine for immediate playback.
    public func streamURL(_ url: URL) async throws -> URL {
        // Prefer m4a/AAC: AVPlayer can't decode YouTube's default WebM/Opus (itag 251) audio,
        // so it silently fails to play. itag 140 (audio/mp4) streams fine.
        let r = try await Shell.runAsync(ytDlpPath, [
            "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/best",
            "-g", "--no-playlist", "--no-warnings", url.absoluteString
        ])
        guard r.status == 0 else {
            throw NSError(domain: "YtDlp", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
        let out: String = r.stdoutString
        let lines: [Substring] = out.split(whereSeparator: { (ch: Character) -> Bool in ch == "\n" || ch == "\r" })
        let first: String = lines.first.map { String($0) } ?? ""
        let trimmed: String = first.trimmingCharacters(in: CharacterSet.whitespaces)
        guard let direct = URL(string: trimmed) else {
            throw NSError(domain: "YtDlp", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "yt-dlp returned no stream URL."])
        }
        // YouTube answers 403 for the first few seconds after issuing a stream URL (yt-dlp's own
        // downloads "sleep as required by the site" for the same reason). AVPlayer fails on that
        // first 403 and never retries, so wait until the URL is actually being served.
        _ = await Self.waitUntilServed(direct)
        return direct
    }

    /// Probe `url` with a 1-byte range request until it stops answering 403/429, or `timeout`
    /// passes. Returns whether it became playable. `probe` is injectable for tests.
    public static func waitUntilServed(
        _ url: URL, timeout: Double = 15, interval: Double = 0.5,
        probe: @Sendable (URL) async -> Int? = Self.probeStatus
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let code = await probe(url), code != 403, code != 429 { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// HTTP status for a 1-byte range GET of `url` (nil on network error).
    @Sendable public static func probeStatus(_ url: URL) async -> Int? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
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
