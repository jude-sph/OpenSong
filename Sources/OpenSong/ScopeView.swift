import SwiftUI
import OpenSongCore

/// Drives the visualiser's redraws and carries the state that has to survive between frames: the
/// precession phases and a short trail of past frames.
///
/// `TimelineView(.animation)` looked like the natural fit but stopped after a handful of frames —
/// measured at 3 frames in the first 392 ms and then nothing, which is what "half a frame a second"
/// looked like on screen. A timer we own is predictable: it runs only while the window is up and
/// something is playing, and it is the single thing that invalidates the canvas.
@Observable
@MainActor
final class ScopeClock {
    private(set) var tick = 0
    @ObservationIgnored private var timer: Timer?

    /// Precession phases, in radians. Accumulated (rather than computed from the playhead) so that
    /// changing how fast the figure swirls changes only its *rate* — a figure that jumped whenever
    /// the music got louder would be the same cheap effect as scaling it on the beat.
    @ObservationIgnored private(set) var phase = SIMD3<Double>(0, 0, 0)
    @ObservationIgnored private var lastPlayhead: Double?
    /// The last few frames of drawn points, for the phosphor trail.
    @ObservationIgnored private var trail: [[SIMD3<Float>]] = []

    func start(fps: Double = 60) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick &+= 1 }
        }
        // `.common` so the trace keeps moving while a menu is open or the window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Callers stop it explicitly (`onDisappear`); there's no `deinit` cleanup because a
    /// main-actor timer can't be touched from a nonisolated deinit.
    func stop() { timer?.invalidate(); timer = nil }

    /// Advance the phases by however far the playhead moved, so they stand still when paused and
    /// never race ahead if a frame is dropped. A seek or a track change resets rather than lurching.
    func advance(rates: SIMD3<Double>, energy: Double, playhead: Double) -> SIMD3<Double> {
        defer { lastPlayhead = playhead }
        guard let last = lastPlayhead else { return phase }
        let dt = playhead - last
        guard dt > 0, dt < 0.5 else { return phase }
        phase += rates * (1 + energy) * dt
        return phase
    }

    func remember(_ points: [SIMD3<Float>], keep: Int) {
        trail.insert(points, at: 0)
        if trail.count > keep { trail.removeLast(trail.count - keep) }
    }

    func recall(_ age: Int) -> [SIMD3<Float>]? {
        age > 0 && age < trail.count ? trail[age] : nil
    }

    func reset() { trail.removeAll(); lastPlayhead = nil }
}

/// The visualiser: the playing track drawn as a Lissajous knot — a closed 3-D curve that winds
/// through itself — turning slowly, in the style of a CRT with phosphor afterglow.
///
/// The form comes from the three band energies, not from the waveform. That is the whole point: the
/// waveform version was measured redrawing 90% of its picture every frame (hence "a frantic scribble
/// that doesn't represent the song"), while band energies move on the timescale a listener hears, so
/// consecutive frames are close relatives and the figure morphs. Bass stretches one axis, mids the
/// second, treble the third, so the music *deforms* the knot; nothing scales it, because scaling the
/// whole figure on the beat is exactly the bounce this replaced. The waveform still rides the line as
/// a fine ripple, so the picture is the audio and not an animation running beside it.
///
/// Given a sampler and a playhead this is a pure function of them — no audio state of its own — which
/// is what lets the render harness screenshot it from a synthetic sampler.
struct ScopeView: View {
    var sampler: ScopeSampler?
    /// Seconds into the track. Read fresh each frame by the caller.
    var playhead: () -> Double
    var isPlaying: Bool = true
    /// Redraw driver. Reading `clock.tick` inside the canvas is what schedules the next frame.
    var clock: ScopeClock?

    // Shape of the knot. Every number came from rendering real audio and measuring two things: how
    // much the picture changes per frame (0.2 here, 0.9 for the waveform version it replaced) and how
    // much its size varies (±1%, so there is nothing left to bounce).
    private let windings = SIMD3<Double>(3, 4, 5)   // sines per axis: 3:4:5 draws the roundest knot
    private let points = 620
    private let reach = 0.65            // how far a band stretches its own axis
    private let squash = 0.24           // how much the mids pull the bass axis in as theirs goes out
    private let ripple = 0.06           // bass vibration along the line — deliberately unchanged
    private let rippleWindow = 0.4      // seconds of audio wrapped around the curve
    private let shimmer = 0.18          // mid-driven movement, on top of the bass vibration
    private let shimmerWindow = 0.10    // a shorter window, so it travels round the curve faster
    private let voice = 0.20            // presence-band tremble — where a singer sits
    private let voiceWindow = 0.06      // shorter again: it crawls fast, so a vocal reads as detail
    private let seamBlend = 0.12        // fraction of the loop over which the ends are eased together
    private let kickSwirl = 1.4         // extra turn rate on a hit
    private let kickFlash = 0.40        // extra brightness on a hit
    private let precession = SIMD3<Double>(0.42, -0.31, 0.24)   // radians per second, per axis
    private let traces = 2              // the newest frame plus a faint older one
    private let traceAge = 2            // frames back for that older one
    private let traceFade = 0.45
    private let spin = 0.10             // whole-figure turn, radians per second
    private let tilt = 0.52
    private let radiusFraction = 0.46
    private let lineScale = 1.3

