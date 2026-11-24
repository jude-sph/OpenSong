# OpenSong — TODO (working tracker)

Kept current as I work. Newest requests at top of "In progress".

## In progress (this batch)
- [x] **Spotify public-playlist import** (v0.2.8) — Settings creds (Client ID/Secret), sidebar
      "Import playlists", paste a playlist/profile link → Client-Credentials fetch → compare vs
      library → per-track owned/pending/in-library + multi-select smart "Add/Remove N" button,
      list-level "Mark N missing", grouped into Pending under the playlist name. Core:
      SpotifyClient (actor, token cache, pagination) + tests (URL parse, pagination, user list).
- [x] **iPod Shuffle 4th-gen support** (v0.2.9) — libgpod is dead on modern macOS, so writing
      the `iTunesSD` DB directly (like the Walkman `.m3u8`).
    - [x] `ShuffleDB` byte-exact iTunesSD writer (bdhs/hths/rths/hphs/lphs, MD5 dbid, VoiceOver
          filenames) — cross-checked vs nims11/IPod-Shuffle-4g, 3 byte-level tests passing.
    - [x] iPod device detection (`DeviceDetector.connectedShuffle()` — volume w/ `iPod_Control/`).
    - [x] VoiceOver generation: `SayVoiceOver` = `say --data-format=LEI16 --file-format=WAVE`
          → Speakable/Tracks + Speakable/Playlists, named by reversed-hex dbid.
    - [x] `ShuffleSyncEngine`: transcode/copy into `iPod_Control/Music/`, incremental file
          add/remove, rebuild iTunesSD + VoiceOver. End-to-end tests (temp iPod dir) passing.
    - [x] Device-type awareness (store `deviceKind`, refreshDevice/preview/runSync branch on
          Walkman vs Shuffle) + Settings VoiceOver toggle + brand-neutral Device UI labels.
    - [ ] HARDWARE: verify on the physical 4th-gen Shuffle (mounts, detects, syncs, plays). Needs
          the device plugged in — can't be tested headlessly.

## Prior batch
- [x] Match screen: listen to each yt-dlp candidate (streaming preview via `yt-dlp -g` + AVPlayer)
- [x] Match screen: real YouTube thumbnails on candidates (i.ytimg fallback from video ID)
- [x] Match screen: unlock metadata — Title/Artist/Album editable (persists to wish), no more "Locked"
- [x] Player: respond to macOS media keys (MPRemoteCommandCenter + Now Playing info)
- [x] Player: fix end-of-track — delegate-based finish; shows paused/replay-ready instead of
      phantom "playing at 0:00"

## Previous batch
- [x] Fix white space / gaps in the Apple Music compare list
- [x] AM detail: click + shift-click + cmd-click multi-select of songs
- [x] AM detail: replace per-song "Add" with a top smart button — acts on selected songs,
      or all missing if none selected (mirrors "Mark N missing")
- [x] AM detail: un-add a song (remove from Pending) once added
- [x] Adopt-from-device (UI on Device view + engine wiring)
- [x] Delete from library (store delete + context menu + confirm)
- [x] Manual playlist management (New Playlist, Add-to-Playlist, reorder/remove in detail)

## Done
- (see docs/FEEDBACK.md for the full running history)

## Requested
- [x] **Album-level device sync** (v0.3.0) — "Send album to device"/pin-whole-album + on-art badge.
- [x] **Capacity forecast (multi-quality)** (v0.3.0) — songs-that-fit at 128/192/256/320k.
- [x] **YouTube playlist import** (v0.3.1) — list videos w/ thumbnails + already-added status,
      multi-select add to Pending, direct download via chosenURL (beginMatch skips search).
- [ ] **Album-level device sync** (user request — "store non-playlist songs as album groups"):
      the library is already album-organized; add a "Send album to device" / pin-whole-album action
      (+ album device toggle) so albums sync without needing a playlist. On the Walkman they already
      land in Artist/Album folders.

## Feature ideas (brainstorm — pick & scope before building)
- **Device Autofill**: "Fill remaining space" — auto-pick songs to fill the device's free bytes
  (by recently-added / never-synced / random). Especially good for the small Shuffle. ← next fun one
- [x] **Quality-upgrade finder** (v0.3.2) — Library Health: low-bitrate + spectral re-encode flags,
  one-click "Find better source".
- [x] **Duplicate detection** (v0.3.2) — identity-based grouping + keep-best dedupe.
- **Listening stats → smart lists**: play counts from the built-in player → "Most played",
  "Never synced", "Recently added"; feed Autofill.
- **Watched YouTube playlists**: remember a YT playlist and pull newly-added videos on refresh.
- **Album-art + tag enrichment**: fetch hi-res art / fix inconsistent tags (iTunes/MusicBrainz).
- **Capacity forecast**: "~1,400 songs fit at 192k" on the device screen.
- **Fresh shuffle rotation**: regenerate a randomized order each sync for the Shuffle.

## Decided against
- **Acoustic fingerprinting (AcoustID/Chromaprint)** — removed in v0.3.42. It could only judge a
  file *after* downloading it, and measured on real candidates the pre-download version (90s excerpt
  → fingerprint → lookup with the expected duration) confirmed only 1 of 4 tracks: excerpt
  fingerprints hit a narrow, thinly-annotated slice of the index, returning "no match" or an
  unrelated title as often as a useful answer. Duration + spectral checks stay.

## Later / known gaps
- Verify on the Walkman itself that `.m3u8` entries with accents/CJK still resolve: OpenSong writes
  the composed (NFC) path while the FAT32 volume reports names decomposed (v0.3.28 normalized the
  app's own comparisons, but the player's matching is its own logic — check a playlist containing
  e.g. "Ce matin-là" plays through on the device)
- Replace-artwork button in metadata editor is a no-op
- Import non-DRM local Apple Music file (engine `importLocal` exists; no UI button)
- Direct "remove from device" list (currently unpin → sync)
- Verify a real device sync + real yt-dlp download on hardware
