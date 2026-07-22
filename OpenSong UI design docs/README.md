# Handoff: OpenSong — macOS music-library manager

## Overview
OpenSong is a native macOS desktop app: a personal music-library manager that keeps
high-quality **master files on the Mac (source of truth)** and syncs bitrate-reduced
copies to a Sony **Walkman NW-E394** (an 8 GB MP3 player that mounts as a USB drive).
It's a calmer, prosumer alternative to iTunes/Doppler. This bundle covers all screens
across every phase so the design is coherent end-to-end.

## About the Design Files
`OpenSong.dc.html` is a **design reference created in HTML** — an interactive prototype
showing the intended look, layout, and behavior. It is **not production code to copy**.
The brief targets **SwiftUI (native macOS)**, so the task is to **recreate these designs
in SwiftUI** using standard AppKit/SwiftUI patterns (`NavigationSplitView` source list,
`Table`, toolbar with `.segmentedControl`/search, `.sheet`/`.popover`, inspector panels,
`ProgressView`). Use SF Pro and system materials/vibrancy natively. If you prefer a
different stack, treat the HTML purely as a visual + interaction spec.

The HTML is a single "Design Component" — one file with a small runtime. To view it,
open it in a browser (or the design tool it came from). Everything is inline-styled.

## Fidelity
**High-fidelity.** Final colors, spacing, typography, states, and interactions are all
intentional. Recreate pixel-close, but swap HTML primitives for their native SwiftUI
equivalents rather than reproducing DOM structure. Album art in the prototype is
**striped/gradient placeholders**; production uses real embedded artwork.

## Global Layout
- Window default **1180 × 770** (design for ~1100×720, resizable, sensible minimum).
- **Title bar (44px):** traffic lights · centered "OpenSong" title · Light/Dark segmented
  toggle · Settings (sliders) icon button.
- **Body:** left **source-list sidebar (222px)** + content column.
- **Content column:** contextual header (title + subtitle/count on the left; view
  switcher / search / actions on the right) → scrolling body → (window-wide) activity bar.
- **Activity bar (46px):** persistent bottom bar. Per-task spinner + label + thin progress
  bar + cancel (×). Right side shows library totals. Empty copy: "No background activity".

### Sidebar sections (source list)
- **LIBRARY:** All Songs, Albums, Artists (music-note / disc / person icons).
- **WISHLIST:** Pending (bookmark icon) + count badge.
- **PLAYLISTS:** user playlists; each shows an accent dot when "generate on device" is on.
- **DEVICE:** Walkman NW-E394 — shows a small **capacity ring** when connected; label
  reads "Walkman — Offline" and is dimmed when disconnected.
- **APPLE MUSIC:** Compare.
- Selected sidebar row = accent-filled pill with white text (macOS accent-selection style).

## Screens / Views

### 1. Onboarding / First-run  *(Phase 1)*
Full-window centered screen: app glyph, "Welcome to OpenSong", one-line explainer that
the Mac is the source of truth and the player is a sync target. Card: **Choose your master
library folder** with a mono path field (`~/Music/OpenSong Library`) + "Choose…". Optional
dashed card: **Connect Apple Music · optional** ("Grant access"). Primary accent button:
**Get Started**. Reachable in the prototype from Settings → "Choose…".

### 2. Library browser (primary)  *(Phase 1)*
- **View switcher** (segmented, top-right): Songs / Albums / Artists.
- **Songs table:** columns → on-device dot · 24px artwork thumb · **Title** · Artist ·
  Album · **Time** (right, tabular) · **Kind** (right, e.g. "FLAC 1411", "ALAC 1005",
  "MP3 320"). Sticky uppercase header row. Compact rows 32px (comfortable = 38px).
  On-device = filled accent dot; not-on-device = hollow ring.
- **Selection:** click = single; ⌘/Ctrl-click = toggle; Shift-click = range. Selected row
  = accent background, white text. A **selection action bar** appears above the table:
  "N selected · Add to Playlist · Pin to Device · Edit Metadata · Delete · Clear".
- **Right-click context menu:** Play · Add to Playlist ▸ · Pin to Device · Edit Metadata… ·
  (sep) · Reveal in Finder · Delete from Library (red).
- **Albums grid:** responsive `repeat(auto-fill, minmax(146px,1fr))`, gap 24×20. Square
  cover (gradient placeholder, initials bottom-left, white on-device dot top-right), name,
  "Artist · Year". Click filters the Songs list to that album.
- **Artists:** list rows — 52px circular gradient avatar, name, "N albums · M songs",
  chevron.
- Double-click a song row opens the metadata editor. Empty-search state shows a message.

### 3. Song metadata editor (sheet)  *(Phase 1)*
Centered sheet ~520px. Left: 120px artwork well ("Replace artwork"). Right: Title, Artist,
Album, then a row of Track # / Genre / Year. Grey info panel: Format, Size, Path (ellipsized,
RTL). Footer: **Cancel** (bordered) + **Save to file tags** (accent).

