import Foundation
import Observation
import AppKit
import OpenSongCore

/// Observable app state, backed by a real GRDB `LibraryStore` and wired to the engine
/// services. Import locations are always chosen by the user (never hardcoded).
@Observable
@MainActor
final class AppStore {
    // Appearance / navigation
    var dark: Bool = false
    var activeView: ActiveView = .allSongs
    var search: String = ""
    var selection: Set<Int64> = []
    var openSheet: Sheet? = nil
    var filterAlbumID: String? = nil       // set → viewing one album's tracks (within Albums)
    var filterArtist: String? = nil        // set → viewing one artist's albums (within Artists)
    var songSort: SongSort = .init()       // Songs table column sort
    var albumSort: AlbumSort = .name       // Albums grid sort (name or recently added)
    var albumScrollID: String? = nil       // top-most album in the grid, preserved across album detail

    enum Sheet: Identifiable, Equatable {
        case metadata(Int64), settings, importReview, addWish, addURL
        case newPlaylist([Int64]), renamePlaylist(Int64), findArt(String)
        var id: String {
            switch self {
            case .metadata(let i): return "meta-\(i)"
            case .settings: return "settings"
            case .importReview: return "import"
            case .addWish: return "addWish"
            case .addURL: return "addURL"
            case .newPlaylist: return "newPlaylist"
            case .renamePlaylist(let i): return "rename-\(i)"
            case .findArt(let a): return "findArt-\(a)"
            }
        }
    }

    // Pending delete confirmation (song ids).
    var deleteConfirm: Set<Int64>? = nil

    // Data
    var songs: [SongRow] = []
    var playlists: [PlaylistRow] = []
    var device = DeviceState()
    var deviceKind: DeviceKind = .none
    var settings = AppSettings() { didSet { persistSettings(); rebuildEngines() } }
    var activity: [ActivityTask] = []
    var syncPreview: SyncPreview? = nil
    var syncing = false
    var syncStatus: SyncStatus? = nil     // live progress of the running sync
    var importing = false
    var importRows: [ImportRow] = []
    var lastMessage: String? = nil

    // Wishlist / acquisition (Phase 2)
    var wishItems: [WishItem] = []
    var matchWishID: Int64? = nil
    var matchStep: MatchStep = .loading
    var matchCandidates: [RankedCandidate] = []
    var selectedCandidateID: String? = nil
    var matchVerify: VerifyResult? = nil
    var matchError: String? = nil          // set on a real failure (download/import), vs. empty search
    var candidateQuality: [String: String] = [:]   // videoID → "~128k AAC" (lazily fetched)
    var downloadErrors: [Int64: String] = [:]       // wishID → last download error (shown in Pending)
    enum MatchStep: Equatable { case loading, results, downloading, done, error }

    // Apple Music (Phase 3)
    var appleMusic: [AppleMusicCollection] = []
    var appleMusicLoading = false
    var appleMusicError: String? = nil
    var appleMusicSort: AMSort = .def
    var amDetail: AppleMusicCollection? = nil
    // Apple Music library albums (loaded lazily when the user switches to the Albums tab).
    var appleMusicBrowse: AMBrowse = .playlists
    var appleMusicAlbums: [AppleMusicCollection] = []
    var appleMusicAlbumsLoading = false
    var appleMusicAlbumsLoaded = false

    // Artwork replacement (iTunes Search → re-embed).
    /// What the Find-Artwork sheet is editing — a whole album or a single song. `searchAlbum` is the
    /// initial iTunes query term (album name, or the song title when there's no album).
    struct ArtTarget: Equatable {
        var id: String            // sheet identity ("album:…" / "song:…")
        var title: String         // display name (album or song title)
        var artist: String
        var searchAlbum: String   // prefilled search term (album, else title)
        var songIDs: [Int64]      // masters to re-embed
    }
    var artFinderTarget: ArtTarget? = nil
    var artFinderResults: [ArtworkFinder.Candidate] = []
    var artFinderLoading = false
    var artFinderError: String? = nil
    var artFinderApplying = false
    var artVersion = 0                           // bump to force thumbnails to re-read the cache
    var artBackfilling = false                   // bulk "fix missing artwork" running
    var trackBackfilling = false                 // "fix track numbers" running

    // Spotify (public-playlist import)
    /// The user whose profile is currently loaded, so the Save button knows who it is saving.
    var spotifyUserID: String?
    var spotifySignedIn = false
    var spotifySigningIn = false
    var spotifyInput = ""
    var spotifyPlaylists: [SpotifyPlaylist] = []   // the loaded user's playlists, or a single pasted one
    var spotifyDetail: SpotifyPlaylist? = nil
    var spotifyLoading = false
    var spotifyError: String? = nil
    var spotifySourceLabel = ""                    // "user: jude" / "playlist" — for the header

    // YouTube playlist import
    var youtubeInput = ""
    var youtubeTitle = ""
    var youtubeEntries: [Candidate] = []
    var youtubeLoading = false
    var youtubeError: String? = nil

    var sortedAppleMusic: [AppleMusicCollection] { sortAppleMusic(appleMusic) }
    /// The albums browser, under the same sort control as the playlists one.
    var sortedAppleMusicAlbums: [AppleMusicCollection] { sortAppleMusic(appleMusicAlbums) }

    private func sortAppleMusic(_ items: [AppleMusicCollection]) -> [AppleMusicCollection] {
        switch appleMusicSort {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            // Newest first. Music doesn't date every track, so anything undated sorts to the end
            // rather than pretending to be ancient (or, worse, brand new).
            return items.sorted { a, b in
                switch (a.addedAt, b.addedAt) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
        case .def:
            return items   // Music's own order (roughly by recency / manual)
        }
    }

    struct ImportRow: Identifiable, Sendable {
        let id = UUID()
        var candidate: ImportCandidate
        var useSuggested: Bool
        var include: Bool = true
        var chosen: TrackIdentity {
            (useSuggested ? candidate.suggested : nil) ?? candidate.original
        }
    }

    // Shared preview player (so any view can play a song into the bottom bar).
    let player = PreviewPlayerModel()
    // Streaming previews for YouTube search candidates on the match screen.
    let candidatePreview = CandidatePreviewModel()

    // Engines
    private var store: LibraryStore?
    private var probe = AudioProbe()
    private var transcoder = Transcoder()
    private var resolver = MetadataResolver()
    private var importer: Importer?
    /// Which device's `device_track` rows the library is showing as "on device".
    ///
    /// Persisted, and deliberately *kept* when nothing is plugged in: the rows describing what's on
    /// the Walkman live in the database, so the dots and album badges should still be visible while
    /// it's unplugged (that's when you decide what to add next). Before this it reset to "none"
    /// whenever the device was absent — including at launch — which looked like the app forgetting.
    private var materializing = false   // re-entrancy guard for materializeCompletedGroups()
    // (Render mode starts from nothing and never writes back, so screenshots can't pick up — or
    // clobber — the real device's records.)
    private var currentUUID: String = renderMode ? "none" : (UserDefaults.standard.string(forKey: "lastDeviceUUID") ?? "none") {
        didSet { if !renderMode { UserDefaults.standard.set(currentUUID, forKey: "lastDeviceUUID") } }
    }
    /// Kind, name and capacity of each device as last seen connected, keyed by device id — what
    /// the Device screen shows (and plans against) while it is unplugged.
    private var rememberedDevices: [String: RememberedDevice] = renderMode ? [:] : AppStore.loadRememberedDevices()

    private var libraryRoot: URL {
        URL(fileURLWithPath: (settings.libraryPath as NSString).expandingTildeInPath)
    }
    private var transcodeSettings: TranscodeSettings {
        TranscodeSettings(format: settings.deviceFormat, bitrateKbps: settings.bitrateKbps,
                          loudnessNormalize: settings.loudnessNormalize)
    }

    init() {
        loadSettings()
        do { try bootstrap() } catch { print("bootstrap error: \(error)") }
        let ytPath = settings.ytDlpPath
        candidatePreview.resolver = { url in
            await Task.detached { try? await YtDlpSource(ytDlpPath: ytPath).streamURL(url) }.value
        }
        candidatePreview.onStart = { [weak self] in
            if self?.player.isPlaying == true { self?.player.toggle() }
        }
    }

    // MARK: setup

    private func supportDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenSong", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func bootstrap() throws {
        let dbURL: URL
        if renderMode {
            // Fresh, seeded, throwaway DB so screenshots are populated.
            dbURL = try supportDir().appendingPathComponent("render-\(UUID().uuidString).sqlite")
        } else {
            dbURL = try supportDir().appendingPathComponent("library.sqlite")
        }
        let store = try LibraryStore(dbURL: dbURL)
        self.store = store
        if renderMode, try store.allAssetsWithIdentity().isEmpty { try seedSampleData(store) }
        rebuildEngines()
        adoptKnownDeviceIfNeeded()   // so the first reload already knows what's on the device
        reload()
        refreshDevice()
    }

    private func rebuildEngines() {
        probe = AudioProbe(ffprobePath: ffprobePath)
        transcoder = Transcoder(ffmpegPath: settings.ffmpegPath, probe: probe)
        resolver = MetadataResolver()
        if let store {
            try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            importer = Importer(store: store, probe: probe, tagger: transcoder,
                                resolver: resolver, libraryRoot: libraryRoot)
        }
    }

    /// ffprobe usually sits next to ffmpeg.
    private var ffprobePath: String {
        settings.ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
    }

