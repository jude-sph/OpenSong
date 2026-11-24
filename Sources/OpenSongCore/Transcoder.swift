import Foundation

public struct TranscodeSettings: Sendable, Equatable {
    public var format: String        // "mp3" (device target)
    public var bitrateKbps: Int      // e.g. 192
    public var loudnessNormalize: Bool
    public var embedArtwork: Bool    // false for screenless players (iPod shuffle) — just wasted bytes
    public init(format: String = "mp3", bitrateKbps: Int = 192, loudnessNormalize: Bool = true,
                embedArtwork: Bool = true) {
        self.format = format; self.bitrateKbps = bitrateKbps
        self.loudnessNormalize = loudnessNormalize; self.embedArtwork = embedArtwork
    }

    /// Bump when the *way* a device file is produced changes in a way that should rebuild files
    /// already on the device — e.g. v2 writes front-cover, baseline 4:2:0 JPEG art (v0.3.31).
    public static let recipeVersion = 2

    /// Fingerprint of these settings, stored per device track. A file whose stored recipe differs
    /// from the current one is stale even if its master hasn't changed, so the next sync rebuilds
    /// it — no "re-send" button to remember, and changing the target bitrate now takes effect too.
    public var deviceRecipe: String {
        "v\(Self.recipeVersion)/\(format)/\(bitrateKbps)k/ln\(loudnessNormalize ? 1 : 0)/art\(embedArtwork ? 1 : 0)"
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

    /// True when the file carries an embedded cover image.
    public func hasArtwork(_ url: URL) -> Bool { probe.attachedPictureCodec(url) != nil }

    /// ffmpeg arguments that re-encode the source's attached picture into cover art the Walkman
    /// will actually display. Empty when there's no picture (or artwork is switched off).
    ///
    /// The NW-E394 is fussy in three ways that ffmpeg gets "wrong" by default:
    /// * the APIC picture type must be **3 (front cover)** — ffmpeg writes 0 ("Other") unless the
    ///   stream's `comment` metadata says otherwise, and the player ignores non-front covers;
    /// * the JPEG must be **baseline 4:2:0** — ffmpeg's mjpeg encoder picks 4:4:4 chroma, which the
    ///   player's decoder won't read (progressive JPEG fails for the same reason);
    /// * the image should be **no larger than 640×640**.
    /// Covers are always re-encoded rather than copied, so an odd master (progressive, CMYK,
    /// 3000 px) can't smuggle an undisplayable image onto the device.
    private func artworkArgs(_ src: URL, _ settings: TranscodeSettings) -> [String] {
        guard settings.embedArtwork, probe.attachedPictureCodec(src) != nil else { return [] }
        return ["-map", "0:v:0", "-disposition:v", "attached_pic",
                "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
                "-vf", "scale=w='min(\(Self.maxCoverPx),iw)':h=-2", "-q:v", "3",
                "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
    }
    /// Largest cover edge the device reliably renders.
    public static let maxCoverPx = 640

    /// Transcode `src` → `dst` (MP3) applying loudness normalization, tags and cover art.
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
        // Without an explicit video mapping ffmpeg drops the attached picture entirely.
        args += artworkArgs(src, settings)
        args += metadataArgs(tags)
        args.append(dst.path)
        let r = try Shell.run(ffmpegPath, args)
        guard r.status == 0 else { throw TranscodeError.failed(r.stderrString) }
    }

    /// Copy a master that needs no re-encoding, but normalize its cover art for the device
    /// (audio is stream-copied, so this is nearly free and loses nothing).
    public func copyNormalizingArtwork(from src: URL, to dst: URL, tags: TrackIdentity,
                                       settings: TranscodeSettings) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var args = ["-y", "-i", src.path, "-map", "0:a:0", "-c:a", "copy", "-id3v2_version", "3"]
        args += artworkArgs(src, settings)
        args += metadataArgs(tags)
        args.append(dst.path)
        let r = try Shell.run(ffmpegPath, args)
        guard r.status == 0 else { throw TranscodeError.failed(r.stderrString) }
    }

    /// Rewrite tags in place (stream copy, no re-encode). Extension-preserving so it works
    /// for mp3 masters and m4a downloads alike.
    public func writeTags(_ url: URL, _ tags: TrackIdentity) throws {
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".ostmp-\(UUID().uuidString).\(ext)")
        var args = ["-y", "-i", url.path, "-map", "0", "-c", "copy"]
        if ext.lowercased() == "mp3" { args += ["-id3v2_version", "3"] }
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
