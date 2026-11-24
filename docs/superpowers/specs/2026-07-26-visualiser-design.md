# Oscilloscope Visualiser — Design

**Status:** approved 2026-07-26; built and shipped in v0.4.0 the same day.

A separate, chrome-free window that draws the playing track as an X-Y oscilloscope trace: left
channel horizontal, right channel vertical, rendered like a CRT with phosphor afterglow. Sized from
a small desktop tile to fullscreen on a second monitor.

## Goal

Give playback a visual companion that is *actually the music* — the figure on screen is the stereo
signal, not an animation loosely scaled by loudness. Chosen from six style mockups rendered in real
SwiftUI; "pure ice" won: cyan-white beam, no graticule, long afterglow.

## Non-goals

- No album artwork anywhere in this window (explicitly rejected during design).
- No second visual style. A tunnel style was mocked and dropped; the data feed would support one
  later, but nothing is built for it now.
- No spectrum/FFT. An X-Y scope needs raw waveform, not frequency bands.
- No visualiser for YouTube streaming previews — there is no local file to read.

## User-facing behaviour

**Opening.** A button in the player bar, beside the album-art one. The visualiser is its own window;
it and the art window can be open at once.

**The window.** Plain `NSWindow` (never `NSPanel`: with Stage Manager enabled macOS re-places
panel-class windows after a drag — see FEEDBACK v0.3.37). Chrome appears on hover only: track title
and artist, transport buttons, close. Traffic lights hidden until hover. Draggable from anywhere via
the existing `WindowDragLayer` (`performDrag(with:)`, not `isMovableByWindowBackground`). Its own
remembered frame. No aspect-ratio lock, and native fullscreen enabled, so it fills a 16:9 display.

**The trace.** A slowly rotating 3-D trajectory, not a flat X-Y figure. Values below were chosen by
rendering *real* audio and comparing — the first attempt (plain left-against-right over a 24 ms
window) drew the diagonal smear that centred mixes always produce:

| | value | why |
|---|---|---|
| low-pass corner | 250 Hz (in the sampler, once at decode) | broadband content draws a scribble; bass and mid draw loops |
| embedding lag | 9 ms between each of the three axes | short lags knot the figure up; this opens it |
| sweep | 26 ms, 220 points | enough to show shape without packing in hundreds of cycles |
| afterglow | 11 sweeps, 0.78 decay, 20 ms apart | the layered-ghost look |
| spin / tilt | 0.30 rad·s⁻¹ / 0.42 rad | reads as a solid turning, rather than a spinning label |
| depth | stereo width × 0.7 on the Z axis, 4 shading bands, perspective clamped to 0.70–1.30 | near stretches brighter and thicker; the clamp stops a loud note flying off-screen |
| gain | chases the 2 s peak to 0.85, settling at 2 % per frame | a quiet master still fills the frame, but the track's dynamics survive |
| pump | beat energy ÷ average, ×0.5, capped at 1.4 | the figure swells on hits |
| glow | 18 pt / 9 pt / 3.4 pt / ~1.8 pt core in `.plusLighter` | light accumulating on phosphor |

Curves are Catmull-Rom through the points, so the beam flows rather than showing polygon corners.
Scanlines and a vignette finish it.

**States**, all of which are just what a real beam does:

| situation | on screen |
|---|---|
| nothing playing | centre dot |
| decoding (first ~0.3 s of a track) | centre dot |
| playing | the trace |
| paused | trace freezes, afterglow decays to a dot |
| mono file | 45° diagonal line — genuinely what mono looks like in X-Y |
| streaming preview / unreadable file | centre dot |
| end of track | centre dot |

## Architecture

Three components, each independently understandable and testable.

### `ScopeSampler` — `Sources/OpenSongCore/ScopeSampler.swift`

Owns one decoded track, already shaped for drawing: low-passed mid/side plus a coarse beat envelope,
all computed in the one decode pass. A `final class`, so ownership is explicit and lifetime is
testable with a weak reference. Buffers are Swift `[Int16]` arrays — ARC-managed, no manual
allocation.

```swift
public final class ScopeSampler: Sendable {
    public static func decode(_ url: URL, targetRate: Double? = nil,
                              cornerHz: Double = 250) throws -> ScopeSampler
    /// One sweep as a 3-D trajectory: the signal against itself at two lags, stereo width on Z.
    public func trace(at: Double, span: Double, points: Int,
                      lag: Double, widthDepth: Float) -> [SIMD3<Float>]
    public func punch(at seconds: Double) -> Float        // beat energy ÷ average
    public func peak(before seconds: Double, window: Double) -> Float   // for auto-gain
    public var duration: Double { get }
    public var sampleRate: Double { get }
}
```

Plotting left against right — what a scope literally does — collapses to a 45° line for any centred
mix, i.e. most music. The delay embedding stays honest (it is nothing but the waveform) while drawing
loops whose size follows the bass and whose detail follows the harmonics.

