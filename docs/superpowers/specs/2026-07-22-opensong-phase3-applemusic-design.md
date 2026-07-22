# OpenSong — Phase 3 Design: Apple Music compare + import

**Date:** 2026-07-22
**Depends on:** Phase 1 (library, importer) + Phase 2 (wishlist).
**Scope (locked):** Apple Music as a reference source — browse/compare playlists/albums/
artists, mark missing tracks to acquire (→ wishlist, `source: appleMusic`), and import
non-DRM local files directly. **No stretch ML.**

## Approach

Read the user's Apple Music library via `osascript` (JXA emitting JSON). The thin
osascript call is isolated; all **parsing and comparison logic are pure, unit-tested
functions**. First use triggers a one-time macOS Automation permission prompt (expected).

## Components (OpenSongCore)

| Module | Responsibility |
|---|---|
| `AppleMusicModels` | `AppleMusicTrack {name, artist, album, durationSec, location?, isCloud}`, `AppleMusicCollection {name, kind(playlist/album/artist), tracks}` |
| `AppleMusicParser` | Parse the JXA JSON output → collections (pure, testable) |
| `AppleMusicBridge` | Run the JXA via `osascript`; `playlists()/albums()/artists()`. Live-gated test. |
| `AppleMusicCompare` | Match AM tracks against library masters (normalized artist+title+album, duration tolerance) → owned count + missing list (pure, testable) |
| `AppleMusicImporter` (AppStore action) | Mark missing → `WishItem(.appleMusic)`; import a non-DRM local `location` via Phase 1 Importer |

## Matching

Normalize: lowercase, strip punctuation/`feat.`/`(remaster)`, collapse spaces. A library
master matches an AM track when normalized title matches AND normalized artist matches AND
(album matches OR duration within 4 s). Missing = AM tracks with no library match.

## Flows

- **Compare:** load AM collections → for each, show owned N / total M + a progress bar.
- **Mark N missing:** append missing tracks to the wishlist as `appleMusic` items (authoritative
  identity: name/artist/album/duration known → the Phase 2 pipeline stamps them directly).
- **Import local file:** for a track whose `location` is a real non-DRM file (not `isCloud`),
  import it into the master tree via the Phase 1 Importer (`.importedLoose`), skipping yt-dlp.

## UI (SwiftUI)

- **Apple Music compare** (sidebar → Compare): rows = collection cover, name + kind badge,
  "owned N of M", an owned/missing progress bar, and either "Complete ✓" or a
  **"Mark N missing"** accent button. Footer: **"Import local file…"** for non-DRM files.
- A first-run "Grant access" affordance if osascript reports no access yet.

## Testing

- `AppleMusicParser`: canned JXA JSON → collections/tracks (incl. cloud + local location).
- `AppleMusicCompare`: library with some matching/mismatching masters → correct owned/missing,
  fuzzy matching (feat./remaster/case), duration tolerance.
- `AppleMusicBridge`: live-gated (`OPENSONG_LIVE=1`, needs Music.app + Automation permission).
- Mark-to-acquire: missing tracks become `.appleMusic` wish items.

## Non-goals

No playback of Apple Music, no DRM circumvention (cloud/DRM tracks fall through to Phase 2
yt-dlp acquisition), no stretch ML.
