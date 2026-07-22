# OpenSong — Phase 1 Design: Local Library + Device Sync

**Date:** 2026-07-22
**Status:** Draft for review
**Scope:** Phase 1 only (local master library + Sony NW-E394 sync). Phases 2–3 summarized as deferred.

---

## 1. Overview

OpenSong is a personal, native macOS (SwiftUI) app for managing a music library and
syncing it to a **Sony Walkman NW-E394** (8 GB MP3 player that mounts as a FAT32 USB
volume). The **Mac holds high-quality master files as the source of truth**; the
player is a **sync target** that receives bitrate-reduced, loudness-normalized copies.

The app is **un-sandboxed** (local Developer ID build) so it can freely run
subprocesses (`ffmpeg`, `ffprobe`, `yt-dlp`, `osascript`), access removable volumes,
and reach the network — none of which a sandboxed app can do cleanly.

### Phase 1 goal

Get masters *into* the system (import messy loose files + adopt what's already on the
device), organize them into a clean library, curate a "device set," and run a safe,
reconciling sync that produces the exact on-disk format the NW-E394 expects.

---

## 2. Scope

### In scope (Phase 1)

- **LibraryStore** — SQLite index (GRDB) over a human-readable master file tree.
- **Importer** — loose-file import (with review table) and adopt-from-device (parse
  existing tracks + `.m3u8` playlists), with tag+duration dedup.
- **MetadataResolver** — iTunes Search API → canonical title/artist/album/track#/
  disc#/genre/year, disambiguated by duration. Used only when identity is unknown.
- **ArtworkResolver** — embedded art → official iTunes cover → user-supplied.
- **Transcoder** — `ffmpeg` transcode to device target (default MP3 192 kbps) with
  **EBU R128 loudness normalization**; skip-transcode when already at/below target.
- **DeviceManager** — detect the Walkman by volume UUID, reconciling sync scoped to
  `MUSIC/`, `.m3u8` playlist generation in the device's exact byte format.
- **UI** — library browser (songs/albums/artists), metadata editor + art picker,
  import review table, playlists, device view with live capacity ring + sync diff,
  settings, in-app preview player, menu bar extra.

### Deferred (later phases, designed-toward but not built now)

- **Phase 2 — Acquisition:** yt-dlp candidate review → download pipeline; local-LLM
  (Apple Foundation Models, swappable to Ollama) title cleanup; acoustic fingerprint
  match-verification (Chromaprint/AcoustID); spectral quality check; lyrics (LRCLIB).
- **Phase 3 — Apple Music:** browse/compare playlists/albums/artists via `osascript`,
  mark-to-acquire → wishlist, import non-DRM local files, Apple Music artwork via
  `osascript`. Stretch: audio-embedding smart playlists/dedup, mood/BPM tagging,
  "fill the rest" capacity optimizer, drag-to-pin, library health dashboard.

### Non-goals