### 4. Wishlist / Pending  *(later phase)*
Table: **State** pill (Wishlist=grey, Matching=amber, Downloaded=green) · Title · Artist ·
**Source** badge (Apple Music=blue, Custom=grey) · action. Matching rows show a **Review**
button → Match review. Downloaded rows show a green "Verified" check. Header action:
"+ Custom Item" (opens a small add sheet: Title, Artist, Add).

### 5. Match review — the yt-dlp flow  *(later phase, key screen)*
Full content view. Header: back-to-Wishlist button + "Finding a source for **Title** — Artist".
Steps:
- **loading:** spinner, "Searching YouTube via yt-dlp…".
- **results:** two columns. Left = **candidate cards** (radio dot, 92×52 thumb with play
  glyph, video title clamped 2 lines, "channel · views", confidence tag (High=green/
  Medium=amber/Low=grey) + "≈ duration match" / "duration differs", right-aligned duration).
  Radio-select one; paste-custom-URL field below. Right = **auto-cleaned metadata form**
  (Title/Artist/Album/Track/Year, "Auto-cleaned" badge) + full-width accent **Download & tag**.
- **downloading:** progress bar + "yt-dlp → ffmpeg → tagging → fingerprint verify" + %.
- **done:** green check, "Downloaded & verified", "Quality verified · 98% match" pill.
- **error (no matches):** red glyph, "No confident matches found", paste-URL field + Retry.

### 6. Playlists  *(Phase 1)*
Sidebar lists user playlists. Detail: header with 74px gradient cover, "PLAYLIST" eyebrow,
big name, "N songs · duration", and a **Generate on device (.m3u)** toggle. Track table is
**drag-to-reorder** (grip handle, 24px art, Title, Artist, Time, hover remove "−").

### 7. Device (Walkman) view  *(Phase 1)*
- **Disconnected:** dashed device glyph, "No device connected", explainer, "Simulate connect".
- **Connected:** header = 82px **capacity ring** (used GB of 7.4 GB) + "Sony Walkman
  NW-E394", "X GB free · Target format MP3 192k", "Bitrate & format…" / "Eject" buttons,
  and a big accent **Sync** button.
- **Sync diff preview:** three groups — **Will add** (accent dot; new songs + transcoded
  size estimate + total), **Will remove** (red dot; strikethrough + −size), **Up to date**
  (grey dot; dimmed). Device set = pinned songs ∪ playlists marked for device.
- **Syncing:** inline progress banner + activity-bar task ("transcoding MP3 192k").
- **Error:** red banner "Device unplugged mid-sync — N files copied…".

### 8. Apple Music browse/compare  *(later phase)*
Rows: 46px cover, name + kind badge (Playlist/Album), "owned N of M" subtitle, an
**owned/missing progress bar**, and either a green "Complete" check or an accent
**Mark N missing** button (→ adds to Wishlist). Footer: dashed **Import local file…** for
non-DRM Apple Music files on disk.

### 9. Settings (sheet)  *(Phase 1)*
Sections: **Master Library** (mono path field + Choose…), **Device Format** (Target format
select MP3/AAC/Opus, Bitrate select 128/192/256/320, Loudness-normalization toggle),
**Tool Paths** (yt-dlp, ffmpeg mono fields), **Smart Features** (toggles: AI metadata
cleanup, Fingerprint match verification, Audio quality checking). Close ×.

### 10. States (throughout)
Empty (empty library search, no device), loading (match search, spinners), error (no
matches, sync unplugged), and in-progress (download %, sync %) states are all represented.

## Interactions & Behavior
- **Light/Dark** toggle in the title bar flips the whole theme (all tokens below have a
  light and dark value). In SwiftUI this is just `.preferredColorScheme` / dynamic colors.
- Sidebar selection routes the content view. View switcher swaps Songs/Albums/Artists.
- Search filters the songs table live (title/artist/album). Sort default = album then track.
- Toggles animate the knob `translateX(16px)` over ~150ms; track goes accent when on.
- Progress simulations (download, sync) tick with a timer to a done/error state.
- Context menu opens at cursor on right-click; closes on any outside click.
- Drag-to-reorder in playlist detail uses native drag events; splice on drop.

## State Management (map to `@State`/`@Observable` / a store)
- `appearance` (light/dark), `activeView` (allSongs | albums | artists | wishlist |
  playlist | device | apple | match), `activePlaylist`, `filterAlbum`, `search`, `sort`.
- `selectedSongIDs: Set`, `contextMenu {x,y}`.
- `openSheet` (none | meta | settings | onboarding | addWishlist), `metaDraft`.
- `matchID`, `matchStep` (loading | results | downloading | done | error), selected
  candidate, `downloadProgress`, editable `matchMeta`.
