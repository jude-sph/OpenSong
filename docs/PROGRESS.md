# OpenSong — Progress

Live task tracker. Phase 1 has a full spec + plan; Phases 2–3 need their own
spec→plan cycles (will be added tonight if time allows).

## Phase 1 — Local library + device sync (26 tasks)

### Engine (headless, fully tested)
- [x] Task 0 — SwiftPM scaffold + TinyTest harness
- [x] Task 1 — PathSanitizer (FAT-safe)
- [x] Task 2 — Domain models
- [x] Task 3 — DeviceRelativePath (canonical path)
- [x] Task 4 — M3U8 writer (golden-byte match to real device)
- [x] Task 5 — M3U8 parser (round-trips golden)
- [x] Task 6 — Subprocess runner
- [x] Task 7 — AudioProbe (ffprobe)
- [x] Task 8 — Transcoder (ffmpeg + R128 + skip rule + tags)
- [x] Task 9 — LibraryStore (GRDB SQLite)
- [x] Task 10 — MetadataResolver (iTunes; offline + live verified)
- [x] Task 11 — ArtworkResolver (extract/embed/download)
- [x] Task 12 — Importer (loose import + adopt-from-device)
- [x] Task 13 — Volume + DeviceManager (scope-guarded)
- [x] Task 14 — SyncEngine (reconcile) (done)
- [x] Task 15 — End-to-end engine integration test

### UI (SwiftUI, recreates design docs; compiled + screenshotted tonight)
- [ ] Task 16 — Design tokens + app shell
- [ ] Task 17 — AppStore (observable, wires engines)
- [ ] Task 18 — Library browser (Songs/Albums/Artists)
- [ ] Task 19 — Metadata editor + art picker
- [ ] Task 20 — Import review table
- [ ] Task 21 — Playlists view
- [ ] Task 22 — Device view (capacity ring + sync diff)
- [ ] Task 23 — Settings (device format MP3/AAC only)
- [ ] Task 24 — Preview player + menu bar extra

### Packaging
- [ ] Task 25 — .app bundle assembly + launch + screenshot
- [ ] Task 26 — Morning handoff report

## Phase 2 — Acquisition (yt-dlp) — not yet spec'd
- yt-dlp candidate review → download pipeline
- Metadata cleanup (heuristic/Ollama now; Foundation Models when on macOS 26)
- Acoustic fingerprint verification (needs `fpcalc`)
- Spectral quality check (ffmpeg FFT)
- Lyrics (LRCLIB)

## Phase 3 — Apple Music — not yet spec'd
- Browse/compare via osascript, mark-to-acquire, import local non-DRM
- Stretch: embedding playlists/dedup, mood/BPM, capacity optimizer

## Test status
`swift run OpenSongTests` — 50 passing, 1 live-only skipped (as of Task 15). ENGINE COMPLETE.
Run live network tests with `OPENSONG_LIVE=1 swift run OpenSongTests`.
