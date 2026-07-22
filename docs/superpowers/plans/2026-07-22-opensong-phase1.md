# OpenSong Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the OpenSong Phase 1 macOS app — a local high-quality master music library with a safe, reconciling sync to a Sony NW-E394 Walkman.

**Architecture:** A SwiftPM package with a pure-Swift engine library (`OpenSongCore`) holding all logic (library index, import/adopt, metadata/artwork resolution, transcode, device sync), a SwiftUI executable (`OpenSong`) recreating the design docs, and a hand-rolled executable test runner (`OpenSongTests`) since XCTest is unavailable under Command Line Tools. Engines wrap `ffmpeg`/`ffprobe` and the iTunes Search API; the device is abstracted behind a `Volume` protocol for hardware-free testing.

**Tech Stack:** Swift 6.0 (Command Line Tools, no Xcode), SwiftPM, GRDB (SQLite), SwiftUI + AppKit, `ffmpeg`/`ffprobe` 8.0.1, iTunes Search API over URLSession, AVFoundation (preview player).

## Global Constraints

- **No XCTest / swift-testing** — tests are functions registered in a custom `TinyTest` harness run by the `OpenSongTests` executable; a failing assertion exits nonzero. Run with `swift run OpenSongTests`.
- **Un-sandboxed** app; subprocesses via `Foundation.Process`. Tool paths configurable, defaults: `/opt/homebrew/bin/ffmpeg`, `/opt/homebrew/bin/ffprobe`.
- **Device write scope:** only under `MUSIC/`. Never touch device system items (`DCIM`, `PICTURE`, `Video`, `FOR_MAC`, `FOR_WINDOWS`, `Help_Guide`, `System Volume Information`, `.fseventsd`, `default-capability.xml`, `DevIcon.fil`, `DevLogo.fil`, `nmdsdcid`, `WMPInfo.xml`).
- **Device identity:** FAT32 volume named `WALKMAN`, matched by volume UUID when known; confirm on first connect.
- **Device music layout:** `MUSIC/<Artist>/<Album>/<Title>.mp3`, bare title filename, `Unknown Artist`/`Unknown Album` fallbacks.
- **Device playlist format (exact):** `MUSIC/<name>.m3u8`, UTF-8 **with BOM** (`EF BB BF`), **CRLF** line endings, `#EXTM3U` header, per entry `#EXTINF:<int-seconds>,<Title>` then a **backslash-separated path relative to MUSIC/**.
- **Device audio:** target **MP3 192 kbps 44.1 kHz**, with **EBU R128** loudness normalization. Device supports MP3/AAC/WMA/WAV only — **never target Opus/FLAC/ALAC for the device**.
- **Sanitizer:** strip FAT-illegal chars `\ / : * ? " < > |` and control chars; trim trailing dots/spaces; preserve Unicode. Same function for tree placement and playlist paths.
- **Never downgrade a master:** dedup keeps the higher-bitrate copy; lossless masters always transcode to MP3 for the device; skip-transcode only when master is MP3 ≤ target bitrate.
- **Design source of truth:** `OpenSong UI design docs/` (British Racing Green accent `#12452b`/`#46a374`, full token table in README).
- **Commit + push** after each green task: `git push` to `origin` (`github.com/jude-sph/OpenSong`), branch `phase-1`.

---

### Task 0: Package scaffold + TinyTest harness

**Files:**
- Create: `Package.swift`, `Sources/OpenSongCore/OpenSongCore.swift`, `Sources/OpenSong/main.swift` (temporary stub), `Sources/OpenSongTests/main.swift`, `Sources/OpenSongTests/TinyTest.swift`

**Interfaces:**
- Produces: `TinyTest` with `func test(_ name: String, _ body: () throws -> Void)`, `func expect(_ cond: Bool, _ msg: String)`, `func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String)`, `func runAll() -> Never`. Global `let t = TinyTest()`. Each test file exposes `func register<Area>Tests()` called from `OpenSongTests/main.swift`.

- [ ] **Step 1:** Create `Package.swift` with three targets: `.target(name:"OpenSongCore", dependencies:[.product(name:"GRDB", package:"GRDB.swift")])`, `.executableTarget(name:"OpenSong", dependencies:["OpenSongCore"])`, `.executableTarget(name:"OpenSongTests", dependencies:["OpenSongCore"])`; dependency `.package(url:"https://github.com/groue/GRDB.swift", from:"7.0.0")`. Platforms `[.macOS(.v14)]`.
- [ ] **Step 2:** Write `TinyTest.swift`: collects `(name, closure)`; `runAll()` executes each, catches throws + assertion failures (throw a `TestFailure` error from `expect`), prints `PASS`/`FAIL` per test and a summary, `exit(failures == 0 ? 0 : 1)`.
- [ ] **Step 3:** `OpenSongTests/main.swift` calls each area's register func then `t.runAll()`. Start with one smoke test `t.test("harness works"){ t.expectEqual(1+1, 2, "math") }`.
- [ ] **Step 4:** Run `swift run OpenSongTests` → expect `PASS harness works` and exit 0.
- [ ] **Step 5:** Commit `chore: scaffold SwiftPM package + TinyTest harness`, push.

---

### Task 1: PathSanitizer

**Files:**
- Create: `Sources/OpenSongCore/PathSanitizer.swift`, `Sources/OpenSongTests/PathSanitizerTests.swift`

**Interfaces:**
- Produces: `enum PathSanitizer { static func component(_ raw: String, fallback: String) -> String }` — sanitizes ONE path component (artist, album, or filename-stem). Strips `\ / : * ? " < > |` + control chars, trims trailing `.`/space, collapses to `fallback` if empty.

- [ ] **Step 1:** Write failing tests over real device names: `component("Richard D. James Album")` keeps interior dot but no trailing; `component("AC/DC")` → `AC DC` (slash removed); `component("Latejapride.")` → `Latejapride` (trailing dot trimmed); `component("half•alive")` unchanged (Unicode kept); `component("")` → fallback; `component("...")` → fallback; `component("Sérgio Mendes")` unchanged; `component("a\\b")` → `a b`.
- [ ] **Step 2:** `swift run OpenSongTests` → FAIL (unresolved `PathSanitizer`).
- [ ] **Step 3:** Implement: filter out illegal set + `CharacterSet.controlCharacters`; replace each removed char with nothing OR a space where it separated words (spec: replace illegal path chars with space, then collapse double spaces, then trim trailing dots/spaces); return fallback if result empty.
- [ ] **Step 4:** `swift run OpenSongTests` → PASS.
- [ ] **Step 5:** Commit `feat: FAT-safe path sanitizer`, push.

---

### Task 2: Domain models

**Files:**
- Create: `Sources/OpenSongCore/Models.swift`, `Sources/OpenSongTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum MetadataProvenance: String, Codable { case appleMusic, itunesResolved, userEdited, unresolved }`
  - `struct TrackIdentity: Codable, Equatable { var id: Int64?; var title: String; var artist: String; var albumArtist: String?; var album: String?; var trackNumber: Int?; var discNumber: Int?; var genre: String?; var year: Int?; var durationSec: Double; var provenance: MetadataProvenance; var artworkPath: String? }`
  - `enum AudioSource: String, Codable { case importedLoose, adoptedFromDevice, downloaded }`
  - `struct AudioAsset: Codable, Equatable { var id: Int64?; var identityID: Int64; var masterPath: String; var format: String; var bitrateKbps: Int; var sampleRate: Int; var sizeBytes: Int64; var contentHash: String; var source: AudioSource }`
  - `struct Playlist: Codable, Equatable { var id: Int64?; var name: String; var syncToDevice: Bool }`
  - `struct PlaylistItem: Codable, Equatable { var id: Int64?; var playlistID: Int64; var assetID: Int64; var position: Int }`
  - `struct DeviceRecord: Codable, Equatable { var id: Int64?; var volumeUUID: String; var name: String; var targetBitrateKbps: Int; var targetFormat: String }`
  - `func effectiveAlbumArtist(_ i: TrackIdentity) -> String` → `albumArtist ?? artist`, sanitized fallback `"Unknown Artist"`.
  - `func effectiveAlbum(_ i: TrackIdentity) -> String` → `album ?? "Unknown Album"`.

- [ ] **Step 1:** Test `effectiveAlbumArtist`/`effectiveAlbum` fallbacks and Codable round-trip of `TrackIdentity` via JSONEncoder/Decoder.
- [ ] **Step 2:** FAIL. **Step 3:** Implement structs/enums + helpers. **Step 4:** PASS. **Step 5:** Commit `feat: core domain models`, push.

---

### Task 3: DeviceRelativePath (canonical path function)

**Files:**
- Create: `Sources/OpenSongCore/DeviceRelativePath.swift`, `Sources/OpenSongTests/DeviceRelativePathTests.swift`

**Interfaces:**
- Consumes: `PathSanitizer`, `TrackIdentity`, model helpers.
- Produces: `enum DeviceRelativePath { static func components(for i: TrackIdentity) -> [String] /* [artist, album, "title.mp3"] */; static func backslashPath(for i: TrackIdentity) -> String; static func fileURL(under musicDir: URL, for i: TrackIdentity) -> URL }`. Filename = `PathSanitizer.component(title) + ".mp3"`.

- [ ] **Step 1:** Test: identity{artist:"Aphex Twin", album:"Drukqs", title:"Vordhosbn"} → `backslashPath` == `Aphex Twin\Drukqs\Vordhosbn.mp3`; missing album → `Unknown Album` segment; `fileURL(under:/M)` ends `/M/Aphex Twin/Drukqs/Vordhosbn.mp3` (forward slashes on disk).
- [ ] **Step 2:** FAIL. **Step 3:** Implement (join sanitized components; backslash join for playlist form, `URL` appendingPathComponent for disk form). **Step 4:** PASS. **Step 5:** Commit `feat: canonical device-relative path`, push.

---

### Task 4: M3U8 playlist writer (golden-byte test)

**Files:**
- Create: `Sources/OpenSongCore/M3U8Writer.swift`, `Sources/OpenSongTests/M3U8WriterTests.swift`
- Use fixture: `Tests/Fixtures/device-brazil.m3u8`

**Interfaces:**
- Consumes: `DeviceRelativePath`, `TrackIdentity`.
- Produces: `enum M3U8Writer { static func data(entries: [(identity: TrackIdentity, durationSec: Int)]) -> Data }`. Emits BOM + `#EXTM3U\r\n` + per entry `#EXTINF:<sec>,<title>\r\n` + `<backslashPath>\r\n`.

