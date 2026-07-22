import Foundation

public struct TranscodeSettings: Sendable, Equatable {
    public var format: String        // "mp3" (device target)
    public var bitrateKbps: Int      // e.g. 192
    public var loudnessNormalize: Bool
    public init(format: String = "mp3", bitrateKbps: Int = 192, loudnessNormalize: Bool = true) {
        self.format = format; self.bitrateKbps = bitrateKbps; self.loudnessNormalize = loudnessNormalize
    }
}

/// Transcodes masters to the device target format and writes ID3 tags, using ffmpeg.
public struct Transcoder: Sendable {
    public var ffmpegPath: String
    public var probe: AudioProbe
    public init(ffmpegPath: String = "/opt/homebrew/bin/ffmpeg", probe: AudioProbe = AudioProbe()) {
        self.ffmpegPath = ffmpegPath; self.probe = probe
    }

    public enum TranscodeError: Error, CustomStringConvertible {
        case failed(String)
        public var description: String {
            switch self { case .failed(let m): return "ffmpeg failed: \(m)" }
        }
    }

    /// True unless the master is already MP3 at or below the target bitrate
    /// (in which case a plain copy avoids pointless generation loss).
    public func needsTranscode(_ src: ProbeResult, _ s: TranscodeSettings) -> Bool {
        !(src.codec == "mp3" && src.bitrateKbps <= s.bitrateKbps)
    }

    /// ID3 metadata arguments common to transcode and tag-write.
    private func metadataArgs(_ i: TrackIdentity) -> [String] {
        var args = ["-metadata", "title=\(i.title)", "-metadata", "artist=\(i.artist)"]
        args += ["-metadata", "album_artist=\(effectiveAlbumArtist(i))"]
        if let album = i.album { args += ["-metadata", "album=\(album)"] }
        if let track = i.trackNumber { args += ["-metadata", "track=\(track)"] }
        if let disc = i.discNumber { args += ["-metadata", "disc=\(disc)"] }
        if let genre = i.genre { args += ["-metadata", "genre=\(genre)"] }
        if let year = i.year { args += ["-metadata", "date=\(year)"] }
        return args
    }

    /// Transcode `src` → `dst` (MP3) applying loudness normalization and tags.
    public func transcode(from src: URL, to dst: URL, tags: TrackIdentity,
                          settings: TranscodeSettings) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var args = ["-y", "-i", src.path]
        if settings.loudnessNormalize {
            args += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
        }
        args += ["-map", "0:a:0", "-c:a", "libmp3lame", "-b:a", "\(settings.bitrateKbps)k",
                 "-ar", "44100", "-id3v2_version", "3"]
        args += metadataArgs(tags)
        args.append(dst.path)
        let r = try Shell.run(ffmpegPath, args)
        guard r.status == 0 else { throw TranscodeError.failed(r.stderrString) }
    }

    /// Rewrite ID3 tags in place (stream copy, no re-encode).
    public func writeTags(_ url: URL, _ tags: TrackIdentity) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".ostmp-\(UUID().uuidString).mp3")
        var args = ["-y", "-i", url.path, "-map", "0", "-c", "copy", "-id3v2_version", "3"]
        args += metadataArgs(tags)
        args.append(tmp.path)
        let r = try Shell.run(ffmpegPath, args)
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw TranscodeError.failed(r.stderrString)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Copy a master unchanged to `dst` (used when needsTranscode is false).
    public func copyMaster(from src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}
