# OpenSong — Phase 2 Design: Acquisition (yt-dlp)

**Date:** 2026-07-22
**Status:** Draft (decisions carried from brainstorming)
**Depends on:** Phase 1 (library, identity/asset model, transcoder, artwork/metadata resolvers)

## Overview

Phase 2 acquires audio for wishlist items via `yt-dlp`, following the identity/asset
separation: **identity is resolved up front; acquisition just fulfills it.** The user
reviews YouTube candidates (ranked by duration match) and confirms; on download we stamp
the already-known metadata + art and verify the audio is the right, good-quality recording.

## Decisions (locked)

- **Flow:** review candidates → download (not download-then-guess).
- **Metadata:** iTunes canonical resolver (Phase 1) + a **regex title-parser** to turn messy
  YouTube titles into search queries. **No LLM** (iTunes does the heavy lifting).
- **Verification:** duration match (vs known length) + **spectral cutoff** quality check +
  **AcoustID fingerprint** (free; graceful fallback when no API key is set).
- **Art:** picker with sources — official iTunes cover, **adjustable square crop of the
  YouTube thumbnail**, custom drop. (Embedded is N/A for fresh downloads.)
- **Download master:** keep yt-dlp `bestaudio` in its native format (m4a/opus/webm→m4a),
  embed tags + art; device sync transcodes to MP3 as in Phase 1.
- **Wishlist states:** `wishlist → matching → downloaded`. Custom entries now; Apple Music
  feeds it in Phase 3.

## Components (OpenSongCore)

| Module | Responsibility |
|---|---|
| `TitleCleaner` | Parse a messy YouTube title → `{artist?, title}` search query; strip `(Official Video)`, `[4K]`, `ft.`, etc. |
| `YouTubeSource` (protocol) + `YtDlpSource` | `search(term,limit)->[Candidate]` (via `yt-dlp -j ytsearchN:`), `download(url,to)->URL` (bestaudio). Protocol lets tests stub it. |
| `SpectralAnalyzer` | Detect real frequency cutoff via ffmpeg; return `cutoffHz` + verdict (flags fake/upsampled); render a spectrogram PNG. |
| `Fingerprinter` | `fpcalc` → (fingerprint, duration). `AcoustIDClient.lookup(fp,dur,key)` → recordings. `verify(audio, expected, key?)` → confidence (skips gracefully with no key). |
| `ArtworkCrop` | Compute a square crop rect over a 16:9 thumbnail; produce the square cover via ffmpeg. |
| `WishlistStore` (LibraryStore ext) | `wish_item` table CRUD + state transitions + link to created asset. |
| `AcquireCoordinator` | Orchestrates: resolve identity → search → (user picks) → download → stamp metadata+art → verify → import as `.downloaded` asset → mark wish item done. |

### Data model

- `WishItem { id, title, artist, album?, durationSec?, source(custom|appleMusic), state, chosenURL?, assetID? }`
- `Candidate { videoID, url, title, channel, durationSec, viewCount?, thumbnailURL?, durationDelta, confidence }`
- `VerifyResult { durationOK, spectralCutoffHz, spectralVerdict, acoustidScore?, acoustidMatched?, overall(High|Medium|Low) }`
- `AcquireSettings { acoustidAPIKey: String, searchLimit: Int }` (added to `AppSettings`).

### Candidate ranking / confidence

`durationDelta = |candidate.duration − known.duration|`. Confidence: High if ≤2s + title
contains artist & title tokens; Medium if ≤6s; Low otherwise. When identity is authoritative
(Apple Music / iTunes-confirmed), the match screen shows metadata **locked** and is purely
source-selection; for custom items the metadata fields stay editable with iTunes suggestions.

## Flows

**Acquire a wishlist item:**
1. Ensure identity resolved (custom → iTunes `bestMatch` by title/duration; else user-typed).
2. `search("<artist> <title>", limit)` → candidates, ranked by durationDelta.
3. User reviews (or pastes a URL), confirms.
4. `download(url)` → bestaudio master file.
5. Stamp known metadata (Transcoder.writeTags) + embed chosen art (ArtworkResolver).
6. Verify: duration + spectral + AcoustID(if key). Show badge.
7. Import as `.downloaded` asset into the library; set wish item `downloaded`, link assetID.

## UI (SwiftUI)

- **Wishlist / Pending** (sidebar → Pending): table with State pill (Wishlist grey / Matching
  amber / Downloaded green), Title, Artist, Source badge, action; "+ Custom Item" sheet.
- **Match review** (full view): candidate cards (thumb, title, channel, duration, confidence,
  "≈ duration match"), radio-select + paste-URL; metadata panel (locked when authoritative,
  editable+iTunes when custom) + **art picker** (adjustable YT crop); Download → progress
  ("yt-dlp → ffmpeg → tag → verify") → done ("Quality verified · N% match") / error (retry).
- **Spectral reveal:** the quality check shows the spectrogram thumbnail with the detected
  cutoff line.

## Testing

- `TitleCleaner`: unit tests over messy real-world titles.
- `SpectralAnalyzer`: lowpass a tone to 8 kHz via ffmpeg → assert detected cutoff ≈8 kHz;
  full-band → high cutoff.
- `Fingerprinter`: real `fpcalc` on a generated file → non-empty fingerprint + duration;
  `AcoustIDClient` JSON parse via stub; live lookup gated by `OPENSONG_LIVE` + key.
- `YtDlpSource`: `AcquireCoordinator` tested with a **stub `YouTubeSource`** returning a local
  generated file (full pipeline: search→download→stamp→verify→import). Live yt-dlp search+
  download gated by `OPENSONG_LIVE`.
- `WishlistStore`: CRUD + state transitions.

## Non-goals (Phase 2)

- No Apple Music (Phase 3). No LLM. No lyrics (device can't show them; optional later).

## Deferred / graceful

- AcoustID requires a free key in Settings to activate acoustic verification; without it,
  verification uses duration + spectral only. `fpcalc` installed via Homebrew.