- [ ] **Step 1:** Write a test that constructs the 9 identities matching `device-brazil.m3u8` (artist/album/title + duration from each `#EXTINF`) and asserts `M3U8Writer.data(...)` equals the fixture bytes exactly (`Data(contentsOf: fixtureURL)`). Resolve fixture path relative to `#filePath`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement writer: `var out = Data([0xEF,0xBB,0xBF]); append "#EXTM3U\r\n"; for e { append "#EXTINF:\(e.durationSec),\(e.identity.title)\r\n"; append "\(DeviceRelativePath.backslashPath(for: e.identity))\r\n" }`. Encode strings UTF-8.
- [ ] **Step 4:** PASS (byte-identical). **Step 5:** Commit `feat: exact-format m3u8 writer w/ golden test`, push.

---

### Task 5: M3U8 playlist parser (for adopt)

**Files:**
- Create: `Sources/OpenSongCore/M3U8Parser.swift`, `Sources/OpenSongTests/M3U8ParserTests.swift`

**Interfaces:**
- Produces: `struct M3U8Entry: Equatable { var title: String?; var durationSec: Int?; var artist: String; var album: String; var titleFromPath: String; var relativePath: String }`; `enum M3U8Parser { static func parse(_ data: Data) -> [M3U8Entry] }`. Strips BOM, splits on CRLF/LF, pairs `#EXTINF` with following path line, splits path on `\` into [artist, album, file], strips `.mp3`.

- [ ] **Step 1:** Test: parse the `device-brazil.m3u8` fixture → 9 entries; first entry `.artist=="Sérgio Mendes"`, `.album=="Unknown Album"`, `.titleFromPath=="Triste"`, `.durationSec==127`, `.title=="Triste"`. Round-trip: `M3U8Writer.data(from parsed)` == fixture.
- [ ] **Step 2:** FAIL. **Step 3:** Implement parser. **Step 4:** PASS. **Step 5:** Commit `feat: m3u8 parser for device adopt`, push.

---

### Task 6: Subprocess runner

**Files:**
- Create: `Sources/OpenSongCore/Shell.swift`, `Sources/OpenSongTests/ShellTests.swift`

**Interfaces:**
- Produces: `struct ProcessResult { let status: Int32; let stdout: Data; let stderr: Data; var stdoutString: String; var stderrString: String }`; `enum Shell { static func run(_ launchPath: String, _ args: [String], stdin: Data? = nil) throws -> ProcessResult }`. Uses `Foundation.Process` + `Pipe`; reads both pipes to avoid deadlock.

- [ ] **Step 1:** Test: `Shell.run("/bin/echo", ["hi"]).stdoutString.trimmed == "hi"`, status 0; `/usr/bin/false` → status 1.
- [ ] **Step 2:** FAIL. **Step 3:** Implement (read pipes on background queues or via `readDataToEndOfFile` after launch; ensure no deadlock by reading stdout+stderr concurrently). **Step 4:** PASS. **Step 5:** Commit `feat: subprocess runner`, push.

---

### Task 7: AudioProbe (ffprobe wrapper)

**Files:**
- Create: `Sources/OpenSongCore/AudioProbe.swift`, `Sources/OpenSongTests/AudioProbeTests.swift`

**Interfaces:**
- Consumes: `Shell`.
- Produces: `struct ProbeResult { var durationSec: Double; var bitrateKbps: Int; var codec: String; var sampleRate: Int; var channels: Int; var tags: [String:String] }`; `struct AudioProbe { var ffprobePath: String; func probe(_ url: URL) throws -> ProbeResult }`. Runs `ffprobe -v quiet -print_format json -show_format -show_streams <file>`, decodes JSON.

- [ ] **Step 1:** Test generates a 1-second silent MP3 via ffmpeg (`ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -b:a 192k -metadata title=Probe -metadata artist=Tester out.mp3`) into a temp dir, then asserts `probe(out).codec=="mp3"`, `bitrateKbps` ~192 (±40), `sampleRate==44100`, `tags["title"]=="Probe"`, `durationSec` in 0.9...1.2.
- [ ] **Step 2:** FAIL. **Step 3:** Implement JSON model + decode; bitrate from `format.bit_rate` or stream; tags lowercased keys. **Step 4:** PASS. **Step 5:** Commit `feat: ffprobe audio metadata reader`, push.

---

### Task 8: Transcoder (ffmpeg + R128 + skip rule + tag write)

**Files:**
- Create: `Sources/OpenSongCore/Transcoder.swift`, `Sources/OpenSongTests/TranscoderTests.swift`

**Interfaces:**
- Consumes: `Shell`, `AudioProbe`, `ProbeResult`.
- Produces:
  - `struct TranscodeSettings { var format: String /* "mp3" */; var bitrateKbps: Int; var loudnessNormalize: Bool }`
  - `struct Transcoder { var ffmpegPath: String; var probe: AudioProbe; func needsTranscode(_ src: ProbeResult, _ s: TranscodeSettings) -> Bool; func transcode(from src: URL, to dst: URL, tags: TrackIdentity, settings: TranscodeSettings) throws; func writeTags(_ url: URL, _ tags: TrackIdentity) throws }`
  - `needsTranscode` returns false only when `src.codec=="mp3" && src.bitrateKbps <= s.bitrateKbps` (else true).
- ffmpeg command: `ffmpeg -y -i src [-af loudnorm=I=-16:TP=-1.5:LRA=11] -c:a libmp3lame -b:a {k}k -ar 44100 -id3v2_version 3 -metadata title=.. -metadata artist=.. -metadata album=.. -metadata album_artist=.. -metadata track=.. -metadata date=.. dst`.

- [ ] **Step 1:** Tests: (a) `needsTranscode(mp3@128, target192)==false`; `(mp3@320,target192)==true`; `(flac,*)==true`. (b) transcode the 320k test file → 192k mp3, probe result codec mp3 & bitrate ≤ ~200 & `tags["title"]` set to identity title & `tags["track"]` set from trackNumber.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Titles/albums with special chars passed as separate argv (no shell). **Step 4:** PASS. **Step 5:** Commit `feat: ffmpeg transcoder w/ R128 + skip rule`, push.

---

### Task 9: LibraryStore (GRDB schema + CRUD)

**Files:**
- Create: `Sources/OpenSongCore/LibraryStore.swift`, `Sources/OpenSongTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: all models.
- Produces: `final class LibraryStore { init(dbURL: URL) throws; func upsertIdentity(_:) throws -> Int64; func insertAsset(_:) throws -> Int64; func allAssetsWithIdentity() throws -> [(AudioAsset, TrackIdentity)]; func createPlaylist(name:syncToDevice:) throws -> Int64; func addToPlaylist(playlistID:assetID:position:) throws; func playlistItems(_ id:Int64) throws -> [AudioAsset]; func devicePlaylists() throws -> [Playlist]; func findAssetByHash(_ hash:String) throws -> AudioAsset?; func findIdentity(title:artist:album:) throws -> TrackIdentity?; func pin(assetID:Int64,_ pinned:Bool) throws; func pinnedAssets() throws -> [AudioAsset]; func upsertDevice(_:) throws -> Int64 }`. Uses GRDB migrations to create tables per spec §4.

