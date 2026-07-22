# OpenSong — User Feedback & Fixes Log

Running log of feedback from real use, with status. Newest first.

## 2026-07-22 session

- [x] **New app icon** — using the provided `OpenSong-icon-macos/AppIcon.icns`.
- [x] **Consistent green** — dark mode used a lighter green; now always the light-mode
  British Racing Green (#12452b) in both themes.
- [x] **Version in Settings + quoted on build** — `VERSION` file drives the app version;
  install.sh stamps a build id and prints it; Settings footer shows "v0.2.0 (build …)".
- [x] **Repo hygiene** — 201 leaked SwiftPM intermediates (.o/.d/.swiftdeps) were committed
  by accident; purged from git and gitignored.
- [~] **Title-bar dead space** — moved `.ignoresSafeArea()` to the OUTERMOST window-content
  modifier (was being re-inset by the outer `.frame` before). Canonical fix; can't
  screenshot the live window from automation (Spaces) so needs visual confirmation.


- [x] **Pending should hold playlists, not just songs.** Fix: wish items can carry a
  `playlistName` group (Apple Music playlists mark grouped); Pending shows grouped playlists
  (with counts + "Review N") above loose songs; the OpenSong playlist is recreated once all
  its tracks download.
- [x] **Player too basic.** Fix: scrubber (drag to seek), prev/next with a queue (double-click
  plays the whole current list), auto-advance, working volume slider + mute, current/total time.
- [x] **Artist screen blank avatar.** iTunes has no artist-photo API, so the avatar now uses a
  representative album cover from that artist's music (real image, gradient fallback).


- [x] **Album art not shown** (app drew gradients; files have embedded covers). Fix:
  `ArtworkThumbnail` + `ArtworkCache` extract embedded art via ffmpeg on first display and
  cache it (self-healing); used in song rows, albums grid, metadata editor, player bar.
- [x] **No way to play a song.** Fix: shared `PreviewPlayerModel` on the store; double-click
  (or context-menu Play) plays into the bottom bar (real AVAudioPlayer + progress).
- [x] **Apple Music capped at 40 playlists** (hardcoded limit). Fix: raised to 2000 playlists
  / 1000 tracks each.


- [x] **Sidebar rows only clickable on the text** — the whole row should be clickable.
  Fix: added `.contentShape(Rectangle())` to sidebar row buttons.

- [x] **Import of ~10 loose files hangs with no progress (UI frozen).** Root causes (not
  file size):
  1. All import work ran on the **main actor** (`scanAndReview` was `@MainActor`) → any
     blocking froze the whole UI. Fix: moved scan+resolve into a `Task.detached`.
  2. Picking individual **files** scanned each file's **parent folder recursively** (×N) →
     could `ffprobe` a whole tree. Fix: `Importer.scan(files:)` scans only the chosen files;
     only chosen *directories* are walked.
  3. iTunes lookups had **no timeout** (URLSession resource timeout defaults to 7 days) →
     a stalled request hangs import indefinitely. Fix: `URLSessionHTTPClient` now uses a
     10 s request+resource timeout; suggestions are best-effort.

- [x] **Apple Music "Grant access & load" does nothing.** Cause: Music.app wasn't running,
  so the JXA returned empty. Fix: bridge now `Music.launch()`es before reading.

- [ ] **Title bar takes too much vertical space** (empty strip above the custom bar).
  Cause: the window reserves the native titlebar height above the custom 44px `TitleBar`.
  Fix: set `fullSizeContentView` + transparent titlebar so content reaches the top.

- [ ] **Pending (wishlist) should hold playlists too, not just songs.** Needs a wishlist
  "playlist" grouping (e.g. mark a whole Apple Music playlist → pending, recreate on import).

## Known environment gotchas (for future sessions)
- **Ad-hoc signing resets TCC**: each `make-app.sh` rebuild changes the ad-hoc signature, so
  macOS Automation/Screen-Recording permission may re-prompt after every rebuild.
- **ImageRenderer** (offscreen screenshots) can't rasterize `ScrollView` content or AppKit
  controls (`Picker`/`TextField`/`Toggle`/`ProgressView`) → use custom SwiftUI + `renderMode`.
- **Stale SwiftPM build cache**: if tests/behavior look stale or a link error mentions missing
  `.o` files, run `swift package clean`.
- **Live screenshots blocked**: the automation session can't composite the app window to the
  display (Spaces); verify UI via `OPENSONG_RENDER=1` offscreen render instead.
