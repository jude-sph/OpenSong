import Foundation
import OpenSongCore

/// Shared test helpers: real audio/image generation via ffmpeg, and temp dirs.
enum TestSupport {
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let ffprobe = "/opt/homebrew/bin/ffprobe"

    /// A fresh unique temp directory (caller may clean up; OS clears /tmp anyway).
    static func tempDir(_ label: String = "opensong") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Generate a real MP3 of `seconds` at `bitrate` kbps with the given tags.
    /// `tone: true` produces a 440 Hz sine (real signal, for loudnorm tests);
    /// otherwise silence.
    @discardableResult
    static func makeMP3(at url: URL, title: String, artist: String, album: String? = nil,
                        track: Int? = nil, bitrateKbps: Int = 192, seconds: Double = 1,
                        tone: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let source = tone ? "sine=frequency=440:sample_rate=44100"
                          : "anullsrc=r=44100:cl=stereo"
        var args = ["-y", "-f", "lavfi", "-i", source,
                    "-t", String(seconds), "-c:a", "libmp3lame", "-b:a", "\(bitrateKbps)k",
                    "-id3v2_version", "3",
                    "-metadata", "title=\(title)", "-metadata", "artist=\(artist)"]
        if let album { args += ["-metadata", "album=\(album)"] }
        if let track { args += ["-metadata", "track=\(track)"] }
        args.append(url.path)
        let r = try Shell.run(ffmpeg, args)
        guard r.status == 0 else { throw NSError(domain: "TestSupport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg mp3 failed: \(r.stderrString)"]) }
        return url
    }

    /// Generate a real FLAC (lossless) file.
    @discardableResult
    static func makeFLAC(at url: URL, title: String, artist: String, seconds: Double = 1) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let r = try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", String(seconds), "-c:a", "flac",
            "-metadata", "title=\(title)", "-metadata", "artist=\(artist)", url.path])
        guard r.status == 0 else { throw NSError(domain: "TestSupport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg flac failed: \(r.stderrString)"]) }
        return url
    }

    /// Generate a small solid-color PNG.
    @discardableResult
    static func makePNG(at url: URL, color: String = "red", size: Int = 64) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let r = try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=\(color):s=\(size)x\(size)",
            "-frames:v", "1", url.path])
        guard r.status == 0 else { throw NSError(domain: "TestSupport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg png failed: \(r.stderrString)"]) }
        return url
    }
}
