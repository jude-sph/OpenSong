# OpenSong — User Feedback & Fixes Log

Running log of feedback from real use, with status. Newest first.

## 2026-11-25 session — the Device screen works with the device unplugged

- [x] **The Device screen was a dead end without the Walkman plugged in**: just a "No device
  connected" placeholder, though `device_track` already remembered exactly what was on it. Now the
  screen has one layout for both states. Unplugged, it says "Not connected · last seen 2 days ago",
  assumes nothing on the device changed, and shows everything recorded on it.
- [x] **Planning split from the live device.** `SyncEngine.makePlan` (and `ShuffleSyncEngine.makePlan`)
  are pure diffs of desired assets vs. managed rows vs. present paths. The live `plan()` feeds them the
  volume walk and real capacity (results unchanged); the new `offlinePlan` feeds the recorded rows as
  the present paths plus the remembered capacity. Plans now carry `removals` (the `device_track` rows),
  so every pending removal maps back to an asset and can be undone. On reconnect the live plan runs as
  before, which catches any drift; there's no separate reconcile.
- [x] **The device is remembered**: kind, name, total/free bytes and last-seen date, per device id
  (UserDefaults `rememberedDevices`), refreshed on every connected `refreshDevice()`, which includes the
  one after each sync. A device synced before this change, with rows but no record, still shows up,
  with its capacity estimated from the rows.
- [x] **Sections**: *Will add* (Undo), *Will update* (out-of-date copies being re-sent), *Will remove*
  (Keep), *Playlists on device* (a sync switch per playlist), and a searchable *On device* list. Each
  song shows why it's there ("Pinned", "via late night"), worked out in one pass from in-memory
  playlists and a single pinned-ids query. Click, ⇧-click and ⌘-click select several songs, and a
  bulk action runs as one batch with one preview rebuild.
- [x] **Removing never edits a playlist silently.** A pinned song is unpinned. A song that's there
  through a playlist opens a choice: "Stop syncing ‹playlist›" or "Remove from ‹playlist›".
- [x] Sync is live only when the device is connected. Unplugged, the button is inert and reads
  "Connect to sync · N changes pending", and the sidebar's Device item shows the same count. Eject,
  Import from device and Rebuild copies only appear while connected. "Simulate connect" is left only
  for a device that has never been seen.
- The weak no-device fallback estimate in `buildSyncPreview()` is gone. It ignored pins and removals.
- Tests: offline plan add/remove/up-to-date, remembered capacity, playlist untick, stale recipe,
  Shuffle equivalent, and "offline agrees with live after a sync". New render shot:
  `05c-device-offline-dark`.
- Not verified on hardware: unplug → edit → replug → one Sync. Also not clicked through live: the
  confirmation dialog and multi-select (the render harness can't show either).

## 2026-08-13 session (v0.13.1) — search kept filtering inside an album

- [x] **Searching for an album, then opening it, showed only the matching tracks** — and the search
  box isn't on screen there, so the missing songs had no visible explanation. Worse than a wrong
  result: an invisible filter.
- Fixed at the single point all three lists share: the search term is now empty once a specific
  album or artist is open. Searching is how you *find* the album; it has no business narrowing what
  is inside it. Going back restores the term, which is still sitting in the box.
- The artist view had the same bug for the same reason — searching, then opening an artist, showed
  only their matching albums. Both are covered by the one change.
- Verified in the render harness with a search term deliberately left set: the album detail now
  lists its full track list where it previously listed none.

## 2026-08-06 session (v0.13.0) — a Spotify playlist wearing Apple Music's cover

- [x] **Cause: the cover was looked up by name alone.** `PlaylistDetailView` asked Music.app for
  "the playlist called X" whatever the real origin, so a Spotify import called *Airy* showed the
  artwork of an unrelated Apple Music playlist of the same name. A name doesn't identify a playlist.
- [x] Playlists now record **where they came from** (`source`) and **their own cover** (`artworkURL`,
  which Spotify publishes) — migration v9. The cover is chosen from that: the source's own URL if
  there is one, Music.app only for Apple Music (and legacy) playlists, a gradient otherwise.
- [x] The import paths pass their real source: Apple Music, Spotify (with its image URL), YouTube.
  Groups materialised later take the source from the **wishes** that formed them, which already
  carry it.
- [x] Existing rows would all have said "manual", losing covers on genuine Apple Music imports and
  keeping the wrong one on Spotify imports. A **one-time backfill** recovers the source from those
  same wishes, and `.manual` still consults Music.app so nothing regresses for playlists made before
  the column existed.

## 2026-08-06 session (v0.12.2) — opening a playlist showed no tracks

- [x] **The same February 2026 rename, one level deeper.** In `/playlists/{id}/items`, each entry now
  holds its track under **`item`**; `track` is deprecated and no longer populated. The parser read
  only `track`, so every entry was skipped and a playlist opened empty. Both names are read now,
  current first — and an entry whose `item` is a podcast episode is ignored rather than mangled.
- [x] A duplication bug fixed while there: the contents fall back to `/items` only when the metadata
  brought nothing inline. Fetching it *as well* would have duplicated the first page of any playlist
  short enough to arrive whole.
- Three renames in one API change, each surfacing only when the previous one was fixed:
  `/tracks` → `/items` (endpoint), `tracks{href,total}` → `items{href,total}` (playlist object),
  `track` → `item` (entry). Each looked like a separate bug from the outside.
- Test support gained a scripted HTTP client, so the two-request path (metadata, then items) is
  covered end to end rather than one parser at a time — which is how all three renames slipped
  through individually.

## 2026-08-06 session (v0.12.1) — every playlist said "0 tracks"

- [x] **The count came from the wrong field.** February 2026 renamed the contents collection on the
  playlist object from `tracks` to `items` (`{href, total}`) and stopped populating the old name, so
  `tracks.total` was always missing — hence 0 everywhere. Both names are now read, current first.
  The same fix applies to playlist metadata, where it also decides the first page and pagination.
- Worth noting the shape trap: in a *paged* response `items` is an array, while on a playlist object
  it is `{href, total}`. The lookup casts to a dictionary, so the array form declines safely.
- [x] **Link bar removed** — signing in lists the account's own playlists, which is what pasting a
  profile link was for. The header is now just the account name and a Refresh button (or Sign in).
- Sign out was already in Settings → Spotify, next to the signed-in status.

## 2026-08-06 session (v0.12.0) — your own Spotify playlists, no link needed

- [x] **"Now that we sign in, why paste a profile link at all?"** Quite right. Signing in makes
  `GET /me/playlists` available — which survived the February 2026 cull that removed
  `/users/{id}/playlists` — so the Spotify screen now lists the signed-in account's own playlists on
  open, exactly like Apple Music's Compare. Pasting a link still works for individual playlists.
- [x] The error the user hit was OpenSong's own hardcoded refusal in `userPlaylists`, which fires
  for profile links regardless of sign-in. Correct in itself (the endpoint is gone), but it was the
  *only* thing the screen could do — hence the redesign above.
- [x] **The Load button wrapped to two lines** once the Save button joined the header row. Given a
  fixed width so a neighbour can't squeeze it.
- [x] Saved-user chips now open the profile in Spotify instead of attempting a load that could only
  ever error — the endpoint behind them no longer exists. Right-click still forgets them.

## 2026-08-06 session (v0.11.1) — "redirect_uri: Not matching configuration"

- Spotify's check is a string comparison against the URIs registered on the app, and its error names
  no expected value, so both plausible causes were addressed:
  - [x] **The redirect URI now goes out percent-encoded.** `URLComponents.queryItems` leaves `:` and
    `/` alone, so it was being sent as `redirect_uri=http://127.0.0.1:8888/callback`. Legal in a
    query string, but pointless risk when the value is compared against a registration.
  - [x] **The redirect URI is editable** in Settings, with the callback port derived from it, so it
    can be pointed at whatever an app already has registered rather than requiring one exact string.
- [x] The timeout message now names the likely cause: when the URI isn't registered, Spotify shows
  the error in the browser and never redirects, so OpenSong's side simply waits — previously saying
  only "timed out".

## 2026-08-06 session (v0.11.0) — Spotify sign-in

- [x] **Authorization Code sign-in**, so playlist links work again: Settings → Spotify → *Sign in to
  Spotify*. Opens the browser, catches the redirect on `http://127.0.0.1:8888/callback`, swaps the
  code for tokens, and renews them silently. Signed-out behaviour is unchanged (search and albums
  still work on app credentials alone).
- Decisions worth recording:
  - **Loopback, not localhost.** Spotify treats `http://localhost` as an insecure redirect URI and
    rejects it; `http://127.0.0.1` with a port is accepted for native apps. The exact string is
    shown in Settings with a copy button, since it must be registered on the Spotify app and the
    failure otherwise is an unhelpful Spotify error page.
  - **The session lives in the Keychain**, not in preferences: a refresh token is a standing key to
    someone's account, a different class of secret from the app's own client id.
  - **One refresh at a time** (an actor plus an in-flight task): several requests hitting an expired
    token would each spend the refresh token, and Spotify may rotate it.
  - **A refresh response that omits `refresh_token` keeps the existing one** — Spotify usually does
    omit it, and dropping it would silently sign the user out an hour later.
  - Scopes are read-only (`playlist-read-private`, `playlist-read-collaborative`); nothing that can
    modify the account is requested.
- Verified beyond unit tests: a standalone harness proved the loopback listener catches a real
  request and replies, capturing `/callback?code=…&state=…`.
- A bug the tests caught: the form encoder allowed only alphanumerics, so `grant_type` went out as
  `authorization%5Fcode`. Now uses the RFC 3986 unreserved set.

## 2026-08-06 session (v0.10.1) — what actually changed at Spotify (correcting v0.10.0)

The v0.10.0 diagnosis below was reached by probing endpoints and generalising, and it was partly
wrong. The user pushed back with the docs page; reading Spotify's **February 2026 changelog** gave
the real answer, which black-box probing had missed:

- `GET /playlists/{id}/tracks` was **removed** and replaced by `GET /playlists/{id}/items`. OpenSong
  was calling the removed one — the proximate cause of the failure, and something no amount of
  probing would have explained. Fixed: contents now come from `/items`.
- `GET /users/{id}` and `GET /users/{id}/playlists` were **removed outright, with no replacement**.
  Profile links can never work again, for any app, signed in or not. The earlier message said a
  sign-in would fix it; that was wrong and is corrected.
- `GET /artists/{id}/top-tracks` was removed too.
- The new `/items` endpoint answers **401 "Valid user authentication required"** to an app-only
  token — an explicit statement of what is needed, where the old endpoint just said "Forbidden".

What I got wrong, and why: I tested two playlists, both Spotify-owned (Lofi Girl), concluded
"editorial playlists are the special case", then when the docs' own example (owned by an ordinary
user) also failed, concluded "all playlist contents are blocked" — each time generalising from a
sample I hadn't checked the composition of, and never reading the changelog. Probing tells you what
*is* refused; documentation tells you *why*, and only the changelog identified a renamed endpoint.

