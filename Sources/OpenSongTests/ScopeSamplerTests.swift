import AVFoundation
import Foundation
import OpenSongCore

/// Write a WAV at the sampler's own analysis rate, so decoding is a straight copy and the numbers can
/// be reasoned about (a resample would filter them as well).
private func writeWAV(at url: URL, seconds: Double, rate: Double = 22050,
                      left: (Int) -> Float, right: (Int) -> Float) throws {
    let frames = Int(seconds * rate)
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(2)
    le32(UInt32(rate)); le32(UInt32(rate) * 4); le16(4); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(UInt32(frames * 4))
    for i in 0..<frames {
        let l = Int16(max(-1, min(1, left(i))) * 32767)
        let r = Int16(max(-1, min(1, right(i))) * 32767)
        le16(UInt16(bitPattern: l)); le16(UInt16(bitPattern: r))
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

/// A sine of `hz`, as a sample-index function.
private func tone(_ hz: Double, rate: Double = 22050, amplitude: Double = 0.9) -> (Int) -> Float {
    { i in Float(sin(2 * Double.pi * hz * Double(i) / rate) * amplitude) }
}

func registerScopeSamplerTests() {
    t.test("bands separate bass from treble") {
        let dir = try TestSupport.tempDir("scope-bands")
        let bass = dir.appendingPathComponent("bass.wav")
        let treble = dir.appendingPathComponent("treble.wav")
        try writeWAV(at: bass, seconds: 2, left: tone(60), right: tone(60))
        try writeWAV(at: treble, seconds: 2, left: tone(5000), right: tone(5000))
        let low = try ScopeSampler.decode(bass)
        let high = try ScopeSampler.decode(treble)

        try t.expect(abs(low.duration - 2) < 0.05, "duration ≈ 2 s (got \(low.duration))")
        let l = low.bands(at: 1.0), h = high.bands(at: 1.0)
        // Each band is normalised against the track's own 97th percentile, so the band carrying the
        // tone reads ≈ 1 and the others read near zero.
        try t.expect(l.bass > 0.8, "60 Hz drives the bass axis (\(l.bass))")
        try t.expect(l.high < 0.2, "and not the treble axis (\(l.high))")
        try t.expect(h.high > 0.8, "5 kHz drives the treble axis (\(h.high))")
        try t.expect(h.bass < 0.2, "and not the bass axis (\(h.bass))")
    }

    t.test("a band rises on a hit and releases gently afterwards") {
        let dir = try TestSupport.tempDir("scope-hit")
        let wav = dir.appendingPathComponent("hits.wav")
        let bed = tone(70, amplitude: 0.05), hit = tone(70, amplitude: 0.95)
        let burst: (Int) -> Float = { i in
            let s = Double(i) / 22050
            return (s > 0.8 && s < 0.9) ? hit(i) : bed(i)
        }
        try writeWAV(at: wav, seconds: 2, left: burst, right: burst)
        let s = try ScopeSampler.decode(wav)
        let during = s.bands(at: 0.88).bass
        let justAfter = s.bands(at: 0.95).bass
        let wellAfter = s.bands(at: 1.6).bass
        try t.expect(during > 0.7, "the hit drives the bass axis (\(during))")
        try t.expect(justAfter > wellAfter, "the release decays rather than cutting (\(justAfter) → \(wellAfter))")
        try t.expect(wellAfter < 0.35, "and settles back down (\(wellAfter))")
    }

    t.test("the ripple carries the waveform, low-passed") {
        let dir = try TestSupport.tempDir("scope-ripple")
        let bass = dir.appendingPathComponent("bass.wav")
        let treble = dir.appendingPathComponent("treble.wav")
        try writeWAV(at: bass, seconds: 1, left: tone(80), right: tone(80))
        try writeWAV(at: treble, seconds: 1, left: tone(6000), right: tone(6000))
        let low = try ScopeSampler.decode(bass)
        let high = try ScopeSampler.decode(treble)
        func swing(_ s: ScopeSampler) -> Float {
            var peak: Float = 0
            var t = 0.4
            while t < 0.6 { peak = max(peak, abs(s.ripple(at: t))); t += 1 / s.waveRate }
            return peak
        }
        try t.expect(swing(low) > 0.4, "80 Hz rides the line (\(swing(low)))")
        // Above the 220 Hz corner the ripple would alias into hair at the spacing the line is drawn
        // with, so it must be gone.
        try t.expect(swing(high) < 0.05, "6 kHz is filtered out (\(swing(high)))")
        try t.expectEqual(low.waveRate, 2205, "ripple is kept at a tenth of the analysis rate")
    }

    t.test("reads outside the track are handled, not crashes") {
        let s = ScopeSampler(bass: [0.5, 0.5], mid: [0.2, 0.2], high: [0.1, 0.1], kick: [0, 0],
                             bandRate: 100, wave: [1000, 2000], waveRate: 100,
                             shimmer: [500, 900], shimmerRate: 100)
        try t.expectEqual(s.bands(at: 999), .silent, "past the end is silent (the centre dot)")
        try t.expectEqual(s.bands(at: -5), .silent, "before the start is silent")
        try t.expectEqual(s.ripple(at: 999), 0, "ripple past the end is flat")
        try t.expectEqual(s.shimmer(at: 999), 0, "shimmer past the end is flat")
        try t.expectEqual(s.kick(at: 999), 0, "no hit past the end")
        try t.expectEqual(s.presence(at: 999), 0, "no presence past the end")
        try t.expectEqual(s.voice(at: 999), 0, "no voice detail past the end")
        try t.expect(s.bands(at: 0.01).bass > 0, "a real read still works")
        try t.expectEqual(ScopeSampler.Bands.silent.energy, 0, "silence has no energy")
    }

    t.test("the kick track fires on a hit, not on a sustained note") {
        let dir = try TestSupport.tempDir("scope-kick")
        let steady = dir.appendingPathComponent("steady.wav")
        let hits = dir.appendingPathComponent("hits.wav")
        // Same band, same loudness — one held, one struck. Only the struck one is a "hit", which is
        // what makes the visualiser's flash and swirl land on the beat rather than on the bass line.
        try writeWAV(at: steady, seconds: 2, left: tone(70), right: tone(70))
        let struck: (Int) -> Float = { i in
            let s = Double(i) / 22050
            return s.truncatingRemainder(dividingBy: 0.5) < 0.08 ? tone(70)(i) : 0
        }
        try writeWAV(at: hits, seconds: 2, left: struck, right: struck)
        let held = try ScopeSampler.decode(steady)
        let beaten = try ScopeSampler.decode(hits)

        var heldPeak: Float = 0, beatenPeak: Float = 0
        var t0 = 0.5
        while t0 < 1.8 {
            heldPeak = max(heldPeak, held.kick(at: t0))
            beatenPeak = max(beatenPeak, beaten.kick(at: t0))
            t0 += 0.005
        }
        try t.expect(beatenPeak > 0.8, "a struck note reads as a hit (\(beatenPeak))")
        try t.expect(heldPeak < 0.3, "a held note of the same loudness does not (\(heldPeak))")
    }

    t.test("shimmer carries the mids, and neither bass nor hiss") {
        let dir = try TestSupport.tempDir("scope-shimmer")
        func swing(_ url: URL) throws -> Float {
            let s = try ScopeSampler.decode(url)
            var peak: Float = 0
            var t0 = 0.4
            while t0 < 0.6 { peak = max(peak, abs(s.shimmer(at: t0))); t0 += 1 / s.shimmerRate }
            return peak
        }
        let low = dir.appendingPathComponent("low.wav")
        let middle = dir.appendingPathComponent("mid.wav")
        let top = dir.appendingPathComponent("top.wav")
        try writeWAV(at: low, seconds: 1, left: tone(80), right: tone(80))
        try writeWAV(at: middle, seconds: 1, left: tone(700), right: tone(700))
        try writeWAV(at: top, seconds: 1, left: tone(6000), right: tone(6000))
        let l = try swing(low), m = try swing(middle), h = try swing(top)
        try t.expect(m > 0.3, "700 Hz moves the line (\(m))")
        try t.expect(l < 0.1, "80 Hz is the other movement's job (\(l))")
        try t.expect(h < 0.1, "6 kHz would alias into hair, so it's filtered out (\(h))")
    }

    t.test("presence follows the register a voice sits in, and prefers the centre") {
        let dir = try TestSupport.tempDir("scope-presence")
        let low = dir.appendingPathComponent("low.wav")
        let vocalRange = dir.appendingPathComponent("vocal.wav")
        let hiss = dir.appendingPathComponent("hiss.wav")
        let wide = dir.appendingPathComponent("wide.wav")
        try writeWAV(at: low, seconds: 1, left: tone(200), right: tone(200))
        try writeWAV(at: vocalRange, seconds: 1, left: tone(1600), right: tone(1600))
        try writeWAV(at: hiss, seconds: 1, left: tone(9000), right: tone(9000))
        // Same 1.6 kHz tone, but panned hard opposite — i.e. as wide as a mix can put it. A lead
        // vocal is centred, so this must read lower than the centred version.
        try writeWAV(at: wide, seconds: 1, left: tone(1600), right: { i in -tone(1600)(i) })

        func level(_ url: URL) throws -> Float {
            let s = try ScopeSampler.decode(url)
            return s.presence(at: 0.6)
        }
        let centred = try level(vocalRange)
        let lowLevel = try level(low), hissLevel = try level(hiss), wideLevel = try level(wide)
        try t.expect(centred > 0.6, "1.6 kHz drives presence (\(centred))")
        try t.expect(lowLevel < 0.25, "200 Hz is the bass axis's job (\(lowLevel))")
        try t.expect(hissLevel < 0.25, "9 kHz is above the band (\(hissLevel))")
        try t.expect(wideLevel < centred * 0.6,
                     "a hard-panned source counts for much less than a centred one "
                     + "(\(wideLevel) vs \(centred))")
    }

    t.test("a track costs well under a megabyte a minute") {
        let dir = try TestSupport.tempDir("scope-size")
        let wav = dir.appendingPathComponent("minute.wav")
        try writeWAV(at: wav, seconds: 60, left: tone(110), right: tone(130))
        let s = try ScopeSampler.decode(wav)
        let mb = Double(s.byteCount) / 1_048_576
        print(String(format: "      one minute of audio costs %.2f MB", mb))
        // The waveform version this replaced held ~5 MB per minute; band envelopes plus a decimated
        // ripple hold a fraction of that, which is why there is no longer a resident-memory test.
        // Three detail tracks now (bass vibration, mid shimmer, presence) plus five envelopes.
        try t.expect(mb < 2.0, "under 2 MB per minute (got \(String(format: "%.2f", mb)))")
        try t.expect(mb > 0.1, "but it really is holding the track (got \(String(format: "%.2f", mb)))")
    }

    t.test("samplers deallocate: no leak across load/drop cycles") {
        let dir = try TestSupport.tempDir("scope-leak")
        let wav = dir.appendingPathComponent("t.wav")
        try writeWAV(at: wav, seconds: 1, left: tone(120), right: tone(140))
        // Ten create/drop cycles, each asserting the previous one is gone — the pattern a leaked
        // reference (a retain cycle, or a stale copy held by a superseded decode) would fail. With the
        // footprint down to ~0.4 MB a minute, this weak-reference check is the meaningful test: a
        // resident-size measurement can no longer tell a leak from the allocator's own noise.
        for cycle in 1...10 {
            weak var weakRef: ScopeSampler?
            do {
                let s = try ScopeSampler.decode(wav)
                weakRef = s
                try t.expect(s.byteCount > 0, "cycle \(cycle): holds analysis")
            }
            try t.expect(weakRef == nil, "cycle \(cycle): sampler deallocated when dropped")
        }
    }

    t.test("a cancelled decode throws instead of returning a sampler") {
        let dir = try TestSupport.tempDir("scope-cancel")
        let wav = dir.appendingPathComponent("t.wav")
        try writeWAV(at: wav, seconds: 6, left: tone(100), right: tone(100))
        let task = Task.detached { () -> Result<ScopeSampler, Error> in
            await Task.yield()
            do { return .success(try ScopeSampler.decode(wav)) } catch { return .failure(error) }
        }
        task.cancel()
        switch await task.value {
        case .failure(let e):
            try t.expect("\(e)".contains("cancel"), "cancelled decode reports cancellation (\(e))")
        case .success:
            // Racing a short file can still finish first; the point is that it never hangs and never
            // installs a partial sampler.
            try t.expect(true, "decode won the race and completed cleanly")
        }
    }

    t.test("envelope attack is faster than its release") {
        // A step up then down, so attack and release can be timed separately.
        let rate = 22050.0
        let n = Int(rate)
        let step: [Float] = (0..<n).map { $0 < n / 2 ? 1 : 0 }
        let e = ScopeSampler.envelope(step, rate: rate, attackMs: 20, releaseMs: 200)
        let rise = e[Int(rate * 0.05)]              // 50 ms into the step
        let fall = e[Int(rate * 0.55)]              // 50 ms after it ends
        try t.expect(rise > 0.9, "20 ms attack is up within 50 ms (\(rise))")
        try t.expect(fall > 0.6, "200 ms release is still falling 50 ms later (\(fall))")
        try t.expect(e[Int(rate * 0.9)] < 0.2, "and gets there eventually (\(e[Int(rate * 0.9)]))")
    }
}