- [ ] **Step 1:** Test against a temp DB file: create identity+asset, read back via `allAssetsWithIdentity`; create playlist, add 2 assets, `playlistItems` returns them in position order; `findAssetByHash` hit/miss; pin/unpin reflected in `pinnedAssets`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement migrations + methods. **Step 4:** PASS. **Step 5:** Commit `feat: GRDB library store`, push.

---

### Task 10: MetadataResolver (iTunes Search API)

**Files:**
- Create: `Sources/OpenSongCore/MetadataResolver.swift`, `Sources/OpenSongTests/MetadataResolverTests.swift`

**Interfaces:**
- Produces:
  - `struct CatalogMatch { var title:String; var artist:String; var album:String; var trackNumber:Int?; var discNumber:Int?; var genre:String?; var year:Int?; var durationSec:Double; var artworkURL:URL? }`
  - `protocol HTTPClient { func get(_ url: URL) async throws -> Data }` (default `URLSessionHTTPClient`)
  - `struct MetadataResolver { var http: HTTPClient; func search(term: String, limit: Int) async throws -> [CatalogMatch]; func bestMatch(term: String, durationSec: Double) async throws -> CatalogMatch? }`
  - `search` calls `https://itunes.apple.com/search?media=music&entity=song&limit={n}&term={url-encoded}`; decode; `artworkURL` upgraded by replacing `100x100bb` → `600x600bb`. `bestMatch` ranks by smallest `abs(durationSec - trackTimeMillis/1000)`.

