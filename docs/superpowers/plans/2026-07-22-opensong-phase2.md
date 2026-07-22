# OpenSong Phase 2 Plan — Acquisition (yt-dlp)

> Execute task-by-task, TDD, one commit per green module. Builds on Phase 1 engines.

**Tools:** `yt-dlp` 2026.07.04, `ffmpeg`/`fpcalc` 1.6.0. Live network tests gated by `OPENSONG_LIVE=1`.

### Task 1 — TitleCleaner
- `enum TitleCleaner { static func parse(_ raw: String) -> (artist: String?, title: String, query: String) }`
- Strip `(Official Video|Audio|Lyrics)`, `[...]`, `HD/4K/Remaster`, trailing `| Label`; split on ` - ` into artist/title; produce a clean search `query`.
- Tests: real messy titles → expected artist/title/query.

### Task 2 — YouTubeSource protocol + Candidate + YtDlpSource
- `struct Candidate { videoID, url, title, channel, durationSec, viewCount?, thumbnailURL? }`
- `protocol YouTubeSource: Sendable { func search(_ term: String, limit: Int) async throws -> [Candidate]; func download(_ url: URL, to dst: URL) async throws }`
- `struct YtDlpSource: YouTubeSource { var ytDlpPath; ... }` — search via `yt-dlp -j --flat-playlist "ytsearch{n}:{term}"` (parse JSON lines); download via `yt-dlp -f bestaudio -x --audio-format m4a --embed-metadata -o dst`.
- Tests: JSON-line parse from canned `yt-dlp -j` output (pure parse function tested directly); live search gated.

### Task 3 — SpectralAnalyzer
- `struct SpectralAnalyzer { var ffmpegPath; func cutoffHz(_ url: URL) throws -> Double; func verdict(cutoffHz, bitrateKbps) -> SpectralVerdict; func spectrogram(_ url, to png) throws }`
- cutoff via ffmpeg `aspectralstats`/`astats` or a lowpass-energy sweep; verdict flags "likely upsampled" when cutoff ≪ expected for the claimed bitrate.
- Tests: generate 44.1k tone, lowpass to 8 kHz → cutoff ≈8 kHz (±1.5k); full-band → >18 kHz.

### Task 4 — Fingerprinter + AcoustIDClient
- `struct Fingerprint { fingerprint: String; durationSec: Int }`
- `struct Fingerprinter { var fpcalcPath; func fingerprint(_ url) throws -> Fingerprint }`
- `struct AcoustIDRecording { artist: String; title: String; score: Double }`
- `struct AcoustIDClient { var http: HTTPClient; func lookup(_ fp: Fingerprint, apiKey: String) async throws -> [AcoustIDRecording] }` (GET api.acoustid.org/v2/lookup?client=KEY&meta=recordings&fingerprint&duration)
- Tests: real fpcalc → non-empty fingerprint + duration; AcoustID JSON parse via stub; live gated by key+`OPENSONG_LIVE`.

### Task 5 — ArtworkCrop
- `enum ArtworkCrop { static func squareCrop(of image: URL, to dst: URL, ffmpegPath, offsetFraction: Double = 0.5) throws }` — crop 16:9 → centered square (offset adjustable).
- Test: make a 320x180 png → crop → assert 180x180 output via ffprobe.

### Task 6 — WishlistStore (LibraryStore ext, migration v3)
- `struct WishItem { id?, title, artist, album?, durationSec?, source: WishSource, state: WishState, chosenURL?, assetID? }`; enums `WishSource{custom,appleMusic}`, `WishState{wishlist,matching,downloaded}`.
- `addWish/allWishes/updateWish/deleteWish` + link assetID on completion.
- Tests: CRUD + state transitions.

### Task 7 — AcquireCoordinator
- `struct AcquireCoordinator { store, source: YouTubeSource, importer, transcoder, artwork, resolver, spectral, fingerprinter, settings }`
- `func candidates(for: WishItem) async throws -> [RankedCandidate]` (search + rank by durationDelta)
- `func acquire(_ wish: WishItem, chosen: Candidate, art: URL?, downloadDir: URL) async throws -> (asset: AudioAsset, verify: VerifyResult)` — download → stamp metadata (known identity) → embed art → import as `.downloaded` → verify → mark wish downloaded.
- `VerifyResult` + `RankedCandidate { candidate, durationDelta, confidence }`.
- Tests: with a **stub YouTubeSource** returning a generated m4a → full pipeline creates a `.downloaded` asset, wish item → downloaded, verify populated (duration High). Never-download-then-guess: metadata comes from the wish identity, not the candidate title.

### Task 8 — Engine integration test
- wishlist add (custom "Aphex Twin – Avril 14th") → resolve identity (stub iTunes) → candidates (stub) → acquire (stub download) → asset in library, wish downloaded, verify.

### Task 9 — UI: Wishlist view + AppStore wiring
- `WishlistView` (sidebar Pending): state pills, source badges, add-custom sheet, Review button.
- AppStore: `wishItems`, `addCustomWish`, `beginMatch(wishID)`, load from store.

### Task 10 — UI: Match review screen + art picker
- `MatchReviewView`: candidate cards (radio), paste-URL, metadata panel (locked/editable by provenance), art picker (iTunes / YT crop / custom), Download → progress → done/error, spectral reveal.
- Wire `AppStore.acquire(...)`.

### Task 11 — Render + verify
- Add wishlist + match-review to the offscreen render set; screenshot both themes.