- No playback *control of the device* (we only read/write its files).
- No live filesystem watching in Phase 1 (manual re-scan button).
- No lyrics in Phase 1 (device can't display them anyway).

---

## 3. Architecture

Thin SwiftUI UI over focused engine services. Three engines wrap external processes
that fail in messy ways, so each is isolated and independently testable.

| Module | Responsibility | Depends on |
|---|---|---|
| **LibraryStore** | SQLite index + master tree; source of truth | GRDB, filesystem |
| **Importer** | Loose-file import + adopt-from-device; dedup; tree placement | LibraryStore, MetadataResolver, ArtworkResolver, ffprobe |
| **MetadataResolver** | Canonical metadata from iTunes catalog, duration-matched | URLSession (network) |
| **ArtworkResolver** | Resolve/choose cover art from ranked sources | URLSession, ffmpeg |
| **Transcoder** | Tag read/write, transcode + R128 normalize | ffmpeg / ffprobe |
| **DeviceManager** | Detect device, reconcile `MUSIC/`, write `.m3u8` | NSWorkspace, filesystem |
| **SyncEngine** | Diff device set vs device contents; drive Transcoder + DeviceManager | above |
| **UI (SwiftUI)** | Screens + preview player + menu bar extra | all engines |

**Key architectural rules:**

- **One canonical device-path function.** A track's device-relative path
  (`Artist\Album\Title.mp3`, sanitized) is computed in exactly one place; both file
  placement and playlist writing call it, so they never disagree byte-for-byte.
- **Identity vs. asset separation** (see §4).
- **Volume abstraction.** DeviceManager talks to a `Volume` protocol so tests point
  it at a temp directory simulating a `MUSIC/` folder — the full sync engine is
  testable with no physical device.

---

## 4. Data model

### Two-part identity/asset split

- **TrackIdentity** — "what song is this": title, artist, albumArtist, album,
  trackNumber, discNumber, genre, year, duration, artworkRef, plus **provenance**
  (`appleMusic` | `itunesResolved` | `userEdited` | `unresolved`) and a confidence.
  Resolved once, up front (import/adopt). Apple Music items arrive authoritative and
  are locked; unresolved items run the MetadataResolver.
- **AudioAsset** — "the actual audio": master file path, format, bitrate, sample
  rate, size, content hash, source (`importedLoose` | `adoptedFromDevice` |
  `downloaded`), and verification status.

An AudioAsset references a TrackIdentity. Acquisition (Phase 2) *fulfills* a known
identity — it stamps the already-known metadata onto downloaded audio rather than
deriving metadata from the source.

### SQLite (GRDB) tables (initial sketch)

- `track_identity` — the fields above.
- `audio_asset` — master file metadata + FK to identity.
- `playlist` — name, ordering, `syncToDevice` flag.
- `playlist_item` — playlist FK, asset FK, position.
- `device` — UUID, name, target bitrate, last-seen; supports >1 device later.
- `device_track` — per-device sync state: asset FK, device relative path,
  transcoded bitrate, content hash at time of transfer (detects staleness).
- `device_playlist` — playlists written to a device + source mapping.

### Master file tree (on the Mac)

- Human-readable: `Library/<AlbumArtist>/<Album>/<Title>.mp3` (mirrors the device
  layout; **AlbumArtist** first so compilations don't scatter — falls back to Artist,
  then `Unknown Artist` / `Unknown Album`).
- Masters are the highest quality available (loose originals preferred over device
  copies during dedup). Tags are authoritative on disk, so the library is
  reconstructable by rescanning if the DB is lost.
- Playlists are **also persisted as files** in the library, so playlist/pin data
  survives DB loss.

---

## 5. Verified NW-E394 device spec

Empirically confirmed by inspecting the connected device (not from docs):

- **Identity:** FAT32, volume name `WALKMAN`, UUID `E97DEE75-C15B-3342-9C1E-8061AF9C468A`.
  Pin to UUID; confirm on first connect; scope all writes under `MUSIC/`.
- **Music layout:** `MUSIC/<Artist>/<Album>/<Title>.mp3` — three levels; filename is
  a **bare `Title.mp3`** (no track-number prefix). Missing → `Unknown Artist` /
  `Unknown Album`. Folder depth well within the device's 8-level limit.
- **Album ordering:** device orders albums by **ID3 track-number tag** in Album/Artist
  (tag) browse; folder-mode is filename-alphabetical. Existing files often have
  `track=0` (unset). **Therefore the importer backfills track & disc numbers from the
  iTunes catalog** so tag-based album order is correct with bare filenames.
- **Playlists:** `MUSIC/<name>.m3u8`. Exact byte format:
  - **UTF-8 with BOM** (`EF BB BF`).
  - **CRLF** (`\r\n`) line endings.
  - `#EXTM3U` header; per track `#EXTINF:<integer-seconds>,<Title>` then a path line.
  - Path is **relative to `MUSIC/`** using **backslash `\`** separators:
    `Aphex Twin\Drukqs\Vordhosbn.mp3`.
- **Audio:** existing library is MP3 CBR **192 kbps / 44.1 kHz stereo** → transcode
  default = **MP3 192 kbps**. No proprietary music database on the device; it indexes
  itself, so sync is pure file operations.
- **Off-limits top-level items** (device system — never touch): `DCIM`, `PICTURE`,
  `Video`, `FOR_MAC`, `FOR_WINDOWS`, `Help_Guide`, `System Volume Information`,
  `.fseventsd`, `default-capability.xml`, `DevIcon.fil`, `DevLogo.fil`, `nmdsdcid`,
  `WMPInfo.xml`.
- **Current contents:** 354 MP3s, 23 `.m3u8` playlists, 245 artist folders.

### Filename sanitization (single source of truth)

Strip/replace FAT-illegal characters `\ / : * ? " < > |` and control chars; trim
trailing dots and spaces (FAT/Windows requirement); **preserve Unicode/accents**
(the device handles them fine). Same function used for tree placement and playlist
paths. Collisions (same title twice in one album) get a disambiguating suffix.

---

## 6. Key flows

### 6.1 Import loose files

1. User points at a messy folder.
2. `ffprobe` reads existing tags + duration for each file.
3. For files with weak/missing tags, MetadataResolver proposes canonical metadata
   (iTunes, duration-matched); ArtworkResolver proposes covers.
4. **Review table**: two columns — *Original* vs *Suggested* — per-field accept/
   override; missing-tag files land in an `Unknown Artist` bucket to fix.
5. On confirm: write chosen tags (incl. backfilled track/disc numbers), **copy**
   (non-destructive) into the master tree, index in SQLite.
6. After success, *offer* to delete the loose originals.

Dedup within the import: identical songs collapse to the **highest-bitrate** copy.

### 6.2 Adopt from device

1. On first connect, read `MUSIC/` contents + the 23 `.m3u8` files.
2. Import the device's tracks as masters (they become masters where no
   higher-quality loose original exists; **never clobber a better master with a
   192 k device copy**).