- `deviceConnected`, `syncing`, `syncProgress`, `syncError`.
- `settings { format, bitrate, loudness, ytDlpPath, ffmpegPath, aiCleanup, fingerprint,
  qualityCheck, libraryPath }`.
- Data models: `Song { title, artist, album, albumID, durationSec, format, kbps, onDevice,
  track, genre, year, path, sizeBytes }`, `Album`, `Playlist { name, onDevice, songIDs[] }`,
  `WishItem { artist, title, source, state }`, `Candidate`, `AppleEntry { name, kind,
  ownedCount, totalCount }`.

## Design Tokens

### Colors — Light
| token | value | use |
|---|---|---|
| desk | `#c9c9cd` | window backdrop |
| content / sheet | `#ffffff` | main surface, sheets |
| sidebar | `#e8e7ea` | source list |
| titlebar | `#edecef` | top + activity bars |
| header | `#f7f6f8` | content header, table header, info panels |
| text | `#1d1d1f` | primary text |
| text2 | `#65656c` | secondary |
| text3 | `#9b9ba2` | tertiary / placeholder |
| sep | `rgba(0,0,0,.09)` | separators |
| sepStrong | `rgba(0,0,0,.14)` | stronger borders |
| **accent / sel** | `#12452b` | **British Racing Green** — selection, buttons, ring |
| accentText / selText | `#ffffff` | text on accent |
| selSoft | `rgba(18,69,43,.11)` | tinted selection wash |
| hover | `rgba(0,0,0,.05)` | row/button hover |
| stripe | `rgba(0,0,0,.02)` | row divider |
| field | `#ffffff` (border `rgba(0,0,0,.16)`) | inputs |
| chip | `rgba(0,0,0,.06)` | segmented track, badges |
| track | `rgba(0,0,0,.10)` | progress track |
| amber `#a8680a` · red `#c2331f` · green `#1f7a45` | | states |

### Colors — Dark
desk `#0d0d0f` · content `#1c1c1f` · sheet `#26262b` · sidebar `#201f24` · titlebar
`#2a2830` · header `#242327` · text `#f2f2f5` · text2 `#a0a0a8` · text3 `#6f6f77` ·
sep `rgba(255,255,255,.09)` · sepStrong `rgba(255,255,255,.16)` · **accent/sel `#46a374`**
(lighter racing green for contrast) · **accentText `#08160f`** (dark text on the lighter
accent) · selText `#eafff2` · selSoft `rgba(70,163,116,.16)` · hover `rgba(255,255,255,.06)`
· stripe `rgba(255,255,255,.025)` · field `#2c2c31` (border `rgba(255,255,255,.18)`) ·
chip `rgba(255,255,255,.09)` · track `rgba(255,255,255,.14)` · amber `#e0a63a` ·
red `#ff6a5a` · green `#54c98a`.

> Note the accent flips between modes AND its text color flips with it — don't reuse the
> light accent on a dark surface (contrast breaks). Model as two dynamic colors.

### Typography
System font stack (SF Pro on macOS). Sizes: window title 13/600 · screen title 18/700
(letter-spacing −.2) · playlist/large title 22–23/800 · table cells 13 · table header
11/600 uppercase (letter-spacing .4) · secondary 12–12.5 · badges/labels 11–11.5/600 ·
mono for paths (`ui-monospace, Menlo`).

### Spacing / radius / shadow
Content padding 20px · content-header 14/20/12 · row heights 30–46 · card gap 20–24.
Radius: rows/inputs 7–8 · cards/sheets 9–12 · window 12 · pills 20 · dots/rings circular.
Shadows: window `0 24px 64px rgba(0,0,0,.30)` (dark `0 28px 74px rgba(0,0,0,.62)`);
sheets `0 24px 70px rgba(0,0,0,.4)`; buttons `0 2–3px 8–10px rgba(0,0,0,.15)`.
Toggle switch: 38×22 track, 18px knob, on = knob `translateX(16px)`, track = accent.

## Assets
No external assets. Album/artist art = **procedural gradient placeholders** keyed by hue
(`linear-gradient(150deg, hsl(H S% 52%), hsl(H+24 S% 32%))`). Icons are simple inline SVG
(circle/line/rect/triangle primitives) — replace with **SF Symbols** in production
(music.note, square.stack, person.crop.circle, bookmark, list.bullet, ipod, sparkles, etc.).
Sample content is a Kanye West discography (real album/track names) — replace with the
user's real library.

## Files
- `OpenSong.dc.html` — the complete interactive prototype (all 10 screens, both themes).
  Open in a browser to explore. All markup is inline-styled; the logic class near the
  bottom holds the data model, theme tokens (`theme()`), and every handler — read it for
  exact values and behavior.
