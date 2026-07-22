import Foundation
import OpenSongCore

func registerAudioProbeTests() {
    t.test("probe reads mp3 codec, bitrate, sample rate, tags") {
        let dir = try TestSupport.tempDir("probe")
        let mp3 = dir.appendingPathComponent("out.mp3")
        try TestSupport.makeMP3(at: mp3, title: "Probe", artist: "Tester", bitrateKbps: 192, seconds: 1)
        let probe = AudioProbe(ffprobePath: TestSupport.ffprobe)
        let r = try probe.probe(mp3)
        try t.expectEqual(r.codec, "mp3", "codec")
        try t.expect(abs(r.bitrateKbps - 192) <= 40, "bitrate ~192 (got \(r.bitrateKbps))")
        try t.expectEqual(r.sampleRate, 44100, "sample rate")
        try t.expectEqual(r.channels, 2, "channels")
        try t.expectEqual(r.tags["title"], "Probe", "title tag")
        try t.expectEqual(r.tags["artist"], "Tester", "artist tag")
        try t.expect(r.durationSec > 0.9 && r.durationSec < 1.3, "duration ~1s (got \(r.durationSec))")
    }
    t.test("probe reads flac as lossless codec") {
        let dir = try TestSupport.tempDir("probe")
        let flac = dir.appendingPathComponent("out.flac")
        try TestSupport.makeFLAC(at: flac, title: "L", artist: "A", seconds: 1)
        let r = try AudioProbe(ffprobePath: TestSupport.ffprobe).probe(flac)
        try t.expectEqual(r.codec, "flac", "flac codec")
    }
}