## 2026-08-06 session (v0.10.0) — Spotify 403, and saved users

- **Diagnosis: Spotify has closed the endpoints this feature depends on.** Reproduced against the
  live API with the app's own credentials. The token is fine; what changed is what an app-only
  (client-credentials) token may read:

  | endpoint | result |
  |---|---|
  | `/search`, `/albums/{id}`, `/albums/{id}/tracks` | 200 |
  | `/playlists/{id}` (metadata) | 200 — but the response no longer contains a `tracks` field at all |
  | `/playlists/{id}/tracks` | **403** |
  | `/users/{id}`, `/users/{id}/playlists` | **403** — including for Spotify's own account, so it isn't about who is being looked up |
  | `/artists/{id}/top-tracks` | **403** |
  | editorial playlists by id (e.g. Today's Top Hits) | 404 |

  So Spotify playlist import cannot work without a user sign-in (Authorization Code flow). Nothing
  in OpenSong is broken and no credential change helps.
- [x] The app said `Spotify: HTTP 403: {"error": {"status": 403, "message": "Forbidden"}}`, which
  explains nothing. Errors are now translated — what was refused, why, and whether the user can do
  anything about it (401 points at Settings; 403 and the editorial-playlist 404 say they can't).
- [x] **Saved Spotify users**, newest first, shown as chips under the header: Save keeps whoever is
  in the box, clicking loads them, right-click offers Open in Spotify or Forget. Ids are matched
  case-insensitively (Spotify treats them that way) while keeping the spelling as pasted, and the
  list is capped at 30.
  Saving works from a pasted link alone, so profiles can be kept now even though loading their
  playlists 403s — the list is ready for whenever sign-in exists.

## 2026-07-31 session (v0.9.0) — sort Apple Music by date added

- [x] **"Date Added" in the Apple Music sort control**, newest first, for albums *and* playlists.
  The control was already there (Name / Default) but the albums browser ignored it — it now uses it
  too, so switching to Albums no longer silently drops the sort.
- Music dates *tracks*, not albums, so an album takes the date of its most recently added track:
  an album ripped over two sessions then sorts by when it was finished, which is what "recently
  added" means to a listener.
- Undated tracks stay undated rather than becoming 0. Treating a missing date as the epoch would
  file those albums at the very bottom as though they were genuinely the oldest things in the
  library; they sort to the end of the list instead, by name.
- `dateAdded` joins the existing bulk property fetch (one Apple Event for the whole library, not one
  per track), and crosses the JSON boundary as epoch seconds — a `Date` would stringify to a
  locale-dependent form that is far more annoying to parse back.
- Verified against the real Music.app as well as by unit test: all **6,804** tracks report a date.

## 2026-07-31 session (v0.8.2) — the reorder drag flickered

- [x] **"On every movement all the songs freak out and flicker."** Caused by reflowing the list under
  the pointer: the dragged row slid out from under the cursor, so SwiftUI ended the gesture on the
  view that had moved, `onEnded` committed, `reload()` rebuilt the whole library, and a new gesture
  started on whatever row was now beneath the pointer — dozens of times a second. Two of my own
  earlier decisions combined into it: live reflow, and commit-on-end.
- The list no longer moves at all during a drag. Only the dragged row follows the pointer (raised,
  shadowed), with an accent line at the slot where it will land. The only state changing per mouse
  move is one `CGFloat`, so nothing else redraws and the gesture keeps its view for the whole drag.
- Lesson for next time: in SwiftUI, never move the view that owns an in-flight gesture. Both this
  and the previous drag-and-drop version failed for versions of the same reason — the thing tracking
  the pointer must stay still.

## 2026-07-31 session (v0.8.1) — the reorder drag was temperamental

- [x] **"If I drag for a second too long or in the wrong direction it can't land and goes back."**
  My fault for building it on `onDrag`/`onDrop`. Drop targets are hit-tested, so a fast drag skips
  the row-enter callbacks that were doing the reordering, and straying outside the list fired
  `dropExited`, which threw away the very state the drop then needed — the row sprang back and the
  reorder was lost.
- Rebuilt on a plain `DragGesture`, which answers to nothing but the pointer. The target index is
  arithmetic on how far the pointer has moved from where the drag started, recomputed from the
  untouched starting order every time — so overshooting, doubling back, pausing, or wandering off
  to the side all give the same answer, and the drop lands wherever the mouse comes up.
- The row stride (row height plus divider) is measured from the rendered list rather than assumed,
  so the arithmetic stays right if the row layout changes.
- The arithmetic lives in `RowDrag` in OpenSongCore with tests, since it is exactly what was broken:
  overshooting the ends now clamps, and returning to the start is a no-op rather than a lost drag.

## 2026-07-31 session (v0.8.0) — drag to reorder playlists

- [x] **Drag songs to reorder inside a playlist.** The list reflows as you drag, the dragged row
  dims, and the new order is written once on drop. Move Up / Move Down stay in the context menu.
- Held the dragged order in view state rather than writing on every hover: committing goes through
  `reload()`, which rebuilds the whole library (436 tracks here), so a write per row crossed would
  have made the drag stutter. Abandoning a drag reverts rather than leaving the rows showing an
  order the library doesn't have.
- [x] **It reaches the device.** No new machinery was needed: `SyncEngine.apply` rewrites every
  device playlist on every sync, and the Sync button isn't gated on the plan being non-empty, so a
  reorder that moves no audio still carries across. Proved with a test that reorders, asserts the
  plan is empty (nothing added or removed), syncs, and parses the `.m3u8` back to check the order
  followed.
- A reorder shows up nowhere in the sync preview, for the same reason — so it now says "Order saved
  — the device playlist is rewritten on the next sync", or it looks as though nothing will happen.
- Note: syncing is still manual. Plugging in doesn't sync by itself; the order goes across the next
  time Sync is pressed.

## 2026-07-29 session (v0.7.1) — update yt-dlp from Settings

- [x] **"Update yt-dlp" button in Settings → Tool Paths**, with the installed version beside it.
  Worth having: YouTube changes often enough that a stale yt-dlp is the usual reason a download that
  worked last month doesn't today.
- The update command has to match how the tool was installed, or it fails confusingly rather than
  updating: `yt-dlp -U` refuses on a pip install (telling you to use pip) and on a Homebrew one
  (telling you to use brew). `ToolUpdate` picks from evidence — the script's shebang for pip, the
  path for Homebrew, otherwise self-update — and is unit-tested, since getting it wrong is silent.
- The interpreter comes from the **shebang**, not from PATH. This machine has yt-dlp twice (a
  python.org pip install, which is what the app is configured to use, and a separate Homebrew copy),
  so `python3 -m pip install -U` would have updated the copy the app *isn't* running.
- pip's two common refusals on a Mac — `externally-managed-environment` and an unwritable install
  location — are retried automatically with `--break-system-packages` and `--user` respectively.
  Anything else is reported as-is rather than retried blindly.
- Verified by running the exact plan the app builds: exit 0, correctly reporting "already up to
  date (2026.07.04)" since that is current.

## 2026-07-27 session (v0.7.0) — repeat modes

- [x] **Repeat button in the player bar**, cycling normal play → repeat queue → repeat one track.
  Grey loop, green loop, green loop-with-a-1; the mode is remembered between launches.
- Decisions worth recording: **repeat-one doesn't apply to the skip buttons** — pressing skip means
  "play something else", so it advances (and wraps) like repeat-all, which is what every other player
  does; a skip button that replayed the same track reads as broken. Skipping back from the first
  track wraps to the end while repeating, and the "restart if more than 3 s in" behaviour is
  unchanged. Landing on the track that just played (repeat-one, or repeat-all with one track queued)
  rewinds the open file rather than reopening it, so the gap is minimal and the visualiser keeps its
  decoded samples.
- The rules live in `PlaybackQueue` in OpenSongCore rather than in the player, so the end-of-queue
  cases are covered by tests without an audio device — six of them, including empty and
  out-of-range queues.

## 2026-07-27 session (v0.6.2) — minimising out of fullscreen left an empty Space

- [x] **Minimising the fullscreen visualiser left a black empty desktop behind** and dropped you back
  on the previous one. Not our bug to invent a fix for so much as our bug to stop causing: a
  fullscreen window has a Space to itself, and taking the window out of that Space strands it. The
  system disables minimise for fullscreen windows for exactly this reason — ours had it enabled
  because the visualiser draws its own chrome. `miniaturize` and `performMiniaturize` (the button
  and ⌘M take different routes) now refuse while fullscreen, and the button greys out to say so.
- [x] **Closing while fullscreen had the same defect**, since ordering the window out strands the
  Space just as well. Closing now leaves fullscreen first and hides the window once that finishes.

## 2026-07-27 session (v0.6.1) — fullscreen visualiser: traffic lights and idle fade

- [x] **Traffic lights inverted in fullscreen** — visible when the pointer was away from them, gone
  the moment it reached them, so they could never be clicked. `TrafficLightHider` was fighting the
  system: in fullscreen macOS hides the whole titlebar itself and reveals it when the pointer hits
  the top of the screen, but reaching up there takes the pointer *out* of the SwiftUI content view,
  so hover ended and the buttons were hidden exactly then. It now leaves them alone in fullscreen.
- [x] **Controls never faded in fullscreen**, because there is no "outside" to move the pointer to
  and the fade was driven by hover alone. Now the chrome also fades after **2.5 s of pointer
  stillness** (`onContinuousHover` reports position, so movement can be told from mere presence; a
  2 pt threshold ignores a trembling hand). Any movement brings it straight back.
- [x] While it fades in fullscreen the **pointer is hidden too**, so nothing sits over the trace; it
  reappears on the next movement. Only in fullscreen — in a window the pointer is how you reach
  everything else. The art window is unchanged.

## 2026-07-27 session (v0.6.0) — "find a new version" for a file that's wrong

- [x] **Replace a bad file.** Right-click a track → **Find a New Version…**. It goes back into Pending
  with a "replacing" tag, the library row shows a *finding a new version* badge, and the current file
  keeps playing until a replacement arrives — there's no sense removing the only copy while the user
  waits for a download. **Keep This Version** cancels.
- [x] **The old file is discarded when a new one is chosen**, and the device is updated on the next
  sync *even if nothing else changed*:
  - same title → the new file takes over the master in place, so the asset keeps its id and
    playlists, album position and the device pin are undisturbed; the device row is marked stale so
    the copy on the Walkman is overwritten.
  - different title (e.g. picking "(Original Mix)") → the replacement becomes its own asset,
    playlist entries and the pin move across, the old row is deleted, the old master goes to the
    Trash, and the sync removes the old file from the device before adding the new one.
- [x] **The blocker was the importer's dedup**, which would have made this feature silently do
  nothing. It skips a file whose bytes are already known, and for a known title keeps whichever
  master has the higher bitrate — so a replacement at the same or lower bitrate was *discarded and
  the bad file kept*. An explicit replacement now overrides both rules: a bad rip at 320k is still a
  bad rip. Only replacements bypass them; ordinary imports are unchanged.
- Covered by five tests, including two that drive a real sync: one asserts the replacement is
  re-sent when the path doesn't change, the other that the old file is deleted from the device when
  it does. Also covered: a track sitting in a playlist twice over doesn't end up duplicated.
- Schema: `wish_item.replacesAssetID` (migration v8).

## 2026-07-27 session (v0.5.2) — the seam, the dark nicks, and what vocals can honestly do

- [x] **Gap where the loop met itself.** Two causes. The Catmull-Rom loop ran `1..<count-2`, so the
  last segment was never drawn; and the two ends of the loop are the same *place* but different
  *moments* (u = 0 is a window ago, u = 1 is now), so the vibration there didn't match. Now the curve
  can be drawn closed with wrapped indices, and the last eighth of the loop eases the detail back to
  its value at u = 0 with a smoothstep, so the ends meet exactly without a corner.
- [x] **Faint dark nicks along the line.** The depth bands: a single point whose depth grazed a
  threshold produced a 2-point run drawn at the dimmest brightness. Bands are now taken from a depth
  averaged over ±3 neighbours, and any run under 8 points is absorbed into its neighbour.
- [x] **"Can vocals show up more?"** Honest answer: not as *vocals*. Measured three cheap detectors
  (centre-channel energy, a 1–4 kHz presence band, syllabic 3–8 Hz modulation) against vocal and
  instrumental sections — none separated them; the instrumental scored highest on the first. Real
  vocal isolation needs source separation (Demucs-class), which is a heavyweight dependency and
  offline per-track work. What shipped instead is a **presence channel**: 1–2.5 kHz, which is the
  register a voice occupies, given its own fine tremble on the line, weighted by how much of that
  band comes from the centre of the mix (where a lead vocal is panned). Singing moves it — so do
  hats and lead guitar, and the code says so.
- [x] A bug the new test caught: the centre-weighting subtraction was done between *waveforms*, so a
  hard-panned tone read as **maximum** presence — cancelling a signal that exists only in the sides
  leaves a large negative one, whose envelope is just as big. The subtraction now happens between
  envelopes.
- Still 60 fps; draw cost 0.87–1.07 ms/frame (from 0.62) for the extra channel and the band
  smoothing. Memory ~1.4 MB per minute.

## 2026-07-27 session (v0.5.1) — visualiser reacts harder, and the bands were unequal

- [x] **"Make it react more strongly — not much happens when sounds are playing. Are all parts of the
  EQ equal in effect?"** They were not, and the honest answer was worth giving: bass stretched an
  axis *and* was the sole source of the line vibration (the ripple is low-passed at 220 Hz), mids
  stretched an axis, treble only changed the depth axis — barely visible. Now:
  bands stretch further (0.30 → 0.65) and **pull against each other** (mids squash the bass axis as
  theirs extends, so proportions change rather than everything growing); each **hit** spins the
  figure faster and flashes it brighter, from a new bass-transient track; and the mids get their own
  **shimmer** — the 300–1100 Hz band wrapped round the curve over a 0.10 s window, so it travels four
  times faster than the bass vibration and only shows up when the music is intense.
  Measured frame-to-frame change 0.21 → 0.38, with size still ±1%.
- [x] **The bass vibration was left exactly as it was** (0.06 at 220 Hz over 0.4 s). I had started
  changing it while adding the new mappings; the user pointed out they liked it, which was fair.
- [x] Two real bugs the new tests caught, both of which would have shown on screen:
  - a **sustained bass note read as a stream of hits**: a 3 ms attack tracks the individual
    half-cycles of a 70 Hz note, so the flash would have flickered at 140 Hz. The rectified signal is
    now smoothed at 40 Hz before the fast/slow comparison.
  - **`x − lowPass(x)` is a poor high-pass**: the low-passed copy is phase-shifted, so subtracting it
    leaves a large residue in the stopband — an 80 Hz tone came through a "300 Hz high-pass" at a
    third of its amplitude, putting bass into both the treble axis and the mid shimmer. Replaced with
    a real cascaded one-pole high-pass.
- Still 60.0 fps, 0.47–0.73 ms/frame at 1290×874. Memory ~0.7 MB per minute (the shimmer track adds
  to the ~0.4 MB).
- Stale-build trap again, twice: two test failures repeated to seven identical digits after a fix.
  `swift package clean` is effectively mandatory in this project after touching `OpenSongCore`.

## 2026-07-27 session (v0.5.0) — visualiser rebuilt: no bounce, bigger fluid shapes

- [x] **"Remove the bouncing — it looks cheap."** The bounce was the auto-gain. Any peak-following
  gain lags a quiet passage and then scales the next loud sweep off the screen; measured size
  variation was ±17% on one track and ±40% on a quieter one, with frames clipped by the window.
  Now the figure is fitted to the frame by measuring its own projected extent each frame: **±1%**.
  Loudness drives brightness instead, and the bands deform the figure *asymmetrically* — uniform
  scaling on the beat is the cheap effect being removed.
- [x] **"Bigger, more fluid shapes — it doesn't obviously represent the song."** Diagnosed properly
  rather than tuned: at 60 fps consecutive frames are 16.7 ms apart, and the sweep was 26 ms of audio
  starting at the playhead, so **consecutive frames shared almost no audio** — the picture was redrawn
  from scratch 60 times a second. Measured frame-to-frame change (occupancy-grid difference): **0.90**.
  Eight rounds of renders on real audio ruled out the alternatives: a scope trigger, period locking by
  autocorrelation, period-synchronous averaging (flattens the figure), and superimposing cycles
  (coherent, but a dense knot).
  What shipped: the form is a **Lissajous knot** driven by three band energies (bass/mid/treble, each
  with its own attack and release), which move on a musical timescale — frame-to-frame change **0.19**
  — with the waveform riding the line as a fine ripple so the picture is still literally the audio.
  Bass stretches one axis, mids the second, treble the third.
- [x] Side effects worth knowing: memory per track fell from ~5 MB/minute to **~0.4 MB/minute** (band
  envelopes plus a decimated ripple instead of full-rate audio), and draw cost from 1.6 ms to
  **0.62 ms/frame** at 1290×874, still a measured 60.0 fps.
- [x] Two drawing bugs the renders caught: filtering points by depth into one path joined opposite
  sides of the loop and **drew a chord across the figure**; drawing the bright core only in depth
  bands left it **dashed** wherever a band lasted a single point. The glow and core are now continuous,
  with the bands laid over additively.
- Note for future sessions: `swift package clean` was needed *again* — a test kept failing against
  code that had already been fixed. Also, two measurement metrics were wrong before they were right
  (a pointwise sample comparison, which differs even when the picture is identical; then an occupancy
  metric that rewarded ink density) — worth sanity-checking a metric against a case whose answer is
  known before trusting it.

## 2026-07-27 session (v0.4.3–0.4.4) — visualiser polish

- [x] **"Remove the horizontal lines, and reduce the number of lines."** The CRT scanline pass read as
  a grid laid over the trace rather than as screen texture, so it's gone; overlapping sweeps cut from
  11 to 6 with a faster decay (0.78 → 0.72) so the afterglow trails off instead of stacking.
- [x] **Yellow minimise button missing from the art window.** Not a hiding bug: `ArtPanel`'s style
  mask never included `.miniaturizable`, so AppKit had nothing to draw there (`TrafficLightHider`
  unhides all three on hover, which is why the gap looked deliberate). Added it. The visualiser
  window already had it, which is why only the art window was affected.
- [x] **Scrubber in the visualiser window** — the art window's `DragBar` plus elapsed/duration
  labels, on the same hover reveal, hidden when no track is loaded.

## 2026-07-26 session (v0.4.1–0.4.2) — visualiser: frame rate, then the look

- [x] **"0.5 frames per second."** Not a drawing cost problem: per-frame instrumentation showed
  `TimelineView(.animation)` delivering **3 frames in the first 392 ms and then nothing**. Replaced
  with `ScopeClock`, a 60 Hz timer on the run loop in `.common` mode, running only while the window
  is open and something plays. Measured after: **60.0 fps at 1290×874, 1.6 ms/frame**.
  My earlier "6 ms/frame" benchmark was worthless — `ImageRenderer` measures the offscreen path, not
  the live one — and my first fps counter initialised on first use, so a scope that had already
  stopped ticking still reported plausible numbers. Raw per-frame timestamps are what exposed it.
- [x] **Traffic lights overlapped the title** — header inset past them.
- [x] **"A small blurry messy clump."** True, and the mockup that sold the feature was a synthetic
  two-tone Lissajous, which was never going to match real music. Rebuilt from renders of the user's
  own audio: low-pass at 250 Hz (broadband content is a scribble; bass draws loops), a 9 ms delay
  embedding across three axes with stereo width on Z, slow rotation with per-depth shading for a
  genuine 3-D read, Catmull-Rom curves, auto-gain that settles over *seconds* so beats still pump,
  and a beat-energy term that swells the figure on hits. Chosen from a 3×3 contact sheet of filter
  corner × lag, then three animated candidates.
- [x] Bug found by the new tests: the sampler's rounded step returned 287 points for a request of
  220. Indices are now spread by exact division.
- [x] Perspective divisor clamped (0.70–1.30) and the base radius rebalanced — a full-scale bass note
  had been thrown clean off the screen, which the render harness caught.
- Notes for future sessions: `swift package clean` is needed far more often than expected in this
  project — three separate times a source change silently didn't reach the binary. And live frame
  rates can't be measured headlessly here: macOS suspends drawing for occluded windows, so the
  terminal covering the app yields zero frames (the same Spaces limitation that blocks screenshots).

## 2026-07-26 session (v0.4.0) — oscilloscope visualiser

New feature, designed from mockups: a separate chrome-free window that draws the playing track as an
X-Y oscilloscope trace (left channel horizontal, right vertical) with CRT phosphor afterglow. Spec:
`docs/superpowers/specs/2026-07-26-visualiser-design.md`.

- Style chosen by rendering six candidates as real SwiftUI frames and four as animated loops, rather
  than describing them: album-art styles were rejected, then a geometric set, landing on "pure ice"
  — cyan-white beam, no graticule, 11-sweep afterglow.
- `ScopeSampler` (core) decodes the master once to 22 kHz Int16 stereo (~5 MB/minute; 11 kHz beyond
  20 minutes) and answers `window(at:count:)`. **Playback never waits on it**: the decode starts
  after `play()`, off the main actor, and the scope shows the centre dot a real scope shows with no
  signal until it lands (0.19–0.31 s measured).
- Decoding only happens while the window is open; the sampler is dropped on close, track change and
  stop, with a generation counter so a late decode can't install itself over a newer track.
- Window is a plain `NSWindow` (never `NSPanel` — Stage Manager, v0.3.37), hover-only chrome,
  `WindowDragLayer` dragging, hand-rolled frame memory, native fullscreen for a second monitor.
- **Memory, the user's hard requirement:** a weak-reference test asserts each sampler deallocates
  across 10 load/drop cycles, and a steady-state test measures resident memory — first batch of 20
  loads +31 MB (allocator working set + CoreAudio codecs), every batch after **+0.0 MB**, 0.3 MB
  drift across 120 decodes. A leak would have added ~100 MB per batch.
- Performance measured before committing to the approach: 6.0 ms/frame at 2560×1440 with the full
  11 traces × 520 segments (2.8× headroom at 60 fps), and cost tracks segment count rather than
  pixels, so fullscreen is no dearer than a small window.

## 2026-07-26 session (v0.3.42) — acoustic fingerprinting removed

The user got an AcoustID key and expected it to vet *candidates* before downloading. It never could:
`verifyAudio` fingerprints the finished file, so with no key the branch was simply skipped, and the
High/Medium/Low badges they'd been reading came from `AcquireCoordinator.rank` — duration delta plus
title tokens, no audio involved.

Measured the pre-download version before deciding, using their key against the live service:

| test | result |
|---|---|
| full library file (223 s) | 0.98, named `Feel Good Inc. — Gorillaz` |
| 60 s excerpt, clip's own duration declared | 0 results |
| 60 s excerpt, **expected** duration declared | 0.98 ✓ |
| 4 real tracks: YouTube search → 90 s excerpt (`yt-dlp --download-sections`, ~4 s, 3.6 MB) → lookup | 1 named correctly, 1 named a *different* recording, 1 no match, 1 fetch failure |

So it's technically possible but not dependable: excerpt fingerprints match a narrow, thinly
annotated slice of the index, so a wrong-or-absent answer is as likely as a useful one — worse than
no signal, because you'd start distrusting good candidates. Removed `Fingerprinter.swift`
(Chromaprint + AcoustID client), the `acoustidAPIKey`/`fingerprint` settings (the toggle had never
been wired to anything), the verify branch and the `acoustidScore`/`acoustidMatched` fields.
Verification is now duration ±5 s + spectral, which is what it had effectively been all along.

## 2026-07-26 session (v0.3.41) — albums are not playlists

User: *"I don't think I would ever want to copy an album as a playlist, the device can already read
and play albums as they are copied in folders."* Right — a marked Apple Music album became a
playlist that duplicated LIBRARY ▸ Albums and crowded out the real playlists (30 of 48 rows).

- [x] Marking an album no longer creates a playlist; the group name is kept only so Pending can show
  its tracks together while they download. The same guard is on the per-download hook and on
  `materializeCompletedGroups`, so nothing recreates one later.
- [x] The sidebar's ALBUMS section is gone, along with `sidebarAlbumPlaylists` / `formingAlbums` /
  `hasSidebarAlbums`. An album being acquired shows its progress in Pending and lands in
  LIBRARY ▸ Albums when it's done; the player browses it as `Artist/Album` folders.
- [x] One-time cleanup (`retireAlbumPlaylists`, a no-op afterwards) removes album-shaped playlists
  already in the library. Checked the impact before shipping it: 30 of 48 were album-shaped and
  **none** was flagged to sync, so nothing about the device changed — verified after the migration:
  17 playlists left, `device_track` still 341 rows, pins unchanged. Where such a playlist *had* been
  flagged, its tracks are pinned first, so the device would keep exactly what it had.
- [x] **Delete Playlist did nothing** on a collection adopted from an acquisition (v0.3.39
  regression): the playlist went, the finished wish group behind it stayed, and the next reload
  re-adopted it. Deleting now retires the group too — completed wishes are dropped (their tracks
  stay in the library), still-downloading ones are detached and finish as individual Pending items.

## 2026-07-26 session (v0.3.39) — edits now reach the device; sidebar + stranded-group fixes

Prompted by the question "does sync update a song/playlist that's already on the device?" — the
honest answer was "playlists yes, edits mostly no", so:

- [x] **Tag and artwork edits never reached the device.** The up-to-date test is
  `assetID + contentHash + recipe`, and `contentHash` was taken once at import and never refreshed
  when OpenSong rewrote a master. Title/artist/album edits happened to work (they move the device
  path, so it's a remove + add), but genre, year, track number and replaced artwork left the device
  copy stale forever. Fix: `Importer.contentHash(of:)` is public and `AppStore.refreshMasterHashes`
  re-hashes whatever was just rewritten — wired into the metadata editor, "Replace artwork…", the
  artwork backfill and the track-number backfill. Those tracks then re-send on the next sync.
- [x] **Stale `.m3u8` files stayed on the device** when a playlist was renamed, deleted or unticked.
  Sync now removes them — but only ones it wrote, tracked in a hidden `.opensong-playlists`
  manifest, so playlists created on the device (or imported from it) are never touched.
- [x] **Sidebar showed a device dot for playlists but not albums.** The dot keyed off the playlist's
  `syncToDevice` flag, and "Send album to device" pins the album's *tracks* instead of setting that
  flag. It now reflects what's actually on the device: filled when the whole collection is there (or
  it's flagged to sync), hollow when only part of it is.
- [x] **A dead "Childish Gambino — 12/12" row in the sidebar.** All 12 tracks had downloaded with
  valid asset ids but no playlist was ever created, so the group stayed "forming" forever and
  clicking it just went to Pending. `materializeCompletedGroups()` (run after every reload) adopts
  any wholly-downloaded group into a real playlist in queue order, healing existing strays as well
  as any future path that misses the per-download hook.

## 2026-07-26 session (v0.3.37–38) — art window: Stage Manager was moving it; controls overhang

- [x] **The art window's "elastic snap back", finally root-caused — it wasn't our code.** Instrumented
  the panel (logging `setFrame`/`setFrameOrigin`/`constrainFrameRect` with stack traces, plus a
  100 ms frame poll) and had the user drag it. The trace showed the window really moving, then
  jumping to a fixed frame **without any call through `NSWindow`'s API** — i.e. the window server
  moved it back. Cause: `com.apple.WindowManager GloballyEnabled = 1` — **Stage Manager** anchors
  panel/dialog-class windows to the app's stage and re-places them after a drag. The art window was
  an `NSPanel` (accessibility subrole `AXDialog`); the main window, a standard window, always dragged
  fine. Fix: the art window is a plain `NSWindow` now — same transparent titlebar, 200 px minimum,
  square aspect and position memory. Dragging goes through `WindowDragLayer` →
  `performDrag(with:)` (AppKit's own drag loop) and `isMovableByWindowBackground` is off.
  Superseded fixes along the way (each real, none sufficient): only ordering the panel front on a
  show/hide transition; `.allowsHitTesting(hovering)` on the faded-out controls; hand-rolled frame
  persistence instead of `setFrameAutosaveName`.
- [x] **Transport controls hung off the window for some covers.** Measured in a scratch harness that
  builds the real window (`NSHostingView` as `contentView`, 501×501): the controls' frame came out
  **x = −170, width 891**. The blurred backdrop layer uses `.aspectRatio(contentMode: .fill)`, which
  reports the *covering* size, so the ZStack grew to 501 × (1280/720) and the bottom overlay was
  centred on that. Square covers overhung ~50 pt (clipping the time labels), a 16:9 thumbnail far
  more — hence "only for some album art". Fix: the window's content is laid out against
  `GeometryReader` size, so artwork can't influence it (`x = 0, width = 501` after the change).

## 2026-07-26 session (v0.3.35) — on-device from the database; window drag via SwiftUI

- [x] **v0.3.34's on-device fix didn't help on the first launch**: persisting the last device id
  only works once a device has been seen *by that build*, and on a fresh launch with the Walkman
  unplugged the id was still `"none"`. Fix: `LibraryStore.primaryDeviceUUID()` — when the current id
  has no managed-track rows, adopt whichever device the database actually has records for (called at
  bootstrap and whenever nothing is connected). No connect needed; the dots come back immediately.
- [x] **Art window drag, third attempt.** Established by experiment that a *programmatic* move
  sticks (set the panel's `AXPosition` via System Events → it stays), so nothing is resetting the
  frame — the drag itself is being cancelled. The AppKit fallback added in v0.3.34 was inert: the
  `NSHostingView` wins hit-testing for every point, so a `WindowDragHost` superview never sees
  `mouseDown`. Replaced with SwiftUI's own **`WindowDragGesture`** (macOS 15+) on the art view, so
  the drag is arbitrated *inside* SwiftUI's gesture system alongside the buttons and scrubber
  instead of racing AppKit's `isMovableByWindowBackground` path for the same events.

## 2026-07-26 session (v0.3.34) — on-device state survives unplugging; art window drag

- [x] **"The app has forgotten which songs are on device again."** Not data loss this time — the 341
  `device_track` rows were intact under the right device id. `currentUUID` was in-memory only and
  reset to `"none"` whenever no device was detected, *including at every launch with the Walkman
  unplugged*, so nothing could be attributed and every dot/badge vanished. Fix: the last device id
  is persisted (`lastDeviceUUID`) and deliberately kept while the device is away — the rows say
  what's on it, which is exactly what you need to see when deciding what to add next. The Device
  screen also keeps reporting its track count while offline.
- [x] **Art window still sprang back when dragged** (v0.3.30's fix was necessary but not
  sufficient). Two further causes, both removed:
  1. The faded-out transport controls were **still hit-testable** (`opacity(0)` doesn't stop hit
     testing in SwiftUI), so a press in the bottom strip went to the scrubber's drag gesture, which
     claimed the event stream and cancelled the window move half-way — the frame then reverts to
     where the drag began. They now get `.allowsHitTesting(hovering)`, as does the return button.
  2. Dragging relied on `isMovableByWindowBackground`, which shares the content view's event stream
     with SwiftUI's gesture recognisers. The panel's content view is now a `WindowDragHost` that
     calls `performDrag(with:)` — AppKit's own modal drag loop, which nothing can take over.
- Note for future debugging: synthetic `CGEvent` drags move the cursor but are **not delivered to
  other applications** from this shell (no Accessibility grant), so window-interaction bugs can't be
  reproduced headlessly — instrument the window (a `setFrame`/`constrainFrameRect`-logging NSPanel
  subclass plus a frame-watch timer worked well) and have a human drive it.

## 2026-07-26 session (v0.3.33) — artwork search finds self-titled albums

- [x] **"Replace artwork" couldn't find a self-titled album** — searching Gorillaz/Gorillaz returned
  *Demon Days*, *Plastic Beach*, singles… but never the 2001 debut. Confirmed against the API: it
  isn't a limit problem, the plain `search` endpoint is a popularity ranking and doesn't return that
  album at all, even at `limit=25`, with or without `attribute=albumTerm`. Fix: when nothing in the
  first pass actually carries the requested title, `ArtworkFinder` resolves the artist's id
  (`entity=musicArtist`) and pulls their full discography (`lookup?entity=album&limit=200`), where
  self-titled and low-profile albums do appear — then title-matches within it. Normal albums still
  take a single request; the fallback costs two extra only when needed.
- [x] **Results are ranked now, not left in iTunes' order.** Exact title first, decorated titles
  ("… (Deluxe Edition)") just behind, partial matches after, a bonus for the right artist and a
  penalty for singles/EPs — so another act's "Gorillaz - Single" can't outrank the album.
- [x] Candidates show the **release year** under the artist, which is often the only way to tell an
  original from a remaster (Weezer's self-titled records now list as 1994 / 2019 / 2026).
- Live-checked (`OPENSONG_LIVE=1`): Gorillaz/Gorillaz → *Gorillaz [2001]* first; Weezer/Weezer →
  all four self-titled records; Gorillaz/Demon Days → exact match first, one request.

## 2026-07-25 session (v0.3.32) — device copies rebuild themselves when the recipe changes

Confirmed on hardware first: the *G I R L* album was re-encoded with the v0.3.31 pipeline and
pushed to the Walkman by hand — covers now display on the player.

- [x] **A plain Sync now applies it to everything; no button to remember.** `device_track` gained a
  `recipe` column (migration v7) holding `TranscodeSettings.deviceRecipe` —
  `v2/mp3/256k/ln1/art1`. `SyncEngine.plan` (and the shuffle's) treats a copy whose stored recipe
  differs from the current one as stale, so it rebuilds. Rows written before this carry `""` and
  are rebuilt on the next sync — which is exactly the mass artwork fix the user wanted.
- [x] **Bonus fix from the same change:** changing the target bitrate used to leave the device
  untouched (the diff only compared master hashes), so a 192k device kept its 192k files after
  switching to 256k. Now the recipe covers format, bitrate, loudness normalization and artwork.
- [x] "Re-send artwork" became "Rebuild device copies" — a rarely-needed escape hatch (files
  changed behind OpenSong's back, an interrupted transfer) rather than a step in the fix, and it
  no longer needs to ffprobe every master to decide.

## 2026-07-25 session (v0.3.31) — cover art the NW-E394 will actually draw

- [x] **Art embedded in the device files (visible in Finder) still didn't show on the Walkman.**
  Inspected the APIC frame we were writing, byte by byte, and found two defects — both matching
  the advice from the Sony forums:
  1. **APIC picture type was 0 ("Other"), not 3 ("Cover (front)").** ffmpeg writes type 0 unless
     the video stream's `comment` metadata says otherwise, and the player only draws front covers.
  2. **The JPEG was 4:4:4 chroma** (ffmpeg's mjpeg default). The player's decoder handles
     baseline **4:2:0** only — the same reason progressive JPEG fails for it.
  Fix: covers are now always re-encoded with `-pix_fmt yuvj420p`, capped at 640 px
  (`Transcoder.maxCoverPx`), and tagged `comment=Cover (front)`; ID3v2.3 as before. Never
  `-c:v copy`, so an odd master (progressive, CMYK, 3000 px) can't smuggle an undrawable image
  onto the device. Verified: `APIC mime=image/jpeg picture_type=3`, `SOF0 baseline 600×600
  sampling=0x22`.
- [x] **Straight copies were normalized too.** An MP3 that needs no re-encode used to be copied
  byte for byte, carrying the master's own (often non-compliant) art. `copyNormalizingArtwork`
  stream-copies the audio — losing nothing — while rewriting just the cover. **Re-send artwork**
  now covers every managed track, not only the transcoded ones.
- [x] The iPod shuffle has no screen, so `TranscodeSettings.embedArtwork` is off for it — no point
  spending its storage on covers.
- Tests: a new `APICInspector` reads the ID3 frame directly, so the suite asserts picture type,
  MIME, baseline SOF0, 4:2:0 sampling and the size cap, rather than trusting ffprobe's summary.

## 2026-07-25 session (v0.3.30) — art window snapped back when dragged

- [x] **The album-art window springs back to where it was when you try to move it.** Cause: the
  panel is driven by `ArtPanelPresenter`, an `NSViewRepresentable` in the main window's view tree,
  and its `updateNSView` unconditionally re-ran `makeKeyAndOrderFront` + `orderOut` on *every*
  SwiftUI update. Re-ordering a window mid-drag cancels the drag, and AppKit restores the frame it
  started from — the elastic snap. Fix: `sync` now only acts on an actual show/hide transition
  (`shown` flag). The panel also gained a frame autosave name, so it reopens where you left it
  (and if AppKit ever rebuilds the presenter, the panel no longer re-centres itself).

## 2026-07-25 session (v0.3.29) — transcoded tracks reached the device with no cover art

- [x] **"Some songs have album art in OpenSong but not on the device."** Root cause: `Transcoder`
  passed `-map 0:a:0` only, so ffmpeg dropped the master's attached picture — every *transcoded*
  track (AAC/ALAC/FLAC masters, or MP3s above the target bitrate) landed on the device art-less,
  while straight MP3 copies kept theirs. Verified on the user's files: master
  `G I R L/Happy.m4a` has `(audio aac, video png)`, the device copy had audio only. Fix: map the
  attached picture too (`-map 0:v:0 -disposition:v attached_pic`), copying it when it's already
  JPEG and re-encoding PNG/WebP covers to JPEG at `-q:v 3` — the APIC format an old player is
  sure to render, and much smaller than a 600×600 PNG.
- [x] **Getting art onto the tracks already on the device.** Their masters haven't changed, so the
  sync diff calls them up to date. New **Re-send artwork** button on the Device screen probes each
  transcoded track's master for a cover and clears the stored content hash for the ones that have
  one (`LibraryStore.invalidateDeviceTracks`), so the next sync re-encodes exactly those tracks
  with the art embedded.

## 2026-07-25 session (v0.3.28) — accented/CJK tracks were re-synced forever

- [x] **Second root cause of "nothing is on the device"** (found by diffing the 257 database paths
  against the 257 files actually on the WALKMAN — only 236 matched): macOS returns **decomposed
  (NFD)** filenames from the device's FAT32 volume, while paths OpenSong derives from tags are
  **composed (NFC)**. So every track with an accent or CJK text ("Ce matin-là", "짧은 치마")
  compared unequal to itself: it never showed as on-device, was recopied on every single sync, and
  `remove(relative:)` silently no-op'd (deleting the database row but leaving the file behind).
  Fix: `DeviceManager.listManagedTracks` and `DeviceRelativePath.backslashPath` both normalize to
  NFC, removal falls back to the decomposed path, and `adoptDeviceTracks` normalizes existing rows
  in place so old data is repaired on connect.

## 2026-07-25 session (v0.3.27) — device forgot what it had already synced

- [x] **"No songs on device" with the Walkman plugged in, and the album covers' device badges
  disappeared.** Root cause found empirically: the library had 257 `device_track` rows keyed to
  volume UUID `8DC6D44A-…`, but the mounted WALKMAN now reports `E97DEE75-…`. macOS *synthesizes*
  the UUID for FAT32 volumes, so it isn't stable across remounts/reformats — every managed-track
  row was orphaned, so nothing showed as on-device (no dots, no album badges) and the next sync
  would have recopied all 257 tracks. Fix: `DeviceIdentity` keeps the device id in a hidden
  `.opensong-device-id` marker file on the device (seeded from the volume UUID, so nothing changes
  for a device that keeps its own), and `LibraryStore.adoptDeviceTracks` re-keys stale rows whose
  file is genuinely present on the device — a per-row check, so other devices' rows are untouched.
  On connect the store reports "Recognised N track(s) already on the device."

## 2026-07-25 session (v0.3.26) — real sync progress, device sorting, collab-split albums

- [x] **Sync progress bar sat at zero for the whole sync.** Root cause: both sync engines only
  emitted `String` status lines, and `AppStore` never read them — the `ActivityTask.progress` was
  created at 0 and never touched. Fix: engines now report `SyncProgress` (step counts + a
  **duration-weighted** fraction, since a 6-minute transcode costs far more wall clock than
  copying an already-MP3 file), the store relays it to the UI, and the Device screen gained a
  sync panel with percentage, current step, "12 of 48" and **about N min left** (extrapolated
  from elapsed ÷ fraction once past 2%). The Sync button also shows the percentage, and the
  sidebar activity footer shows the counts/ETA line.
- [x] **Sort songs and albums by on-device.** Songs table: the iPod glyph in the header row
  (over the on-device dot column) is now a sort column — first click puts on-device tracks on
  top, click again to invert. Albums grid: a third **Device** sort mode, ordering fully-synced
  albums first, then partially-synced, then off-device.
- [x] **Albums split apart by per-track collaboration credits** ("Demon Days" appearing three
  times as *Gorillaz*, *Gorillaz & De La Soul*, *Gorillaz & MF DOOM*). Fix: new
  `AlbumArtistMerge` collapses a credit onto a shorter one **only when the same album provides
  the evidence** — another track credited to exactly the leading part, followed by a real
  separator (`&`, `and`, `,`, `+`, `x`, `with`, `vs`, `/`, `feat.`) and a named guest. So
  "Simon & Garfunkel" or "Earth, Wind & Fire" are never stripped, but
  "Earth, Wind & Fire & The Emotions" merges into the band. Chains ("A & B & C" → "A") resolve
  to the primary credit; grouping now uses `SongRow.groupArtist` everywhere (albums, artists,
  album detail, artist detail).

## 2026-07-25 session (v0.3.25) — preserve albums scroll position

- [x] **Returning from an album keeps your place in the Albums grid.** The grid now tracks the
  top-most album via `.scrollPosition(id:)` bound to state on the store, so opening an album and
  pressing back restores the previous scroll position instead of jumping to the top. (Main grid only;
  artist-filtered album lists start at the top.)

## 2026-07-25 session (v0.3.24) — track numbers (capture + backfill)

- [x] **Apple Music track & disc numbers now flow into the downloaded file's tags.** Root cause was
  two-fold: (1) the JXA bridge never fetched `trackNumber`/`discNumber` and `AppleMusicTrack` →
  `WishItem` → identity dropped them; (2) the Importer (and metadata editor) only wrote tags for
  **mp3**, so downloaded **m4a** files got no tags at all. Now the JXA fetches track/disc, they ride
  through the wish/identity (DB migration v6 adds the wish columns), and tags — title/artist/album/
  **track/disc**/genre/year — are stamped into mp3/m4a/flac/aac on import.
- [x] **Backfill track numbers on existing albums.** "Fix track numbers" on the album detail header
  and album right-click menu (and a bulk button in Library Health) look up each track missing a
  number against the iTunes catalog (duration-disambiguated via `MetadataResolver.bestMatch`) and
  write the number into both the DB and the file tags. Background task with progress.

## 2026-07-25 session (v0.3.23) — per-song artwork replace

- [x] **Replace artwork for a single song** via the song row's right-click menu ("Replace artwork…").
  Reuses the same iTunes find-and-embed sheet as the album flow, generalized to target either a whole
  album or one track. Prefills the search with the song's **album** (that's the cover art) and falls
  back to the **song title** for singles / album-less tracks — the search terms stay editable, so
  either works.

## 2026-07-25 session (v0.3.22) — sort albums by recently added

- [x] **Albums grid can sort by Name or Recent.** A Name/Recent toggle in the Albums header; "Recent"
  orders albums by the newest track's date-added (the same `addedAt` the Songs table uses), so newly
  acquired albums surface first.

## 2026-07-25 session (v0.3.21) — sidebar nav order

- [x] **Moved Device / Wishlist / Apple Music / Spotify / YouTube above the Playlists & Albums lists**
  in the sidebar, so the fixed navigation stays visible instead of being pushed off-screen by a long
  list of playlists/albums.

## 2026-07-25 session (v0.3.20) — albums get their own sidebar header

- [x] **Marked Apple Music albums now live under an "ALBUMS" sidebar header**, not mixed in with
  Playlists. A grouped acquisition is classified as an album when its pending tracks all share the
  group's album name (or its materialized entry holds only that one same-named album), matched
  normalized so spelling variants like "GIRL"/"G I R L" still group. Applies to albums already
  marked and future ones; curated playlists stay under PLAYLISTS. The header only appears when you
  have album acquisitions.

## 2026-07-25 session (v0.3.19) — search albums/artists + drop redundant toggle

- [x] **Search now filters Albums and Artists too**, not just Songs. Albums match on album name,
  artist, or any track title within; Artists match on name, or an album/track by that artist.
- [x] **Removed the Songs / Albums / Artists segmented toggle** from the Library header — the sidebar
  already navigates between those views, so the toggle was redundant.

## 2026-07-25 session (v0.3.18) — candidate cover-art preview

- [x] **YouTube candidates now preview their resulting cover.** Each candidate's thumbnail is shown
  as a square (48×48) center-crop instead of a 16:9 still — reproducing exactly the cover
  `squareCropEmbeddedArt` embeds on download (side = height, centered; same geometry as
  `ArtworkCrop.squareCrop`). It still doubles as the play/preview button.

## 2026-07-25 session (v0.3.17) — Apple Music albums, artwork replace + missing-art fix

- [x] **Add Apple Music *albums* to Pending** (alongside playlists). The Apple Music view now has a
  **Playlists / Albums** toggle. Albums are read from your whole library and grouped by album +
  album artist (featured guests don't split an album; two artists' same-named albums stay distinct).
  Marking an album seeds/creates a playlist named after it and drops its missing tracks into Pending,
  filling over time — identical to the playlist flow, syncable half-complete.
- [x] **Replace bad/missing album art (iTunes).** New `ArtworkFinder` queries Apple's keyless iTunes
  Search API for candidate covers (upscaled to ~600px). "Replace artwork…" appears in the album
  detail header and the album grid's right-click menu → pick a cover → it's downloaded, square-cropped,
  and re-embedded into every track of the album, then the display cache is invalidated so it updates
  immediately.
- [x] **"Songs downloading without cover art" — root-caused (two bugs).**
  1. *Display:* the artwork cache wrote a permanent 0-byte "no art" sentinel; once a file later
     gained art the sentinel was never re-checked (and file mtime is unreliable — yt-dlp stamps
     downloads with the video's upload date). Sentinels now record the master's byte size and
     self-heal when the file changes; legacy 0-byte sentinels re-extract on next display.
  2. *Download:* some uploads carry no usable thumbnail, so the file downloaded art-less. Acquisition
     now falls back to the official iTunes cover (square-cropped, embedded) whenever a finished
     download has no embedded art.
- [x] **Bulk "Fix missing artwork"** button in Library Health: scans every track and fetches the
  official iTunes cover for any that lack embedded art (background task with progress).
- [x] **Imported playlist covers now show.** The playlist detail header reuses the Apple Music cover
  (by playlist name) instead of a flat gradient, so imported playlists display their real artwork
  (falls back to a gradient only when Music has none).

## 2026-07-24 session (v0.3.16) — Date Added column

- [x] **"Date Added" sortable column** in the Songs table — the date each track was added to the
  OpenSong library. Added an `addedAt` timestamp on the audio asset (migration v5), set on import
  and preserved on re-import; existing libraries are backfilled from each master file's creation
  date. Click the ADDED header to sort (toggles newest/oldest). Column widths tightened to fit.

## 2026-07-24 session (v0.3.15) — art window swap + candidate-duration root cause

- [x] **Only one window at a time.** Opening the art panel now hides the main window; returning
  (return button or the panel's close box) brings the main window back and hides the art panel. No
  more both-on-screen-at-once.
- [x] **Smaller art-window minimum** (200×200), independent of the main window's 960×640.
- Dismissal goes through a direct callback (not SwiftUI state on the hidden window), so the main
  window always comes back.
- [x] **Candidate scrubber showing the wrong length — ROOT-CAUSED & FIXED.** The scrubber read a
  duration exactly 2× the real one (e.g. 27:06 vs 13:33). Probing the resolved stream with ffprobe
  showed the file is genuinely 13:33 — yt-dlp's metadata agrees — so it's **AVFoundation misreading
  YouTube's fragmented-MP4 audio duration as double** (a known quirk). Fix: the preview now uses the
  search-metadata length (authoritative, matches ffprobe) for the scrubber total + seek basis
  instead of AVPlayer's reported duration, so the row time and the scrubber now agree and seeking is
  correct. (Replaced the earlier hide-the-number workaround.)

## 2026-07-24 session (v0.3.14) — art window is now its own square panel

- [x] **Square art window with its own (small) min-size.** Made the album-art view a SEPARATE
  panel (its own NSWindow) instead of taking over the main window. The panel is locked to 1:1 and
  has a small 260×260 minimum, while the main window keeps its roomy 960×640 minimum — different
  mins, as requested. Because it's a distinct window, the 1:1 aspect ratio no longer fights the
  main window's constraints (that was the source of the not-square / fly-away / crash saga). The
  square cover fills the square panel; traffic lights still hide unless hovering; the return button
  and the panel's close both dismiss it.

## 2026-07-24 session (v0.3.12) — art window: stable square tile (resize crash fixed)

- [x] **Resize crash — root-caused & FIXED.** Clearing the window's aspect ratio with
  `aspectRatio = .zero` actually installs an INVALID 0:0 ratio; the next live drag divides by it
  and traps in AppKit's resize path. The documented way to clear it is `resizeIncrements = (1,1)`.
- [x] **Art window flying off-screen on resize — FIXED by redesign.** Forcing the NSWindow itself
  to a locked 1:1 ratio fought the app's (non-square) min-size and jumped the origin. Dropped the
  window-squaring entirely (removed SquareWindowController — no more aspect-ratio manipulation).
  The art view is now a **centered square tile of the whole cover over a blurred, darkened fill of
  the same art** — so there are no black bars regardless of the window shape, the full cover is
  visible, and the window is a normal, crash-free resizable window. Traffic-lights-hidden-on-hover
  is kept.

## 2026-07-24 session (v0.3.11) — min-size + resize-crash fix

- [x] **Normal window crashed on resize — FIXED.** Removing the SwiftUI min-size (to make the art
  window square) let the window shrink until a layout hit an invalid (NaN) geometry and crashed.
  Restored a square-friendly minimum (720×560) via SwiftUI; the art window's 1:1 min is now 720×720
  (not a tiny unusable square). Simplified the square controller so nothing fights the min anymore.

## 2026-07-24 session (v0.3.10) — art-window polish

- [x] **Traffic lights hidden unless hovering** in the album-art window (TrafficLightHider toggles
  the close/min/zoom buttons on hover; restored to visible when you return to the full window).
- [x] **Return button + player controls realigned** — they were overflowing the window edges
  (times sat in the corners). Controls are now overlays anchored to the art's bounds (top-trailing
  return, bottom control bar), clipped to the window, with proper insets.

## 2026-07-24 session (v0.3.9) — art-window + ownership fixes

- [x] **Art window not square / flew off-screen on resize — FIXED.** Root cause: the app's SwiftUI
  min-size (980×640, non-square) conflicted with the art window's 1:1 aspect ratio, so it never
  snapped square and resizing jumped. Moved min-size enforcement onto the NSWindow (900×600
  normal), and the square controller now relaxes limits → resizes to a centered, on-screen-clamped
  square → *then* locks the 1:1 ratio; on exit it clears the ratio and restores the previous frame.
- [x] **Downloaded tracks shown as "missing" in Apple Music/Spotify compare — FIXED.** A track
  that's downloaded/verified (e.g. "Almost Blue") was still counted missing because the fuzzy match
  (title+artist + album-or-duration±4) failed (YouTube length ≠ Apple's, albums differ). Ownership
  now also treats a track as **owned** when a downloaded wish matches it (normalized title+artist),
  and "Pending" now means only a not-yet-downloaded wish.

## 2026-07-24 session (v0.3.8) — polish batch

- [x] **"+N still downloading" badge bug** — pendingCount counted all grouped wishes, so a
  complete playlist wrongly showed "+11 / 11 still downloading". Now counts only not-downloaded;
  wishes are kept (not deleted) so completed groups stay visible in Pending.
- [x] **Collapse completed playlists in Pending** — completed groups collapse (chevron on the
  header, click to expand); incomplete ones stay open.
- [x] **Mini art window: forced square + fill** — the window is locked to a 1:1 aspect ratio
  (resizable but always square, min-size relaxed) and the art aspect-FILLS (crops) so there are no
  black bars, even for non-square covers.
- [x] **Covers cropped to square on download** — after acquiring, the embedded cover is
  center-cropped to a square (YouTube thumbnails are often 16:9) so all library art is square.
- [x] **Download error indicator** — a failed background download now shows a red "Error" pill in
  Pending with the reason on hover, and the button becomes "Retry" (clears on retry).
- [x] **One duration in candidate preview** — while previewing, the static search time is hidden
  so only the live scrubber length shows (no more conflicting 4:11 vs 8:21).
- [x] **Now-playing indicator** — the currently-playing track shows a waveform/pause badge on its
  artwork and an accent title in the Songs table, album detail, and playlist detail.
- [x] **Paste a YouTube URL to download directly** — "Paste URL" on Pending and Library: paste a
  link, optionally "Fetch info" (yt-dlp title → artist/title), tidy the metadata, and it downloads
  straight to the library in the background (skips the search).

## 2026-07-24 session (v0.3.7) — playlists as intent (forming + partial sync)

- [x] **Imported playlists are now first-class intent.** Marking an Apple Music / Spotify / YouTube
  playlist creates a real OpenSong playlist immediately (seeded with any tracks already in your
  library), which then **fills over time** as its Pending tracks download and join it. The sidebar
  shows the playlist right away with a **"+N" badge** for how many tracks are still downloading
  (before anything downloads, an all-pending import shows as a dimmed forming row that opens
  Pending). The playlist detail shows "N still downloading".
- [x] **Half-complete playlists can sync to the device.** Because the playlist is real from the
  moment you mark it, its device-sync toggle works even when partial — Sync pushes whatever tracks
  have downloaded so far, and later syncs add the rest as they arrive (no engine change needed).
- On completion the ribbon announces "Playlist ready".

## 2026-07-24 session (v0.3.6) — background downloads + ribbon

- [x] **Background downloads.** "Download & tag" no longer blocks on a full-screen spinner. It
  returns you to Pending immediately and runs the download/tag/verify as tracked background
  activity (shown in the sidebar footer), so you can keep queuing more. Multiple downloads run at
  once; a failed one reverts its wish to the wishlist for retry.
- [x] **In-app ribbon notification** (no system notification, per request). A toast slides in at
  the top on completion ("Download complete — '<title>' is in your library.") or failure, with a
  checkmark/warning icon and a close button; auto-dismisses after ~4.5s. Used for both the main
  and "download separately" background jobs.

## 2026-07-24 session (v0.3.5) — library / navigation / player

- [x] **Sortable song columns** — click Title/Artist/Album/Time/Kind to sort; click again flips
  direction (arrow on the active column).
- [x] **Self-contained album view + back button** — opening an album now stays within Albums
  (sidebar highlight unchanged) with a back arrow to the grid, instead of jumping to a filtered
  Songs view.
- [x] **Artist → their albums + back button** — clicking an artist opens their albums (was a
  no-op), with a back arrow to the Artists list. Opening an album from there returns to the artist.
- [x] **Library multi-select + bulk actions** — click / ⇧-click / ⌘-click to select; right-click
  acts on the whole selection: Play, Play Next, Add to Playlist, Send/Remove Device, Delete.
- [x] **Play Next** in the right-click menu (queue insertion after the current track).
- [x] **Shuffle** — a Shuffle button on All Songs, album, artist, and playlist views (playlist
  also gets a Play button).
- [x] **Queue viewer** — a list button by the player opens an "Up Next" popover; each row has a
  minus to remove it from the queue.
- [x] **Mini album-art window** — clicking the now-playing cover opens an album-art-only takeover
  (whole cover, centered on black); transport controls + a return button fade in on hover.
- Also: imported playlists only appear in the sidebar once fully downloaded — logged as a known
  gap (TODO #17) to show forming/partial playlists.

## 2026-07-24 session (v0.3.4) — candidate screen

- [x] **Scrubbing bar on candidate previews.** The playing candidate shows a small seek bar
  (current time / DragBar / duration) via an AVPlayer periodic time observer + seek.
- [x] **Quality shown next to candidates.** Each candidate shows its best-audio quality (e.g.
  "~129k AAC" / "~160k Opus"), fetched concurrently in the background from yt-dlp so the flat
  search stays fast.
- [x] **Right-click "Download separately".** On any candidate: download an edit/remix into the
  library standalone (NOT added to the wish's playlist/album). Runs in the background so the main
  match screen stays usable; title is cleaned (TitleCleaner) so versions stay distinct.

## 2026-07-24 session (v0.3.3) — critical bug fixes

- [x] **Downloads failing → misleading "No confident matches" — FIXED (root cause).** yt-dlp's
  audio extraction (`-x --audio-format m4a`) needs ffmpeg, but a GUI app launched from Finder
  inherits a minimal PATH without /opt/homebrew/bin, so yt-dlp couldn't find ffmpeg and every
  download errored. Now passes `--ffmpeg-location` from settings. Verified: under a minimal PATH
  the download fails with "ffprobe and ffmpeg not found" without it and succeeds with it. Also the
  error screen now says "Download failed — <reason>" with a Try-again button, instead of the
  misleading "No confident matches" (which now only shows for a genuinely empty search).
- [x] **Pending double-add / re-add-all — FIXED.** The list-level "Mark N missing" button added
  every track with no already-pending check, so repeated clicks (or re-adding after deleting one)
  re-queued everything. All add-to-Pending paths now dedupe against existing wishes (normalized
  title+artist) and report the true added count ("Already in Pending or your library" when 0).
- [x] **Album split by featured artist — FIXED.** "GIRL" split into 3 because tracks credited
  "Pharrell Williams", "…Feat. Alicia Keys", "…Feat. Justin Timberlake". Albums and Artists now
  group by a base artist with the "feat./ft./featuring …" suffix stripped (`TitleCleaner.baseArtist`,
  unit-tested), keeping the album/artist unified.
- [x] **Album cover not downloaded — FIXED.** Acquisition now passes `--embed-thumbnail
  --convert-thumbnails jpg` to yt-dlp, embedding the video's thumbnail (often the real cover) into
  the m4a via mutagen. Import copies m4a as-is so the cover survives and shows in the library.

## 2026-07-23 session (v0.3.2) — Library Health (quality + dedupe)

- [x] **Library Health view** (sidebar, with a live issue-count badge).
  - **Low quality**: flags lossy masters under 192k instantly (no scan), plus a **Deep scan**
    button that runs the existing spectral analyzer over every master to catch high-bitrate
    *re-encodes* by their frequency cutoff (incl. fake-lossless — a FLAC made from a 128k source).
    Each flagged track has a one-click **"Find better source"** that opens the acquire flow.
  - **Possible duplicates**: groups songs with the same normalized title+artist, ranks them
    (lossless > bitrate > size), marks the best "Keep", and offers **"Keep best, remove N"**
    (routed through the Trash-vs-keep confirm dialog).

## 2026-07-23 session (v0.3.1) — YouTube playlist import

- [x] **Import a YouTube playlist** (user request). Sidebar → YouTube → Import playlist: paste a
  public playlist link, `yt-dlp --flat-playlist` lists every video with thumbnail, channel and
  duration. Each row shows whether it's already **Pending** or **In library** (matched by video id
  in the wish's chosen URL). Click / ⇧-click / ⌘-click to multi-select; one smart button adds the
  selection (or all not-yet-added) to Pending, grouped under the playlist name.
  - Because these are already source URLs, queued videos **download directly** — `beginMatch` now
    honors a wish's `chosenURL` and skips the YouTube search, presenting it as the pre-selected
    candidate (one click to download, and you can still preview it first).
  - Messy titles ("Artist - Song (Official Video)") are parsed via `TitleCleaner` into artist/title
    for tagging. Test added for playlist-title extraction.

## 2026-07-23 session (v0.3.0) — album sync + capacity forecast

- [x] **Album-level device sync** (store non-playlist songs as album groups). The library was
  already album-organized; now albums are a first-class device unit: "Send album to device" /
  "Remove album" in the Albums grid context menu and as a header button when viewing one album,
  plus an on-art badge showing full/partial device status. Implemented as pin-all-tracks, so it
  reuses the tested desired-set logic and lands in Artist/Album folders on the Walkman.
- [x] **Capacity forecast (multi-quality).** The Device screen now shows how many songs the free
  space fits at 128/192/256/320k, based on the library's average track length, with the current
  bitrate highlighted — a quick "should I go 320 or 192?" gauge.

## 2026-07-23 session (v0.2.9) — iPod Shuffle (4th gen)

- [x] **Sync to an iPod Shuffle (4th gen).** `libgpod`/`gtkpod` are dead on modern macOS, so
  OpenSong writes the Shuffle's binary `iTunesSD` database **directly** — the same
  reverse-engineered-and-byte-matched approach used for the Walkman `.m3u8`.
    - `ShuffleDB`: byte-exact iTunesSD writer (bdhs/hths/rths/hphs/lphs, little-endian, MD5[:8]
      track ids, VoiceOver filename derivation), cross-checked against nims11/IPod-Shuffle-4g.
    - `ShuffleSyncEngine`: transcodes/copies desired assets into `iPod_Control/Music/` (incremental
      add/remove by asset id + content hash), then rebuilds `iTunesSD` and VoiceOver each sync.
    - **VoiceOver** via macOS `say --data-format=LEI16 --file-format=WAVE` (the exact PCM WAV the
      firmware wants) → `Speakable/Tracks` + `Speakable/Playlists`, named by reversed-hex dbid.
      Toggle in Settings → Device Format.
    - Auto-detects the iPod (mounted volume with `iPod_Control/`); the app now tracks device *kind*
      (Walkman vs Shuffle) and routes sync/preview accordingly. Device screen + sidebar show the
      right name; "Import from device" (adopt) is hidden for the iPod (managed from library).
    - 5 new tests: 3 byte-level DB assertions + 2 end-to-end sync runs against a temp iPod dir
      (files land, iTunesSD valid, VoiceOver clips generated, idempotency, foreign-file safety).
    - **Still needs the physical Shuffle** plugged in for final confirmation (mount/detect/play) —
      that's the one part I can't test headlessly.

## 2026-07-23 session (v0.2.8) — Spotify

- [x] **Import public Spotify playlists → Pending.** Add free Spotify app credentials (Client
  ID + Secret) in Settings; sidebar gains **Spotify → Import playlists**. Paste any public
  playlist or profile link (URL/URI/ID). We read it via the **Client Credentials flow** (app-only
  token — nobody logs in), compare each track against the local library, and show owned / pending
  / in-library status. Same multi-select "smart add" UX as Apple Music: click / ⇧-click / ⌘-click,
  one button acts on the selection or all-missing, flips to "Remove N from Pending". List-level
  "Mark N missing" queues a whole playlist, grouped under its name (so it's recreated once
  downloaded). Spotify gives no audio (DRM) — it's only the track list; acquisition stays yt-dlp.
  Core: `SpotifyClient` actor (token caching + pagination) with unit tests (URL/URI parsing,
  track pagination + null-track skipping, user playlist listing).

## 2026-07-23 session (v0.2.7)

- [x] **Candidate preview played nothing — FIXED.** Root cause: `yt-dlp -g` with `bestaudio`
  returns YouTube's default audio, which is Opus-in-WebM (itag 251). **AVFoundation can't decode
  WebM/Opus**, so AVPlayer got a valid URL but silently played nothing. Fix: request an
  AVPlayer-friendly format — `bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/best` —
  which yields itag 140 (`audio/mp4`, AAC). Verified with `AVURLAsset`: `isPlayable: true`,
  codec `aac`. Also added an `AVPlayerItemFailedToPlayToEndTime` observer so a bad stream resets
  the row instead of leaving it stuck on "pause".

## 2026-07-23 session (v0.2.6)

- [x] **Preview yt-dlp candidates before downloading.** Each search result's thumbnail is now a
  play/pause button that streams the actual YouTube audio (`yt-dlp -g` → direct URL → AVPlayer),
  so you can confirm you've got the right take before committing. Streaming preview pauses the
  library player; stops when you leave the screen or hit Download.
- [x] **Real thumbnails on candidates.** Uses yt-dlp's thumbnail, falling back to the standard
  `i.ytimg.com/vi/<id>/hqdefault.jpg` still. Cached in memory + on disk. (Gradient placeholder
  in offscreen render, which has no network.)
- [x] **Metadata no longer locked.** Title/Artist/Album on the match screen are editable text
  fields (pre-filled from Apple Music/iTunes, edited freely); edits persist to the wish and are
  used to tag the download. Replaced the "Locked (from Apple Music)" note.
- [x] **Media keys.** Player responds to the macOS play/pause/next/previous hardware keys via
  `MPRemoteCommandCenter`, and publishes Now Playing info (title/artist/duration + scrubbing) so
  the system knows OpenSong is the active audio app.
- [x] **End-of-song bug FIXED.** Root cause: end-of-track was detected by polling `currentTime`,
  but AVAudioPlayer resets `currentTime` to 0 on finish — so the poll never fired, leaving the
  button showing "playing" while silent at 0:00. Now uses `audioPlayerDidFinishPlaying`: advances
  to the next track, or (end of queue) shows a paused, replay-ready state.

## 2026-07-22 session

- [x] **Apple Music: sort + tags + drill-in.** Sort playlists by Name or Default (Music's
  order — Apple's API doesn't expose a real creation date). Origin tag ("Apple Music"/"Smart"/
  "Genius" + "not yours") for playlists not hand-made by the user. Click a playlist to open a
  detail view: add individual missing tracks OR "Mark all missing" — all go to Pending, grouped
  under the playlist name (recreated once downloaded).


- [x] **Title-bar dead space FIXED** (confirmed from user screenshot — traffic lights,
  title, toggles on one row). `.ignoresSafeArea()` at the outermost window-content level.
- [x] **Apple Music load slow / "stuck"** — the JXA fetched each track field one-by-one
  (~6 Apple Events per track = tens of thousands of round-trips). Now fetches properties in
  BULK arrays (~6 events per playlist). Plus an explicit loading spinner + message.
- [x] **Apple Music playlist cover art** — fetch each playlist's artwork (raw data via
  AppleScript), cache on disk, show in the compare rows (gradient fallback if none).


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

- [x] **Pending-tab previews won't play (2026-11-09).** Root cause: YouTube answers 403 for the
  first ~3–4 s after issuing a stream URL; AVPlayer hit it immediately, failed ("Cannot Open")
  and silently stopped. Fix: `YtDlpSource.streamURL` now probes the URL (1-byte range GET)
  until it's served before returning. Also: `Shell` now adds /opt/homebrew/bin + /usr/local/bin
  to child PATH so yt-dlp finds `deno` (YouTube JS challenges) when launched from the Dock.

- [x] **Previews after the first one take ages / never start (2026-11-09, v0.13.2).** Root cause:
  `Shell.run` blocks its thread until the child exits; the review screen fires a yt-dlp quality
  probe per candidate (plus background downloads), parking all ~12 Swift-concurrency threads, so
  the preview's resolve couldn't even start. Fix: `Shell.runAsync` (waits on GCD, not the pool)
  for all async yt-dlp calls; quality probes capped at 4 concurrent.

- [x] **Pasted links won't preview (2026-11-09, v0.13.3).** Root cause: links copied while
  playing carry `&list=RD…` (a YouTube Mix, ~3.9k entries); yt-dlp expanded the whole playlist
  for -g / quality / download / title. Fix: `--no-playlist` on all single-video yt-dlp calls,
  and pasted URLs are trimmed.

- [x] **"Add to Apple Music" button (2026-11-10).** Request: send OpenSong song files into Apple
  Music on click (multi-select or a whole album), like the "Automatically Add to Music" folder.
  Done via Music's scripted `add` (reports per-file success, respects the "copy to Media folder"
  setting) rather than that folder (which moves files and reports nothing). Songs Music already
  has (same file, or title+artist confirmed by album/length) are skipped; non-Music formats
  (FLAC/Opus…) are converted to ALAC/AAC .m4a under Application Support first. Entry points:
  song right-click (multi-select), album right-click + album detail button, playlist right-click.

- [x] **Also update the iCloud library automatically (2026-11-11).** Found 3 songs added to Music
  (2 via the new button) still at cloud status "unknown" ~10 h later — Music wasn't uploading on
  its own. Music has no scripting command for this, so OpenSong UI-scripts File ▸ Library ▸
  Update Cloud Library (needs Accessibility; item stays disabled until Music has a window, hence
  `reopen`). Verified live: all 3 went "unknown" → "uploaded" within 20 s. Runs after every add,
  plus an "Update Cloud Library" button on the Apple Music page.

- [x] **Paste SoundCloud links (2026-11-14).** yt-dlp already handled SoundCloud end to end
  (verified: 160k AAC HLS, no re-encode, cover embedded), so the work was around it:
  `PastedLink` classifies links (track vs set/profile/likes — collections are refused, since a
  set would download every track over one output file); "Fetch info" fills the artist from the
  track's artist tag or uploader when the title has no "Artist - " (SoundCloud titles rarely do);
  labels say "YouTube or SoundCloud". Short on.soundcloud.com links that resolve to a set are
  caught by yt-dlp returning >1 entry.

- [x] **Performance pass (2026-11-24).** Audit found repeated work rather than slow algorithms:
  - `reload()` ran ~500 queries (identity per asset, asset per playlist item) → now 4 (bulk reads
    joined in memory; `allPlaylistAssetIDs`, `allIdentitiesByID`). Sync planner likewise.
  - `filteredSongs` / `albums` recomputed on every access (≈8× per redraw) → memoised on
    `songsVersion` + their inputs. `song(id)` linear scan → dictionary. Album sort keys computed
    once per album, not per comparison. `songs` assigned once per reload (was 1 + one per row).
  - Apple Music / Spotify ownership: rebuilt the library and ran ~12 regexes per comparison per
    track per redraw → `OwnershipIndex` (Core; dictionary lookup, memoised normalise; tested to
    agree with `AppleMusicCompare.matches`).
  - Multi-select "Send to Device" walked the Walkman + reloaded once per song → once per action.
  - Thumbnails re-decoded the full-size cover from disk on every row appearance → ImageIO
    downsample to drawn size + `NSCache`.
  Not done (noted for later): `Shell.run` inside `Task.detached` in a few places, streaming
  SHA-256, splitting `AppStore`, iPod-shuffle sync's per-track identity queries.

## Known environment gotchas (for future sessions)
- **Ad-hoc signing resets TCC**: each `make-app.sh` rebuild changes the ad-hoc signature, so
  macOS Automation/Screen-Recording permission may re-prompt after every rebuild.
- **ImageRenderer** (offscreen screenshots) can't rasterize `ScrollView` content or AppKit
  controls (`Picker`/`TextField`/`Toggle`/`ProgressView`) → use custom SwiftUI + `renderMode`.
- **Stale SwiftPM build cache**: if tests/behavior look stale or a link error mentions missing
  `.o` files, run `swift package clean`.
- **Live screenshots blocked**: the automation session can't composite the app window to the
  display (Spaces); verify UI via `OPENSONG_RENDER=1` offscreen render instead.
