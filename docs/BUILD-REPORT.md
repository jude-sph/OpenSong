# OpenSong — Build Report (all 3 phases)

**Status:** Phases 1–3 complete, tested, and pushed to `github.com/jude-sph/OpenSong`
(branch **`phase-1`**; specs/plans on branch history + `docs/`). ~6,000 lines Swift,
**72 passing tests** (76 total; 4 gated live/hardware tests), 11 rendered screens.

## What's built

**Phase 1 — Library + device sync**
- Master library (readable tree + GRDB index), import from user-chosen folders (review sheet,
  iTunes suggestions, dedup, never-downgrade), adopt-from-device (+ playlist reconstruction).
- ffmpeg transcode → MP3 192k + EBU R128, skip-transcode rule; scope-guarded device manager;
  idempotent, foreign-file-safe reconciling sync; `.m3u8` byte-identical to the real NW-E394.
- Full UI: library (songs/albums/artists), device view (live capacity ring + sync diff),
  playlists, settings, metadata editor, preview player, menu bar extra. Wired to the engines.

**Phase 2 — Acquisition (yt-dlp)**
- Wishlist (states + custom items), TitleCleaner, yt-dlp search/download (live-verified),
  candidate ranking by duration, download that stamps the *known* identity (never re-derives),
  import as `.downloaded`. Verification: duration + spectral cutoff + AcoustID (free key,
  graceful fallback). Art picker (iTunes / adjustable YouTube crop). UI: Pending + Match review.

**Phase 3 — Apple Music**
- Read library via osascript/JXA (parser + fuzzy ownership compare, unit-tested), mark-missing
  → wishlist, import non-DRM local files. UI: Compare (owned/missing bars, mark-missing).

## Verified on real hardware / services
- `.m3u8` round-trips a **real 23-track device playlist byte-for-byte**.
- Live **yt-dlp** search and live **iTunes** metadata both pass.
- Real **fpcalc** fingerprinting passes. Spectral cutoff discriminates band-limited vs full.

## Gated tests (run when ready)
- `OPENSONG_LIVE=1 swift run OpenSongTests` — live iTunes + yt-dlp + Apple Music (Music.app +
  Automation permission prompt on first use).
- `OPENSONG_DEVICE_TEST=1 swift run OpenSongTests` — self-cleaning real Walkman write test
  (plug in the device first; it auto-unmounts when idle).

## How to run
```bash
swift run OpenSongTests            # 72 tests
./Scripts/make-app.sh              # build build/OpenSong.app (no Xcode)
open build/OpenSong.app            # launch; Import… to add your folders, Sync to the Walkman
```

## Notes / caveats
- **Screenshots** (`docs/screenshots/`) are rendered offscreen via `ImageRenderer` — the
  automation session can't composite a live window to the display (Spaces), but the real app
  window shows normally when you launch it yourself.
- **No Xcode required** anywhere. CLT-only: Swift 6, ffmpeg/ffprobe/fpcalc, yt-dlp, osascript.
- **Deferred by your choice:** stretch ML (audio embeddings / mood / BPM), on-device LLM
  (iTunes canonical metadata covers cleanup; Ollama hook can be added later).
- **AcoustID**: free; paste a key in Settings to enable acoustic verification (falls back to
  duration+spectral without it).

## Suggested next steps
1. Launch it, import your real folders, and sync to the Walkman (watch a real end-to-end).
2. Run the gated hardware + live tests with the device plugged / Music.app authorized.
3. Optional polish: real audio-preview wiring for downloaded m4a, art-picker UI in match review,
   Apple Music album/artist collections (currently playlists), and any stretch features you want.