- [ ] **Step 1a (unit, offline):** Feed a canned iTunes JSON payload via a stub `HTTPClient`; assert decode → `trackNumber`, `discNumber`, `year` (from `releaseDate` prefix), `durationSec`, hi-res `artworkURL`.
- [ ] **Step 1b (live, guarded):** If env `OPENSONG_LIVE=1`, `bestMatch(term:"Aphex Twin Vordhosbn", durationSec:291)` returns album containing "Drukqs" (tolerant contains check). Skip when unset (log SKIP).
- [ ] **Step 2:** FAIL. **Step 3:** Implement client + Codable models + ranking. **Step 4:** PASS (run `OPENSONG_LIVE=1 swift run OpenSongTests` once to confirm live path). **Step 5:** Commit `feat: iTunes metadata resolver`, push.

---

### Task 11: ArtworkResolver

**Files:**
- Create: `Sources/OpenSongCore/ArtworkResolver.swift`, `Sources/OpenSongTests/ArtworkResolverTests.swift`

**Interfaces:**
- Consumes: `Shell` (ffmpeg embedded-art extract), `HTTPClient`.
- Produces: `struct ArtworkResolver { var ffmpegPath:String; var http:HTTPClient; func extractEmbedded(from url: URL, to dst: URL) throws -> Bool; func download(_ url: URL, to dst: URL) async throws; func embed(_ art: URL, into audio: URL) throws }`. Extract via `ffmpeg -i in.mp3 -an -c:v copy cover.jpg` (returns false if no video stream). Embed via `ffmpeg -i audio -i art -map 0:a -map 1:v -c copy -id3v2_version 3 -metadata:s:v title="Album cover" out` (to temp then replace).

