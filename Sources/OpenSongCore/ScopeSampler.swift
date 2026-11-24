import AVFoundation
import Foundation

/// One decoded track, prepared for the visualiser.
///
/// Not the waveform. Eight rounds of rendering real audio settled the question the first version got
/// wrong: a music waveform is genuinely different every 15 ms, so anything whose *shape* is the
/// waveform gets redrawn from scratch every frame — measured at 0.9 frame-to-frame change against 0.2
/// for what's here — and that reads as a frantic scribble however it is filtered.
///
/// So what's stored is what a listener actually hears moving: the energy in three bands, each with its
/// own attack and release, which change over tens to hundreds of milliseconds. Plus a heavily
/// decimated low-passed wave, which rides the drawn line as a fine ripple so the picture is still
/// literally the audio rather than an animation running alongside it.
///
/// The side effect is a 15× smaller footprint than the waveform version: ~0.4 MB per minute instead
/// of ~5 MB. Still a class rather than a struct so its lifetime stays explicit and testable with a
/// weak reference, and immutable once built, so it is safely `Sendable` — decoding happens off the
/// main actor and hands the finished sampler across.
public final class ScopeSampler: Sendable {
    /// Energy in one band at one instant, normalised so 1.0 is a loud moment *for this track*.
    /// A quietly mastered track therefore fills the figure as much as a loud one.
    public struct Bands: Sendable, Equatable {
        public let bass: Float, mid: Float, high: Float
        public init(bass: Float, mid: Float, high: Float) {
            self.bass = bass; self.mid = mid; self.high = high
        }
        public static let silent = Bands(bass: 0, mid: 0, high: 0)
        /// Overall drive, for brightness and for how fast the figure swirls.
        public var energy: Float { (bass + mid + high) / 3 }
    }

    /// Band envelopes, one value per `bandHop` samples of the decoded audio.
    private let bass: [Float], mid: [Float], high: [Float]
    /// Bass *transient* rather than bass level: how hard a hit landed, not how loud the bass is.
    private let kickTrack: [Float]
    /// Low-passed mono, decimated: the bass vibration along the line.
    private let wave: [Int16]
    /// The 300–1100 Hz band, kept at a higher rate: the mid-driven shimmer, which is a separate,
    /// faster movement laid on top of the bass vibration rather than a change to it.
    private let shimmerWave: [Int16]
    /// The 1–2.5 kHz presence band, centre-weighted, with its own envelope. This is the register a
    /// voice sits in — *not* vocal isolation, which cheap DSP cannot do: hats and lead instruments
    /// live here too. Centre-weighting at least favours a dead-centre lead over wide-panned parts.
    private let presenceWave: [Int16]
    private let presenceTrack: [Float]
    public let bandRate: Double        // envelope values per second
    public let waveRate: Double        // vibration samples per second
    public let shimmerRate: Double     // shimmer samples per second
    public let presenceRate: Double    // presence samples per second

    public var duration: Double { Double(bass.count) / bandRate }
    /// Bytes actually held, for logging and the memory test.
    public var byteCount: Int {
        (bass.count + mid.count + high.count + kickTrack.count + presenceTrack.count)
            * MemoryLayout<Float>.size
            + (wave.count + shimmerWave.count + presenceWave.count) * MemoryLayout<Int16>.size
    }

    public init(bass: [Float], mid: [Float], high: [Float], kick: [Float], bandRate: Double,
                wave: [Int16], waveRate: Double, shimmer: [Int16], shimmerRate: Double,
                presence: [Float] = [], presenceWave: [Int16] = [],
                presenceRate: Double = ScopeSampler.analysisRate
                    / Double(ScopeSampler.presenceDecimation)) {
        precondition(bass.count == mid.count && mid.count == high.count,
                     "band tracks must be the same length")
        self.bass = bass; self.mid = mid; self.high = high; self.kickTrack = kick
        self.bandRate = bandRate
        self.wave = wave; self.waveRate = waveRate
        self.shimmerWave = shimmer; self.shimmerRate = shimmerRate
        self.presenceTrack = presence; self.presenceWave = presenceWave
        self.presenceRate = presenceRate
    }

    // MARK: reading

    /// Band energies at a moment. Reads outside the track are silent, which draws the near-circle a
    /// scope shows with no signal.
    public func bands(at seconds: Double) -> Bands {
        let i = Int(seconds * bandRate)
        guard i >= 0, i < bass.count else { return .silent }
        return Bands(bass: bass[i], mid: mid[i], high: high[i])
    }

