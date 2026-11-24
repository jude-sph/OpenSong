import Foundation
import OpenSongCore

func registerTranscoderTests() {
    let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
    let transcoder = Transcoder(ffmpegPath: TestSupport.ffmpeg, probe: probe)
    let s192 = TranscodeSettings(format: "mp3", bitrateKbps: 192, loudnessNormalize: true)

    t.test("needsTranscode skip rule") {
        let mp3_128 = ProbeResult(durationSec: 1, bitrateKbps: 128, codec: "mp3", sampleRate: 44100, channels: 2, tags: [:])
        let mp3_320 = ProbeResult(durationSec: 1, bitrateKbps: 320, codec: "mp3", sampleRate: 44100, channels: 2, tags: [:])
        let flac = ProbeResult(durationSec: 1, bitrateKbps: 1000, codec: "flac", sampleRate: 44100, channels: 2, tags: [:])
        try t.expect(transcoder.needsTranscode(mp3_128, s192) == false, "mp3@128 <= 192 -> skip")
        try t.expect(transcoder.needsTranscode(mp3_320, s192) == true, "mp3@320 -> transcode")
        try t.expect(transcoder.needsTranscode(flac, s192) == true, "flac -> transcode")
    }

    t.test("transcode carries the cover art onto the device copy") {
        let dir = try TestSupport.tempDir("transcode-art")
        let src = dir.appendingPathComponent("src.mp3")
        let art = try TestSupport.makePNG(at: dir.appendingPathComponent("cover.png"), color: "blue", size: 64)
        // `tone: true` — libmp3lame's psymodel asserts on pure silence through loudnorm.
        try TestSupport.makeMP3(at: src, title: "Arty", artist: "A", bitrateKbps: 320, seconds: 1, tone: true)
        // Embed the PNG the way a download or an Apple Music master carries it.
        let withArt = dir.appendingPathComponent("withart.mp3")
        let r = try Shell.run(TestSupport.ffmpeg, ["-y", "-i", src.path, "-i", art.path,
            "-map", "0:a", "-map", "1:v", "-c", "copy", "-disposition:v", "attached_pic",
            "-id3v2_version", "3", withArt.path])
        try t.expectEqual(r.status, 0, "source has embedded art")
        try t.expectEqual(probe.attachedPictureCodec(withArt), "png", "png cover on the master")

        let dst = dir.appendingPathComponent("out.mp3")
        try transcoder.transcode(from: withArt, to: dst,
                                 tags: TrackIdentity(title: "Arty", artist: "A", albumArtist: "A",
                                                     album: "Alb", durationSec: 1),
                                 settings: s192)
        // Re-encoded to JPEG — the format an old player is sure to render.
        try t.expectEqual(probe.attachedPictureCodec(dst), "mjpeg", "cover survives the transcode")
        try t.expectEqual(try probe.probe(dst).codec, "mp3", "still an mp3")
        // …and in the exact shape the NW-E394 will display (see `Transcoder.artworkArgs`).
        let cover = try APICInspector.read(dst)
        try t.expectEqual(cover.pictureType, 3, "APIC type 3 = front cover")
        try t.expectEqual(cover.mime, "image/jpeg", "jpeg cover")
        try t.expect(cover.baseline, "baseline JPEG, not progressive")
        try t.expect(cover.chroma420, "4:2:0 chroma")
        try t.expect(cover.width <= Transcoder.maxCoverPx && cover.height <= Transcoder.maxCoverPx,
                     "within \(Transcoder.maxCoverPx)px (got \(cover.width)×\(cover.height))")

        // A master without art transcodes fine (no bogus stream mapping).
        let plain = dir.appendingPathComponent("plain.mp3")
        try transcoder.transcode(from: src, to: plain,
                                 tags: TrackIdentity(title: "Arty", artist: "A", albumArtist: "A",
                                                     album: "Alb", durationSec: 1),
                                 settings: s192)
        try t.expect(probe.attachedPictureCodec(plain) == nil, "no art, no problem")
    }

    t.test("a copied master gets its oversized cover normalized for the device") {
        let dir = try TestSupport.tempDir("copy-art")
        // An MP3 that needs no re-encode, carrying a 1400px 4:4:4 JPEG cover — the kind of art
        // Apple Music masters ship and the Walkman refuses to draw.
        let big = dir.appendingPathComponent("big.jpg")
        _ = try Shell.run(TestSupport.ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=green:s=1400x1400",
            "-frames:v", "1", "-pix_fmt", "yuvj444p", big.path])
        let src = dir.appendingPathComponent("src.mp3")
        try TestSupport.makeMP3(at: src, title: "Copy", artist: "A", bitrateKbps: 128, seconds: 1, tone: true)
        let withArt = dir.appendingPathComponent("withart.mp3")
        _ = try Shell.run(TestSupport.ffmpeg, ["-y", "-i", src.path, "-i", big.path,
            "-map", "0:a", "-map", "1:v", "-c", "copy", "-disposition:v", "attached_pic",
            "-id3v2_version", "3", withArt.path])

        let dst = dir.appendingPathComponent("out.mp3")
        try transcoder.copyNormalizingArtwork(from: withArt, to: dst,
            tags: TrackIdentity(title: "Copy", artist: "A", albumArtist: "A", album: "Alb", durationSec: 1),
            settings: s192)
        let cover = try APICInspector.read(dst)
        try t.expectEqual(cover.pictureType, 3, "front cover")
        try t.expect(cover.chroma420, "downsampled to 4:2:0")
        try t.expectEqual(cover.width, Transcoder.maxCoverPx, "scaled down to 640px")
        // The audio itself is untouched — this path must never re-encode. Compare the raw audio
        // streams (the file's own bitrate is dominated by the cover on a 1-second clip).
        func audioBytes(_ url: URL) throws -> Data {
            let out = dir.appendingPathComponent("audio-\(UUID().uuidString).mp3")
            _ = try Shell.run(TestSupport.ffmpeg, ["-y", "-i", url.path, "-map", "0:a", "-c", "copy",
                                                   "-write_xing", "0", "-id3v2_version", "0", out.path])
            return try Data(contentsOf: out)
        }
        try t.expectEqual(try audioBytes(dst), try audioBytes(withArt), "audio stream-copied, not re-encoded")

        // Artwork switched off (screenless players) → no picture at all.
        let noArt = dir.appendingPathComponent("noart.mp3")
        var quiet = s192; quiet.embedArtwork = false
        try transcoder.transcode(from: withArt, to: noArt,
            tags: TrackIdentity(title: "Copy", artist: "A", albumArtist: "A", album: "Alb", durationSec: 1),
            settings: quiet)
        try t.expect(probe.attachedPictureCodec(noArt) == nil, "no cover when embedArtwork is off")
    }

    t.test("transcode 320k -> 192k with loudnorm sets tags") {
        let dir = try TestSupport.tempDir("transcode")
        let src = dir.appendingPathComponent("src.mp3")
        let dst = dir.appendingPathComponent("out/dst.mp3")
        try TestSupport.makeMP3(at: src, title: "Loud", artist: "A", bitrateKbps: 320, seconds: 2, tone: true)
        let tags = TrackIdentity(title: "Clean Title", artist: "The Artist",
                                 albumArtist: "The Artist", album: "The Album",
                                 trackNumber: 3, discNumber: 1, year: 2001, durationSec: 2,
                                 provenance: .itunesResolved)
        try transcoder.transcode(from: src, to: dst, tags: tags, settings: s192)
        let r = try probe.probe(dst)
        try t.expectEqual(r.codec, "mp3", "output codec")
        try t.expect(r.bitrateKbps <= 210, "bitrate reduced (got \(r.bitrateKbps))")
        try t.expectEqual(r.tags["title"], "Clean Title", "title tag written")
        try t.expectEqual(r.tags["track"], "3", "track tag written")
        try t.expectEqual(r.tags["artist"], "The Artist", "artist tag")
    }

    t.test("writeTags rewrites tags in place without re-encode") {
        let dir = try TestSupport.tempDir("tagwrite")
        let f = dir.appendingPathComponent("song.mp3")
        try TestSupport.makeMP3(at: f, title: "Old", artist: "Old A", bitrateKbps: 192, seconds: 1)
        let before = try probe.probe(f).bitrateKbps
        let tags = TrackIdentity(title: "New Title", artist: "New A", album: "New Album",
                                 trackNumber: 7, durationSec: 1)
        try transcoder.writeTags(f, tags)
        let after = try probe.probe(f)
        try t.expectEqual(after.tags["title"], "New Title", "title updated")
        try t.expectEqual(after.tags["track"], "7", "track updated")
        try t.expect(abs(after.bitrateKbps - before) <= 8, "bitrate unchanged (copy)")
    }
}