- [ ] **Step 1:** Test: create mp3 with embedded art (generate a tiny PNG via ffmpeg `-f lavfi -i color=c=red:s=64x64 -frames:v 1 art.png`, embed, then `extractEmbedded` returns true and dst file non-empty). Plain mp3 (no art) → `extractEmbedded` returns false.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `feat: artwork resolver`, push.

---

### Task 12: Importer (loose import + adopt-from-device)

**Files:**
- Create: `Sources/OpenSongCore/Importer.swift`, `Sources/OpenSongTests/ImporterTests.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `AudioProbe`, `MetadataResolver`, `ArtworkResolver`, `PathSanitizer`, `DeviceRelativePath`, `M3U8Parser`, models.
- Produces:
  - `struct ImportCandidate { var sourceURL:URL; var probe:ProbeResult; var original:TrackIdentity; var suggested:TrackIdentity?; var chosen:TrackIdentity }` (review-table row)
  - `struct Importer { var store:LibraryStore; var probe:AudioProbe; var resolver:MetadataResolver; var libraryRoot:URL; func scanLoose(_ folder:URL) throws -> [ImportCandidate]; func resolveSuggestions(_ c: inout [ImportCandidate]) async; func commit(_ chosen:[ImportCandidate]) throws -> [AudioAsset] /* copies into tree, backfills track#, dedups highest-bitrate, indexes */; func adopt(musicDir:URL) throws -> (assets:[AudioAsset], playlists:[Playlist]) }`
  - `commit` copies to `libraryRoot/<AlbumArtist>/<Album>/<Title>.<ext>`, computes contentHash (SHA256 of file), dedups via `findAssetByHash` and via identity match keeping higher bitrate; writes chosen tags to the copied file (Transcoder.writeTags).
  - `adopt` walks `musicDir/*/*/*.mp3`, imports as `adoptedFromDevice` (never replacing a higher-bitrate master), parses each `*.m3u8` and reconstructs playlists mapping entries→assets by artist/album/title.

- [ ] **Step 1a:** `scanLoose` over a temp folder with 2 generated mp3s (one tagged, one untagged) returns 2 candidates; untagged one's `original.title` falls back to filename stem.
- [ ] **Step 1b:** `commit` places files under the tree at expected paths, indexes them, and dedups two identical-hash inputs to a single asset.
- [ ] **Step 1c:** `adopt` over a simulated `MUSIC/` (2 tracks in Artist/Album, one `test.m3u8` written by `M3U8Writer`) returns 2 assets + 1 playlist whose items resolve to those assets.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `feat: importer (loose + adopt)`, push.

---

### Task 13: Volume abstraction + DeviceManager

**Files:**
- Create: `Sources/OpenSongCore/Volume.swift`, `Sources/OpenSongCore/DeviceManager.swift`, `Sources/OpenSongTests/DeviceManagerTests.swift`

**Interfaces:**
- Produces:
  - `protocol Volume { var musicDir: URL { get }; var uuid: String { get }; var name: String { get }; func capacity() throws -> (totalBytes: Int64, freeBytes: Int64) }`
  - `struct DiskVolume: Volume` (real, from a mount point; capacity via `URLResourceValues.volumeAvailableCapacity`/`volumeTotalCapacity`) and `struct TempVolume: Volume` (test, backed by a temp dir with injectable capacity).
  - `enum DeviceDetector { static func connectedWalkman() -> DiskVolume? }` — scans `/Volumes/*`, picks FAT volume named `WALKMAN` (or any with a `MUSIC` dir), reads UUID via `URLResourceValues`.
  - `struct DeviceManager { var volume: Volume; static let systemNames: Set<String>; func listManagedTracks() throws -> [String] /* relative backslash paths present under MUSIC */; func write(assetFile: URL, to i: TrackIdentity) throws; func remove(relative: String) throws; func writePlaylist(name:String, data:Data) throws; func existingPlaylists() throws -> [URL] }`. All writes assert path is under `musicDir` and not a system item.

- [ ] **Step 1:** Using `TempVolume`: `write` an mp3 for an identity → file appears at `musicDir/Artist/Album/Title.mp3`; `listManagedTracks` includes its backslash relative path; `remove` deletes it; `writePlaylist` writes bytes at `musicDir/x.m3u8`; attempting `remove("../WMPInfo.xml")` throws (scope guard).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `feat: volume abstraction + device manager`, push.

---

### Task 14: SyncEngine (reconcile)

**Files:**
- Create: `Sources/OpenSongCore/SyncEngine.swift`, `Sources/OpenSongTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `Transcoder`, `DeviceManager`, `M3U8Writer`, `DeviceRelativePath`, models.
- Produces:
  - `struct SyncPlan { var toAdd:[AudioAsset]; var toRemove:[String]; var upToDate:[AudioAsset]; var projectedUsedBytes:Int64; var totalBytes:Int64 }`
  - `struct SyncEngine { var store:LibraryStore; var transcoder:Transcoder; var device:DeviceManager; var settings:TranscodeSettings; func desiredAssets() throws -> [AudioAsset] /* pinned ∪ device-playlist members */; func plan() throws -> SyncPlan; func apply(_ plan:SyncPlan, progress:(String)->Void) throws /* transcode-or-copy adds, remove managed removes, (re)write device playlists */ }`
  - `toRemove` only includes OpenSong-managed device tracks absent from desired set — never foreign files.
  - `apply` is idempotent: re-running `plan()` after `apply` yields empty add/remove.