Decoding uses `AVAudioFile` + `AVAudioConverter` to 22 kHz stereo, stored as `Int16` (~5 MB per
minute of audio). Tracks longer than 20 minutes decode at 11 kHz instead, halving the footprint;
the beam draws only a few hundred points per frame, so the difference is invisible. The decode loop
checks `Task.isCancelled` and abandons its buffers if the track changed.

### `ScopeView` — `Sources/OpenSong/ScopeView.swift`

A `Canvas` redrawn by `ScopeClock`, a 60 Hz timer added to the run loop in `.common` mode. Per frame:
read the playhead, ask the sampler for 11 sweeps, project and stroke them.

`TimelineView(.animation)` was the first choice and does not work here: instrumenting every frame
showed **3 frames in the first 392 ms, then nothing**, which on screen looked like half a frame per
second. The clock also carries the auto-gain, the one piece of state that must persist between
frames.

Under `renderMode` (the offscreen `ImageRenderer` harness) it draws a single frame at a fixed time
from a synthetic sampler, so it appears in the screenshot set without animation.

### `VisualiserWindow` — `Sources/OpenSong/VisualiserWindow.swift`

`NSViewRepresentable` + coordinator that owns the window, mirroring `ArtPanelPresenter` and reusing
its lessons: act only on show/hide transitions, hand-rolled frame persistence, `WindowDragLayer`
for dragging, hover-hidden traffic lights.

Open state is `PreviewPlayerModel.showVisualiser`, alongside the existing `showArtWindow`, so the two
windows are independent and the player model is the single place that knows whether a decode is
warranted.

## Data flow

```
track starts  → AVAudioPlayer created and play() called          (unchanged, never delayed)
              → if the visualiser window is open:
                    Task.detached { ScopeSampler(decoding: masterURL) }   ~0.2–0.3 s
                    → on MainActor, install it only if the generation still matches

each frame    → TimelineView tick (display-linked)
              → playhead = model.audioTime   ← reads AVAudioPlayer.currentTime directly, so the
                                               figure tracks the audio rather than the model's
                                               250 ms publish tick
              → sampler.window(at: playhead − k·0.022, count: 520), k in 0…10
              → Canvas draws 11 traces, oldest first
```

**Playback is never blocked by the decode.** The player starts first; the sampler arrives later and
the scope shows its dot until it does.

## Memory and lifetime

~20 MB per loaded track makes this the one place where a leak would actually hurt, so the rules are
explicit:

1. **One owner.** The sampler lives in a single property on the player model. Nothing else retains
   it; `ScopeView` receives it per frame and does not store it.
2. **Decode only while the window is open.** Closed window → no decode, no buffers, zero cost.
3. **Released on every exit path:** window closed, track changed, playback stopped, app quit. The
   old sampler is cleared *before* a new decode starts, so two never coexist.
4. **No cycles.** The decode task captures `[weak model]` and a generation number; a late result
   from a superseded task is dropped rather than installed.
5. **Cancellation.** Skipping tracks cancels the in-flight decode, which abandons its partial
   buffers at the next loop check.
6. **No unsafe memory.** Swift arrays only — no `UnsafeMutablePointer`, no manual free to get wrong.

**Verification (required, not optional):**

- A unit test that holds a `weak var` to a sampler, drops the strong reference, and asserts it
  deallocates — repeated across a create/destroy cycle.
- A unit test that cancels a decode mid-flight and asserts the sampler is not installed.
- An empirical check after implementation: repeated decode → hold → draw → drop cycles, watching
  resident memory. **Measured:** the first batch of 20 loads costs ~31 MB (the allocator claiming
  its working set plus CoreAudio codec setup); every batch after that adds **0.0 MB**, and 120
  further decodes drifted 0.3 MB in total. A leak would have repeated the ~100 MB. Decoding without
  building a sampler showed the same flat profile, so CoreAudio isn't accumulating either. This is
  now the shipped test `resident memory holds steady across 60 track loads`.

## Performance budget

Measured on this machine before committing to the approach (`ImageRenderer`, i.e. CPU rasterisation;
live `Canvas` is GPU-backed and should be faster):

| case | ms/frame | headroom at 60 fps |
|---|---|---|
| 560² window, 520 seg × 11 traces | 8.3 | 2.0× |
| 900² window | 6.0 | 2.8× |
| 2560×1440 fullscreen | 6.0 | 2.8× |
| 1440p at 360 seg × 7 traces | 3.0 | 5.6× |

Cost tracks segment count, not pixel count, so fullscreen is no more expensive than a small window.
Decode measured at 0.19–0.31 s for 3.7–6.4 minute tracks. If a Retina fullscreen ever drops frames,
segments and persistence are the knob.

## Testing

- **`ScopeSampler` (unit, `OpenSongTests`)** — synthesise a WAV with a known sine in L and cosine in
  R; assert the window at a given offset matches expected values; assert clamping before zero,
  silence past the end, mono duplication into both axes, and the 11 kHz path for long files.