    // MARK: settings persistence

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        }
        dark = UserDefaults.standard.bool(forKey: "dark")
    }
    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    // MARK: loading

    func reload() {
        guard let store else { return }
        do {
            let pairs = try store.allAssetsWithIdentity()
            let managed = (try? store.deviceTracks(currentUUID)) ?? []
            let onDeviceIDs = Set(managed.map { $0.assetID })
            var rows: [SongRow] = pairs.compactMap { (asset, ident) in
                guard let id = asset.id else { return nil }
                return SongRow(id: id, identityID: asset.identityID, title: ident.title,
                               artist: ident.artist, album: effectiveAlbum(ident),
                               durationSec: ident.durationSec, format: asset.format,
                               kbps: asset.bitrateKbps, onDevice: onDeviceIDs.contains(id),
                               track: ident.trackNumber, genre: ident.genre, year: ident.year,
                               path: asset.masterPath, sizeBytes: asset.sizeBytes, addedAt: asset.addedAt)
            }.sorted { ($0.artist, $0.album, $0.track ?? 0) < ($1.artist, $1.album, $1.track ?? 0) }
            Self.applyAlbumArtists(&rows)
            // One assignment (one change notification), then rebuild the lookups derived from it.
            songs = rows
            rebuildSongIndexes()

            let playlistSongs = try store.allPlaylistAssetIDs()
            playlists = try store.allPlaylists().map { pl in
                PlaylistRow(id: pl.id!, name: pl.name, syncToDevice: pl.syncToDevice,
                                   songIDs: playlistSongs[pl.id!] ?? [],
                                   source: pl.source, artworkURL: pl.artworkURL)
            }
            wishItems = try store.allWishes()
        } catch { print("reload error: \(error)") }
        backfillPlaylistSources()      // one-time: recover sources for playlists made before v9
        retireAlbumPlaylists()         // albums are not playlists (one-time cleanup, then a no-op)
        materializeCompletedGroups()   // adopt finished acquisitions that never became playlists
    }

    /// Resolve each song's grouping artist. Within one album title, credits that are another
    /// credit plus a collaborator ("Gorillaz & MF DOOM" alongside "Gorillaz") collapse onto the
    /// primary one, so guest features don't shatter the album into single-track fragments.
    private static func applyAlbumArtists(_ songs: inout [SongRow]) {
        var creditsByAlbum: [String: [String]] = [:]
        for s in songs where !s.album.trimmingCharacters(in: .whitespaces).isEmpty {
            creditsByAlbum[AppleMusicCompare.normalize(s.album), default: []].append(Self.baseArtist(s.artist))
        }
        let canonical = creditsByAlbum.mapValues { AlbumArtistMerge.canonicalArtists($0) }
        for i in songs.indices {
            let base = Self.baseArtist(songs[i].artist)
            let key = AppleMusicCompare.normalize(songs[i].album)
            songs[i].albumArtist = canonical[key]?[base] ?? base
        }
    }

    // MARK: derived collections

    // Lookups and memos derived from `songs`. `songs` is only ever assigned in `reload()`, which
    // calls `rebuildSongIndexes()`; the memos are keyed on `songsVersion` plus their other inputs,
    // so views can read `filteredSongs` / `albums` as often as they like without recomputing.
    @ObservationIgnored private var songIndex: [Int64: Int] = [:]
    @ObservationIgnored private var songsVersion = 0
    @ObservationIgnored private let ownershipIndex = OwnershipIndex()
    @ObservationIgnored private var filteredMemo: (key: FilteredKey, rows: [SongRow])?
    @ObservationIgnored private var albumsMemo: (key: AlbumsKey, rows: [AlbumRow])?
    private struct FilteredKey: Equatable { var version: Int; var albumID: String?; var query: String; var sort: SongSort }
    private struct AlbumsKey: Equatable { var version: Int; var query: String; var sort: AlbumSort }

    private func rebuildSongIndexes() {
        songsVersion += 1
        songIndex = Dictionary(songs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        ownershipIndex.rebuild(songs.map {
            ($0.id, AppleMusicCompare.LibraryTrack(title: $0.title, artist: $0.artist,
                                                   album: $0.album, durationSec: $0.durationSec))
        })
    }

    private func norm(_ s: String) -> String { ownershipIndex.normalize(s) }

    /// The library song matching a track from another service, by the same rule as
    /// `AppleMusicCompare.matches`: title + artist equal (normalised), corroborated by album or by
    /// duration (±4s). A dictionary lookup instead of a scan of the whole library.
    private func ownedSongID(name: String, artist: String, album: String, durationSec: Double) -> Int64? {
        ownershipIndex.match(name: name, artist: artist, album: album, durationSec: durationSec)
    }

    var filteredSongs: [SongRow] {
        let all = songs   // always read: keeps the observing view subscribed even on a memo hit
        let key = FilteredKey(version: songsVersion, albumID: filterAlbumID, query: searchQuery, sort: songSort)
        if let m = filteredMemo, m.key == key { return m.rows }
        let rows = computeFilteredSongs(all)
        filteredMemo = (key, rows)
        return rows
    }

    private func computeFilteredSongs(_ all: [SongRow]) -> [SongRow] {
        var rows = all
        if let albumID = filterAlbumID {
            rows = rows.filter { "\($0.groupArtist)␟\($0.album)" == albumID }
        }
        let q = searchQuery
        if !q.isEmpty {
            rows = rows.filter {
                $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
                    || $0.album.lowercased().contains(q)
            }
        }
        if let col = songSort.column {
            let asc = songSort.ascending
            func cmp(_ a: Bool) -> Bool { asc ? a : !a }
            rows.sort { l, r in
                switch col {
                // Descending-looking default: first click puts the on-device tracks on top.
                case .device: return l.onDevice == r.onDevice
                    ? l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending
                    : cmp(l.onDevice && !r.onDevice)
                case .title:  return cmp(l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending)
                case .artist: return cmp(l.artist.localizedCaseInsensitiveCompare(r.artist) == .orderedAscending)
                case .album:  return cmp(l.album.localizedCaseInsensitiveCompare(r.album) == .orderedAscending)
                case .time:   return cmp(l.durationSec < r.durationSec)
                case .kind:   return cmp(l.kindLabel.localizedCaseInsensitiveCompare(r.kindLabel) == .orderedAscending)
                case .dateAdded: return cmp(l.addedAt < r.addedAt)
                }
            }
        }
        return rows
    }

    /// The album/primary artist (feat.-suffix stripped) so guest-crediting tracks stay grouped.
    static func baseArtist(_ s: String) -> String { TitleCleaner.baseArtist(s) }

    /// Current search term (lowercased, trimmed); empty when not searching.
    ///
    /// Also empty once a specific album or artist is open. Searching is how you *find* the album;
    /// carrying the term inside it then hides most of the tracks you came to see — and the search
    /// box isn't even on screen there, so the missing songs have no visible explanation. Going back
    /// restores the term, which is still in the box.
    private var searchQuery: String {
        guard filterAlbumID == nil, filterArtist == nil else { return "" }
        return search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var albums: [AlbumRow] {
        let all = songs
        let key = AlbumsKey(version: songsVersion, query: searchQuery, sort: albumSort)
        if let m = albumsMemo, m.key == key { return m.rows }
        let rows = computeAlbums(all)
        albumsMemo = (key, rows)
        return rows
    }

    private func computeAlbums(_ songs: [SongRow]) -> [AlbumRow] {
        var map: [String: AlbumRow] = [:]
        for s in songs {
            let base = s.groupArtist
            let id = "\(base)␟\(s.album)"
            if var a = map[id] { a.songIDs.append(s.id); map[id] = a }
            else { map[id] = AlbumRow(id: id, name: s.album, artist: base, year: s.year, songIDs: [s.id]) }
        }
        var rows = Array(map.values)
        let q = searchQuery
        if !q.isEmpty {
            // Match album name, artist, or any track title within the album.
            rows = rows.filter { a in
                a.name.lowercased().contains(q) || a.artist.lowercased().contains(q)
                    || a.songIDs.contains { song($0)?.title.lowercased().contains(q) == true }
            }
        }
        switch albumSort {
        case .name:
            return rows.sorted { ($0.artist, $0.name) < ($1.artist, $1.name) }
        case .recent:
            // Most-recently-added album first (by the newest track it contains). Keys are worked
            // out once per album, not once per comparison.
            let added = Dictionary(rows.map { ($0.id, albumAddedAt($0)) }, uniquingKeysWith: { a, _ in a })
            return rows.sorted { (added[$0.id] ?? 0) > (added[$1.id] ?? 0) }
        case .device:
            // Fully on the device first, then partially synced, then not on the device at all.
            let rank = Dictionary(rows.map { ($0.id, deviceRank($0)) }, uniquingKeysWith: { a, _ in a })
            return rows.sorted {
                let (l, r) = (rank[$0.id] ?? 0, rank[$1.id] ?? 0)
                return l == r ? ($0.artist, $0.name) < ($1.artist, $1.name) : l > r
            }
        }
    }

    /// How much of a sidebar collection is on the device. Counts the tracks themselves rather than
    /// the playlist's sync flag, so an album sent across with "Send album to device" — which pins
    /// its tracks individually and never touches that flag — is shown as on-device too.
    func playlistDeviceState(_ pl: PlaylistRow) -> (onDevice: Int, total: Int) {
        let on = pl.songIDs.filter { song($0)?.onDevice == true }.count
        return (on, pl.songIDs.count)
    }

    /// 2 = every track on the device, 1 = some, 0 = none.
    private func deviceRank(_ a: AlbumRow) -> Int {
        let dev = albumDeviceState(a)
        if dev.total > 0 && dev.onDevice == dev.total { return 2 }
        return dev.onDevice > 0 ? 1 : 0
    }

    /// When an album was added: the newest `addedAt` among its tracks.
    private func albumAddedAt(_ a: AlbumRow) -> Double {
        a.songIDs.compactMap { song($0)?.addedAt }.max() ?? 0
    }

    var artists: [ArtistRow] {
        var albumSet: [String: Set<String>] = [:]
        var songCount: [String: Int] = [:]
        for s in songs {
            let base = s.groupArtist
            albumSet[base, default: []].insert(s.album)
            songCount[base, default: 0] += 1
        }
        var rows = albumSet.keys.sorted().map {
            ArtistRow(id: $0, name: $0, albumCount: albumSet[$0]!.count, songCount: songCount[$0]!)
        }
        let q = searchQuery
        if !q.isEmpty {
            // Match artist name, or an album/track by that artist.
            rows = rows.filter { ar in
                ar.name.lowercased().contains(q)
                    || songs.contains { $0.groupArtist == ar.name
                        && ($0.album.lowercased().contains(q) || $0.title.lowercased().contains(q)) }
            }
        }
        return rows
    }

    func song(_ id: Int64) -> SongRow? {
        let all = songs
        guard let i = songIndex[id], i < all.count, all[i].id == id else { return nil }
        return all[i]
    }

    var libraryTotalsLabel: String {
        let total = songs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(songs.count) songs · \(byteLabel(total))"
    }

    // MARK: import (user-chosen folders)

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Library"
        panel.message = "Choose where OpenSong stores your master library."
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryPath = url.path
            reload()
        }
    }

    /// Prompt for one or more messy folders, scan + resolve suggestions, open the review sheet.
    func beginImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = "Choose one or more folders (or files) of loose music to import."
        guard panel.runModal() == .OK, let importer else { return }
        let urls = panel.urls
        importing = true
        activity = [ActivityTask(label: "Scanning \(urls.count) item(s)…", progress: 0)]
        Task {
            let rows = await Self.scanWork(importer, urls)
            self.importRows = rows
            self.importing = false
            self.activity = []
            if rows.isEmpty {
                self.lastMessage = "No audio files found in the chosen item(s)."
            } else {
                self.openSheet = .importReview
            }
        }
    }

    /// Scan chosen files/folders and resolve iTunes suggestions — entirely off the main
    /// thread. Individually-chosen files are scanned directly (their parent folders are NOT
    /// walked); only chosen directories are scanned recursively.
    private nonisolated static func scanWork(_ importer: Importer, _ urls: [URL]) async -> [ImportRow] {
        await Task.detached {
            var files: [URL] = []
            var candidates: [ImportCandidate] = []
            for url in urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue { candidates += (try? importer.scanLoose(url)) ?? [] }
                else { files.append(url) }
            }
            candidates += (try? importer.scan(files: files)) ?? []
            await importer.resolveSuggestions(&candidates)
            return candidates.map { ImportRow(candidate: $0, useSuggested: $0.suggested != nil) }
        }.value
    }

    func commitImport() {
        guard let importer else { return }
        let chosen = importRows.filter { $0.include }.map { row -> ImportCandidate in
            var c = row.candidate; c.chosen = row.chosen; return c
        }
        openSheet = nil
        importing = true
        activity = [ActivityTask(label: "Importing \(chosen.count) track(s)…", progress: 0)]
        let imp = importer
        Task {
            let count = await Self.commitWork(imp, chosen)
            self.importing = false
            self.activity = []
            self.importRows = []
            self.lastMessage = "Imported \(count) track(s)."
            self.reload()
        }
    }

    private nonisolated static func commitWork(_ imp: Importer, _ chosen: [ImportCandidate]) async -> Int {
        await Task.detached { (try? imp.commit(chosen))?.count ?? 0 }.value
    }

    // MARK: device + sync

    func refreshDevice() {
        if let vol = DeviceDetector.connectedWalkman() {
            deviceKind = .walkman
            currentUUID = walkmanUUID(vol)
            let cap = (try? vol.capacity()) ?? (totalBytes: device.totalBytes, freeBytes: device.freeBytes)
            let present = (try? DeviceManager(volume: vol).listManagedTracks()) ?? []
            // The volume UUID may have changed since the last sync (FAT32 doesn't keep one) —
            // re-attach the managed-track rows for files that are still on the device.
            if let store, let adopted = try? store.adoptDeviceTracks(uuid: currentUUID, presentPaths: Set(present)),
               adopted > 0 {
                lastMessage = "Recognised \(adopted) track(s) already on the device."
            }
            device = DeviceState(connected: true, name: "Walkman NW-E394",
                                 totalBytes: cap.totalBytes, freeBytes: cap.freeBytes,
                                 songCount: present.count, known: true)
            rememberDevice(kind: .walkman)
        } else if let sh = DeviceDetector.connectedShuffle() {
            deviceKind = .shuffle
            currentUUID = shuffleUUID(sh)
            let cap = shuffleEngine(sh).capacity()
            let count = (try? FileManager.default.contentsOfDirectory(atPath: sh.layout.musicDir.path).count) ?? 0
            device = DeviceState(connected: true, name: "iPod shuffle",
                                 totalBytes: cap.totalBytes, freeBytes: cap.freeBytes, songCount: count,
                                 known: true)
            rememberDevice(kind: .shuffle)
        } else {
            deviceKind = .none
            // Unplugged, but not forgotten: the managed-track rows still say what's on it, and the
            // remembered record says what it is and how full it was.
            adoptKnownDeviceIfNeeded()
            device = offlineDeviceState((try? store?.deviceTracks(currentUUID)) ?? [])
        }
        reload()                                    // picks up the on-device flags
        // …which the diff preview then reports on — live when mounted, else the offline plan.
        // (Runs after every sync too: `finishSync` calls back in here, which also re-remembers
        // the device's post-sync capacity above.)
        if device.connected || device.known { buildSyncPreview() } else { syncPreview = nil }
    }

    /// Point at whichever device the database has records for, when the current id has none — the
    /// device is unplugged, or this install has never had it connected, so there's nothing
    /// remembered. Without this the library shows every song as "not on device".
    private func adoptKnownDeviceIfNeeded() {
        guard let store, ((try? store.deviceTracks(currentUUID))?.isEmpty ?? true) else { return }
        if let known = (try? store.primaryDeviceUUID()) ?? nil { currentUUID = known }
    }

    // MARK: remembered device (offline Device screen)

    private static let rememberedDevicesKey = "rememberedDevices"

    private static func loadRememberedDevices() -> [String: RememberedDevice] {
        guard let data = UserDefaults.standard.data(forKey: rememberedDevicesKey),
              let map = try? JSONDecoder().decode([String: RememberedDevice].self, from: data) else { return [:] }
        return map
    }

    /// Record the connected device's kind, name and live capacity under its id, stamped now.
    private func rememberDevice(kind: DeviceKind) {
        rememberedDevices[currentUUID] = RememberedDevice(
            kind: kind == .shuffle ? "shuffle" : "walkman", name: device.name,
            totalBytes: device.totalBytes, freeBytes: device.freeBytes, lastSeen: Date())
        guard !renderMode, let data = try? JSONEncoder().encode(rememberedDevices) else { return }
        UserDefaults.standard.set(data, forKey: Self.rememberedDevicesKey)
    }

    /// The device as last seen, for when it's unplugged. A device with rows but no record (synced
    /// before records were kept) is still shown, with its capacity estimated from the rows.
    private func offlineDeviceState(_ rows: [DeviceTrackRow]) -> DeviceState {
        if let r = rememberedDevices[currentUUID] {
            return DeviceState(connected: false, name: r.name, totalBytes: r.totalBytes,
                               freeBytes: r.freeBytes, songCount: rows.count, known: true, lastSeen: r.lastSeen)
        }
        guard !rows.isEmpty else { return DeviceState(connected: false) }
        let shuffle = Self.inferKind(rows) == .shuffle
        let total: Int64 = shuffle ? 1_960_000_000 : DeviceState().totalBytes
        let used = rows.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return DeviceState(connected: false, name: shuffle ? "iPod shuffle" : "Walkman NW-E394",
                           totalBytes: total, freeBytes: max(0, total - used),
                           songCount: rows.count, known: true)
    }

    /// The Shuffle keeps its files under `iPod_Control/`; the Walkman under artist folders.
    private static func inferKind(_ rows: [DeviceTrackRow]) -> DeviceKind {
        rows.first?.relativePath.hasPrefix("iPod_Control") == true ? .shuffle : .walkman
    }

    /// The kind of device to plan for: the connected one, else the remembered one.
    private func planningKind(_ rows: [DeviceTrackRow]) -> DeviceKind {
        if deviceKind != .none { return deviceKind }
        return rememberedDevices[currentUUID]?.deviceKind ?? Self.inferKind(rows)
    }

    func simulateDevice() {
        deviceKind = .walkman
        device = DeviceState(connected: true, name: "Walkman NW-E394 (simulated)",
                             totalBytes: 7_363_067_904, freeBytes: 5_338_390_528, songCount: 0, known: true)
        buildSyncPreview()
    }

    /// Stable per-device ids. Both players are FAT32, whose volume UUID macOS synthesizes and can
    /// change between mounts, so the id is kept in a marker file on the device (seeded from the
    /// volume UUID, so nothing changes for a device that keeps its own).
    private func walkmanUUID(_ vol: DiskVolume) -> String {
        DeviceIdentity.stableID(mountPoint: vol.mountPoint, fallback: vol.uuid)
    }
    private func shuffleUUID(_ sh: ShuffleDevice) -> String {
        DeviceIdentity.stableID(mountPoint: sh.layout.mountPoint,
                                fallback: sh.uuid.isEmpty ? "shuffle:\(sh.name)" : sh.uuid)
    }

    /// The shuffle has no screen — embedding cover art would only eat its (small) storage. Shared
    /// by the live engine and the offline plan, so both compare against the same recipe.
    private var shuffleTranscodeSettings: TranscodeSettings {
        var s = transcodeSettings; s.embedArtwork = false; return s
    }

    private func shuffleEngine(_ sh: ShuffleDevice) -> ShuffleSyncEngine {
        ShuffleSyncEngine(store: store!, transcoder: transcoder, layout: sh.layout,
                          settings: shuffleTranscodeSettings, deviceUUID: shuffleUUID(sh),
                          voiceover: settings.shuffleVoiceOver ? SayVoiceOver() : nil)
    }

    /// The Device screen's model. Mounted: the engine's live plan (walks the device, real capacity).
    /// Unplugged but known: the offline plan — the recorded rows stand in for the device and the
    /// remembered capacity for the volume — so edits made offline show up as the pending diff that
    /// one Sync applies on reconnect. Never seen: nil.
    func buildSyncPreview() {
        guard let store else { return }
        let rows = (try? store.deviceTracks(currentUUID)) ?? []
        let plan: SyncPlan? = {
            if device.connected, deviceKind == .walkman, let vol = DeviceDetector.connectedWalkman() {
                return try? SyncEngine(store: store, transcoder: transcoder, device: DeviceManager(volume: vol),
                                       settings: transcodeSettings, deviceUUID: walkmanUUID(vol)).plan()
            } else if device.connected, deviceKind == .shuffle, let sh = DeviceDetector.connectedShuffle() {
                return try? shuffleEngine(sh).plan()
            } else if device.connected || device.known {
                // Unplugged (or simulated): trust the rows and the remembered capacity.
                if planningKind(rows) == .shuffle {
                    return try? ShuffleSyncEngine.offlinePlan(
                        store: store, settings: shuffleTranscodeSettings, deviceUUID: currentUUID,
                        totalBytes: device.totalBytes, freeBytes: device.freeBytes)
                }
                return try? SyncEngine.offlinePlan(
                    store: store, transcoder: transcoder, settings: transcodeSettings, deviceUUID: currentUUID,
                    totalBytes: device.totalBytes, freeBytes: device.freeBytes)
            }
            return nil
        }()
        guard let plan else { syncPreview = nil; return }
        syncPreview = makePreview(plan, rows: rows, pinned: (try? store.pinnedAssetIDs()) ?? [])
    }

    /// Turn a plan into Device-screen rows, working out in one pass why each song is wanted on the
    /// device (pinned, and/or via which syncing playlists) from data already in memory.
    private func makePreview(_ plan: SyncPlan, rows: [DeviceTrackRow], pinned: Set<Int64>) -> SyncPreview {
        var via: [Int64: [DevicePlaylistRef]] = [:]
        for pl in playlists where pl.syncToDevice {
            let ref = DevicePlaylistRef(id: pl.id, name: pl.name)
            for sid in pl.songIDs where via[sid]?.last?.id != pl.id { via[sid, default: []].append(ref) }
        }
        let recordedIDs = Set(rows.map { $0.assetID })
        let desiredIDs = Set((plan.toAdd + plan.upToDate).compactMap { $0.id })
        let removing = Set(plan.toRemove)

        func make(_ id: String, assetID: Int64, path: String?, size: Int64) -> DeviceSongRow {
            let s = song(assetID)
            return DeviceSongRow(id: id, assetID: assetID, song: s,
                                 title: s?.title ?? Self.titleFromDevicePath(path ?? ""),
                                 artist: s?.artist ?? "", pinned: pinned.contains(assetID),
                                 viaPlaylists: via[assetID] ?? [], sizeBytes: size)
        }
        func sortKey(_ r: DeviceSongRow) -> (String, String, Int, String) {
            (r.song?.groupArtist ?? r.artist, r.song?.album ?? "", r.song?.track ?? 0, r.title)
        }
        func ordered(_ list: [DeviceSongRow]) -> [DeviceSongRow] { list.sorted { sortKey($0) < sortKey($1) } }

        let onDevice = rows.map { r -> DeviceSongRow in
            var row = make(r.relativePath, assetID: r.assetID, path: r.relativePath, size: r.sizeBytes)
            row.pendingRemoval = removing.contains(r.relativePath)
            return row
        }
        let rate = Double(settings.bitrateKbps) * 1000 / 8
        var adds: [DeviceSongRow] = [], updates: [DeviceSongRow] = []
        for a in plan.toAdd {
            guard let id = a.id else { continue }
            let est = Int64(rate * (song(id)?.durationSec ?? 0))
            let row = make("asset:\(id)", assetID: id, path: nil, size: est)
            if recordedIDs.contains(id) { updates.append(row) } else { adds.append(row) }
        }
        let removals = plan.removals.map { r -> DeviceSongRow in
            var row = make(r.relativePath, assetID: r.assetID, path: r.relativePath, size: r.sizeBytes)
            row.pendingRemoval = true
            row.replaced = desiredIDs.contains(r.assetID)
            return row
        }
        return SyncPreview(onDevice: ordered(onDevice), willAdd: ordered(adds), willUpdate: ordered(updates),
                           willRemove: ordered(removals), upToDateCount: plan.upToDate.count,
                           projectedUsedBytes: plan.projectedUsedBytes)
    }

    /// "Artist\Album\Title.mp3" → "Title", for a recorded track whose library entry is gone.
    private static func titleFromDevicePath(_ path: String) -> String {
        let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        return (last as NSString).deletingPathExtension
    }

    // MARK: editing the device (works unplugged; applied by the next sync)

    /// Take songs off the device by unpinning them. Songs that a syncing playlist also holds stay
    /// — the Device screen offers "Stop syncing" / "Remove from playlist" for those instead, since
    /// a playlist is never edited silently.
    func removeFromDevice(_ songIDs: [Int64]) {
        guard !songIDs.isEmpty else { return }
        pin(songIDs, false)
        reportStillOnDevice(songIDs)
    }

    /// Undo a pending removal: pin the songs, so they're wanted on the device again.
    func keepOnDevice(_ songIDs: [Int64]) {
        guard !songIDs.isEmpty else { return }
        pin(songIDs, true)
    }

    /// Stop syncing these playlists (and unpin `unpin`), with one preview rebuild for the lot.
    func stopSyncingPlaylists(_ playlistIDs: [Int64], unpin: [Int64] = []) {
        guard let store else { return }
        for pid in playlistIDs {
            try? store.setPlaylistSync(pid, false)
            if let i = playlists.firstIndex(where: { $0.id == pid }) { playlists[i].syncToDevice = false }
        }
        for id in unpin { try? store.pin(assetID: id, false) }
        buildSyncPreview()
        reportStillOnDevice(unpin)
    }

    /// Remove songs from one playlist (and unpin `unpin`) — the explicit "Remove from <playlist>"
    /// choice on the Device screen. One reload and one preview rebuild for the whole selection.
    func removeFromPlaylist(_ playlistID: Int64, songIDs: [Int64], unpin: [Int64] = []) {
        guard let store else { return }
        for sid in songIDs { try? store.removePlaylistItem(playlistID: playlistID, assetID: sid) }
        for id in unpin { try? store.pin(assetID: id, false) }
        reload()
        buildSyncPreview()
        reportStillOnDevice(songIDs + unpin)
    }

    /// After a removal, say so if some of the songs are still wanted (another syncing playlist).
    private func reportStillOnDevice(_ songIDs: [Int64]) {
        guard let p = syncPreview else { return }
        let asked = Set(songIDs)
        let still = Set((p.onDevice.filter { !$0.pendingRemoval } + p.willAdd + p.willUpdate)
            .filter { asked.contains($0.assetID) && $0.wanted }.map { $0.assetID })
        if !still.isEmpty {
            lastMessage = "\(still.count) song(s) stay on the device — a syncing playlist still includes them."
        }
    }

    /// An unplugged Walkman with a few songs on it and some edits queued, for the render harness.
    func seedOfflineDeviceForRender() {
        guard renderMode, let store, currentUUID != "RENDER-WALKMAN" else { return }
        currentUUID = "RENDER-WALKMAN"
        let recipe = transcodeSettings.deviceRecipe
        let onDevice = ["Vordhosbn", "Feel Good Inc.", "Ivy", "Self Control", "Dare", "Helmet"]
        for s in songs where onDevice.contains(s.title) {
            guard let asset = try? store.asset(s.id), let ident = try? store.identity(s.identityID) else { continue }
            try? store.setDeviceTrack(DeviceTrackRow(
                deviceUUID: currentUUID, relativePath: DeviceRelativePath.backslashPath(for: ident),
                assetID: s.id, transcodedBitrate: settings.bitrateKbps, contentHash: asset.contentHash,
                sizeBytes: Int64(Double(settings.bitrateKbps) * 1000 / 8 * s.durationSec), recipe: recipe))
        }
        rememberedDevices[currentUUID] = RememberedDevice(
            kind: "walkman", name: "Walkman NW-E394", totalBytes: 7_363_067_904, freeBytes: 5_100_000_000,
            lastSeen: Date().addingTimeInterval(-2 * 86_400))
        deviceKind = .none
        device = offlineDeviceState((try? store.deviceTracks(currentUUID)) ?? [])
        reload()
        buildSyncPreview()
    }

    func runSync() {
        guard !syncing, let store else { return }
        if deviceKind == .walkman, let vol = DeviceDetector.connectedWalkman() {
            let engine = SyncEngine(store: store, transcoder: transcoder, device: DeviceManager(volume: vol),
                                    settings: transcodeSettings, deviceUUID: walkmanUUID(vol))
            startSync(label: "Syncing to Walkman…") { await Self.syncWork(engine, $0) }
        } else if deviceKind == .shuffle, let sh = DeviceDetector.connectedShuffle() {
            let engine = shuffleEngine(sh)
            startSync(label: "Syncing to iPod shuffle…") { await Self.shuffleSyncWork(engine, $0) }
        } else {
            device.connected = false
        }
    }

    /// Runs a sync, relaying the engine's step reports (which arrive on a background thread)
    /// into the activity footer and the Device screen's progress panel.
    private func startSync(label: String,
                           _ work: @escaping @Sendable (@escaping @Sendable (SyncProgress) -> Void) async -> String?) {
        syncing = true
        let taskID = UUID()
        let started = Date()
        activity = [ActivityTask(id: taskID, label: label, progress: 0, detail: "Preparing…")]
        syncStatus = SyncStatus(label: "Preparing…", fraction: 0, done: 0, total: 0, etaSec: nil)
        let relay: @Sendable (SyncProgress) -> Void = { p in
            Task { @MainActor in self.applySyncProgress(taskID, label, started, p) }
        }
        Task { let error = await work(relay); self.finishSync(error) }
    }

    /// Fold one engine report into the UI: bar fraction, step counts and a time-left estimate
    /// (extrapolated from elapsed time once the run is a few percent in, so it isn't wild).
    private func applySyncProgress(_ taskID: UUID, _ label: String, _ started: Date, _ p: SyncProgress) {
        guard syncing else { return }
        let elapsed = Date().timeIntervalSince(started)
        let eta: Double? = (p.fraction > 0.02 && p.fraction < 1) ? elapsed / p.fraction - elapsed : nil
        let status = SyncStatus(label: p.label, fraction: p.fraction, done: p.done, total: p.total, etaSec: eta)
        syncStatus = status
        if let idx = activity.firstIndex(where: { $0.id == taskID }) {
            activity[idx].progress = p.fraction
            activity[idx].label = p.total > 0 ? p.label : label
            activity[idx].detail = status.countsLabel
        }
    }

    private nonisolated static func syncWork(_ engine: SyncEngine,
                                             _ progress: @escaping @Sendable (SyncProgress) -> Void) async -> String? {
        await Task.detached {
            do { try engine.apply(try engine.plan(), progress: progress); return nil }
            catch { return "\(error)" }
        }.value
    }

    private nonisolated static func shuffleSyncWork(_ engine: ShuffleSyncEngine,
                                                    _ progress: @escaping @Sendable (SyncProgress) -> Void) async -> String? {
        await Task.detached {
            do { try engine.apply(progress: progress); return nil }
            catch { return "\(error)" }
        }.value
    }

    private func finishSync(_ error: String?) {
        syncing = false
        activity = []
        syncStatus = nil
        lastMessage = error.map { "Sync failed: \($0)" } ?? "Sync complete."
        refreshDevice()
    }

    /// Force every managed track to be re-sent on the next sync.
    ///
    /// Rarely needed: a sync already rebuilds any copy whose recipe is out of date (bitrate change,
    /// the cover-art fix, …). This is the escape hatch for a device whose files were changed behind
    /// OpenSong's back, or a transfer that was interrupted.
    func rebuildDeviceCopies() {
        guard let store, device.connected, !syncing else {
            if !device.connected { lastMessage = "Plug in the device first." }
            return
        }
        let managed = Set(((try? store.deviceTracks(currentUUID)) ?? []).map { $0.assetID })
        let n = (try? store.invalidateDeviceTracks(uuid: currentUUID, assetIDs: managed)) ?? 0
        buildSyncPreview()
        lastMessage = n == 0 ? "Nothing on the device to rebuild."
            : "\(n) track(s) will be re-sent on the next sync."
    }

    /// Import the tracks + playlists already on the connected Walkman into the library.
    func adoptFromDevice() {
        guard let importer else { return }
        if deviceKind == .shuffle {
            lastMessage = "Importing from an iPod isn't supported — OpenSong manages the iPod from your library."; return
        }
        guard let vol = DeviceDetector.connectedWalkman() else {
            lastMessage = "Plug in the Walkman first."; return
        }
        importing = true
        activity = [ActivityTask(label: "Importing from Walkman…", progress: 0)]
        let musicDir = vol.musicDir
        Task {
            let (a, p) = await Self.adoptWork(importer, musicDir)
            self.importing = false; self.activity = []
            self.lastMessage = "Imported \(a) track(s) and \(p) playlist(s) from the device."
            self.reload()
        }
    }
    private nonisolated static func adoptWork(_ importer: Importer, _ musicDir: URL) async -> (Int, Int) {
        await Task.detached {
            let r = try? importer.adopt(musicDir: musicDir)
            return (r?.assets.count ?? 0, r?.playlists.count ?? 0)
        }.value
    }

    // MARK: delete from library

    func deleteSongs(_ ids: Set<Int64>, trashFiles: Bool = true) {
        guard let store else { return }
        for id in ids {
            if trashFiles, let asset = try? store.asset(id) {
                let url = URL(fileURLWithPath: (asset.masterPath as NSString).expandingTildeInPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
            try? store.deleteAsset(id)
        }
        selection.subtract(ids)
        reload()
        lastMessage = "Deleted \(ids.count) song(s)\(trashFiles ? " (moved to Trash)" : "")."
    }

    // MARK: tool updates

    /// yt-dlp's version, shown in Settings. Nil until looked up.
    var ytDlpVersion: String?
    var updatingYtDlp = false

    func refreshYtDlpVersion() {
        let path = settings.ytDlpPath
        Task {
            let v = await Self.toolVersionWork(path)
            self.ytDlpVersion = v ?? "not found"
        }
    }

    /// Update yt-dlp in place, however it was installed.
    ///
    /// Worth having a button for: YouTube changes things often, and an out-of-date yt-dlp is the
    /// usual reason a download that used to work suddenly doesn't.
    func updateYtDlp() {
        guard !updatingYtDlp else { return }
        updatingYtDlp = true
        let path = settings.ytDlpPath
        let before = ytDlpVersion
        let task = ActivityTask(label: "Updating yt-dlp…", progress: 0)
        activity.append(task)
        Task {
            let outcome = await Self.updateYtDlpWork(path)
            self.activity.removeAll { $0.id == task.id }
            self.updatingYtDlp = false
            self.ytDlpVersion = outcome.version ?? before
            self.lastMessage = outcome.message
            if outcome.failed {
                self.announce("yt-dlp update failed", outcome.message, isError: true)
            }
        }
    }

    private nonisolated static func toolVersionWork(_ path: String) async -> String? {
        await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: path),
                  let r = try? Shell.run(path, ["--version"]) else { return nil }
            let v = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }.value
    }

    private struct UpdateOutcome: Sendable {
        var version: String?
        var message: String
        var failed = false
    }

    private nonisolated static func updateYtDlpWork(_ path: String) async -> UpdateOutcome {
        await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return UpdateOutcome(version: nil,
                                     message: "No yt-dlp at \(path) — set the path in Settings first.",
                                     failed: true)
            }
            let before = (try? Shell.run(path, ["--version"]))?.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let plan = ToolUpdate.ytDlpPlan(path: path, shebang: ToolUpdate.shebang(ofFileAt: path))

            // pip refuses in two recoverable ways on a Mac (a managed environment, or an install
            // location it can't write to); each has an argument that fixes it, so try in turn
            // rather than handing the user a stack trace.
            var arguments = plan.arguments
            var result = try? Shell.run(plan.executable, arguments)
            var stderr = result?.stderrString ?? ""
            if result?.status != 0, plan.method == .pip,
               let retry = ToolUpdate.pipRetryArguments(forStderr: stderr) {
                arguments += retry
                result = try? Shell.run(plan.executable, arguments)
                stderr = result?.stderrString ?? ""
            }

            let after = (try? Shell.run(path, ["--version"]))?.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let result, result.status == 0 else {
                let detail = stderr.split(separator: "\n").last.map(String.init)
                    ?? "exit status \(result?.status ?? -1)"
                return UpdateOutcome(version: after,
                                     message: "Couldn't update yt-dlp via \(plan.method.label): \(detail)",
                                     failed: true)
            }
            if let before, let after, before != after {
                return UpdateOutcome(version: after, message: "yt-dlp updated \(before) → \(after).")
            }
            return UpdateOutcome(version: after,
                                 message: "yt-dlp is already up to date (\(after ?? "unknown")).")
        }.value
    }

    // MARK: replacing a bad file

    /// Mark tracks as needing a different version: the user has found a problem with the file
    /// (bad rip, wrong edit, cut short) and wants to re-acquire it.
    ///
    /// The track stays in the library and keeps playing until a replacement arrives — there is no
    /// point taking away the only copy while the user waits for a download. What appears now is a
    /// pending item to match, and a badge on the row so it is obvious why.
    func markForReplacement(_ ids: Set<Int64>) {
        guard let store else { return }
        var added = 0
        for id in ids {
            guard replacementWish(for: id) == nil, let row = song(id) else { continue }
            let identity = (try? store.asset(id)).flatMap { try? store.identity($0.identityID) }
            let wish = WishItem(title: row.title, artist: row.artist,
                                album: row.album.isEmpty ? nil : row.album,
                                trackNumber: identity?.trackNumber, discNumber: identity?.discNumber,
                                durationSec: row.durationSec > 0 ? row.durationSec : nil,
                                source: .custom, state: .wishlist, replacesAssetID: id)
            if (try? store.addWish(wish)) != nil { added += 1 }
        }
        reload()
        guard added > 0 else { lastMessage = "Already waiting for a new version."; return }
        lastMessage = added == 1
            ? "Looking for a new version — find it in Pending."
            : "\(added) tracks marked for a new version — find them in Pending."
    }

    /// The pending wish that will replace this track, if it has been marked.
    func replacementWish(for assetID: Int64) -> WishItem? {
        wishItems.first { $0.replacesAssetID == assetID && $0.state != .downloaded }
    }

    /// Drop the replacement request; the current file stays as it is.
    func cancelReplacement(_ assetID: Int64) {
        guard let store, let wish = replacementWish(for: assetID), let id = wish.id else { return }
        try? store.deleteWish(id)
        reload()
        lastMessage = "Keeping the current version."
    }

    /// Finish a replacement once its download has landed: move everything that pointed at the old
    /// file over to the new one, then discard the old file.
    ///
    /// Runs after the acquire task, reading the wish back from the store because that is where the
    /// coordinator recorded the new asset's id.
    private func completeReplacement(wishID: Int64) {
        guard let store,
              let wish = (try? store.allWishes())?.first(where: { $0.id == wishID }),
              let oldID = wish.replacesAssetID, let newID = wish.assetID
        else { return }

        var result = LibraryStore.ReplacementResult()
        if oldID == newID {
            // Same track, so the new file took over the master in place and kept the asset's id:
            // playlists, album position and the pin never moved, and there is no old row to delete.
            // The device still has to be told, because its copy is now the wrong file.
            result.deviceRows = markDeviceCopyStale(oldID)
            result.wasPinned = songs.first { $0.id == newID }?.onDevice ?? false
        } else {
            // A differently-titled version became its own asset: move everything across, then
            // discard the old file. Its path has to be read before the row goes.
            let oldPath = (try? store.asset(oldID))?.masterPath
            result = (try? store.replaceAsset(old: oldID, with: newID)) ?? .init()
            if let oldPath {
                let url = URL(fileURLWithPath: (oldPath as NSString).expandingTildeInPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
            selection.remove(oldID)
        }
        try? store.deleteWish(wishID)
        reload()
        buildSyncPreview()

        var parts = ["Replaced “\(wish.title)”"]
        if oldID != newID { parts.append("the old file is in the Trash") }
        if result.playlists > 0 {
            parts.append("\(result.playlists) playlist entr\(result.playlists == 1 ? "y" : "ies") moved")
        }
        if result.deviceRows > 0 { parts.append("the device copy is replaced on the next sync") }
        lastMessage = parts.joined(separator: "; ") + "."
    }

    /// Mark this track's device copy as needing to be re-sent, whatever else has changed.
    @discardableResult
    private func markDeviceCopyStale(_ assetID: Int64) -> Int {
        guard let store, let uuid = currentUUID ?? (try? store.primaryDeviceUUID()) ?? nil else { return 0 }
        return (try? store.invalidateDeviceTracks(uuid: uuid, assetIDs: [assetID])) ?? 0
    }

    // MARK: manual playlists

    @discardableResult
    func newPlaylist(name: String, songIDs: [Int64] = []) -> Int64? {
        guard let store, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let id = try? store.createPlaylist(name: name, syncToDevice: false) else { return nil }
        addSongsToPlaylist(id, songIDs)
        reload()
        return id
    }
    func addSongsToPlaylist(_ playlistID: Int64, _ songIDs: [Int64]) {
        guard let store else { return }
        for sid in songIDs where !((try? store.playlistContains(playlistID, assetID: sid)) ?? false) {
            let pos = (try? store.nextPlaylistPosition(playlistID)) ?? 0
            try? store.addToPlaylist(playlistID: playlistID, assetID: sid, position: pos)
        }
        reload()
        lastMessage = "Added \(songIDs.count) to playlist."
    }
    func removeFromPlaylist(_ playlistID: Int64, _ songID: Int64) {
        try? store?.removePlaylistItem(playlistID: playlistID, assetID: songID)
        reload()
    }
    func deletePlaylist(_ id: Int64) {
        let name = playlists.first { $0.id == id }?.name
        try? store?.deletePlaylist(id)
        // Also retire the acquisition group behind it, or the next reload would adopt the finished
        // wishes into a brand-new playlist and the delete would appear to do nothing. The songs
        // themselves stay in the library; only the record of "these belong together" goes.
        if let name { retireAcquisitionGroup(name) }
        if case .playlist(let pid) = activeView, pid == id { activeView = .allSongs }
        reload()
    }

    /// Forget a named acquisition group: completed wishes are dropped (their tracks are already in
    /// the library), and any still downloading are detached so they finish as individual items
    /// rather than re-forming the collection.
    private func retireAcquisitionGroup(_ name: String) {
        guard let store else { return }
        for w in wishItems where w.playlistName == name {
            if w.state == .downloaded, let wid = w.id {
                try? store.deleteWish(wid)
            } else {
                var detached = w; detached.playlistName = nil
                try? store.updateWish(detached)
            }
        }
    }
    func renamePlaylist(_ id: Int64, _ name: String) {
        try? store?.renamePlaylist(id, name: name)
        reload()
    }
    func reorderPlaylist(_ playlistID: Int64, _ orderedSongIDs: [Int64]) {
        try? store?.setPlaylistOrder(playlistID, assetIDs: orderedSongIDs)
        reload()
        // A reorder adds and removes no files, so it appears nowhere in the sync preview. Say that
        // the device will follow anyway, or it looks as though nothing is going to happen.
        if playlists.first(where: { $0.id == playlistID })?.syncToDevice == true {
            lastMessage = "Order saved — the device playlist is rewritten on the next sync."
        }
    }

    // MARK: mutations

    func togglePlaylistDeviceSync(_ id: Int64) {
        guard let store, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let newVal = !playlists[idx].syncToDevice
        try? store.setPlaylistSync(id, newVal)
        playlists[idx].syncToDevice = newVal
        buildSyncPreview()
    }

    func pin(_ songID: Int64, _ pinned: Bool) { pin([songID], pinned) }

    /// Pin or unpin several songs, then rebuild the sync preview (which walks the device) and
    /// reload once — not once per song.
    func pin(_ songIDs: [Int64], _ pinned: Bool) {
        guard let store, !songIDs.isEmpty else { return }
        for id in songIDs { try? store.pin(assetID: id, pinned) }
        buildSyncPreview()
        reload()
    }

    // In-app ribbon toast (used to report background-job outcomes since the user may be elsewhere).
    struct Toast: Equatable, Identifiable { let id = UUID(); var text: String; var isError = false }
    var toast: Toast? = nil
    private var toastDismiss: Task<Void, Never>? = nil

    func showToast(_ text: String, isError: Bool = false) {
        let t = Toast(text: text, isError: isError)
        toast = t
        toastDismiss?.cancel()
        toastDismiss = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self.toast?.id == t.id { self.toast = nil }
        }
    }

    /// Report a background-job outcome via the in-app ribbon.
    func announce(_ title: String, _ body: String, isError: Bool = false) {
        showToast(body, isError: isError)
        lastMessage = body
    }

    // MARK: Artwork replacement (iTunes Search → re-embed)

    /// Open the Find-Artwork sheet for a whole album and kick off the initial search.
    func findArtwork(for album: AlbumRow) {
        openArtFinder(ArtTarget(id: "album:\(album.id)", title: album.name, artist: album.artist,
                                searchAlbum: album.name, songIDs: album.songIDs))
    }

    /// Open the Find-Artwork sheet for a single song. Searches by album when the song has one (that's
    /// the cover), falling back to the song title for singles / album-less tracks — both editable.
    func findArtwork(forSong song: SongRow) {
        let term = song.album.trimmingCharacters(in: .whitespaces).isEmpty ? song.title : song.album
        openArtFinder(ArtTarget(id: "song:\(song.id)", title: song.title, artist: song.artist,
                                searchAlbum: term, songIDs: [song.id]))
    }

    private func openArtFinder(_ target: ArtTarget) {
        artFinderTarget = target
        artFinderResults = []
        artFinderError = nil
        artFinderApplying = false
        openSheet = .findArt(target.id)
        runArtworkSearch(artist: target.artist, album: target.searchAlbum)
    }

    /// Search iTunes for candidate covers (also called when the user edits the search terms).
    func runArtworkSearch(artist: String, album: String) {
        artFinderLoading = true; artFinderError = nil
        Task {
            let (results, err) = await Self.artworkSearchWork(artist: artist, album: album)
            self.artFinderResults = results
            self.artFinderError = err ?? (results.isEmpty ? "No covers found — try editing the search." : nil)
            self.artFinderLoading = false
        }
    }

    /// Apply a chosen cover to every track in the album: download → square-crop → re-embed into each
    /// master file, then invalidate the display cache so the new art shows immediately.
    func applyArtwork(_ candidate: ArtworkFinder.Candidate) {
        guard let target = artFinderTarget, !artFinderApplying else { return }
        let masters = target.songIDs.compactMap { song($0)?.path }
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
        guard !masters.isEmpty else { showToast("No local file for this track.", isError: true); return }
        let caches = masters.map { ArtworkCache.cacheURL(forMaster: $0).path }
        artFinderApplying = true
        let ffmpeg = settings.ffmpegPath
        let url = candidate.fullURL
        let name = target.title
        let ids = target.songIDs
        Task {
            let applied = await Self.applyArtworkWork(url: url, masters: masters, cachePaths: caches, ffmpegPath: ffmpeg)
            self.artFinderApplying = false
            if applied > 0 {
                await self.refreshMasterHashes(ids)   // re-send these to the device on next sync
                self.artVersion += 1
                self.openSheet = nil
                self.artFinderTarget = nil
                self.reload()
                self.showToast("Updated artwork for “\(name)” (\(applied) track\(applied == 1 ? "" : "s")).")
            } else {
                self.showToast("Couldn't update artwork — download or embed failed.", isError: true)
            }
        }
    }

    // MARK: Send to Apple Music

    var addingToAppleMusic = false

    /// Add library songs to Apple Music (Music.app). Songs Music already has are skipped; formats
    /// Music can't play are converted to an .m4a copy first (kept under Application Support so the
    /// Music entry keeps working even when Music references files in place instead of copying).
    func addToAppleMusic(_ songIDs: [Int64], label: String) {
        if addingToAppleMusic { showToast("Already adding songs to Apple Music…"); return }
        let items = songIDs.compactMap { song($0) }.compactMap { s -> (id: Int64, item: AppleMusicExport.Item)? in
            let path = (s.path as NSString).expandingTildeInPath
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return (s.id, AppleMusicExport.Item(path: path, title: s.title, artist: s.artist,
                                                album: s.album, durationSec: s.durationSec))
        }
        guard !items.isEmpty else { showToast("No song files found to add.", isError: true); return }
        let convertDir = (try? supportDir().appendingPathComponent("For Apple Music", isDirectory: true))
        let ffmpeg = settings.ffmpegPath
        addingToAppleMusic = true
        let taskID = UUID()
        activity.append(ActivityTask(id: taskID, label: label, progress: 0, detail: "Checking Apple Music…"))
        Task {
            let r = await Self.addToAppleMusicWork(items, convertDir: convertDir, ffmpeg: ffmpeg) { done, total in
                Task { @MainActor in
                    if let i = self.activity.firstIndex(where: { $0.id == taskID }) {
                        self.activity[i].progress = Double(done) / Double(max(total, 1))
                        self.activity[i].detail = "\(done)/\(total)"
                    }
                }
            }
            activity.removeAll { $0.id == taskID }
            addingToAppleMusic = false
            appleMusicAlbumsLoaded = false   // the Apple Music tab re-reads the library next time
            if let err = r.error {
                announce("Apple Music", "Couldn't add to Apple Music: \(err)", isError: true)
                return
            }
            var parts: [String] = []
            parts.append(r.added == 1 ? "Added 1 song to Apple Music" : "Added \(r.added) songs to Apple Music")
            if r.skipped > 0 { parts.append("\(r.skipped) already there") }
            if r.failed > 0 { parts.append("\(r.failed) failed") }
            if r.added > 0 { parts.append("syncing to iCloud") }
            announce("Apple Music", parts.joined(separator: " · "), isError: r.failed > 0 && r.added == 0)
            if r.added > 0 { updateCloudLibrary(quiet: true) }
        }
    }

    var updatingCloudLibrary = false

    /// Ask Music to sync its cloud library now (File ▸ Library ▸ Update Cloud Library), so newly
    /// added songs upload instead of sitting at "unknown" — Music doesn't reliably do it by itself.
    /// `quiet` = called after an add: only speak up when something needs the user.
    func updateCloudLibrary(quiet: Bool = false) {
        if updatingCloudLibrary { return }
        // Pressing another app's menu needs Accessibility. Ask macOS up front: it shows its own
        // prompt (once) and lists OpenSong in Privacy & Security ▸ Accessibility.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard trusted else {
            announce("Apple Music", "To update the iCloud library, allow OpenSong in System Settings ▸ Privacy & Security ▸ Accessibility, then try again.", isError: true)
            return
        }
        updatingCloudLibrary = true
        Task {
            let result = await Task.detached { AppleMusicBridge().updateCloudLibrary() }.value
            updatingCloudLibrary = false
            switch result {
            case .triggered:
                if !quiet { showToast("Apple Music is updating your iCloud library.") }
            case .unavailable:
                announce("Apple Music", "Couldn't update the iCloud library — check Sync Library is on in Music ▸ Settings ▸ General.", isError: true)
            case .needsAccessibility:
                announce("Apple Music", "To update the iCloud library, allow OpenSong in System Settings ▸ Privacy & Security ▸ Accessibility.", isError: true)
            case .failed(let msg):
                announce("Apple Music", "Couldn't update the iCloud library: \(msg)", isError: true)
            }
        }
    }

    private struct AMAddResult { var added = 0, skipped = 0, failed = 0; var error: String? }

    private nonisolated static func addToAppleMusicWork(
        _ items: [(id: Int64, item: AppleMusicExport.Item)], convertDir: URL?, ffmpeg: String,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> AMAddResult {
        await Task.detached {
            let bridge = AppleMusicBridge()
            var res = AMAddResult()
            let existing: [AppleMusicTrack]
            do { existing = try bridge.libraryTracks() }
            catch { res.error = "\(error)"; return res }
            let known = (try? bridge.libraryFileLocations()) ?? []
            let (toAdd, already) = AppleMusicExport.plan(items.map(\.item), existing: existing, knownPaths: known)
            res.skipped = already.count
            let idByPath = Dictionary(items.map { ($0.item.path, $0.id) }, uniquingKeysWith: { a, _ in a })
            // Add in small batches so the progress bar moves and one bad file can't sink the rest.
            var done = 0
            progress(0, toAdd.count)
            for batch in stride(from: 0, to: toAdd.count, by: 10).map({ Array(toAdd[$0..<min($0 + 10, toAdd.count)]) }) {
                var paths: [String] = []
                for it in batch {
                    if AppleMusicExport.isNative(it.path) { paths.append(it.path); continue }
                    guard let dir = convertDir else { res.failed += 1; continue }
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = PathSanitizer.component("\(it.artist) - \(it.title)", fallback: "track")
                    let dst = dir.appendingPathComponent("\(name) [\(idByPath[it.path] ?? 0)].m4a").path
                    let r = try? Shell.run(ffmpeg, AppleMusicExport.convertArgs(src: it.path, dst: dst))
                    if r?.status == 0 { paths.append(dst) } else { res.failed += 1 }
                }
                do {
                    let failed = try bridge.addFiles(paths)
                    res.failed += failed.count
                    res.added += paths.count - failed.count
                } catch {
                    res.failed += paths.count
                    if res.added == 0 { res.error = "\(error)"; return res }
                }
                done += batch.count
                progress(done, toAdd.count)
            }
            return res
        }.value
    }

    // MARK: Track-number backfill (iTunes → tags + DB)

    /// Fill in missing track (and disc) numbers for one album from the iTunes catalog.
    func backfillTrackNumbers(for album: AlbumRow) {
        runTrackBackfill(songIDs: album.songIDs, label: "Fixing track numbers for “\(album.name)”…")
    }
    /// Fill in missing track numbers across the whole library.
    func backfillAllTrackNumbers() {
        runTrackBackfill(songIDs: songs.map { $0.id }, label: "Fixing track numbers…")
    }

    private func runTrackBackfill(songIDs: [Int64], label: String) {
        if trackBackfilling { return }
        // Only tracks that are missing a number and have a local file.
        let todo = songIDs.compactMap { song($0) }
            .filter { ($0.track ?? 0) <= 0 }
            .map { (id: $0.id, identityID: $0.identityID, artist: $0.artist, title: $0.title,
                    dur: $0.durationSec, path: ($0.path as NSString).expandingTildeInPath) }
            .filter { !$0.path.isEmpty }
        guard !todo.isEmpty else { showToast("Track numbers already set for these tracks."); return }
        trackBackfilling = true
        let ffmpeg = settings.ffmpegPath
        let taskID = UUID()
        activity.append(ActivityTask(id: taskID, label: label, progress: 0))
        Task {
            var fixed = 0
            var rewritten: [Int64] = []
            for (i, it) in todo.enumerated() {
                if let match = await Self.resolveTrackNumber(artist: it.artist, title: it.title, dur: it.dur),
                   let tn = match.trackNumber, tn > 0,
                   let store = self.store, var ident = try? store.identity(it.identityID) {
                    ident.trackNumber = tn
                    if let dn = match.discNumber, dn > 0 { ident.discNumber = dn }
                    try? store.upsertIdentity(ident)
                    await Self.writeTagsWork(path: it.path, ident: ident, ffmpegPath: ffmpeg)
                    rewritten.append(it.id)
                    fixed += 1
                }
                if let idx = activity.firstIndex(where: { $0.id == taskID }) {
                    activity[idx].progress = Double(i + 1) / Double(todo.count)
                }
            }
            activity.removeAll { $0.id == taskID }
            await refreshMasterHashes(rewritten)   // these files changed → re-send them on next sync
            trackBackfilling = false
            if fixed > 0 { reload() }
            showToast(fixed == 0 ? "Couldn't find track numbers for these tracks."
                                 : "Set track numbers for \(fixed) track\(fixed == 1 ? "" : "s").")
        }
    }

    /// Resolve one track against the iTunes catalog (duration-disambiguated).
    private nonisolated static func resolveTrackNumber(artist: String, title: String, dur: Double) async -> CatalogMatch? {
        let term = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        return try? await MetadataResolver().bestMatch(term: term, durationSec: dur)
    }

    /// Re-hash masters that OpenSong has just rewritten (tags, artwork), so the device diff sees
    /// them as changed and re-sends them on the next sync.
    ///
    /// `AudioAsset.contentHash` was only ever taken at import, so edits that don't move a track's
    /// device path — genre, year, track number, replaced artwork — left the device copy untouched
    /// forever. Path-changing edits (title/artist/album) worked by accident, via the remove+add of
    /// the old and new paths.
    func refreshMasterHashes(_ songIDs: [Int64]) async {
        guard let store else { return }
        let assets = songIDs.compactMap { id -> (Int64, String)? in
            guard let row = song(id) else { return nil }
            return (id, (row.path as NSString).expandingTildeInPath)
        }
        guard !assets.isEmpty else { return }
        let hashes = await Self.hashWork(assets)
        for (id, hash) in hashes {
            guard var asset = try? store.asset(id), asset.contentHash != hash else { continue }
            asset.contentHash = hash
            try? store.updateAsset(asset)
        }
        buildSyncPreview()
    }

    private nonisolated static func hashWork(_ files: [(Int64, String)]) async -> [(Int64, String)] {
        await Task.detached {
            files.compactMap { (id, path) in
                guard let h = try? Importer.contentHash(of: URL(fileURLWithPath: path)) else { return nil }
                return (id, h)
            }
        }.value
    }

    /// Off-main: write the identity's tags into a supported audio file.
    private nonisolated static func writeTagsWork(path: String, ident: TrackIdentity, ffmpegPath: String) async {
        await Task.detached {
            let ext = (path as NSString).pathExtension.lowercased()
            guard ["mp3", "m4a", "m4b", "flac", "aac"].contains(ext),
                  FileManager.default.fileExists(atPath: path) else { return }
            try? Transcoder(ffmpegPath: ffmpegPath).writeTags(URL(fileURLWithPath: path), ident)
        }.value
    }

    /// Scan the whole library for tracks with no embedded cover and fetch official art from iTunes
    /// for each. Runs in the background with a progress task; refreshes thumbnails when done.
    func backfillMissingArtwork() {
        if artBackfilling { return }
        let items = songs.map { (id: $0.id, path: ($0.path as NSString).expandingTildeInPath,
                                 artist: $0.artist, album: $0.album, title: $0.title) }
            .filter { !$0.path.isEmpty }
        guard !items.isEmpty else { return }
        artBackfilling = true
        let ffmpeg = settings.ffmpegPath
        let taskID = UUID()
        activity.append(ActivityTask(id: taskID, label: "Fixing missing artwork…", progress: 0))
        Task {
            var fixed = 0
            var rewritten: [Int64] = []
            for (i, it) in items.enumerated() {
                if await Self.backfillArtworkOne(path: it.path, artist: it.artist, album: it.album,
                                                 title: it.title, ffmpegPath: ffmpeg) {
                    fixed += 1
                    rewritten.append(it.id)
                    let c = ArtworkCache.cacheURL(forMaster: it.path)
                    try? FileManager.default.removeItem(at: c)
                    try? FileManager.default.removeItem(atPath: (c.path as NSString).deletingPathExtension + ".noart")
                }
                if let idx = activity.firstIndex(where: { $0.id == taskID }) {
                    activity[idx].progress = Double(i + 1) / Double(items.count)
                }
            }
            activity.removeAll { $0.id == taskID }
            await refreshMasterHashes(rewritten)   // these files changed → re-send them on next sync
            artBackfilling = false
            if fixed > 0 { artVersion += 1; reload() }
            showToast(fixed == 0 ? "Every track already has artwork."
                                 : "Added artwork to \(fixed) track\(fixed == 1 ? "" : "s").")
        }
    }

    /// One track: skip if it already has embedded art, else pull the official cover from iTunes,
    /// square-crop, and embed. Returns true only when new art was embedded.
    private nonisolated static func backfillArtworkOne(path: String, artist: String, album: String,
                                                       title: String, ffmpegPath: String) async -> Bool {
        await Task.detached {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return false }
            let resolver = ArtworkResolver(ffmpegPath: ffmpegPath)
            let scratch = fm.temporaryDirectory.appendingPathComponent("osart-bf-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let chk = scratch.appendingPathComponent("chk.png")
            if (try? resolver.extractEmbedded(from: URL(fileURLWithPath: path), to: chk)) == true { return false }
            let term = album.isEmpty ? title : album
            guard let cands = try? await ArtworkFinder(http: resolver.http).search(artist: artist, album: term, limit: 1),
                  let best = cands.first else { return false }
            let raw = scratch.appendingPathComponent("raw.img")
            guard (try? await resolver.download(best.fullURL, to: raw)) != nil, fm.fileExists(atPath: raw.path) else { return false }
            let sq = scratch.appendingPathComponent("sq.png")
            let art = ((try? ArtworkCrop.squareCrop(of: raw, to: sq, ffmpegPath: ffmpegPath)) != nil
                       && fm.fileExists(atPath: sq.path)) ? sq : raw
            do { try resolver.embed(art, into: URL(fileURLWithPath: path)); return true }
            catch { return false }
        }.value
    }

    private nonisolated static func artworkSearchWork(artist: String, album: String) async -> ([ArtworkFinder.Candidate], String?) {
        do { return (try await ArtworkFinder().search(artist: artist, album: album), nil) }
        catch { return ([], "\(error)") }
    }

    /// Off-main worker: download the cover once, square-crop it, embed into every master, and
    /// delete each master's cached PNG. Returns the number of files successfully updated.
    private nonisolated static func applyArtworkWork(url: URL, masters: [String], cachePaths: [String],
                                                     ffmpegPath: String) async -> Int {
        await Task.detached {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory.appendingPathComponent("opensong-art-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let raw = scratch.appendingPathComponent("raw.img")
            let square = scratch.appendingPathComponent("cover.png")
            let resolver = ArtworkResolver(ffmpegPath: ffmpegPath)
            do { try await resolver.download(url, to: raw) } catch { return 0 }
            let art: URL
            if (try? ArtworkCrop.squareCrop(of: raw, to: square, ffmpegPath: ffmpegPath)) != nil,
               fm.fileExists(atPath: square.path) { art = square } else { art = raw }
            var applied = 0
            for (i, master) in masters.enumerated() where fm.fileExists(atPath: master) {
                do {
                    try resolver.embed(art, into: URL(fileURLWithPath: master))
                    applied += 1
                    // Force re-extract from the updated file: drop both the cached cover and any
                    // "no art" sentinel for this master.
                    try? fm.removeItem(atPath: cachePaths[i])
                    try? fm.removeItem(atPath: (cachePaths[i] as NSString).deletingPathExtension + ".noart")
                } catch { continue }
            }
            return applied
        }.value
    }

    // MARK: playback helpers (play-next / shuffle)

    func playNext(_ ids: [Int64]) { player.playNext(ids.compactMap { song($0) }) }
    func playNow(_ ids: [Int64]) { player.playAll(ids.compactMap { song($0) }) }
    func shuffle(_ rows: [SongRow]) { player.playAll(rows, shuffled: true) }
    func songsForArtist(_ name: String) -> [SongRow] { songs.filter { $0.groupArtist == name } }

    /// Send a whole album to the device (or remove it) by pinning/unpinning all its tracks —
    /// albums sync without needing a playlist, landing in Artist/Album folders on the Walkman.
    func pinAlbum(_ album: AlbumRow, _ pinned: Bool) {
        guard let store else { return }
        for id in album.songIDs { try? store.pin(assetID: id, pinned) }
        buildSyncPreview(); reload()
        lastMessage = pinned ? "Sending “\(album.name)” to the device on next sync."
                             : "Removed “\(album.name)” from the device set."
    }

    /// How many of an album's tracks are currently on the device.
    func albumDeviceState(_ album: AlbumRow) -> (onDevice: Int, total: Int) {
        let on = album.songIDs.filter { song($0)?.onDevice == true }.count
        return (on, album.songIDs.count)
    }

    func saveMetadata(songID: Int64, title: String, artist: String, album: String,
                      track: String, genre: String, year: String) {
        guard let store, let row = song(songID),
              var ident = try? store.identity(row.identityID) else { return }
        ident.title = title; ident.artist = artist; ident.albumArtist = artist
        ident.album = album.isEmpty ? nil : album
        ident.trackNumber = Int(track); ident.genre = genre.isEmpty ? nil : genre
        ident.year = Int(year); ident.provenance = .userEdited
        try? store.upsertIdentity(ident)
        let url = URL(fileURLWithPath: (row.path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path),
           ["mp3", "m4a", "m4b", "flac", "aac"].contains(url.pathExtension.lowercased()) {
            try? transcoder.writeTags(url, ident)
            Task { await refreshMasterHashes([songID]) }   // so the device copy gets the new tags
        }
        reload()
    }

    func chooseToolPath(_ keyPath: WritableKeyPath<AppSettings, String>, directory: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings[keyPath: keyPath] = url.path
        }
    }

    // MARK: wishlist / acquisition (Phase 2)

    /// Fetch a pasted link's title (off-main) and work out artist/title for pre-filling. Shows its
    /// own toast on failure (so a SoundCloud set gets a useful message, not "couldn't read").
    func fetchURLMetadata(_ urlString: String) async -> (title: String, artist: String)? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = PastedLink.classify(trimmed)
        if link == .soundcloudCollection { showToast(Self.collectionMessage, isError: true); return nil }
        guard let url = URL(string: trimmed) else { showToast("That doesn't look like a link.", isError: true); return nil }
        let ytPath = settings.ytDlpPath
        let lines = await Task.detached { () -> [String]? in
            let r = try? Shell.run(ytPath, ["--no-playlist", "--skip-download", "--no-warnings",
                                            "--print", "%(title)s\t%(artist)s\t%(uploader)s", url.absoluteString])
            guard r?.status == 0, let out = r?.stdoutString else { return nil }
            return out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }.value
        guard let lines, let first = lines.first else {
            showToast("Couldn't read that link's info.", isError: true); return nil
        }
        // A short link (on.soundcloud.com/…) can turn out to be a whole set.
        if lines.count > 1 { showToast(Self.collectionMessage, isError: true); return nil }
        let f = first.components(separatedBy: "\t")
        let m = PastedLink.suggestedMeta(rawTitle: f[0], artistTag: f.count > 1 ? f[1] : "",
                                         uploader: f.count > 2 ? f[2] : "", link: link)
        return (m.title, m.artist)
    }

    static let collectionMessage = "That's a SoundCloud set or profile — paste a single track's link."

    /// Download a pasted YouTube or SoundCloud link directly into the library (background), with
    /// user-supplied metadata. Skips the search entirely (the URL is the chosen source).
    func addFromURL(urlString: String, title: String, artist: String, album: String) {
        if PastedLink.classify(urlString) == .soundcloudCollection {
            showToast(Self.collectionMessage, isError: true); return
        }
        guard let store, let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let coord = try? buildCoordinator(), let dir = try? downloadDir() else {
            showToast("That URL or your setup looks wrong.", isError: true); return
        }
        let t = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title
        let wish = WishItem(title: t, artist: artist, album: album.isEmpty ? nil : album,
                            source: .custom, state: .matching, chosenURL: url.absoluteString)
        guard let wid = try? store.addWish(wish) else { return }
        var w = wish; w.id = wid
        let candidate = Candidate(videoID: url.absoluteString, url: url, title: t, channel: "", durationSec: 0)
        let task = ActivityTask(label: "Downloading “\(t)”…", progress: 0)
        activity.append(task); reload()
        showToast("Downloading “\(t)” in the background…")
        Task {
            let result = await Self.acquireWork(coord, w, candidate, dir)
            self.activity.removeAll { $0.id == task.id }
            switch result {
            case .success:
                self.reload(); self.announce("Download complete", "“\(t)” is in your library.")
            case .failure(let e):
                self.downloadErrors[wid] = Self.shortError(e)
                if var ww = self.wishItems.first(where: { $0.id == wid }) { ww.state = .wishlist; try? store.updateWish(ww) }
                self.reload(); self.announce("Download failed", "“\(t)” — \(Self.shortError(e))", isError: true)
            }
        }
    }

    func addCustomWish(title: String, artist: String, album: String) {
        guard let store, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.addWish(WishItem(title: title, artist: artist,
                                        album: album.isEmpty ? nil : album, source: .custom))
        reload()
    }

    func deleteWish(_ id: Int64) { try? store?.deleteWish(id); reload() }

    /// Edit the metadata that will be used to tag the downloaded file. Pre-filled from Apple
    /// Music/iTunes but freely editable — updates in place without a full reload (so typing in
    /// the match screen's fields stays smooth).
    func updateWishMeta(_ id: Int64, title: String? = nil, artist: String? = nil, album: String? = nil) {
        guard let idx = wishItems.firstIndex(where: { $0.id == id }) else { return }
        var w = wishItems[idx]
        if let title { w.title = title }
        if let artist { w.artist = artist }
        if let album { w.album = album.isEmpty ? nil : album }
        wishItems[idx] = w
        try? store?.updateWish(w)
    }

    private func buildCoordinator() throws -> AcquireCoordinator {
        guard let store, let importer else { throw NSError(domain: "OpenSong", code: 1) }
        return AcquireCoordinator(
            store: store,
            source: YtDlpSource(ytDlpPath: settings.ytDlpPath, ffmpegPath: settings.ffmpegPath),
            importer: importer,
            artwork: ArtworkResolver(ffmpegPath: settings.ffmpegPath),
            spectral: SpectralAnalyzer(ffmpegPath: settings.ffmpegPath),
            probe: probe,
            settings: AcquireSettings(searchLimit: settings.searchLimit))
    }

    private func downloadDir() throws -> URL {
        let d = try supportDir().appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func beginMatch(_ wishID: Int64) {
        guard let wish = wishItems.first(where: { $0.id == wishID }) else { return }
        downloadErrors[wishID] = nil          // clear any prior failure on retry
        matchWishID = wishID
        activeView = .match(wishID)
        matchStep = .loading
        matchCandidates = []; matchVerify = nil; selectedCandidateID = nil; matchError = nil
        var w = wish; w.state = .matching; try? store?.updateWish(w); reload()

        // If a source URL is already known (e.g. imported from a YouTube playlist), skip the
        // search entirely and present it as the pre-selected candidate — one click to download.
        if let chosen = wish.chosenURL, let url = URL(string: chosen), !chosen.isEmpty {
            let c = Candidate(videoID: url.absoluteString, url: url,
                              title: wish.title.isEmpty ? "Chosen source" : wish.title,
                              channel: "", durationSec: wish.durationSec ?? 0)
            matchCandidates = [RankedCandidate(candidate: c, durationDelta: 0, confidence: .high)]
            selectedCandidateID = c.id
            matchStep = .results
            fetchCandidateQualities()
            return
        }

        guard let coord = try? buildCoordinator() else { matchStep = .error; return }
        Task {
            switch await Self.searchWork(coord, wish) {
            case .success(let ranked):
                self.matchCandidates = ranked
                self.selectedCandidateID = ranked.first?.id
                self.matchStep = ranked.isEmpty ? .error : .results
                self.fetchCandidateQualities()
            case .failure:
                self.matchStep = .error
            }
        }
    }

    /// Download the selected candidate in the BACKGROUND: the user is returned to Pending so they
    /// can keep queuing, while the download/tag/verify runs and reports via the activity footer.
    /// Multiple downloads can run at once.
    func acquireSelected() {
        guard let wishID = matchWishID,
              let wish = wishItems.first(where: { $0.id == wishID }),
              let candID = selectedCandidateID,
              let ranked = matchCandidates.first(where: { $0.id == candID }),
              let coord = try? buildCoordinator(),
              let dir = try? downloadDir() else { matchStep = .error; return }
        candidatePreview.stop()
        matchError = nil
        let candidate = ranked.candidate
        let title = wish.title
        let isReplacement = wish.isReplacement
        let task = ActivityTask(label: isReplacement
                                ? "Downloading a new version of “\(title)”…"
                                : "Downloading “\(title)”…", progress: 0)
        activity.append(task)
        // Return to Pending — the item stays in a matching state until the background job finishes.
        activeView = .wishlist
        matchStep = .results
        showToast("Downloading “\(title)” in the background…")
        Task {
            let result = await Self.acquireWork(coord, wish, candidate, dir)
            self.activity.removeAll { $0.id == task.id }
            switch result {
            case .success:
                self.reload()
                // A replacement swaps itself in for the old file; an ordinary download doesn't.
                if isReplacement {
                    self.completeReplacement(wishID: wishID)
                    self.announce("Replacement ready", "“\(title)” now uses the new file.")
                    return
                }
                self.maybeRecreatePlaylist(wishID: wishID)
                self.announce("Download complete", "“\(title)” is in your library.")
            case .failure(let error):
                // Revert to wishlist so it can be retried, and record the error for the Pending row.
                if var w = self.wishItems.first(where: { $0.id == wishID }) {
                    w.state = .wishlist; try? self.store?.updateWish(w)
                }
                self.downloadErrors[wishID] = Self.shortError(error)
                self.reload()
                self.announce("Download failed", "“\(title)” — \(Self.shortError(error))", isError: true)
            }
        }
    }

    /// Download a candidate as a standalone library track (not added to the current wish's
    /// playlist/album). Used for the "download separately" action on edits/remixes; runs in the
    /// background so the main match screen stays usable. Titles are cleaned so versions differ.
    func acquireSideCandidate(_ ranked: RankedCandidate) {
        guard let store, let coord = try? buildCoordinator(), let dir = try? downloadDir() else { return }
        let cand = ranked.candidate
        let parsed = TitleCleaner.parse(cand.title)
        let mainArtist = wishItems.first { $0.id == matchWishID }?.artist ?? ""
        let sideWish = WishItem(title: parsed.title, artist: parsed.artist ?? mainArtist,
                                durationSec: cand.durationSec > 0 ? cand.durationSec : nil,
                                source: .custom, state: .matching, chosenURL: cand.url.absoluteString)
        guard let wid = try? store.addWish(sideWish) else { return }
        var w = sideWish; w.id = wid
        let task = ActivityTask(label: "Downloading “\(parsed.title)” separately…", progress: 0)
        activity.append(task)
        showToast("Downloading “\(parsed.title)” separately…")
        Task {
            let result = await Self.acquireWork(coord, w, cand, dir)
            self.activity.removeAll { $0.id == task.id }
            switch result {
            case .success:
                self.reload()
                self.announce("Download complete", "“\(parsed.title)” added to the library (not the playlist).")
            case .failure(let e):
                if let id = w.id { try? store.deleteWish(id) }   // don't leave a stuck wish
                self.announce("Download failed", "“\(parsed.title)” — \(Self.shortError(e))", isError: true)
            }
        }
    }

    /// Fetch best-audio quality for each visible candidate concurrently (background), for display.
    func fetchCandidateQualities() {
        let ytPath = settings.ytDlpPath
        let cands = matchCandidates.map { $0.candidate }.filter { candidateQuality[$0.videoID] == nil }
        guard !cands.isEmpty else { return }
        Task {
            // At most 4 at once: each is a full yt-dlp + deno run, and a flood of them slows
            // the preview resolve the user is actually waiting on.
            await withTaskGroup(of: (String, String?).self) { group in
                var pending = cands[...]
                func addNext() {
                    guard let c = pending.popFirst() else { return }
                    group.addTask { (c.videoID, await Self.qualityWork(ytPath, c.url)) }
                }
                for _ in 0..<4 { addNext() }
                for await (vid, q) in group {
                    if let q { self.candidateQuality[vid] = q }
                    addNext()
                }
            }
        }
    }
    private nonisolated static func qualityWork(_ ytPath: String, _ url: URL) async -> String? {
        await Task.detached { try? await YtDlpSource(ytDlpPath: ytPath).audioQuality(url) }.value
    }

    /// Trim a raw error into a short, user-facing line.
    private static func shortError(_ error: Error) -> String {
        let msg = (error as NSError).localizedDescription
        return String(msg.split(whereSeparator: \.isNewline).first ?? Substring(msg)).prefix(200).description
    }

    func pasteCustomURL(_ urlString: String) {
        if PastedLink.classify(urlString) == .soundcloudCollection {
            showToast(Self.collectionMessage, isError: true); return
        }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let c = Candidate(videoID: url.absoluteString, url: url, title: "Custom URL", channel: "", durationSec: 0)
        matchCandidates.insert(RankedCandidate(candidate: c, durationDelta: .infinity, confidence: .medium), at: 0)
        selectedCandidateID = c.id
    }

    // Render-only seeding for screenshots.
    func seedWishesForRender() {
        guard let store, ((try? store.allWishes())?.isEmpty ?? false) else { reload(); return }
        _ = try? store.addWish(WishItem(title: "Windowlicker", artist: "Aphex Twin", album: "Windowlicker", durationSec: 363, source: .custom, state: .wishlist))
        _ = try? store.addWish(WishItem(title: "Xtal", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", durationSec: 293, source: .appleMusic, state: .matching))
        _ = try? store.addWish(WishItem(title: "Ageispolis", artist: "Aphex Twin", durationSec: 323, source: .appleMusic, state: .downloaded, assetID: 1))
        // A track the user marked as needing a different file: shows the badge in the library and
        // the "replacing" tag in Pending.
        if let first = songs.first {
            _ = try? store.addWish(WishItem(title: first.title, artist: first.artist,
                                            album: first.album.isEmpty ? nil : first.album,
                                            durationSec: first.durationSec, source: .custom,
                                            state: .wishlist, replacesAssetID: first.id))
        }
        // A grouped playlist from Apple Music.
        _ = try? store.addWish(WishItem(title: "Nights", artist: "Frank Ocean", album: "Blonde", durationSec: 307, source: .appleMusic, state: .wishlist, playlistName: "blonde faves"))
        _ = try? store.addWish(WishItem(title: "White Ferrari", artist: "Frank Ocean", album: "Blonde", durationSec: 248, source: .appleMusic, state: .matching, playlistName: "blonde faves"))
        reload()
    }
    func seedMatchForRender() {
        seedWishesForRender()
        guard let w = wishItems.first(where: { $0.state == .matching }) ?? wishItems.first else { return }
        matchWishID = w.id
        matchStep = .results
        matchCandidates = [
            RankedCandidate(candidate: Candidate(videoID: "a", url: URL(string: "https://y/a")!, title: "Aphex Twin - Xtal", channel: "WARP Records", durationSec: 293, viewCount: 2_400_000), durationDelta: 0, confidence: .high),
            RankedCandidate(candidate: Candidate(videoID: "b", url: URL(string: "https://y/b")!, title: "Xtal (Aphex Twin) HQ Audio", channel: "ambient vibes", durationSec: 296, viewCount: 120_000), durationDelta: 3, confidence: .medium),
            RankedCandidate(candidate: Candidate(videoID: "c", url: URL(string: "https://y/c")!, title: "Xtal - live edit 2011", channel: "bootlegs", durationSec: 410, viewCount: 5_000), durationDelta: 117, confidence: .low),
        ]
        selectedCandidateID = "a"
        candidateQuality = ["a": "~129k AAC", "b": "~160k Opus", "c": "~128k AAC"]
    }

    // MARK: Apple Music (Phase 3)

    func loadAppleMusic() {
        appleMusicLoading = true; appleMusicError = nil
        Task {
            let (cols, err) = await Self.appleMusicWork()
            self.appleMusic = cols
            self.appleMusicError = err
            self.appleMusicLoading = false
        }
    }

    /// Load the user's Apple Music library albums (lazy — first switch to the Albums tab). Reading
    /// the whole library can be slow the first time, so we cache the result for the session.
    func loadAppleMusicAlbums(force: Bool = false) {
        if appleMusicAlbumsLoading { return }
        if appleMusicAlbumsLoaded && !force { return }
        appleMusicAlbumsLoading = true; appleMusicError = nil
        Task {
            let (cols, err) = await Self.appleMusicAlbumsWork()
            self.appleMusicAlbums = cols
            if err != nil { self.appleMusicError = err }
            self.appleMusicAlbumsLoaded = (err == nil)
            self.appleMusicAlbumsLoading = false
        }
    }

    func ownership(_ col: AppleMusicCollection) -> (owned: Int, total: Int, missing: [AppleMusicTrack]) {
        var owned = 0; var missing: [AppleMusicTrack] = []
        for t in col.tracks { if isOwned(t) { owned += 1 } else { missing.append(t) } }
        return (owned, col.tracks.count, missing)
    }

    /// A wish (in the given download state) whose title+artist match, normalized.
    private func hasWish(title: String, artist: String, downloaded: Bool) -> Bool {
        let nt = norm(title), na = norm(artist)
        return wishItems.contains {
            ($0.state == .downloaded) == downloaded && norm($0.title) == nt && norm($0.artist) == na
        }
    }

    func markMissing(_ col: AppleMusicCollection) {
        // Both kinds are grouped so Pending can show them together, but only a *playlist* becomes a
        // real playlist. An album needs no playlist: its tracks are an album already — they group
        // themselves under Albums by their tags, and the device browses them as Artist/Album
        // folders, so a playlist would just be a duplicate cluttering the sidebar.
        let group = (col.kind == .playlist || col.kind == .album) ? col.name : nil
        if let name = group, col.kind == .playlist {
            seedPlaylist(name, ownedAssetIDs: ownedAssetIDs(col.tracks), source: .appleMusic)
        }
        addTracksToPending(ownership(col).missing, group: group)
    }

    func openAMDetail(_ col: AppleMusicCollection) {
        amDetail = col
        activeView = .appleMusicDetail
    }

    /// Add a single Apple Music track to Pending (grouped under its playlist).
    func addTrackToPending(_ track: AppleMusicTrack, group: String?) {
        addTracksToPending([track], group: group)
    }

    func addTracksToPending(_ tracks: [AppleMusicTrack], group: String?) {
        guard let store, !tracks.isEmpty else { return }
        var added = 0
        for t in tracks where !isPending(t) && !isOwned(t) {
            var w = t.wishItem; w.playlistName = group
            _ = try? store.addWish(w); added += 1
        }
        reload()
        lastMessage = added == 0 ? "Already in Pending or your library."
                                 : "Added \(added) to Pending\(group.map { " from “\($0)”" } ?? "")."
    }

    func removeTracksFromPending(_ tracks: [AppleMusicTrack]) {
        guard let store, !tracks.isEmpty else { return }
        let keys = Set(tracks.map { "\($0.name)␟\($0.artist)" })
        for w in wishItems where keys.contains("\(w.title)␟\(w.artist)") {
            if let id = w.id { try? store.deleteWish(id) }
        }
        reload()
        lastMessage = "Removed \(tracks.count) from Pending."
    }

    /// Owned = in the library by fuzzy match, OR already downloaded via a wish (authoritative,
    /// even when the fuzzy metadata match fails because the download's duration/album differ).
    func isOwned(_ track: AppleMusicTrack) -> Bool {
        _ = songs
        if ownedSongID(name: track.name, artist: track.artist, album: track.album, durationSec: track.durationSec) != nil { return true }
        return hasWish(title: track.name, artist: track.artist, downloaded: true)
    }

    /// Pending = a not-yet-downloaded wish matches (downloaded wishes count as owned, not pending).
    func isPending(_ track: AppleMusicTrack) -> Bool {
        hasWish(title: track.name, artist: track.artist, downloaded: false)
    }

    /// Playlists that predate the `source` column say "manual", which would show a gradient for a
    /// genuine Apple Music import and keep the wrong cover on a Spotify one. The wishes that built
    /// each group still name their service, so the source is recovered from them once.
    private func backfillPlaylistSources() {
        guard let store, !UserDefaults.standard.bool(forKey: "playlistSourcesBackfilled") else { return }
        defer { UserDefaults.standard.set(true, forKey: "playlistSourcesBackfilled") }
        let byName = Dictionary(grouping: wishItems.filter { $0.playlistName != nil },
                                by: { $0.playlistName! })
        for pl in (try? store.allPlaylists()) ?? [] where pl.source == .manual {
            guard let id = pl.id, let wishes = byName[pl.name] else { continue }
            let source = playlistSource(of: wishes)
            guard source != .manual else { continue }
            try? store.setPlaylistSource(id, source)
        }
    }

    /// Which service a group of wishes came from.
    private func playlistSource(of wishes: [WishItem]) -> PlaylistSource {
        switch wishes.first?.source {
        case .appleMusic: return .appleMusic
        case .spotify: return .spotify
        default: return .manual
        }
    }

    /// Get (or create) a playlist by name, recording where it came from so its cover can be
    /// resolved later — by name alone, a Spotify import and an Apple Music playlist are the same
    /// thing, which is how one ended up wearing the other's artwork.
    private func ensurePlaylist(_ name: String, source: PlaylistSource = .manual,
                                artworkURL: String? = nil) -> Int64? {
        guard let store else { return nil }
        if let existing = (try? store.allPlaylists())?.first(where: { $0.name == name }), let id = existing.id { return id }
        return try? store.createPlaylist(name: name, syncToDevice: false,
                                         source: source, artworkURL: artworkURL)
    }

    private func addAssetToPlaylist(_ plID: Int64, _ assetID: Int64) {
        guard let store else { return }
        if (try? store.playlistContains(plID, assetID: assetID)) == true { return }
        let pos = (try? store.nextPlaylistPosition(plID)) ?? 0
        try? store.addToPlaylist(playlistID: plID, assetID: assetID, position: pos)
    }

    /// Create the playlist for a marked import right away and seed it with the tracks already in
    /// the library (in the collection's order). Missing tracks are added to Pending separately and
    /// join the playlist as they download — so a marked playlist is a real, growing playlist you
    /// can even sync half-complete.
    private func seedPlaylist(_ name: String, ownedAssetIDs: [Int64],
                              source: PlaylistSource = .manual, artworkURL: String? = nil) {
        guard let plID = ensurePlaylist(name, source: source, artworkURL: artworkURL) else { return }
        for id in ownedAssetIDs { addAssetToPlaylist(plID, id) }
    }

    /// When a grouped wish finishes downloading, drop it into its playlist (creating the playlist
    /// if needed). The wish is kept (state .downloaded) so the group stays visible in Pending
    /// (collapsible once complete); the playlist fills incrementally.
    private func maybeRecreatePlaylist(wishID: Int64) {
        guard let done = wishItems.first(where: { $0.id == wishID }),
              let name = done.playlistName, let assetID = done.assetID,
              !isAlbumGroup(name),          // albums aren't playlists — they group by their tags
              let plID = ensurePlaylist(name, source: playlistSource(of: [done])) else { return }
        let wasIncomplete = pendingCount(forPlaylist: name) > 0
        addAssetToPlaylist(plID, assetID)
        reload()
        if wasIncomplete && pendingCount(forPlaylist: name) == 0 {
            announce("Playlist ready", "“\(name)” is complete.")
        }
    }

    /// Retire album-shaped playlists left over from when marking an Apple Music album created one.
    ///
    /// Albums aren't playlists any more: they group themselves under LIBRARY ▸ Albums by their tags,
    /// and the player browses them as `Artist/Album` folders — so the extra rows only crowded the
    /// real playlists. Deleting the playlist doesn't touch the tracks; and where one was flagged to
    /// sync, its tracks are pinned first so the device keeps exactly what it had (they were only
    /// "wanted" on the device by way of that flag).
    private func retireAlbumPlaylists() {
        guard let store else { return }
        let albums = playlists.filter { isAlbumGroup($0.name) }
        guard !albums.isEmpty else { return }
        for pl in albums {
            if pl.syncToDevice { for id in pl.songIDs { try? store.pin(assetID: id, true) } }
            try? store.deletePlaylist(pl.id)
            if case .playlist(let pid) = activeView, pid == pl.id { activeView = .albums }
        }
        reload()
    }

    /// Turn a finished acquisition group into a real playlist.
    ///
    /// Each download normally files itself into its playlist as it lands (`maybeRecreatePlaylist`),
    /// but a group whose downloads all completed without that hook running — an older import path,
    /// or the app quitting mid-run — is left stranded: every track is in the library, no playlist
    /// exists, and the sidebar shows a dead "12/12" row that only leads to Pending. This runs after
    /// every reload and adopts any such group, so it heals itself.
    private func materializeCompletedGroups() {
        guard !materializing, store != nil else { return }
        let realNames = Set(playlists.map { $0.name })
        var groups: [String: [WishItem]] = [:]
        for w in wishItems {
            guard let name = w.playlistName, !realNames.contains(name) else { continue }
            groups[name, default: []].append(w)
        }
        // Only groups that are wholly downloaded and know their library tracks.
        let ready = groups
            .filter { !isAlbumGroup($0.key) }   // albums never become playlists
            .filter { $0.value.allSatisfy { $0.state == .downloaded && $0.assetID != nil } }
        guard !ready.isEmpty else { return }
        materializing = true
        for (name, wishes) in ready {
            // The wishes remember where the group came from, so a playlist materialised after the
            // fact still knows whose cover to wear.
            let source = playlistSource(of: wishes)
            guard let plID = ensurePlaylist(name, source: source) else { continue }
            // Wish ids ascend in the order the tracks were queued — the collection's own order.
            for w in wishes.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
                if let assetID = w.assetID { addAssetToPlaylist(plID, assetID) }
            }
        }
        materializing = false
        reload()
    }

    /// How many of a playlist's tracks are still downloading (grouped wishes not yet downloaded).
    func pendingCount(forPlaylist name: String) -> Int {
        wishItems.filter { $0.playlistName == name && $0.state != .downloaded }.count
    }

    /// Library asset ids that match a set of Apple Music tracks, in track order (for seeding).
    private func ownedAssetIDs(_ tracks: [AppleMusicTrack]) -> [Int64] {
        tracks.compactMap { ownedSongID(name: $0.name, artist: $0.artist, album: $0.album, durationSec: $0.durationSec) }
    }
    private func ownedAssetIDsSpotify(_ tracks: [SpotifyTrack]) -> [Int64] {
        tracks.compactMap { ownedSongID(name: $0.title, artist: $0.artist, album: $0.album, durationSec: $0.durationSec) }
    }

    /// Imported playlists (Apple Music / Spotify / YouTube) that are still downloading — grouped
    /// Pending items whose real playlist doesn't exist yet. Shown in the sidebar with progress.
    struct FormingPlaylist: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var total: Int
        var downloaded: Int
    }
    var formingPlaylists: [FormingPlaylist] {
        let realNames = Set(playlists.map { $0.name })
        var groups: [String: (total: Int, done: Int)] = [:]
        for w in wishItems {
            guard let name = w.playlistName, !realNames.contains(name) else { continue }
            var g = groups[name] ?? (0, 0)
            g.total += 1
            if w.state == .downloaded { g.done += 1 }
            groups[name] = g
        }
        return groups.map { FormingPlaylist(name: $0.key, total: $0.value.total, downloaded: $0.value.done) }
            .sorted { $0.name < $1.name }
    }

    /// Whether a grouped acquisition named `name` is an Apple Music *album* (vs a playlist). Albums
    /// are marked with the album name as the group and every track shares that album; a materialized
    /// album holds only that one same-named album. Used to give albums their own sidebar section.
    func isAlbumGroup(_ name: String) -> Bool {
        let n = AppleMusicCompare.normalize(name)
        let gw = wishItems.filter { $0.playlistName == name }
        if !gw.isEmpty { return gw.allSatisfy { AppleMusicCompare.normalize($0.album ?? "") == n } }
        if let pl = playlists.first(where: { $0.name == name }) {
            let albums = Set(pl.songIDs.compactMap { song($0).map { AppleMusicCompare.normalize($0.album) } })
            return albums == [n]
        }
        return false
    }

    /// Sidebar partition: real (curated) playlists vs album acquisitions.
    var sidebarPlaylists: [PlaylistRow] { playlists }
    /// Playlists still filling from an import. Albums are excluded — an album being acquired shows
    /// its progress in Pending, and lands in LIBRARY ▸ Albums when it's done.
    var formingRealPlaylists: [FormingPlaylist] { formingPlaylists.filter { !isAlbumGroup($0.name) } }

    func importLocal(_ track: AppleMusicTrack) {
        guard let importer, let loc = track.location else { return }
        let url = URL(fileURLWithPath: loc)
        let identity = track.identity
        Task {
            let ok = await Self.importOneWork(importer, url, identity)
            self.reload()
            self.lastMessage = ok ? "Imported \(track.name)." : "Couldn't import \(track.name)."
        }
    }

    /// Import many local Music files in one go: one `reload()` and one summary message at the end.
    func importLocal(_ tracks: [AppleMusicTrack]) {
        guard let importer else { return }
        let jobs = tracks.compactMap { t in t.location.map { (URL(fileURLWithPath: $0), t.identity) } }
        guard !jobs.isEmpty else { return }
        Task {
            var done = 0
            for (url, identity) in jobs where await Self.importOneWork(importer, url, identity) { done += 1 }
            self.reload()
            self.lastMessage = "Imported \(done) of \(jobs.count) from Music"
        }
    }

    // MARK: Spotify (public playlists → Pending)

    private func spotifyClient() -> SpotifyClient? {
        guard let auth = spotifyAuth() else { return nil }
        return SpotifyClient(clientID: auth.id, clientSecret: auth.secret, userTokens: auth.signIn)
    }

    /// The Spotify credentials plus the sign-in actor built from them, or nil when unconfigured.
    private func spotifyAuth() -> (id: String, secret: String, signIn: SpotifySignIn)? {
        let id = settings.spotifyClientID.trimmingCharacters(in: .whitespaces)
        let secret = settings.spotifyClientSecret.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        let redirect = settings.spotifyRedirectURI.trimmingCharacters(in: .whitespaces)
        return (id, secret, SpotifySignIn(clientID: id, clientSecret: secret,
                                          redirectURI: redirect.isEmpty
                                              ? SpotifyAuth.defaultRedirectURI : redirect))
    }

    // MARK: Spotify sign-in

    /// The redirect URI to register in the Spotify dashboard. Editable, because sign-in fails with
    /// nothing but "redirect_uri: Not matching configuration" unless it matches exactly.
    var spotifyRedirectURI: String {
        let s = settings.spotifyRedirectURI.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? SpotifyAuth.defaultRedirectURI : s
    }

    func refreshSpotifySignInState() {
        guard let auth = spotifyAuth() else { spotifySignedIn = false; return }
        Task { self.spotifySignedIn = await auth.signIn.isSignedIn }
    }

    /// Load the signed-in account's own playlists — the Apple Music "Compare" equivalent, and the
    /// reason a profile link is no longer needed.
    func loadMySpotifyPlaylists() {
        guard let client = spotifyClient() else {
            spotifyError = "Add your Spotify Client ID + Secret in Settings first."; return
        }
        guard spotifySignedIn else { return }
        spotifyLoading = true; spotifyError = nil
        Task {
            do {
                let pls = try await client.myPlaylists()
                self.spotifyPlaylists = pls
                self.spotifyUserID = nil
                let who = (try? await client.myDisplayName()) ?? nil
                self.spotifySourceLabel = who.map { "your playlists · \($0)" } ?? "your playlists"
                if pls.isEmpty { self.spotifyError = "No playlists on this Spotify account." }
            } catch {
                self.spotifyError = "Spotify: \(error.localizedDescription)"
            }
            self.spotifyLoading = false
        }
    }

    /// Called when the Spotify screen appears: show the account's playlists straight away rather
    /// than an empty box waiting for a link.
    func spotifyViewAppeared() {
        refreshSpotifySignInState()
        guard spotifyPlaylists.isEmpty, !spotifyLoading else { return }
        Task {
            // The sign-in check is async; wait for it before deciding there is nothing to load.
            try? await Task.sleep(for: .milliseconds(150))
            if self.spotifySignedIn, self.spotifyPlaylists.isEmpty { self.loadMySpotifyPlaylists() }
        }
    }

    func spotifySignIn() {
        guard let auth = spotifyAuth() else {
            spotifyError = "Add your Spotify Client ID + Secret in Settings first."; return
        }
        spotifySigningIn = true
        Task {
            do {
                try await auth.signIn.signIn()
                self.spotifySignedIn = true
                self.spotifyError = nil
                self.lastMessage = "Signed in to Spotify."
                self.loadMySpotifyPlaylists()      // show them immediately
            } catch {
                self.spotifyError = "Spotify sign-in: \(error.localizedDescription)"
            }
            self.spotifySigningIn = false
        }
    }

    func spotifySignOut() {
        guard let auth = spotifyAuth() else { return }
        Task {
            await auth.signIn.signOut()
            self.spotifySignedIn = false
            self.lastMessage = "Signed out of Spotify."
        }
    }

    /// Resolve whatever the user pasted (playlist or user URL/URI/ID) and load it.
    // MARK: saved Spotify users

    var savedSpotifyUsers: [String] { settings.savedSpotifyUsers }

    /// Whether the profile in the box (or currently loaded) is already saved.
    func isSpotifyUserSaved(_ id: String) -> Bool {
        SpotifyBookmarks.contains(id, in: settings.savedSpotifyUsers)
    }

    /// The user id the Save button would act on: whatever is in the box if it is a profile link,
    /// else whichever profile is loaded. Saving works from a pasted link alone, so a profile can be
    /// kept for later even when Spotify won't let us list its playlists.
    var spotifyUserToSave: String? {
        if case .user(let uid)? = SpotifyClient.parse(spotifyInput) { return uid }
        return spotifyUserID
    }

    func saveSpotifyUser(_ id: String) {
        settings.savedSpotifyUsers = SpotifyBookmarks.add(id, to: settings.savedSpotifyUsers)
        persistSettings()
        lastMessage = "Saved “\(id)”."
    }

    func removeSavedSpotifyUser(_ id: String) {
        settings.savedSpotifyUsers = SpotifyBookmarks.remove(id, from: settings.savedSpotifyUsers)
        persistSettings()
    }

    /// Open a saved user — the same path as pasting their profile link.
    func openSavedSpotifyUser(_ id: String) {
        spotifyInput = "https://open.spotify.com/user/\(id)"
        loadSpotify(spotifyInput)
    }

    func loadSpotify(_ input: String) {
        guard let ref = SpotifyClient.parse(input) else {
            spotifyError = "That doesn't look like a Spotify playlist or profile link."; return
        }
        guard let client = spotifyClient() else {
            spotifyError = "Add your Spotify Client ID + Secret in Settings first."; return
        }
        spotifyLoading = true; spotifyError = nil; spotifyPlaylists = []
        if case .playlist = ref { spotifyUserID = nil }
        Task {
            do {
                switch ref {
                case .playlist(let id):
                    let pl = try await client.playlist(id: id)
                    self.spotifyPlaylists = [pl]
                    self.spotifySourceLabel = "playlist"
                    self.spotifyLoading = false
                    self.openSpotifyDetail(pl)             // one playlist → straight to it
                case .user(let uid):
                    self.spotifyUserID = uid
                    let pls = try await client.userPlaylists(userID: uid)
                    self.spotifyPlaylists = pls
                    self.spotifySourceLabel = "user: \(uid)"
                    self.spotifyLoading = false
                    if pls.isEmpty { self.spotifyError = "No public playlists found for “\(uid)”." }
                }
            } catch {
                self.spotifyLoading = false
                self.spotifyError = "Spotify: \(error.localizedDescription)"
            }
        }
    }

    /// Open a playlist's track list, fetching its full contents if we only have metadata.
    func openSpotifyDetail(_ pl: SpotifyPlaylist) {
        if !pl.tracks.isEmpty {
            spotifyDetail = pl; activeView = .spotifyDetail; return
        }
        guard let client = spotifyClient() else {
            spotifyError = "Add your Spotify Client ID + Secret in Settings first."; return
        }
        spotifyDetail = pl; activeView = .spotifyDetail; spotifyLoading = true
        Task {
            do {
                let full = try await client.playlist(id: pl.id)
                if let i = self.spotifyPlaylists.firstIndex(where: { $0.id == pl.id }) { self.spotifyPlaylists[i] = full }
                self.spotifyDetail = full
            } catch {
                self.spotifyError = "Spotify: \(error.localizedDescription)"
            }
            self.spotifyLoading = false
        }
    }


    func spotifyOwnership(_ pl: SpotifyPlaylist) -> (owned: Int, total: Int, missing: [SpotifyTrack]) {
        var owned = 0; var missing: [SpotifyTrack] = []
        for tr in pl.tracks { if isOwnedSpotify(tr) { owned += 1 } else { missing.append(tr) } }
        return (owned, pl.tracks.count, missing)
    }

    func isOwnedSpotify(_ track: SpotifyTrack) -> Bool {
        _ = songs
        if ownedSongID(name: track.title, artist: track.artist, album: track.album, durationSec: track.durationSec) != nil { return true }
        return hasWish(title: track.title, artist: track.artist, downloaded: true)
    }
    func isPendingSpotify(_ track: SpotifyTrack) -> Bool {
        hasWish(title: track.title, artist: track.artist, downloaded: false)
    }

    func addSpotifyTracksToPending(_ tracks: [SpotifyTrack], group: String?) {
        guard let store, !tracks.isEmpty else { return }
        var added = 0
        for t in tracks where !isPendingSpotify(t) && !isOwnedSpotify(t) {
            var w = t.wishItem; w.playlistName = group
            _ = try? store.addWish(w); added += 1
        }
        reload()
        lastMessage = "Added \(added) to Pending\(group.map { " from “\($0)”" } ?? "")."
    }

    func removeSpotifyTracksFromPending(_ tracks: [SpotifyTrack]) {
        guard let store, !tracks.isEmpty else { return }
        let keys = Set(tracks.map { "\($0.title)␟\($0.artist)" })
        for w in wishItems where keys.contains("\(w.title)␟\(w.artist)") {
            if let id = w.id { try? store.deleteWish(id) }
        }
        reload()
        lastMessage = "Removed \(tracks.count) from Pending."
    }

    /// Queue every missing track of a playlist (grouped under its name, so it's recreated once
    /// downloaded — same behavior as the Apple Music path).
    func markSpotifyMissing(_ pl: SpotifyPlaylist) {
        // Spotify publishes its own cover; keep it, or the playlist would fall back to whatever
        // Music.app has under the same name.
        seedPlaylist(pl.name, ownedAssetIDs: ownedAssetIDsSpotify(pl.tracks),
                     source: .spotify, artworkURL: pl.imageURL?.absoluteString)
        addSpotifyTracksToPending(spotifyOwnership(pl).missing, group: pl.name)
    }

    // MARK: YouTube playlist import

    enum YTStatus { case none, pending, inLibrary }

    /// Whether a YouTube video has already been queued/acquired — matched by its video id
    /// appearing in a wish's chosen URL (set when added from here).
    func youtubeStatus(_ c: Candidate) -> YTStatus {
        guard let w = wishItems.first(where: { ($0.chosenURL ?? "").contains(c.videoID) }) else { return .none }
        return w.state == .downloaded ? .inLibrary : .pending
    }

    func loadYouTube(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), trimmed.contains("youtu") else {
            youtubeError = "Paste a YouTube playlist link."; return
        }
        let ytPath = settings.ytDlpPath
        youtubeLoading = true; youtubeError = nil; youtubeEntries = []; youtubeTitle = ""
        Task {
            let result = await Task.detached { () -> (String, [Candidate])? in
                try? YtDlpSource(ytDlpPath: ytPath).playlistEntries(url)
            }.value
            self.youtubeLoading = false
            if let (title, entries) = result, !entries.isEmpty {
                self.youtubeTitle = title; self.youtubeEntries = entries
            } else {
                self.youtubeError = "Couldn't read that playlist. Make sure it's a public YouTube playlist link."
            }
        }
    }

    /// Queue selected YouTube videos to Pending with their source URL pre-chosen, so acquiring
    /// them skips the search step. Titles are cleaned into artist/title for tagging.
    func addYouTubeToPending(_ entries: [Candidate], group: String?) {
        guard let store, !entries.isEmpty else { return }
        // Playlist appears immediately and fills as tracks download.
        if let name = group { _ = ensurePlaylist(name, source: .youtube) }
        var added = 0
        for c in entries where youtubeStatus(c) == .none {
            let parsed = TitleCleaner.parse(c.title)
            let w = WishItem(title: parsed.title, artist: parsed.artist ?? "",
                             durationSec: c.durationSec > 0 ? c.durationSec : nil,
                             source: .custom, state: .wishlist,
                             chosenURL: c.url.absoluteString, playlistName: group)
            _ = try? store.addWish(w); added += 1
        }
        reload()
        lastMessage = "Added \(added) from YouTube to Pending\(group.map { " (\($0))" } ?? "")."
    }

    // MARK: Library health (quality + duplicates)

    /// Bitrate below which a lossy master is considered low quality.
    private let lowBitrateThreshold = 192
    private static let losslessFormats: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape"]

    var spectralVerdicts: [Int64: Bool] = [:]   // songID → passed spectral check (deep scan)
    var healthScanning = false

    private func isLossy(_ s: SongRow) -> Bool { !Self.losslessFormats.contains(s.format.lowercased()) }

    /// Masters that look low quality: a lossy file under the bitrate threshold, or one the deep
    /// spectral scan flagged as a likely re-encode (frequency cutoff too low for its bitrate).
    var lowQualitySongs: [SongRow] {
        songs.filter { s in
            (isLossy(s) && s.kbps > 0 && s.kbps < lowBitrateThreshold) || (spectralVerdicts[s.id] == false)
        }.sorted { $0.kbps < $1.kbps }
    }

    /// Groups of songs that are almost certainly the same recording (same normalized title +
    /// artist), imported more than once.
    var duplicateGroups: [[SongRow]] {
        var map: [String: [SongRow]] = [:]
        for s in songs {
            let key = AppleMusicCompare.normalize(s.title) + "␟" + AppleMusicCompare.normalize(s.artist)
            map[key, default: []].append(s)
        }
        return map.values.filter { $0.count > 1 }
            .map { $0.sorted { qualityRank($0) > qualityRank($1) } }   // best first
            .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
    }

    /// Higher = better: lossless beats lossy, then higher bitrate, then bigger file.
    private func qualityRank(_ s: SongRow) -> Double {
        (Self.losslessFormats.contains(s.format.lowercased()) ? 1_000_000 : 0)
            + Double(s.kbps) * 100 + Double(s.sizeBytes) / 1_000_000
    }

    var healthIssueCount: Int { lowQualitySongs.count + duplicateGroups.count }

    /// Queue a better-quality re-acquire for a low-quality track (opens the find-a-source flow).
    func findBetterSource(_ song: SongRow) {
        guard let store else { return }
        let album = song.album == "Unknown Album" ? "" : song.album
        guard let id = try? store.addWish(WishItem(title: song.title, artist: song.artist,
                                                   album: album.isEmpty ? nil : album,
                                                   durationSec: song.durationSec, source: .custom)) else { return }
        reload()
        beginMatch(id)
    }

    /// Remove the redundant copies of a duplicate group, keeping the best one (routes through the
    /// delete confirm dialog so the user chooses Trash vs keep-files).
    func dedupeKeepBest(_ group: [SongRow]) {
        let losers = group.dropFirst().map { $0.id }   // group is best-first
        guard !losers.isEmpty else { return }
        deleteConfirm = Set(losers)
    }

    /// Deep quality scan: run the spectral analyzer over every master (off-main) to catch
    /// re-encodes disguised at a high bitrate. Populates `spectralVerdicts`.
    func scanSpectral() {
        guard !healthScanning else { return }
        let items = songs.map { ($0.id, ($0.path as NSString).expandingTildeInPath, $0.kbps) }
        let ffmpeg = settings.ffmpegPath
        healthScanning = true
        activity = [ActivityTask(label: "Deep quality scan…", progress: 0)]
        Task {
            let verdicts = await Self.spectralScanWork(ffmpeg, items)
            self.spectralVerdicts = verdicts
            self.healthScanning = false
            self.activity = []
            let bad = verdicts.values.filter { !$0 }.count
            self.lastMessage = "Deep scan done — \(bad) track(s) look like re-encodes."
        }
    }

    private nonisolated static func spectralScanWork(_ ffmpeg: String,
                                                     _ items: [(Int64, String, Int)]) async -> [Int64: Bool] {
        await Task.detached {
            let analyzer = SpectralAnalyzer(ffmpegPath: ffmpeg)
            var out: [Int64: Bool] = [:]
            for (id, path, kbps) in items {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let cutoff = try? analyzer.cutoffHz(URL(fileURLWithPath: path)) {
                    out[id] = analyzer.verdict(cutoffHz: cutoff, bitrateKbps: kbps).isGood
                }
            }
            return out
        }.value
    }

    /// Mid-sync state for the offscreen render harness (the real one comes from the engine).
    func seedSyncProgressForRender() {
        syncing = true
        let s = SyncStatus(label: "Transcoding Feel Good Inc. → MP3 192k", fraction: 0.42,
                           done: 10, total: 26, etaSec: 214)
        syncStatus = s
        activity = [ActivityTask(label: "Transcoding Feel Good Inc. → MP3 192k", progress: s.fraction,
                                 detail: s.countsLabel)]
    }

    func seedHealthForRender() {
        // Flag the first couple of songs as spectral re-encodes so the populated state renders.
        for s in songs.prefix(2) { spectralVerdicts[s.id] = false }
    }

    func seedYouTubeForRender() {
        youtubeTitle = "lo-fi beats to code to"
        youtubeEntries = [
            Candidate(videoID: "aaa11111111", url: URL(string: "https://youtu.be/aaa11111111")!, title: "Nujabes - Aruarian Dance", channel: "Hydeout", durationSec: 244),
            Candidate(videoID: "bbb22222222", url: URL(string: "https://youtu.be/bbb22222222")!, title: "Aphex Twin - Xtal (Official Audio)", channel: "Warp", durationSec: 293),
            Candidate(videoID: "ccc33333333", url: URL(string: "https://youtu.be/ccc33333333")!, title: "Frank Ocean - Nights", channel: "blonded", durationSec: 307),
        ]
    }

    func seedSpotifyForRender() {
        if settings.savedSpotifyUsers.isEmpty {
            settings.savedSpotifyUsers = ["emilie.mlx", "glennpmcdonald", "bbcradio1"]
        }
        spotifySignedIn = true
        func tr(_ n: String, _ a: String, _ al: String, _ d: Double) -> SpotifyTrack {
            SpotifyTrack(title: n, artist: a, album: al, durationSec: d)
        }
        let pl = SpotifyPlaylist(id: "PL", name: "friend's roadtrip", owner: "alex", imageURL: nil,
                                 trackCount: 4, tracks: [
                                    tr("Nights", "Frank Ocean", "Blonde", 307),
                                    tr("Xtal", "Aphex Twin", "Selected Ambient Works 85-92", 293),
                                    tr("Windowlicker", "Aphex Twin", "Windowlicker", 363),
                                    tr("Redbone", "Childish Gambino", "Awaken, My Love!", 327)])
        spotifyPlaylists = [pl]; spotifyDetail = pl; spotifySourceLabel = "user: alex"
    }

    func seedAppleMusicForRender() {
        func tr(_ n: String, _ a: String, _ al: String, _ d: Double) -> AppleMusicTrack {
            AppleMusicTrack(name: n, artist: a, album: al, durationSec: d)
        }
        appleMusic = [
            AppleMusicCollection(name: "Blonde", kind: .album, tracks: [
                tr("Nikes", "Frank Ocean", "Blonde", 314), tr("Ivy", "Frank Ocean", "Blonde", 249),
                tr("Self Control", "Frank Ocean", "Blonde", 249), tr("White Ferrari", "Frank Ocean", "Blonde", 248),
                tr("Nights", "Frank Ocean", "Blonde", 307),
            ]),
            AppleMusicCollection(name: "Demon Days", kind: .album, tracks: [
                tr("Feel Good Inc.", "Gorillaz", "Demon Days", 222), tr("Dare", "Gorillaz", "Demon Days", 245),
                tr("El Mañana", "Gorillaz", "Demon Days", 222),
            ]),
            AppleMusicCollection(name: "late night mix", kind: .playlist, tracks: [
                tr("Ivy", "Frank Ocean", "Blonde", 249), tr("Aruarian Dance", "Nujabes", "Departure", 244),
                tr("Peaceland", "Nujabes", "Modal Soul", 201),
            ], cls: "subscription playlist"),
            AppleMusicCollection(name: "chill focus", kind: .playlist, tracks: [
                tr("Avril 14th", "Aphex Twin", "Drukqs", 125), tr("Ivy", "Frank Ocean", "Blonde", 249),
            ], smart: true, cls: "smart playlist"),
        ]
    }

    private nonisolated static func appleMusicWork() async -> ([AppleMusicCollection], String?) {
        await Task.detached {
            do { return (try AppleMusicBridge().playlists(), nil) }
            catch { return ([], "\(error)") }
        }.value
    }
    private nonisolated static func appleMusicAlbumsWork() async -> ([AppleMusicCollection], String?) {
        await Task.detached {
            do { return (try AppleMusicBridge().libraryAlbums(), nil) }
            catch { return ([], "\(error)") }
        }.value
    }
    private nonisolated static func importOneWork(_ importer: Importer, _ url: URL, _ identity: TrackIdentity) async -> Bool {
        await Task.detached { (try? importer.importOne(url, identity: identity, source: .importedLoose)) != nil }.value
    }

    private nonisolated static func searchWork(_ coord: AcquireCoordinator, _ wish: WishItem) async -> Result<[RankedCandidate], Error> {
        await Task.detached {
            do { return .success(try await coord.candidates(for: wish)) }
            catch { return .failure(error) }
        }.value
    }
    private nonisolated static func acquireWork(_ coord: AcquireCoordinator, _ wish: WishItem, _ candidate: Candidate, _ dir: URL) async -> Result<VerifyResult, Error> {
        await Task.detached {
            do { let r = try await coord.acquire(wish, chosen: candidate, art: nil, downloadDir: dir); return .success(r.verify) }
            catch { return .failure(error) }
        }.value
    }
}

func byteLabel(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_000_000
    return String(format: "%.0f MB", mb)
}