3. **Reconstruct playlists directly from the parsed `.m3u8` files** (exact, since
   they encode `Artist\Album\Title`), mapping entries to imported assets.
4. Foreign files (added by another computer) are offered for adoption, not deleted.

### 6.3 Curate the device set

Device set = union of (playlists flagged `syncToDevice`) + (individually pinned
songs/albums). This is the desired state the sync reconciles toward.

### 6.4 Sync (reconcile)

1. Compute the desired set (device set → concrete assets).
2. Read current `MUSIC/` contents + `device_track` state.
3. Diff into **Will add / Will remove / Up to date**; show the **live capacity ring**
   (projected used/free of 8 GB) *before* commit.
4. For each add: transcode (or copy, per skip rule §6.5) into `MUSIC/<path>`, update
   `device_track`.
5. For each remove: delete only OpenSong-managed files; never foreign files (unless
   adopted).
6. (Re)write `.m3u8` playlist files for device-flagged playlists in the exact byte
   format (§5).
7. Idempotent/resumable: an unplug mid-sync leaves a consistent partial device that
   a re-sync completes.

### 6.5 Transcode + loudness

- Target: MP3 192 kbps (configurable) + **EBU R128** normalization via ffmpeg.
- **Skip-transcode rule:** if master is MP3 and bitrate ≤ target, **copy as-is**
  (still apply R128 if not already normalized) — avoid pointless generation loss.
- Each song is transcoded at most once per device (the device *is* the cache); a
  changed target bitrate or edited master (hash change) marks device tracks stale for
  re-push.

---

## 7. Safety & edge cases

- **Wrong-volume protection:** identify by UUID; confirm device on first connect; all
  writes strictly under `MUSIC/`.
- **Foreign files:** never removed; offered for adoption.
- **Never downgrade a master:** dedup always keeps the higher-quality copy.
- **Non-destructive import:** copy then optionally delete originals.
- **DB loss recovery:** master tree + tags + on-disk playlist files reconstruct state.
- **Mid-sync unplug:** reconciliation is idempotent; re-sync finishes.
- **FAT limits:** sanitize names; watch 8-level depth (our 3-level layout is safe).

---

## 8. UI