- **Lifetime (unit)** — the weak-reference deallocation test above.
- **`ScopeView` (render harness)** — one offscreen frame from a synthetic sampler, added to the
  screenshot set.
- **Manual** — open the window, play, pause, skip, resize, fullscreen on the second monitor, close
  and reopen (position remembered), drag with Stage Manager enabled.

## Out of scope (possible later)

Second visual style (the tunnel), per-track colour, visualiser for streaming previews, and a
"visualiser follows the art window" layout mode.

---

# Revision, 2026-07-27 (v0.5.0): band-driven knot

The design above shipped, ran at 60 fps, and was then rejected on how it looked: *"remove the
bouncing, it looks kind of cheap"* and *"kind of like a frantic scribble all over the screen, it
doesn't seem to be obviously representing the sound of the song."* Both complaints turned out to be
structural rather than matters of tuning, so this section replaces the drawing model and the sampler.

## Why the waveform model could not be tuned into shape

Measured on two real tracks (a dense one and a quiet one), rendering candidates offscreen:

| problem | cause | measurement |
|---|---|---|
| bouncing | the auto-gain. Any peak follower lags a quiet passage, then scales the next loud sweep off screen | size variation ±17% (dense) and ±40% (quiet), frames clipped by the window |
| frantic | at 60 fps frames are 16.7 ms apart while a sweep was 26 ms of audio *starting at the playhead* — consecutive frames shared almost no audio | frame-to-frame change 0.90 (occupancy-grid difference) |

Alternatives tried and rejected, each on its own measurement:

- **Scope trigger** (sweep from a rising zero crossing) — helped stability, change still 0.88.
- **Period lock** (timebase from autocorrelation) — change still 0.93: locking the period does not
  choose the same *cycle*, and successive cycles of music genuinely differ.
- **Superimposing 8–12 cycles** — change fell to 0.50, but the figure became a dense knot of ink.
- **Period-synchronous averaging** — one clean loop, but averaging cancels amplitude and flattens it.
- **Temporal blending of sweeps** — same cancellation: the figure shrank and dimmed.
- **Polar envelope ring** — big and stable (size ±3%), but hairy, and it read as an amoeba.

## What shipped

**Form: a Lissajous knot.** A closed 3-D curve, `sin(3θ+φ₁)`, `sin(4θ+φ₂)`, `sin(5θ+φ₃)`, 620 points,
which winds through itself and reads as a solid turning in space.

**Drive: three band energies, not samples.** Bass (<150 Hz), mid (300–1200 Hz) and treble (>2 kHz),
each envelope-followed with its own attack/release (25/180, 40/260, 20/140 ms). These move on a
musical timescale, so consecutive frames are close relatives: **frame-to-frame change 0.19**. Each
band stretches one axis, so music *deforms* the figure; nothing scales it.

**Detail: the waveform still rides the line.** A 220 Hz low-passed wave is wrapped around the curve
over the last 0.4 s as a ±6% ripple, so the picture is the audio rather than an animation beside it.
220 Hz is the ceiling: higher aliases into hair at the spacing the line is drawn with.

**Size: fitted, not gained.** Each frame measures its own projected extent and scales to 97% of the
frame. Measured size variation **±1%**. Loudness goes to brightness (0.62–1.0) and to how fast the
phases precess, never to size.

**One shared band reference.** Bands are divided by the 97th percentile of the *whole* signal's
envelope, with per-band gains (1.0 / 1.7 / 3.0) offsetting music's spectral tilt. Normalising each
band against itself — the first implementation, caught by a test — drove the treble axis to full on a
bass-only passage, because a tiny residual is still that band's own maximum.

## Consequences

- **Memory: ~0.4 MB per minute**, down from ~5 MB — band envelopes at 172 Hz plus a wave decimated to
  2205 Hz, instead of full-rate mid/side. A 4-minute track costs ~1.6 MB.
  The resident-memory test is therefore gone: at this size a leak can no longer be told from
  allocator noise. The weak-reference deallocation test (10 create/drop cycles) is the real check.
- **Draw cost: 0.62 ms/frame** at 1290×874 (was 1.6 ms), measured live at 60.0 fps. Two layers of
  ~5 strokes replace six traces × four bands × four strokes.
- **Drawing rules learned the hard way:** depth banding must never reorder points on a closed curve
  (it drew a chord across the figure), and the bright core must be drawn continuously with the bands
  laid over it additively (banded-only left it dashed wherever a band lasted one point).

## Sampler API (replaces the `trace`/`punch`/`peak` interface)

```swift
public struct Bands { let bass, mid, high: Float; var energy: Float }
public func bands(at seconds: Double) -> Bands      // silent outside the track
public func ripple(at seconds: Double) -> Float     // −1…1, low-passed at 220 Hz
public static func decode(_ url: URL) throws -> ScopeSampler   // cancellation-aware
```