    private let beam = Color(red: 0.88, green: 0.98, blue: 1.0)
    private let glow = Color(red: 0.20, green: 0.75, blue: 1.0)

    /// Frame-rate probe for `OPENSONG_DEBUG_VIS=1`: the live path behaves nothing like the offscreen
    /// renderer, so the only trustworthy measurement comes from the running window.
    static let debug = ProcessInfo.processInfo.environment["OPENSONG_DEBUG_VIS"] == "1"
    /// Kept as the lever if a huge display ever struggles: `OPENSONG_VIS_METAL=1` rasterises the
    /// canvas offscreen via Metal.
    static let metal = ProcessInfo.processInfo.environment["OPENSONG_VIS_METAL"] == "1"

    private final class FPS {
        var frames = 0
        var since = Date()
        var total = 0.0
        func record(_ t: Double) { total += t }
        func tick(_ size: CGSize, _ playing: Bool) {
            frames += 1
            let elapsed = Date().timeIntervalSince(since)
            guard elapsed >= 1 else { return }
            let n = Double(frames)
            FileHandle.standardError.write(Data(String(
                format: "[vis] %.1f fps at %.0f×%.0f playing=%@ — draw %.2f ms\n",
                n / elapsed, size.width, size.height, playing ? "y" : "n", total / n * 1000).utf8))
            frames = 0; since = Date(); total = 0
        }
    }
    private static let fps = FPS()

    var body: some View {
        canvas.background(Color(red: 0.02, green: 0.03, blue: 0.035))
    }

    @ViewBuilder private var canvas: some View {
        let c = Canvas { ctx, size in
            _ = clock?.tick          // the dependency that makes the next tick redraw us
            let t0 = Self.debug ? Date() : nil
            draw(&ctx, size: size)
            if let t0 { Self.fps.record(Date().timeIntervalSince(t0)) }
            if Self.debug { Self.fps.tick(size, isPlaying) }
        }
        if Self.metal { c.drawingGroup() } else { c }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * radiusFraction
        let now = playhead()

        guard let sampler else {
            dot(&ctx, at: centre, radius: radius)   // no signal — a scope shows a centre dot
            finish(&ctx, size: size, centre: centre)
            return
        }

        let bands = sampler.bands(at: now)
        let kick = Double(sampler.kick(at: now))
        // A hit spins the figure faster rather than inflating it — the speed change, not a pump.
        let phase = clock?.advance(rates: precession,
                                   energy: Double(bands.energy) + kickSwirl * kick,
                                   playhead: now) ?? SIMD3<Double>(0, 0, 0)
        let shape = knot(sampler, at: now, bands: bands, phase: phase)
        clock?.remember(shape, keep: traces * traceAge + 1)
        let scale = fitScale(shape, at: now)
        // Loudness goes to brightness, never to size, with a flash on each hit.
        let brightness = 0.55 + 0.45 * min(1, Double(bands.energy) * 1.2) + kickFlash * kick

        ctx.blendMode = .plusLighter          // light accumulating on phosphor
        for age in stride(from: traces - 1, through: 0, by: -1) {
            let pts = age == 0 ? shape : clock?.recall(age * traceAge)
            guard let pts, pts.count > 1 else { continue }
            stroke(&ctx, pts, scale: scale, at: now, centre: centre, radius: radius,
                   opacity: pow(traceFade, Double(age)) * brightness)
        }
        ctx.blendMode = .normal
        finish(&ctx, size: size, centre: centre)
    }