**Design reference:** `OpenSong UI design docs/` (README + `OpenSong.dc.html`, a
high-fidelity interactive HTML prototype of all 10 screens in both themes). We
**recreate it natively in SwiftUI** (`NavigationSplitView` source list, `Table`,
toolbar segmented/search, `.sheet`/`.popover`, `ProgressView`) — the HTML is a
visual/interaction spec, not code to port. Match it pixel-close.

- **Window:** 1180×770 default, resizable. Title bar (44px) with light/dark toggle +
  Settings. Sidebar (222px) → content column (contextual header → body → activity bar).
- **Accent:** British Racing Green — `#12452b` (light) / `#46a374` (dark), with the
  accent's *text* color flipping per mode. Model as two dynamic colors (SF Symbols for
  icons, SF Pro type). Full token table (colors/typography/spacing/radius/shadow) is in
  the README — treat as source of truth for visuals.
- **Sidebar sources:** Library (All Songs / Albums / Artists), Playlists (accent dot
  when device-flagged), Device (capacity ring when connected; "Offline"/dimmed when
  not), [Wishlist, Apple Music — later phases].
- **Phase 1 screens:** onboarding (pick library folder); library browser (Songs table
  w/ on-device dot + `Kind` column + selection action bar + context menu, Albums grid,
  Artists list); metadata editor sheet with **art picker**; **import review table**;
  playlists (drag-to-reorder, device toggle); **device view** (82px capacity ring +
  Will add / Will remove / Up to date diff + Sync); settings sheet. Plus empty/error/
  loading states, a persistent **preview-player** transport bar, and a **menu bar
  extra** ("Walkman: N songs · X GB free" + sync).

### Design ↔ device reconciliations (build to the device reality)

- **Playlist extension:** the design labels the toggle "Generate on device (.m3u)";
  the verified device format is **`.m3u8`** (§5). Keep the friendly label if desired,
  but write `.m3u8`.
- **Device target formats:** the Settings format picker in the design offers
  **MP3 / AAC / Opus**. The NW-E394 supports **MP3, AAC, WMA, WAV — NOT Opus** (and
  not FLAC/ALAC). Restrict the *device* target to MP3 (default 192k) / AAC; Opus must
  not be offered as a device format or it produces unplayable files.
- **`Kind` column** implies masters may be lossless (FLAC/ALAC) or high-bitrate — good,
  that's the point of masters. Such masters are **always transcoded to MP3** for the
  device (the skip-transcode rule §6.5 only applies when the master is already MP3 at
  or below the target bitrate).

---

## 9. Testing strategy

- **Volume abstraction** lets the SyncEngine + DeviceManager run against a temp
  `MUSIC/` dir — full sync tested with no hardware.
- **Golden-file test for the playlist writer**: assert exact bytes (BOM + CRLF +
  backslash relative paths + `#EXTINF`) against a captured real device `.m3u8`.
- **Sanitizer unit tests** over the tricky real names seen on-device (accents,
  brackets, `feat.`, leading dots, `&`, `#`, `•`).
- **Dedup tests**: loose original vs device copy → higher bitrate wins.
- **Reconcile tests**: add/remove/up-to-date, foreign-file preservation, idempotent
  re-run after simulated mid-sync interruption.
- TDD per the project's test-driven-development workflow.

---

## 10. Tech & dependencies

- **Swift/SwiftUI**, un-sandboxed macOS app.
- **GRDB** (SQLite).
- System binaries via `Process`: `ffmpeg`, `ffprobe` (`/opt/homebrew/bin`), `yt-dlp`
  (later), `osascript` (later). Paths configurable in Settings.
- **URLSession** for iTunes Search API (metadata + artwork).
- Apple Foundation Models (later, swappable) for LLM title cleanup.

---

## 11. Open items / verification checkpoints

- Confirm the generated `.m3u8` (our byte format) plays correctly on the physical
  device after the first real sync (should match captured format exactly).
- Confirm R128-normalized 192 k files behave well on the device.
- Decide artwork embedding target size for masters (iTunes hi-res vs device needs).
- Track-number backfill: handle multi-release ambiguity (which album pressing) — pick
  best iTunes match by duration + album-name similarity; user can override.