- [ ] **Step 1a:** Build a library (2 assets) + 1 device playlist flagged sync, backed by a `TempVolume`. `plan()` → both in `toAdd`, none removed; projectedUsed grows.
- [ ] **Step 1b:** `apply` copies/transcodes both into MUSIC + writes the `.m3u8`; a second `plan()` → all `upToDate`, empty add/remove (idempotent).
- [ ] **Step 1c:** Remove one asset from the desired set → `plan().toRemove` contains exactly that track's relative path; a pre-planted foreign file `MUSIC/foreign/x.mp3` is never in `toRemove`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `feat: reconciling sync engine`, push.

---

### Task 15: Engine integration test (end-to-end, headless)

**Files:**
- Create: `Sources/OpenSongTests/EndToEndTests.swift`

- [ ] **Step 1:** One test: generate 3 loose mp3s (varied bitrate incl. a 320k) in a temp folder → `Importer.scanLoose`+`commit` into a temp library → create a playlist with 2 of them, flag syncToDevice → `SyncEngine.plan/apply` against a `TempVolume` → assert: MUSIC contains 2 files at expected backslash paths, the 320k one was transcoded to ≤200k (probe), the `.m3u8` parses back (M3U8Parser) to the 2 entries, second plan is empty. Also assert never-downgrade: an adopted 192k track vs a 320k loose original of the same identity keeps the 320k as master.
- [ ] **Step 2:** Run → PASS. **Step 3:** Commit `test: end-to-end engine integration`, push.

