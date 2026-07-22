import Foundation
import OpenSongCore

func registerSpectralAnalyzerTests() {
    let analyzer = SpectralAnalyzer(ffmpegPath: TestSupport.ffmpeg)

    t.test("a band-limited source reads clearly lower than full-band") {
        let dir = try TestSupport.tempDir("spectral")
        let low = dir.appendingPathComponent("low.wav")
        let full = dir.appendingPathComponent("full.wav")
        try TestSupport.makeNoise(at: low, lowpassHz: 8000, seconds: 2)
        try TestSupport.makeNoise(at: full, seconds: 2)
        let lowCut = try analyzer.cutoffHz(low)
        let fullCut = try analyzer.cutoffHz(full)
        try t.expect(lowCut <= 15000, "band-limited cutoff is low (got \(Int(lowCut)))")
        try t.expect(fullCut >= 18000, "full-band cutoff is high (got \(Int(fullCut)))")
        try t.expect(fullCut - lowCut >= 4000, "clear separation (low \(Int(lowCut)) vs full \(Int(fullCut)))")
    }
    t.test("verdict flags a low cutoff at a high claimed bitrate") {
        try t.expect(!analyzer.verdict(cutoffHz: 15000, bitrateKbps: 320).isGood, "15 kHz @ 320k is suspicious")
        try t.expect(analyzer.verdict(cutoffHz: 20000, bitrateKbps: 320).isGood, "20 kHz @ 320k is good")
        try t.expect(analyzer.verdict(cutoffHz: 16000, bitrateKbps: 128).isGood, "16 kHz @ 128k is fine")
    }
    t.test("renders a spectrogram png") {
        let dir = try TestSupport.tempDir("spectral")
        let f = dir.appendingPathComponent("full.wav")
        try TestSupport.makeNoise(at: f, seconds: 1)
        let png = dir.appendingPathComponent("spec.png")
        try analyzer.spectrogram(f, to: png)
        let size = (try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int) ?? 0
        try t.expect(size > 0, "spectrogram written")
    }
}
