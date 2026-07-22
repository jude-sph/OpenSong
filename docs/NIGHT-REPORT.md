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

**Still to wire (the natural "do it together" morning task):** the UI *buttons* aren't yet
connected to the engines — "Choose folder…" (import), "Sync", "Save to file tags", path
pickers, pin/delete. The engines they'll call are all built and tested; this is
NSOpenPanel + action wiring, best done with you present and the device plugged in so we
can watch a real import → sync end-to-end. Sample data gets replaced by your real library
through that first import/adopt.

## How to run it

```bash
cd ~/Documents/projects/OpenSong
swift run OpenSongTests           # 50 tests (add OPENSONG_LIVE=1 for the 51st, live)
./Scripts/make-app.sh             # builds build/OpenSong.app (no Xcode needed)
open build/OpenSong.app           # launch in your session

# regenerate screenshots headlessly:
OPENSONG_RENDER=1 OPENSONG_RENDER_DIR=/tmp/shots ./build/OpenSong.app/Contents/MacOS/OpenSong
```

## Verification checkpoints (need you / the device)

1. **Reconnect the Walkman** so I can (a) re-confirm our generated `.m3u8` is byte-identical
   to the device's own files, and (b) run a real import → adopt → sync end-to-end on hardware.
2. Confirm album ordering on the device after we backfill track-number tags (bare filenames
   rely on ID3 track numbers — your existing files mostly had `track=0`).
3. R128-normalized 192k files sound right on the device.

## Non-blocking questions for whenever

1. **Where's your messy music folder?** I'll point the first real import at it (replaces
   the sample data) once we wire the import button.
2. Want me to **wire the UI↔engine actions next**, or start **Phase 2 (yt-dlp acquisition)**?
   Phase 2 needs its own brief→spec→plan pass; note the CLT SDK targets macOS 15, so the
   on-device LLM cleanup will use a heuristic/Ollama path (Foundation Models needs macOS 26).
3. Optional: installing **Xcode** would give a nicer interactive debug loop, but it's not
   required for building, testing, or shipping this.

## Commit trail

`phase-1` branch, ~20 commits — scaffold → each engine (TDD, one commit per green module)
→ full UI → render verification. `docs/PROGRESS.md` has the task checklist;
`docs/superpowers/specs/` and `docs/superpowers/plans/` have the spec and plan.