---

### Task 16: Design tokens + app shell

**Files:**
- Create: `Sources/OpenSong/Theme.swift`, `Sources/OpenSong/OpenSongApp.swift` (replaces `main.swift` stub), `Sources/OpenSong/RootView.swift`, `Sources/OpenSong/Sidebar.swift`, `Sources/OpenSong/ActivityBar.swift`

**Interfaces:**
- Produces: `enum Theme` with dynamic `Color` tokens for every README token (light+dark values), keyed off `@Environment(\.colorScheme)` or a custom appearance toggle; `@main struct OpenSongApp: App`; `RootView` = `NavigationSplitView { Sidebar } detail: { content } ` with a bottom `ActivityBar`. Sidebar sections/rows per README §"Sidebar sections". Use `-parse-as-library` semantics (no top-level code in the @main file).

- [ ] **Step 1:** Implement token colors (Color(red:green:blue:) from hex), sidebar with the LIBRARY/PLAYLISTS/DEVICE/(later) sections, selection pill styling, 44px title bar with light/dark toggle + Settings button, 46px activity bar with "No background activity" empty copy.
- [ ] **Step 2:** `swift build` → compiles clean. (No GUI run tonight; compile-verify only.)
- [ ] **Step 3:** Commit `feat: design tokens + app shell (compile-verified)`, push.

---

### Task 17: AppStore (observable view-model wiring engines)

**Files:**
- Create: `Sources/OpenSong/AppStore.swift`, `Sources/OpenSong/UIModels.swift`

**Interfaces:**
- Produces: `@Observable final class AppStore` holding `libraryRoot`, `LibraryStore`, engines, `songs: [SongRow]`, `playlists`, `device state`, `settings`, `activeView`, `selection`, `openSheet`, plus actions `loadLibrary()`, `beginImport(folder:)`, `commitImport(...)`, `refreshDevice()`, `buildSyncPlan()`, `runSync()`. `SongRow` mirrors README `Song` model (title/artist/album/durationSec/format/kbps/onDevice/track/genre/year/path/sizeBytes). Long ops run off the main actor; UI observes.

- [ ] **Step 1:** Implement; provide an in-memory/temp default library so the app runs without onboarding during dev. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: observable app store wiring engines`, push.

---

### Task 18: Library browser (Songs/Albums/Artists)

**Files:**
- Create: `Sources/OpenSong/LibraryView.swift`, `Sources/OpenSong/SongsTable.swift`, `Sources/OpenSong/AlbumsGrid.swift`, `Sources/OpenSong/ArtistsList.swift`

- [ ] **Step 1:** Songs `Table` with columns per README §2 (on-device dot, artwork thumb, Title, Artist, Album, Time tabular, Kind); selection (single/⌘/⇧), selection action bar, right-click context menu; Albums `LazyVGrid` (`minmax(146)`), Artists list rows; view switcher segmented control; live search filter; sort album-then-track. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: library browser views (compile-verified)`, push.

---

### Task 19: Metadata editor + art picker sheet

**Files:**
- Create: `Sources/OpenSong/MetadataEditorView.swift`, `Sources/OpenSong/ArtPickerView.swift`

- [ ] **Step 1:** ~520px sheet: 120px artwork well, Title/Artist/Album, Track#/Genre/Year row, grey info panel (Format/Size/Path RTL-ellipsized), Cancel + "Save to file tags" (calls `Transcoder.writeTags`); art picker row of candidate covers (embedded / iTunes / drop). `swift build` compiles.
- [ ] **Step 2:** Commit `feat: metadata editor + art picker (compile-verified)`, push.

---

### Task 20: Import review table

**Files:**
- Create: `Sources/OpenSong/ImportReviewView.swift`

