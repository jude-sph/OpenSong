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
- [x] Task 16 — Design tokens + app shell
- [x] Task 17 — AppStore (observable, wires engines)
- [x] Task 18 — Library browser (Songs/Albums/Artists)
- [x] Task 19 — Metadata editor + art picker
- [x] Task 20 — Import review table
- [x] Task 21 — Playlists view
- [x] Task 22 — Device view (capacity ring + sync diff)
- [x] Task 23 — Settings (device format MP3/AAC only)
- [x] Task 24 — Preview player + menu bar extra

### Packaging
- [x] Task 25 — .app bundle assembly + launch + screenshot
- [x] Task 26 — Morning handoff report

## Phase 2 — Acquisition (yt-dlp) — COMPLETE
- [x] TitleCleaner, YtDlpSource (live search verified)
- [x] SpectralAnalyzer, Fingerprinter + AcoustID
- [x] ArtworkCrop, WishlistStore, AcquireCoordinator (full pipeline)
- [x] UI: Wishlist/Pending + Match review + settings AcoustID key
- yt-dlp candidate review → download pipeline
- Metadata cleanup (heuristic/Ollama now; Foundation Models when on macOS 26)
- Acoustic fingerprint verification (needs `fpcalc`)
- Spectral quality check (ffmpeg FFT)
- Lyrics (LRCLIB)

## Phase 3 — Apple Music — COMPLETE
- [x] AppleMusicBridge (JXA/osascript) + parser
- [x] Fuzzy ownership compare (owned vs missing)
- [x] Mark-missing -> wishlist, import non-DRM local files
- [x] UI: Compare view (owned/missing bars, mark-missing)
- Browse/compare via osascript, mark-to-acquire, import local non-DRM
- Stretch (deferred by choice): embedding playlists/dedup, mood/BPM, capacity optimizer

## Test status
`swift run OpenSongTests` — 51 passing (53 total; live iTunes + real-device tests gated). PHASE 1 COMPLETE (engine + UI + wiring).
Run live network tests with `OPENSONG_LIVE=1 swift run OpenSongTests`.