    /// The knot: three sine axes at integer ratios, each stretched by one band, with the recent
    /// waveform wrapped around the curve as a ripple. Bounded by construction, so it cannot inflate.
    private func knot(_ sampler: ScopeSampler, at now: Double, bands: ScopeSampler.Bands,
                      phase: SIMD3<Double>) -> [SIMD3<Float>] {
        // The bands pull against each other rather than all pushing outward: as the mids come up they
        // squash the bass axis while extending their own, so the figure changes proportions. Without
        // that, a loud passage just made everything bigger, which the frame fit then cancelled out.
        let amplitude = SIMD3<Double>(1 + reach * Double(bands.bass) - squash * Double(bands.mid),
                                      1 + reach * Double(bands.mid) * 0.9
                                        - squash * Double(bands.bass) * 0.5,
                                      0.55 + reach * Double(bands.high))
        // How much the mid-band shimmer shows: nothing on a quiet passage, plenty on an intense one.
        let shimmerDrive = shimmer * Double(bands.mid + bands.high) / 2
        let voiceDrive = voice * Double(sampler.presence(at: now))

        // Both movements travel round the loop as the track plays — u = 1 is now, u = 0 is a window
        // ago — the bass slowly, the shimmer four times faster.
        func detail(_ u: Double) -> Double {
            ripple * Double(sampler.ripple(at: now - rippleWindow * (1 - u)))
                + shimmerDrive * Double(sampler.shimmer(at: now - shimmerWindow * (1 - u)))
                + voiceDrive * Double(sampler.voice(at: now - voiceWindow * (1 - u)))
        }
        // The two ends of the loop are the same *place* but different *moments*, so the detail there
        // doesn't match and the curve failed to close. Easing the last stretch back to the value at
        // u = 0 makes the ends meet exactly, with the join spread over an eighth of the loop rather
        // than landing on one point.
        let start = detail(0)

        var out = [SIMD3<Float>]()
        out.reserveCapacity(points)
        for i in 0..<points {
            let u = Double(i) / Double(points)
            let theta = u * 2 * .pi
            var d = detail(u)
            if u > 1 - seamBlend {
                let k = (u - (1 - seamBlend)) / seamBlend
                d += (start - d) * (k * k * (3 - 2 * k))     // smoothstep, so there's no corner
            }
            out.append(SIMD3(Float(sin(windings.x * theta + phase.x) * amplitude.x + d),
                             Float(sin(windings.y * theta + phase.y) * amplitude.y + d),
                             Float(sin(windings.z * theta + phase.z) * amplitude.z)))
        }
        return out
    }

    /// Rotate, tilt and project, returning screen offsets in units of the radius along with each
    /// point's depth.
    private func project(_ pts: [SIMD3<Float>], scale: Double,
                         at now: Double) -> [(point: CGPoint, depth: Double)] {
        let angle = now * spin
        let ca = Float(cos(angle)), sa = Float(sin(angle))
        let ct = Float(cos(tilt)), st = Float(sin(tilt))
        let s = Float(scale)
        return pts.map { raw in
            let p = raw * s
            let x1 = p.x * ca + p.z * sa, z1 = -p.x * sa + p.z * ca   // spin about the vertical
            let y1 = p.y * ct - z1 * st, z2 = p.y * st + z1 * ct      // then tilt
            // Clamped: the divisor grows without bound as a point comes towards the viewer, which
            // once threw a loud bass note clean off the screen.
            let perspective = min(1.30, max(0.70, 1 / (1 + Double(z2) * 0.45)))
            return (CGPoint(x: Double(x1) * perspective, y: -Double(y1) * perspective), perspective)
        }
    }

    /// Scale so the projected figure just fits the frame. Two passes, because the perspective divisor
    /// makes the mapping slightly non-linear. Measured size variation with this in place is ±1%: a
    /// peak-following gain, however tuned, lagged quiet passages and then threw the next loud frame
    /// off screen, which was the "bouncing".
    private func fitScale(_ pts: [SIMD3<Float>], at now: Double) -> Double {
        var scale = 1.0
        for _ in 0..<2 {
            var extent = 0.0
            for (p, _) in project(pts, scale: scale, at: now) { extent = max(extent, hypot(p.x, p.y)) }
            guard extent > 1e-6 else { return scale }
            scale *= 0.97 / extent
        }
        return scale
    }

    private func stroke(_ ctx: inout GraphicsContext, _ pts: [SIMD3<Float>], scale: Double,
                        at now: Double, centre: CGPoint, radius: CGFloat, opacity f: Double) {
        let projected = project(pts, scale: scale, at: now).map {
            (point: CGPoint(x: centre.x + $0.point.x * radius, y: centre.y + $0.point.y * radius),
             depth: $0.depth)
        }
        guard projected.count > 1 else { return }

        // One continuous pass: three glow widths and a bright core, all at the same brightness the
        // whole way round. Shading the core by depth (four bands, nearer stretches brighter) is gone
        // at the user's request — it read as banding on the line rather than as depth, and the sense
        // of three dimensions comes from the perspective scaling anyway.
        var whole = Path()
        curve(projected.map(\.point), into: &whole, closed: true)
        ctx.stroke(whole, with: .color(glow.opacity(0.030 * f)), lineWidth: 18 * lineScale)
        ctx.stroke(whole, with: .color(glow.opacity(0.055 * f)), lineWidth: 9 * lineScale)
        ctx.stroke(whole, with: .color(glow.opacity(0.14 * f)), lineWidth: 3.4 * lineScale)
        // 0.78 at 1.35 replaces the old 0.42 continuous core plus the ~0.36 the bands added on
        // average, so the beam keeps the weight it had.
        ctx.stroke(whole, with: .color(beam.opacity(0.78 * f)), lineWidth: 1.35 * lineScale)
    }