    /// The low-passed wave at a moment, −1…1: the bass vibration on the drawn line.
    public func ripple(at seconds: Double) -> Float {
        let i = Int(seconds * waveRate)
        guard i >= 0, i < wave.count else { return 0 }
        return Float(wave[i]) / 32767
    }

    /// The 300–1100 Hz band at a moment, −1…1: the faster movement that appears when the mids do.
    public func shimmer(at seconds: Double) -> Float {
        let i = Int(seconds * shimmerRate)
        guard i >= 0, i < shimmerWave.count else { return 0 }
        return Float(shimmerWave[i]) / 32767
    }

    /// How strongly the presence band (where a voice sits) is sounding, 0…1.4.
    public func presence(at seconds: Double) -> Float {
        let i = Int(seconds * bandRate)
        guard i >= 0, i < presenceTrack.count else { return 0 }
        return presenceTrack[i]
    }

    /// The presence band itself, −1…1: the fine tremble that appears when someone sings.
    public func voice(at seconds: Double) -> Float {
        let i = Int(seconds * presenceRate)
        guard i >= 0, i < presenceWave.count else { return 0 }
        return Float(presenceWave[i]) / 32767
    }

    /// How hard a hit landed at this moment, 0…1.6 — the bass *transient*, not the bass level, so a
    /// sustained bass note doesn't read as a continuous kick.
    public func kick(at seconds: Double) -> Float {
        let i = Int(seconds * bandRate)
        guard i >= 0, i < kickTrack.count else { return 0 }
        return kickTrack[i]
    }

    // MARK: decoding

    public enum DecodeError: Error, CustomStringConvertible {
        case unreadable(String)
        case cancelled
        public var description: String {
            switch self {
            case .unreadable(let p): return "can't read audio at \(p)"
            case .cancelled: return "decode cancelled"
            }
        }
    }

    /// Rate the audio is decoded at before analysis.
    public static let analysisRate: Double = 22050
    /// One envelope value per this many analysis samples (~172 per second): fine enough to catch a
    /// kick drum, coarse enough to cost nothing.
    public static let bandHop = 128
    /// The ripple keeps 2205 samples a second, having been low-passed at 220 Hz first — any higher
    /// and it aliases into hair at the spacing the line is drawn with.
    public static let waveDecimation = 10
    public static let rippleCornerHz: Double = 220
    /// The shimmer keeps more samples (2205 → 2756 a second) because it carries content up to
    /// 1100 Hz, and is wrapped around the curve over a much shorter window.
    public static let shimmerDecimation = 8
    /// Presence carries content to 2.5 kHz, so it keeps more samples again (5512 a second).
    public static let presenceDecimation = 4

    /// Decode and analyse a master file. Synchronous and cancellation-aware: call it from a detached
    /// `Task` and cancel that task to abandon the work part-way.
    public static func decode(_ url: URL) throws -> ScopeSampler {
        let (mono, side) = try decodeChannels(url)
        if Task.isCancelled { throw DecodeError.cancelled }

        let rate = analysisRate
        let lp150 = lowPass(mono, cornerHz: 150, rate: rate)
        if Task.isCancelled { throw DecodeError.cancelled }

        // Real band-passes (high-pass then low-pass) rather than differences of low-passes.
        let midBand = lowPass(highPass(mono, cornerHz: 300, rate: rate), cornerHz: 1200, rate: rate)
        let highBand = highPass(mono, cornerHz: 2000, rate: rate)

        // One reference for all three bands, taken from the whole signal. Normalising each band
        // against itself looked right on dense music but was wrong: a bass-only passage still drove
        // the treble axis to full, because a tiny residual is still that band's own maximum. Sharing
        // a reference keeps the balance between bands, which is what makes the figure look like the
        // track sounds.
        let reference = self.reference(of: mono, rate: rate)
        // Attack and release per band: bass and mids are given a slower release so a beat decays
        // rather than flickering; treble is quick, because that's how it sounds. The gains offset
        // music's natural spectral tilt — there is far less energy at 5 kHz than at 60 Hz.
        let bassTrack = track(lp150, rate: rate, attackMs: 25, releaseMs: 180,
                              reference: reference, gain: 1.0)
        let kickTrack = self.kick(lp150, rate: rate)
        let midTrack = track(midBand, rate: rate, attackMs: 40, releaseMs: 260,
                             reference: reference, gain: 1.7)
        let highTrack = track(highBand, rate: rate, attackMs: 20, releaseMs: 140,
                              reference: reference, gain: 3.0)
        if Task.isCancelled { throw DecodeError.cancelled }

        let rippleSource = lowPass(mono, cornerHz: rippleCornerHz, rate: rate)
        let wave = decimate(rippleSource, by: waveDecimation)
        // Shimmer is the mid band itself, not its envelope, so the line moves *with* the music
        // rather than merely swelling. Band-limited to 1100 Hz before decimating, which keeps it
        // clear of both the decimated Nyquist and the spacing the curve is drawn at.
        let shimmer = decimate(lowPass(midBand, cornerHz: 1100, rate: rate), by: shimmerDecimation)
        // Presence: 1–2.5 kHz, with most of the wide-panned content taken out. A lead vocal is panned
        // dead centre, so subtracting a share of the sides favours it over guitars and reverb.
        let presenceBand = presence(mono: mono, rate: rate)
        let presenceLevel = presenceTrack(mono: mono, side: side, rate: rate, reference: reference)

        return ScopeSampler(bass: bassTrack, mid: midTrack, high: highTrack, kick: kickTrack,
                            bandRate: rate / Double(bandHop),
                            wave: wave, waveRate: rate / Double(waveDecimation),
                            shimmer: shimmer, shimmerRate: rate / Double(shimmerDecimation),
                            presence: presenceLevel,
                            presenceWave: decimate(presenceBand, by: presenceDecimation),
                            presenceRate: rate / Double(presenceDecimation))
    }

