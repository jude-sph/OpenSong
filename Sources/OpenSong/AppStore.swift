import Foundation
import Observation
import OpenSongCore

/// Observable app state. Backs the UI with a real GRDB `LibraryStore` (seeded with
/// sample data on first launch) and wires to the engine services.
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
        case metadata(Int64), settings, importReview
        var id: String {
            switch self {
            case .metadata(let i): return "meta-\(i)"
            case .settings: return "settings"
            case .importReview: return "import"
            }
        }
    }

    // Data
    var songs: [SongRow] = []
    var playlists: [PlaylistRow] = []
    var device = DeviceState()
    var settings = AppSettings()
    var activity: [ActivityTask] = []
    var syncPreview: SyncPreview? = nil

    struct SyncPreview {
        var willAdd: [SongRow]
        var willRemove: [String]
        var upToDate: [SongRow]
        var projectedUsedBytes: Int64
    }

    // Engine
    private var store: LibraryStore?

    init() {
        do { try bootstrap() } catch { print("bootstrap error: \(error)") }
    }

    private func supportDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenSong", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func bootstrap() throws {
        let dbURL = try supportDir().appendingPathComponent("library.sqlite")
        let store = try LibraryStore(dbURL: dbURL)
        self.store = store
        if try store.allAssetsWithIdentity().isEmpty { try seedSampleData(store) }
        reload()
        refreshDevice()
    }

    // MARK: loading

    func reload() {
        guard let store else { return }
        do {
            let pairs = try store.allAssetsWithIdentity()
            let managed = (try? store.deviceTracks(device.connected ? currentUUID : "none")) ?? []
            let onDeviceIDs = Set(managed.map { $0.assetID })
            songs = pairs.compactMap { (asset, ident) in
                guard let id = asset.id else { return nil }
                return SongRow(id: id, title: ident.title, artist: ident.artist,
                               album: effectiveAlbum(ident), durationSec: ident.durationSec,
                               format: asset.format, kbps: asset.bitrateKbps,
                               onDevice: onDeviceIDs.contains(id), track: ident.trackNumber,
                               genre: ident.genre, year: ident.year, path: asset.masterPath,
                               sizeBytes: asset.sizeBytes)
            }.sorted { ($0.artist, $0.album, $0.track ?? 0) < ($1.artist, $1.album, $1.track ?? 0) }

            playlists = try store.allPlaylists().map { pl in
                let items = (try? store.playlistItems(pl.id!)) ?? []
                return PlaylistRow(id: pl.id!, name: pl.name, syncToDevice: pl.syncToDevice,
                                   songIDs: items.compactMap { $0.id })
            }
        } catch { print("reload error: \(error)") }
    }

    private var currentUUID: String = "none"

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

    // MARK: device

    func refreshDevice() {
        if let vol = DeviceDetector.connectedWalkman() {
            currentUUID = vol.uuid
            let cap = (try? vol.capacity()) ?? (totalBytes: device.totalBytes, freeBytes: device.freeBytes)
            device = DeviceState(connected: true, name: "Walkman NW-E394",
                                 totalBytes: cap.totalBytes, freeBytes: cap.freeBytes,
                                 songCount: ((try? DeviceManager(volume: vol).listManagedTracks().count) ?? 0))
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

    /// Build a display-only sync preview from pins/device-playlists vs a simulated device.
    func buildSyncPreview() {
        let desired = Set(playlists.filter { $0.syncToDevice }.flatMap { $0.songIDs })
        let add = songs.filter { desired.contains($0.id) && !$0.onDevice }
        let addBytes = add.reduce(Int64(0)) { $0 + Int64(Double(settings.bitrateKbps) * 1000 / 8 * $1.durationSec) }
        syncPreview = SyncPreview(willAdd: add, willRemove: [],
                                  upToDate: songs.filter { desired.contains($0.id) && $0.onDevice },
                                  projectedUsedBytes: device.usedBytes + addBytes)
    }

    // MARK: mutations

    func togglePlaylistDeviceSync(_ id: Int64) {
        guard let store, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let newVal = !playlists[idx].syncToDevice
        try? store.setPlaylistSync(id, newVal)
        playlists[idx].syncToDevice = newVal
        buildSyncPreview()
    }
}

func byteLabel(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_000_000
    return String(format: "%.0f MB", mb)
}
