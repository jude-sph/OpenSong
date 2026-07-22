import Foundation

/// Resolves cover art from ranked sources: embedded art, downloaded official art
/// (iTunes), or a user-supplied image; and embeds art into audio files.
public struct ArtworkResolver: Sendable {
    public var ffmpegPath: String
    public var http: HTTPClient
    public init(ffmpegPath: String = "/opt/homebrew/bin/ffmpeg", http: HTTPClient = URLSessionHTTPClient()) {
        self.ffmpegPath = ffmpegPath; self.http = http
    }

    /// Extract embedded cover art to `dst` (PNG). Returns false if the file has no art.
    @discardableResult
    public func extractEmbedded(from url: URL, to dst: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let r = try Shell.run(ffmpegPath, ["-y", "-i", url.path, "-an", "-vframes", "1", dst.path])
        var sizeBytes = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path),
           let s = attrs[.size] as? Int { sizeBytes = s }
        let ok = r.status == 0 && sizeBytes > 0
        if !ok { try? FileManager.default.removeItem(at: dst) }
        return ok
    }

    /// Download art from a URL to `dst`.
    public func download(_ url: URL, to dst: URL) async throws {
        let data = try await http.get(url)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: dst)
    }

    /// Embed `art` as the front cover of `audio` (in place). Extension-preserving.
    public func embed(_ art: URL, into audio: URL) throws {
        let ext = audio.pathExtension.isEmpty ? "mp3" : audio.pathExtension
        let tmp = audio.deletingLastPathComponent()
            .appendingPathComponent(".osart-\(UUID().uuidString).\(ext)")
        var args = ["-y", "-i", audio.path, "-i", art.path,
                    "-map", "0:a", "-map", "1:v", "-c:a", "copy", "-c:v", "copy",
                    "-disposition:v", "attached_pic",
                    "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        if ext.lowercased() == "mp3" { args += ["-id3v2_version", "3"] }
        args.append(tmp.path)
        let r = try Shell.run(ffmpegPath, args)
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "ArtworkResolver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "embed failed: \(r.stderrString)"])
        }
        _ = try FileManager.default.replaceItemAt(audio, withItemAt: tmp)
    }
}