    /// The level a loud moment reaches in this track: the 97th percentile of its overall envelope.
    /// Dividing every band by this one number means a quietly mastered track still fills the figure
    /// while the balance between its bands is preserved.
    public static func reference(of mono: [Float], rate: Double) -> Float {
        let followed = envelope(mono, rate: rate, attackMs: 25, releaseMs: 180)
        var sampled = [Float]()
        var i = 0
        while i < followed.count { sampled.append(followed[i]); i += bandHop }
        guard !sampled.isEmpty else { return 0.005 }
        return max(0.005, sampled.sorted()[Int(Double(sampled.count) * 0.97)])
    }

    /// The bass *transient*: a fast energy follower minus a slow one, which is what a hit feels like
    /// as opposed to how loud the bass is. A sustained bass note reads as near zero here.
    ///
    /// The rectified signal is smoothed at 40 Hz first. Without that, a 3 ms attack tracks the
    /// individual half-cycles of a 70 Hz note, and every sustained bass note reads as a stream of
    /// hits at 140 Hz — which would have flickered the flash on screen.
    public static func kick(_ bass: [Float], rate: Double) -> [Float] {
        let magnitude = lowPass(bass.map { abs($0) }, cornerHz: 40, rate: rate, poles: 1)
        let fast = lowPass(magnitude, cornerHz: 12, rate: rate, poles: 1)
        let slow = lowPass(magnitude, cornerHz: 1.2, rate: rate, poles: 1)
        var out = [Float]()
        out.reserveCapacity(fast.count / bandHop + 1)
        var i = 0
        while i < fast.count { out.append(max(0, fast[i] - slow[i])); i += bandHop }
        guard !out.isEmpty else { return out }
        let reference = max(0.004, out.sorted()[Int(Double(out.count) * 0.96)])
        return out.map { min(1.6, $0 / reference) }
    }

