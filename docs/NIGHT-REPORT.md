# OpenSong — Overnight Build Report (2026-07-22)

Good morning! Here's what got built while you slept. **Phase 1 is functionally
complete**: the entire engine layer (tested) and the full SwiftUI UI (rendered &
verified in light + dark). Everything is committed and pushed to
`github.com/jude-sph/OpenSong` on branch **`phase-1`** (spec lives on `main`).

## TL;DR

- **51 automated tests pass** (`swift run OpenSongTests`), including a live iTunes API test.
- **All 9 engine modules built test-first** — import, adopt-from-device, iTunes metadata
  resolve, artwork, ffmpeg transcode (R128 + skip rule), GRDB library index, scope-guarded
  device manager, and the reconciling sync engine.
- **Full SwiftUI UI** recreating your design docs (British Racing Green, light + dark) —
  see `docs/screenshots/` for 8 rendered screens.
- **The device format is verified against your real Walkman** — the `.m3u8` writer
  reproduces its exact bytes (BOM + CRLF + backslash paths), proven by a golden test.

## Correction to my earlier caveat

I was wrong last night that we'd need Xcode installed to run/screenshot the app — the
other Claude was right. Everything built, bundled (`.app`), and got visually verified
**without Xcode**, using Command Line Tools only. The *live* on-display screenshot was
blocked by a window-server/Spaces quirk in this automation session (the app window
renders to a Space the headless `screencapture` can't reach), so I verified the UI with
SwiftUI's offscreen `ImageRenderer` instead — display-independent, and the screenshots in
`docs/screenshots/` are the result. When **you** launch it in your own session
(`open build/OpenSong.app`) the window should appear normally.

## What's real vs. what still needs wiring

**Real and tested (engine layer — 51 tests):**
- Loose-file import with review candidates, hash dedup, never-downgrade, master-tree placement
- Adopt-from-device: imports device tracks + reconstructs playlists from real `.m3u8`
- iTunes metadata resolver (canonical tags + track#/disc# backfill, duration-matched) + artwork
- ffmpeg transcode to MP3 192k + EBU R128 loudness norm + skip-transcode rule + tag write
- GRDB library index (identities/assets/playlists/pins/device state)
- Device manager (UUID identity, `MUSIC/`-scoped writes, foreign-file safety, `.m3u8` gen)
- Reconciling sync engine (add/remove/up-to-date diff, capacity projection, idempotent)

**Real (UI):** every Phase 1 screen renders from a real GRDB store (seeded with sample
data), in light + dark. Sidebar, library (songs/albums/artists), device view with live
capacity ring + sync diff, playlists, settings, metadata editor, preview player, menu bar.

**UI↔engine wiring is now DONE too** (you asked me to just do it — I did):
- **Import** from folders *you* choose (multi-select `NSOpenPanel`, never hardcoded) →
  scans → iTunes suggestions → review sheet (Original vs Suggested per row) → imports into
  the master tree. The empty library prompts you to Import to get started.
- **Sync** button runs the real reconciling engine against the mounted Walkman.
- **Settings** library folder + tool paths via pickers, persisted (UserDefaults).
- **Metadata editor** saves to the identity and writes ID3 tags; pin/unpin + Reveal in Finder.
- Sample data now seeds **only** in render mode; the real app starts empty and clean.

So the app is fully usable end-to-end. The one thing left is watching a real
import→sync on the physical device (see below).

## How to run it

```bash
cd ~/Documents/projects/OpenSong
swift run OpenSongTests           # 50 tests (add OPENSONG_LIVE=1 for the 51st, live)
./Scripts/make-app.sh             # builds build/OpenSong.app (no Xcode needed)
open build/OpenSong.app           # launch in your session

# regenerate screenshots headlessly:
OPENSONG_RENDER=1 OPENSONG_RENDER_DIR=/tmp/shots ./build/OpenSong.app/Contents/MacOS/OpenSong
```

## Real-device verification status

- ✅ **`.m3u8` byte-identity confirmed on real hardware** — I captured a fresh playlist
  from your Walkman and a test round-trips it byte-for-byte (`device-aphex-real.m3u8`).
- ⏳ **Live write-to-device test is written and ready but didn't get to run** — your Walkman
  **auto-unmounted** (these players drop off USB when idle; it wasn't in `/Volumes` by the
  time the write test ran). The test (`OPENSONG_DEVICE_TEST=1 swift run OpenSongTests`) is
  self-cleaning: it writes two `OpenSong SelfTest` tracks + a playlist, verifies them on the
  device, then removes them — leaving your device untouched. Re-plug the Walkman and run it
  (or just click **Sync** in the app) to close this loop.

Still worth confirming with the device in hand:
1. Album ordering after track-number backfill (bare filenames rely on ID3 track numbers).
2. R128-normalized 192k files sound right on the device.

## Non-blocking questions for whenever

1. **Try it:** `open build/OpenSong.app`, click **Import…**, pick your messy folders, and
   review/import. Then re-plug the Walkman and hit **Sync**. Tell me if anything feels off.
2. Next up: **Phase 2 (yt-dlp acquisition)**? It needs its own brief→spec→plan pass; note the
   CLT SDK targets macOS 15, so on-device LLM cleanup will use a heuristic/Ollama path
   (Foundation Models needs macOS 26). Or I can polish/adopt-from-device flow in the UI first.
3. Optional: installing **Xcode** gives a nicer interactive debug loop, but it's not required.

## Commit trail

`phase-1` branch, ~20 commits — scaffold → each engine (TDD, one commit per green module)
→ full UI → render verification. `docs/PROGRESS.md` has the task checklist;
`docs/superpowers/specs/` and `docs/superpowers/plans/` have the spec and plan.
