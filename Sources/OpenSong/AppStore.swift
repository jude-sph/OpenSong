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
    var filterAlbumID: String? = nil

    enum Sheet: Identifiable, Equatable {
        case metadata(Int64), settings, importReview, addWish
        var id: String {
            switch self {
            case .metadata(let i): return "meta-\(i)"
            case .settings: return "settings"
            case .importReview: return "import"
            case .addWish: return "addWish"
            }
        }
    }

    // Data
    var songs: [SongRow] = []
    var playlists: [PlaylistRow] = []
    var device = DeviceState()
    var settings = AppSettings() { didSet { persistSettings(); rebuildEngines() } }
    var activity: [ActivityTask] = []
    var syncPreview: SyncPreview? = nil
    var syncing = false
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
    enum MatchStep: Equatable { case loading, results, downloading, done, error }

    struct SyncPreview {
        var willAdd: [SongRow]
        var willRemove: [String]
        var upToDate: [SongRow]
        var projectedUsedBytes: Int64
    }

    struct ImportRow: Identifiable {
        let id = UUID()
        var candidate: ImportCandidate
        var useSuggested: Bool
        var include: Bool = true
        var chosen: TrackIdentity {
            (useSuggested ? candidate.suggested : nil) ?? candidate.original
        }
    }

    // Engines
    private var store: LibraryStore?
    private var probe = AudioProbe()
    private var transcoder = Transcoder()
    private var resolver = MetadataResolver()
    private var importer: Importer?
    private var currentUUID: String = "none"

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
            songs = pairs.compactMap { (asset, ident) in
                guard let id = asset.id else { return nil }
                return SongRow(id: id, identityID: asset.identityID, title: ident.title,
                               artist: ident.artist, album: effectiveAlbum(ident),
                               durationSec: ident.durationSec, format: asset.format,
                               kbps: asset.bitrateKbps, onDevice: onDeviceIDs.contains(id),
                               track: ident.trackNumber, genre: ident.genre, year: ident.year,
                               path: asset.masterPath, sizeBytes: asset.sizeBytes)
            }.sorted { ($0.artist, $0.album, $0.track ?? 0) < ($1.artist, $1.album, $1.track ?? 0) }

            playlists = try store.allPlaylists().map { pl in
                let items = (try? store.playlistItems(pl.id!)) ?? []
                return PlaylistRow(id: pl.id!, name: pl.name, syncToDevice: pl.syncToDevice,
                                   songIDs: items.compactMap { $0.id })
            }
            wishItems = try store.allWishes()
        } catch { print("reload error: \(error)") }
    }

    // MARK: derived collections

    var filteredSongs: [SongRow] {
        var rows = songs
        if let albumID = filterAlbumID {
            rows = rows.filter { "\($0.artist)␟\($0.album)" == albumID }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
                    || $0.album.lowercased().contains(q)
            }
        }
        return rows
    }

    var albums: [AlbumRow] {
        var map: [String: AlbumRow] = [:]
        for s in songs {
            let id = "\(s.artist)␟\(s.album)"
            if var a = map[id] { a.songIDs.append(s.id); map[id] = a }
            else { map[id] = AlbumRow(id: id, name: s.album, artist: s.artist, year: s.year, songIDs: [s.id]) }
        }
        return map.values.sorted { ($0.artist, $0.name) < ($1.artist, $1.name) }
    }

    var artists: [ArtistRow] {
        var albumSet: [String: Set<String>] = [:]
        var songCount: [String: Int] = [:]
        for s in songs {
            albumSet[s.artist, default: []].insert(s.album)
            songCount[s.artist, default: 0] += 1
        }
        return albumSet.keys.sorted().map {
            ArtistRow(id: $0, name: $0, albumCount: albumSet[$0]!.count, songCount: songCount[$0]!)
        }
    }

    func song(_ id: Int64) -> SongRow? { songs.first { $0.id == id } }

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
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        activity = [ActivityTask(label: "Scanning \(urls.count) location(s)…", progress: 0)]
        Task { await scanAndReview(urls) }
    }

    private func scanAndReview(_ urls: [URL]) async {
        guard let importer else { importing = false; activity = []; return }
        var candidates: [ImportCandidate] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
            candidates += (try? importer.scanLoose(folder)) ?? []
        }
        activity = [ActivityTask(label: "Resolving metadata for \(candidates.count) track(s)…", progress: 0.5)]
        await importer.resolveSuggestions(&candidates)
        importRows = candidates.map { ImportRow(candidate: $0, useSuggested: $0.suggested != nil) }
        importing = false
        activity = []
        if importRows.isEmpty {
            lastMessage = "No audio files found in the chosen location(s)."
        } else {
            openSheet = .importReview
        }
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
            currentUUID = vol.uuid
            let cap = (try? vol.capacity()) ?? (totalBytes: device.totalBytes, freeBytes: device.freeBytes)
            device = DeviceState(connected: true, name: "Walkman NW-E394",
                                 totalBytes: cap.totalBytes, freeBytes: cap.freeBytes,
                                 songCount: ((try? DeviceManager(volume: vol).listManagedTracks().count) ?? 0))
            buildSyncPreview()
        } else {
            device.connected = false
        }
        reload()
    }

    func simulateDevice() {
        device = DeviceState(connected: true, name: "Walkman NW-E394 (simulated)",
                             totalBytes: 7_363_067_904, freeBytes: 5_338_390_528, songCount: 0)
        buildSyncPreview()
    }

    /// Real diff preview from the sync engine when a device is present; else a display estimate.
    func buildSyncPreview() {
        guard let store else { return }
        if let vol = DeviceDetector.connectedWalkman() {
            let engine = SyncEngine(store: store, transcoder: transcoder,
                                    device: DeviceManager(volume: vol),
                                    settings: transcodeSettings, deviceUUID: vol.uuid)
            if let plan = try? engine.plan() {
                syncPreview = SyncPreview(
                    willAdd: plan.toAdd.compactMap { asset in songs.first { $0.id == asset.id } },
                    willRemove: plan.toRemove,
                    upToDate: plan.upToDate.compactMap { asset in songs.first { $0.id == asset.id } },
                    projectedUsedBytes: plan.projectedUsedBytes)
                return
            }
        }
        // Fallback (simulated/no device): estimate from device-flagged playlists + pins.
        let desired = Set(playlists.filter { $0.syncToDevice }.flatMap { $0.songIDs })
        let add = songs.filter { desired.contains($0.id) && !$0.onDevice }
        let addBytes = add.reduce(Int64(0)) { $0 + Int64(Double(settings.bitrateKbps) * 1000 / 8 * $1.durationSec) }
        syncPreview = SyncPreview(willAdd: add, willRemove: [],
                                  upToDate: songs.filter { desired.contains($0.id) && $0.onDevice },
                                  projectedUsedBytes: device.usedBytes + addBytes)
    }

    func runSync() {
        guard !syncing, let store else { return }
        guard let vol = DeviceDetector.connectedWalkman() else { device.connected = false; return }
        let engine = SyncEngine(store: store, transcoder: transcoder,
                                device: DeviceManager(volume: vol),
                                settings: transcodeSettings, deviceUUID: vol.uuid)
        syncing = true
        activity = [ActivityTask(label: "Syncing to Walkman…", progress: 0)]
        Task {
            let error = await Self.syncWork(engine)
            self.finishSync(error)
        }
    }

    private nonisolated static func syncWork(_ engine: SyncEngine) async -> String? {
        await Task.detached {
            do { try engine.apply(try engine.plan()); return nil }
            catch { return "\(error)" }
        }.value
    }

    private func finishSync(_ error: String?) {
        syncing = false
        activity = []
        lastMessage = error.map { "Sync failed: \($0)" } ?? "Sync complete."
        refreshDevice()
    }

    // MARK: mutations

    func togglePlaylistDeviceSync(_ id: Int64) {
        guard let store, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let newVal = !playlists[idx].syncToDevice
        try? store.setPlaylistSync(id, newVal)
        playlists[idx].syncToDevice = newVal
        buildSyncPreview()
    }

    func pin(_ songID: Int64, _ pinned: Bool) {
        try? store?.pin(assetID: songID, pinned)
        buildSyncPreview()
        reload()
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
        if FileManager.default.fileExists(atPath: url.path), url.pathExtension.lowercased() == "mp3" {
            try? transcoder.writeTags(url, ident)
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

    func addCustomWish(title: String, artist: String, album: String) {
        guard let store, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.addWish(WishItem(title: title, artist: artist,
                                        album: album.isEmpty ? nil : album, source: .custom))
        reload()
    }

    func deleteWish(_ id: Int64) { try? store?.deleteWish(id); reload() }

    private func buildCoordinator() throws -> AcquireCoordinator {
        guard let store, let importer else { throw NSError(domain: "OpenSong", code: 1) }
        return AcquireCoordinator(
            store: store,
            source: YtDlpSource(ytDlpPath: settings.ytDlpPath),
            importer: importer,
            artwork: ArtworkResolver(ffmpegPath: settings.ffmpegPath),
            spectral: SpectralAnalyzer(ffmpegPath: settings.ffmpegPath),
            fingerprinter: Fingerprinter(),
            acoustid: AcoustIDClient(),
            probe: probe,
            settings: AcquireSettings(acoustidAPIKey: settings.acoustidAPIKey, searchLimit: settings.searchLimit))
    }

    private func downloadDir() throws -> URL {
        let d = try supportDir().appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func beginMatch(_ wishID: Int64) {
        guard let wish = wishItems.first(where: { $0.id == wishID }) else { return }
        matchWishID = wishID
        activeView = .match(wishID)
        matchStep = .loading
        matchCandidates = []; matchVerify = nil; selectedCandidateID = nil
        var w = wish; w.state = .matching; try? store?.updateWish(w); reload()
        guard let coord = try? buildCoordinator() else { matchStep = .error; return }
        Task {
            switch await Self.searchWork(coord, wish) {
            case .success(let ranked):
                self.matchCandidates = ranked
                self.selectedCandidateID = ranked.first?.id
                self.matchStep = ranked.isEmpty ? .error : .results
            case .failure:
                self.matchStep = .error
            }
        }
    }

    func acquireSelected() {
        guard let wishID = matchWishID,
              let wish = wishItems.first(where: { $0.id == wishID }),
              let candID = selectedCandidateID,
              let ranked = matchCandidates.first(where: { $0.id == candID }),
              let coord = try? buildCoordinator(),
              let dir = try? downloadDir() else { matchStep = .error; return }
        matchStep = .downloading
        let candidate = ranked.candidate
        Task {
            switch await Self.acquireWork(coord, wish, candidate, dir) {
            case .success(let v):
                self.matchVerify = v; self.matchStep = .done; self.reload()
            case .failure:
                self.matchStep = .error
            }
        }
    }

    func pasteCustomURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
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