    /// Catmull-Rom through the points: a flowing beam rather than a polyline.
    ///
    /// `closed` wraps the indices so the loop is drawn all the way round. The open form covers every
    /// segment too, clamping at the ends — the earlier version started at the second point and
    /// stopped two short, which is what left a small gap where the knot met itself.
    private func curve(_ pts: [CGPoint], into path: inout Path, closed: Bool = false) {
        guard pts.count > 1 else { return }
        path.move(to: pts[0])
        guard pts.count > 3 else {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return
        }
        let n = pts.count
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = closed ? pts[(i - 1 + n) % n] : pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = closed ? pts[(i + 1) % n] : pts[i + 1]
            let p3 = closed ? pts[(i + 2) % n] : pts[min(n - 1, i + 2)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
    }

    /// Just the vignette: the CRT scanlines that were here read as a grid laid over the trace rather
    /// than as screen texture.
    private func finish(_ ctx: inout GraphicsContext, size: CGSize, centre: CGPoint) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.5)]), center: centre,
            startRadius: min(size.width, size.height) * 0.32,
            endRadius: max(size.width, size.height) * 0.72))
    }

    private func dot(_ ctx: inout GraphicsContext, at centre: CGPoint, radius: CGFloat) {
        for (r, alpha) in [(radius * 0.035, 0.10), (radius * 0.016, 0.30), (radius * 0.006, 0.9)] {
            let rect = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color((alpha > 0.5 ? beam : glow).opacity(alpha)))
        }
    }
}

extension ScopeSampler {
    /// A short synthetic track for the render harness and previews: a steady beat with content in all
    /// three bands, so the knot draws a recognisable figure without needing an audio file.
    static func synthetic(seconds: Double = 2) -> ScopeSampler {
        let rate = ScopeSampler.analysisRate
        let n = Int(seconds * rate)
        var mono = [Float]()
        mono.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / rate
            let beat = 0.4 + 0.6 * max(0, cos(2 * .pi * 2 * t))       // two hits a second
            mono.append(Float((sin(2 * .pi * 60 * t) * 0.5 * beat)
                              + sin(2 * .pi * 480 * t) * 0.2
                              + sin(2 * .pi * 3800 * t) * 0.08 * beat))
        }
        let lp150 = lowPass(mono, cornerHz: 150, rate: rate)
        let midBand = lowPass(highPass(mono, cornerHz: 300, rate: rate), cornerHz: 1200, rate: rate)
        let highBand = highPass(mono, cornerHz: 2000, rate: rate)
        let rippleSource = lowPass(mono, cornerHz: rippleCornerHz, rate: rate)
        var wave = [Int16]()
        var i = 0
        while i < rippleSource.count {
            wave.append(Int16(max(-1, min(1, rippleSource[i])) * 32767)); i += waveDecimation
        }
        let shimmerSource = lowPass(midBand, cornerHz: 1100, rate: rate)
        var shimmerWave = [Int16]()
        var j = 0
        while j < shimmerSource.count {
            shimmerWave.append(Int16(max(-1, min(1, shimmerSource[j])) * 32767)); j += shimmerDecimation
        }
        let presenceBand = presence(mono: mono, rate: rate)
        let ref = reference(of: mono, rate: rate)
        let bassTrack = track(lp150, rate: rate, attackMs: 25, releaseMs: 180, reference: ref, gain: 1.0)
        let midTrack = track(midBand, rate: rate, attackMs: 40, releaseMs: 260, reference: ref, gain: 1.7)
        let highTrack = track(highBand, rate: rate, attackMs: 20, releaseMs: 140, reference: ref, gain: 3.0)
        return ScopeSampler(bass: bassTrack, mid: midTrack, high: highTrack,
                            kick: kick(lp150, rate: rate), bandRate: rate / Double(bandHop),
                            wave: wave, waveRate: rate / Double(waveDecimation),
                            shimmer: shimmerWave, shimmerRate: rate / Double(shimmerDecimation),
                            presence: presenceTrack(mono: mono, side: [], rate: rate, reference: ref),
                            presenceWave: decimate(presenceBand, by: presenceDecimation),
                            presenceRate: rate / Double(presenceDecimation))
    }
}