- [ ] **Step 1:** Table with Original vs Suggested columns per field, per-field accept/override, Unknown-Artist bucket, "Import N songs" action → `AppStore.commitImport`; after success, an offer to delete originals. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: import review table (compile-verified)`, push.

---

### Task 21: Playlists view

**Files:**
- Create: `Sources/OpenSong/PlaylistsView.swift`

- [ ] **Step 1:** Playlist detail: 74px gradient cover, PLAYLIST eyebrow, name, "N songs · duration", "Generate on device" toggle (writes `syncToDevice`; label may say .m3u but engine writes .m3u8), drag-to-reorder track table with hover remove. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: playlists view (compile-verified)`, push.

---

### Task 22: Device view (capacity ring + sync diff)

**Files:**
- Create: `Sources/OpenSong/DeviceView.swift`, `Sources/OpenSong/CapacityRing.swift`

- [ ] **Step 1:** Disconnected state (dashed glyph + explainer); connected header with 82px `CapacityRing` (used/7.4GB), model + "X GB free · Target MP3 192k", Bitrate/Eject buttons, Sync button; sync diff three groups (Will add + transcoded-size estimate + total, Will remove strikethrough, Up to date dimmed); **live capacity ring** reflects projectedUsed from `SyncPlan`; syncing/error banners. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: device view w/ live capacity ring (compile-verified)`, push.

---

### Task 23: Settings sheet

**Files:**
- Create: `Sources/OpenSong/SettingsView.swift`

- [ ] **Step 1:** Sections: Master Library (path + Choose…), Device Format (format select **MP3/AAC only** — no Opus, no lossless; bitrate 128/192/256/320; loudness toggle), Tool Paths (ffmpeg/ffprobe/yt-dlp), Smart Features (toggles, disabled/"coming in Phase 2" where not yet wired). Persist to `UserDefaults`/store. `swift build` compiles.
- [ ] **Step 2:** Commit `feat: settings (device format restricted to MP3/AAC)`, push.

---

### Task 24: Preview player + menu bar extra

**Files:**
- Create: `Sources/OpenSong/PreviewPlayer.swift`, `Sources/OpenSong/MenuBarExtraView.swift`

- [ ] **Step 1:** `PreviewPlayer` (AVFoundation `AVAudioPlayer`/`AVPlayer`) transport bar: artwork thumb, title/artist, play/pause, scrub w/ time, volume; idle state. `MenuBarExtra` ("Walkman: N songs · X GB free" when connected / "Offline"; quick Sync). `swift build` compiles.
- [ ] **Step 2:** Commit `feat: preview player + menu bar extra (compile-verified)`, push.

---

### Task 25: App bundle assembly + smoke run

**Files:**
- Create: `Scripts/make-app.sh`, `Resources/Info.plist`

- [ ] **Step 1:** Script builds release (`swift build -c release`) and assembles `OpenSong.app/Contents/{MacOS/OpenSong, Info.plist}` (LSUIElement false, bundle id `com.jude.OpenSong`, min macOS 14). Document that launching/visual verification happens with Xcode in the morning.
- [ ] **Step 2:** Run `Scripts/make-app.sh` → bundle builds without error. Commit `chore: .app bundle assembly script`, push.

---

### Task 26: Morning handoff notes

**Files:**
- Create: `docs/NIGHT-REPORT.md`

- [ ] **Step 1:** Write what was built, test results (`swift run OpenSongTests` output), what's compile-verified vs runtime-verified, the deferred/non-blocking questions, and the "install Xcode → run visual pass → reconnect device to re-verify m3u8 byte-identity" checklist. Commit + push.

---

## Self-Review

**Spec coverage:** LibraryStore(T9)·Importer loose+adopt(T12)·MetadataResolver(T10)·ArtworkResolver(T11)·Transcoder+R128+skip(T8)·DeviceManager+scope guard(T13)·SyncEngine+capacity+foreign-safe+idempotent(T14)·sanitizer(T1)·canonical path(T3)·m3u8 write/parse exact format(T4/T5)·all UI screens(T16-24)·MP3/AAC-only device format(T23)·preview player+menu bar(T24). Verified device facts encoded in Global Constraints. Deferred Phase 2/3 correctly out of scope.

**Placeholder scan:** No TBD/TODO; each engine task has concrete tests + commands; UI tasks are compile-verified tonight (runtime pass deferred to Xcode, per capability constraint) — this is an explicit, justified limitation, not a placeholder.

**Type consistency:** `TrackIdentity`/`AudioAsset`/`Playlist` names consistent across T2→T14; `DeviceRelativePath.backslashPath` used by both writer(T4) and device manager/sync(T13/14); `TranscodeSettings` shared T8/T14/T23; `HTTPClient` shared T10/T11.
