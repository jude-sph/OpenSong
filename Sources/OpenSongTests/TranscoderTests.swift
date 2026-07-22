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