    /// Keep every nth sample as 16-bit. The source must already be band-limited below the resulting
    /// Nyquist — that is the caller's job, and getting it wrong shows up as hair on the line.
    public static func decimate(_ x: [Float], by step: Int) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(x.count / step + 1)
        var i = 0
        while i < x.count { out.append(Int16(max(-1, min(1, x[i])) * 32767)); i += step }
        return out
    }

    /// Envelope-follow a band, sample it at `bandHop`, and scale it against the shared reference.
    public static func track(_ band: [Float], rate: Double, attackMs: Double, releaseMs: Double,
                             reference: Float, gain: Float) -> [Float] {
        let followed = envelope(band, rate: rate, attackMs: attackMs, releaseMs: releaseMs)
        var out = [Float]()
        out.reserveCapacity(followed.count / bandHop + 1)
        var i = 0
        while i < followed.count { out.append(followed[i]); i += bandHop }
        // Clipped a little above 1 so an unusually loud moment can still read as louder.
        return out.map { min(1.4, $0 * gain / reference) }
    }

    /// Rectify, then smooth with separate attack and release constants — the asymmetry is what makes
    /// the motion read as musical rather than as a meter twitching.
    public static func envelope(_ x: [Float], rate: Double, attackMs: Double,
                               releaseMs: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        let attack = Float(1 - exp(-1 / (attackMs / 1000 * rate)))
        let release = Float(1 - exp(-1 / (releaseMs / 1000 * rate)))
        var out = [Float](repeating: 0, count: x.count)
        var y: Float = 0
        for i in 0..<x.count {
            let v = abs(x[i])
            y += (v - y) * (v > y ? attack : release)
            out[i] = y
        }
        return out
    }

    /// Cascaded one-pole high-pass — a real difference equation, not `x − lowPass(x)`.
    ///
    /// The subtraction looks equivalent and isn't: the low-passed copy is phase-shifted, so
    /// subtracting it leaves a large residue well inside the stopband. An 80 Hz tone came through a
    /// "300 Hz high-pass" at a third of its amplitude that way, which put bass into the treble axis
    /// and into the mid shimmer.
    public static func highPass(_ x: [Float], cornerHz: Double, rate: Double,
                                poles: Int = 2) -> [Float] {
        guard !x.isEmpty, cornerHz > 0 else { return x }
        let dt = 1 / rate, rc = 1 / (2 * .pi * cornerHz)
        let a = Float(rc / (rc + dt))
        var out = x
        for _ in 0..<poles {
            var y: Float = 0, previous: Float = 0
            for i in 0..<out.count {
                let input = out[i]
                y = a * (y + input - previous)
                previous = input
                out[i] = y
            }
        }
        return out
    }

    /// Cascaded one-pole low-pass: a single pass over the track at decode time rather than per-frame
    /// work while drawing.
    public static func lowPass(_ x: [Float], cornerHz: Double, rate: Double,
                              poles: Int = 2) -> [Float] {
        guard !x.isEmpty, cornerHz > 0 else { return x }
        let dt = 1 / rate, rc = 1 / (2 * .pi * cornerHz)
        let a = Float(dt / (rc + dt))
        var out = x
        for _ in 0..<poles {
            var y: Float = 0
            for i in 0..<out.count { y += a * (out[i] - y); out[i] = y }
        }
        return out
    }

    /// The presence band: 1–2.5 kHz of the *centre* channel. Not vocal isolation — hats and lead
    /// instruments share this register — but it is where a voice lives.
    public static func presence(mono: [Float], rate: Double) -> [Float] {
        lowPass(highPass(mono, cornerHz: 1000, rate: rate), cornerHz: 2500, rate: rate)
    }

    /// How much of the presence band is coming from the centre of the mix, where a lead vocal sits.
    ///
    /// The subtraction has to happen between *envelopes*. Subtracting the side waveform from the mid
    /// waveform instead — the first attempt — made a hard-panned tone read as maximum presence, since
    /// cancelling a signal that is only in the sides leaves a large negative one, and the envelope of
    /// that is just as big.
    public static func presenceTrack(mono: [Float], side: [Float], rate: Double,
                                     reference: Float) -> [Float] {
        let centre = envelope(presence(mono: mono, rate: rate), rate: rate,
                              attackMs: 15, releaseMs: 130)
        let wide = side.count == mono.count
            ? envelope(presence(mono: side, rate: rate), rate: rate, attackMs: 15, releaseMs: 130)
            : [Float](repeating: 0, count: centre.count)
        var out = [Float]()
        out.reserveCapacity(centre.count / bandHop + 1)
        var i = 0
        while i < centre.count { out.append(max(0, centre[i] - 0.7 * wide[i])); i += bandHop }
        return out.map { min(1.4, $0 * 3.4 / reference) }
    }

    /// Decode any supported file to mid and side channels at `analysisRate`.
    private static func decodeChannels(_ url: URL) throws -> (mono: [Float], side: [Float]) {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let source = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: analysisRate,
                                            channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: source, to: outFormat) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }

        let chunk: AVAudioFrameCount = 16384
        var mono = [Float](), side = [Float]()
        let expected = Int(Double(file.length) / source.sampleRate * analysisRate)
        mono.reserveCapacity(expected); side.reserveCapacity(expected)
        var finished = false
        while !finished {
            if Task.isCancelled { throw DecodeError.cancelled }
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else {
                    outStatus.pointee = .endOfStream; return nil
                }
                do { try file.read(into: inBuffer) } catch {
                    outStatus.pointee = .endOfStream; return nil
                }
                if inBuffer.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let channels = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                let n = Int(outBuffer.frameLength)
                let l = channels[0], r = outFormat.channelCount > 1 ? channels[1] : channels[0]
                for i in 0..<n {
                    mono.append((l[i] + r[i]) * 0.5)
                    side.append((l[i] - r[i]) * 0.5)
                }
            }
            if status == .error || status == .endOfStream || outBuffer.frameLength == 0 { finished = true }
        }
        return (mono, side)
    }
}
