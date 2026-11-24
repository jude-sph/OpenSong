import Foundation
import GRDB

// GRDB record conformances (kept here so Models.swift stays persistence-agnostic).
extension TrackIdentity: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track_identity"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
extension AudioAsset: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audio_asset"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
extension Playlist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
extension PlaylistItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
extension DeviceRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "device"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
extension WishItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "wish_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Per-device record of a track OpenSong has placed on the device: where it sits, at
/// what bitrate, and the master content hash at transfer time (to detect staleness).
public struct DeviceTrackRow: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "device_track"
    public var id: Int64?
    public var deviceUUID: String
    public var relativePath: String
    public var assetID: Int64
    public var transcodedBitrate: Int
    public var contentHash: String
    public var sizeBytes: Int64
    /// How this copy was produced (`TranscodeSettings.deviceRecipe`). When the recipe changes —
    /// a different bitrate, or a fix to how cover art is written — the file is stale even though
    /// the master hasn't moved, and the next sync rebuilds it.
    public var recipe: String
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public init(id: Int64? = nil, deviceUUID: String, relativePath: String, assetID: Int64,
                transcodedBitrate: Int, contentHash: String, sizeBytes: Int64, recipe: String = "") {
        self.id = id; self.deviceUUID = deviceUUID; self.relativePath = relativePath
        self.assetID = assetID; self.transcodedBitrate = transcodedBitrate
        self.contentHash = contentHash; self.sizeBytes = sizeBytes; self.recipe = recipe
    }
}

/// The SQLite index over the master library. Source of truth for metadata, playlists,
/// pins, and device records.
public final class LibraryStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbURL: URL) throws {
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "track_identity") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumArtist", .text)
                t.column("album", .text)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("durationSec", .double).notNull()
                t.column("provenance", .text).notNull()
                t.column("artworkPath", .text)
            }
            try db.create(table: "audio_asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identityID", .integer).notNull()
                    .references("track_identity", onDelete: .cascade)
                t.column("masterPath", .text).notNull()
                t.column("format", .text).notNull()
                t.column("bitrateKbps", .integer).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("contentHash", .text).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("syncToDevice", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "playlist_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistID", .integer).notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("assetID", .integer).notNull()
                    .references("audio_asset", onDelete: .cascade)
                t.column("position", .integer).notNull()
            }
            try db.create(table: "pinned_asset") { t in
                t.column("assetID", .integer).notNull().unique()
                    .references("audio_asset", onDelete: .cascade)
            }
            try db.create(table: "device") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("volumeUUID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("targetBitrateKbps", .integer).notNull().defaults(to: 192)
                t.column("targetFormat", .text).notNull().defaults(to: "mp3")
            }
        }
        m.registerMigration("v2-device-track") { db in
            try db.create(table: "device_track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("deviceUUID", .text).notNull()
                t.column("relativePath", .text).notNull()
                t.column("assetID", .integer).notNull()
                t.column("transcodedBitrate", .integer).notNull()
                t.column("contentHash", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.uniqueKey(["deviceUUID", "relativePath"])
            }
        }
        m.registerMigration("v3-wishlist") { db in
            try db.create(table: "wish_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text)
                t.column("durationSec", .double)
                t.column("source", .text).notNull()
                t.column("state", .text).notNull()
                t.column("chosenURL", .text)
                t.column("assetID", .integer)
            }
        }
        m.registerMigration("v4-wish-playlist") { db in
            try db.alter(table: "wish_item") { t in
                t.add(column: "playlistName", .text)
            }
        }
        m.registerMigration("v5-asset-addedAt") { db in
            try db.alter(table: "audio_asset") { t in
                t.add(column: "addedAt", .double).notNull().defaults(to: 0)
            }
            // Backfill existing rows from the master file's creation date (fallback: now), so
            // "Date Added" sort is meaningful for a library that predates this column.
            let now = Date().timeIntervalSince1970
            for row in try Row.fetchAll(db, sql: "SELECT id, masterPath FROM audio_asset") {
                let id: Int64 = row["id"]
                let path = ((row["masterPath"] as String) as NSString).expandingTildeInPath
                let created = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
                    .flatMap { $0 }?.timeIntervalSince1970 ?? now
                try db.execute(sql: "UPDATE audio_asset SET addedAt = ? WHERE id = ?", arguments: [created, id])
            }
        }
        m.registerMigration("v6-wish-track-disc") { db in
            try db.alter(table: "wish_item") { t in
                t.add(column: "trackNumber", .integer)
                t.add(column: "discNumber", .integer)
            }
        }
        // How the device copy was produced (format/bitrate/loudness/artwork). Rows written before
        // this get "", which never matches the current recipe — so the first sync after an upgrade
        // rebuilds them, which is exactly what a recipe change is supposed to do.
        m.registerMigration("v7-device-track-recipe") { db in
            try db.alter(table: "device_track") { t in
                t.add(column: "recipe", .text).notNull().defaults(to: "")
            }
        }
        // Where a playlist came from, and its own cover. Existing rows get "manual", which shows a
        // gradient rather than borrowing a same-named cover from Music.app.
        m.registerMigration("v9-playlist-source") { db in
            try db.alter(table: "playlist") { t in
                t.add(column: "source", .text).notNull().defaults(to: PlaylistSource.manual.rawValue)
                t.add(column: "artworkURL", .text)
            }
        }
        // A wish that exists to replace a track already in the library.
        m.registerMigration("v8-wish-replaces") { db in
            try db.alter(table: "wish_item") { t in
                t.add(column: "replacesAssetID", .integer)
            }
        }
        return m
    }

    // MARK: identities & assets

    @discardableResult
    public func upsertIdentity(_ identity: TrackIdentity) throws -> Int64 {
        try dbQueue.write { db in
            var i = identity
            if i.id != nil { try i.update(db); return i.id! }
            try i.insert(db); return i.id!
        }
    }

    @discardableResult
    public func insertAsset(_ asset: AudioAsset) throws -> Int64 {
        try dbQueue.write { db in
            var a = asset
            try a.insert(db); return a.id!
        }
    }

    public func allAssetsWithIdentity() throws -> [(AudioAsset, TrackIdentity)] {
        try dbQueue.read { db in
            // Two queries joined in memory, rather than one identity lookup per asset.
            let assets = try AudioAsset.order(Column("id")).fetchAll(db)
            let idents = try Self.identitiesByID(db)
            return assets.compactMap { a in idents[a.identityID].map { (a, $0) } }
        }
    }

    private static func identitiesByID(_ db: Database) throws -> [Int64: TrackIdentity] {
        var out: [Int64: TrackIdentity] = [:]
        for i in try TrackIdentity.fetchAll(db) { if let id = i.id { out[id] = i } }
        return out
    }

    /// Every identity keyed by id — for callers that would otherwise call `identity(_:)` in a loop.
    public func allIdentitiesByID() throws -> [Int64: TrackIdentity] {
        try dbQueue.read { db in try Self.identitiesByID(db) }
    }

    /// Each playlist's asset ids in playlist order, in one query.
    public func allPlaylistAssetIDs() throws -> [Int64: [Int64]] {
        try dbQueue.read { db in
            var out: [Int64: [Int64]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT playlist_item.playlistID, playlist_item.assetID FROM playlist_item
                JOIN audio_asset ON audio_asset.id = playlist_item.assetID
                ORDER BY playlist_item.playlistID, playlist_item.position
            """)
            for r in rows { out[r[0] as Int64, default: []].append(r[1] as Int64) }
            return out
        }
    }

    public func findAssetByHash(_ hash: String) throws -> AudioAsset? {
        try dbQueue.read { db in
            try AudioAsset.filter(Column("contentHash") == hash).fetchOne(db)
        }
    }

    public func assetsForIdentity(_ identityID: Int64) throws -> [AudioAsset] {
        try dbQueue.read { db in
            try AudioAsset.filter(Column("identityID") == identityID).fetchAll(db)
        }
    }

    public func updateAsset(_ asset: AudioAsset) throws {
        try dbQueue.write { db in try asset.update(db) }
    }

    public func asset(_ id: Int64) throws -> AudioAsset? {
        try dbQueue.read { db in try AudioAsset.filter(key: id).fetchOne(db) }
    }

    /// Delete an asset (cascades playlist items + pins) and its now-orphaned identity if
    /// no other asset references it. Also clears any device_track rows for it.
    public func deleteAsset(_ id: Int64) throws {
        try dbQueue.write { db in
            let identityID = try AudioAsset.filter(key: id).fetchOne(db)?.identityID
            try db.execute(sql: "DELETE FROM device_track WHERE assetID = ?", arguments: [id])
            _ = try AudioAsset.deleteOne(db, key: id)
            if let identityID,
               try AudioAsset.filter(Column("identityID") == identityID).fetchCount(db) == 0 {
                _ = try TrackIdentity.deleteOne(db, key: identityID)
            }
        }
    }

    // MARK: playlist editing

    public func removePlaylistItem(playlistID: Int64, assetID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM playlist_item WHERE playlistID = ? AND assetID = ?",
                           arguments: [playlistID, assetID])
        }
    }
    public func deletePlaylist(_ id: Int64) throws {
        _ = try dbQueue.write { db in try Playlist.deleteOne(db, key: id) }
    }
    public func renamePlaylist(_ id: Int64, name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }
    /// Next free position at the end of a playlist.
    public func nextPlaylistPosition(_ playlistID: Int64) throws -> Int {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playlist_item WHERE playlistID = ?",
                              arguments: [playlistID]) ?? -1) + 1
        }
    }
    public func playlistContains(_ playlistID: Int64, assetID: Int64) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlistID = ? AND assetID = ?",
                             arguments: [playlistID, assetID]) ?? 0 > 0
        }
    }
    /// Rewrite a playlist's items in the given asset-id order (for reordering).
    public func setPlaylistOrder(_ playlistID: Int64, assetIDs: [Int64]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM playlist_item WHERE playlistID = ?", arguments: [playlistID])
            for (i, aid) in assetIDs.enumerated() {
                var item = PlaylistItem(playlistID: playlistID, assetID: aid, position: i)
                try item.insert(db)
            }
        }
    }

    public func findIdentity(title: String, artist: String, album: String?) throws -> TrackIdentity? {
        try dbQueue.read { db in
            let candidates = try TrackIdentity
                .filter(Column("title") == title && Column("artist") == artist)
                .fetchAll(db)
            return candidates.first(where: { $0.album == album }) ?? candidates.first
        }
    }

    // MARK: playlists

    @discardableResult
    public func createPlaylist(name: String, syncToDevice: Bool,
                               source: PlaylistSource = .manual,
                               artworkURL: String? = nil) throws -> Int64 {
        try dbQueue.write { db in
            var p = Playlist(name: name, syncToDevice: syncToDevice,
                             source: source, artworkURL: artworkURL)
            try p.insert(db); return p.id!
        }
    }

    public func addToPlaylist(playlistID: Int64, assetID: Int64, position: Int) throws {
        try dbQueue.write { db in
            var item = PlaylistItem(playlistID: playlistID, assetID: assetID, position: position)
            try item.insert(db)
        }
    }

    public func playlistItems(_ playlistID: Int64) throws -> [AudioAsset] {
        try dbQueue.read { db in
            try AudioAsset.fetchAll(db, sql: """
                SELECT audio_asset.* FROM playlist_item
                JOIN audio_asset ON audio_asset.id = playlist_item.assetID
                WHERE playlist_item.playlistID = ?
                ORDER BY playlist_item.position
            """, arguments: [playlistID])
        }
    }

    public func devicePlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try Playlist.filter(Column("syncToDevice") == true).order(Column("name")).fetchAll(db)
        }
    }

    public func allPlaylists() throws -> [Playlist] {
        try dbQueue.read { db in try Playlist.order(Column("name")).fetchAll(db) }
    }

    /// Record where a playlist came from (used to backfill rows that predate the column).
    public func setPlaylistSource(_ id: Int64, _ source: PlaylistSource,
                                  artworkURL: String? = nil) throws {
        try dbQueue.write { db in
            if let url = artworkURL {
                try db.execute(sql: "UPDATE playlist SET source = ?, artworkURL = ? WHERE id = ?",
                               arguments: [source.rawValue, url, id])
            } else {
                try db.execute(sql: "UPDATE playlist SET source = ? WHERE id = ?",
                               arguments: [source.rawValue, id])
            }
        }
    }

    public func setPlaylistSync(_ id: Int64, _ sync: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlist SET syncToDevice = ? WHERE id = ?",
                           arguments: [sync, id])
        }
    }

    // MARK: pins

    public func pin(assetID: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            if pinned {
                try db.execute(sql: "INSERT OR IGNORE INTO pinned_asset(assetID) VALUES (?)",
                               arguments: [assetID])
            } else {
                try db.execute(sql: "DELETE FROM pinned_asset WHERE assetID = ?", arguments: [assetID])
            }
        }
    }

    public func pinnedAssets() throws -> [AudioAsset] {
        try dbQueue.read { db in
            try AudioAsset.fetchAll(db, sql: """
                SELECT audio_asset.* FROM audio_asset
                JOIN pinned_asset ON pinned_asset.assetID = audio_asset.id
                ORDER BY audio_asset.id
            """)
        }
    }

    public func identity(_ id: Int64) throws -> TrackIdentity? {
        try dbQueue.read { db in try TrackIdentity.filter(key: id).fetchOne(db) }
    }

    // MARK: device_track state

    public func deviceTracks(_ uuid: String) throws -> [DeviceTrackRow] {
        try dbQueue.read { db in
            try DeviceTrackRow.filter(Column("deviceUUID") == uuid)
                .order(Column("relativePath")).fetchAll(db)
        }
    }

    /// The device most of the managed-track rows belong to. Lets the library keep showing what's on
    /// the device when none is plugged in — including on an install that has never yet seen it
    /// connected, where there's no remembered id to fall back on.
    public func primaryDeviceUUID() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT deviceUUID FROM device_track GROUP BY deviceUUID
                ORDER BY COUNT(*) DESC LIMIT 1
                """)
        }
    }

    public func setDeviceTrack(_ row: DeviceTrackRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM device_track WHERE deviceUUID = ? AND relativePath = ?",
                           arguments: [row.deviceUUID, row.relativePath])
            var r = row; r.id = nil
            try r.insert(db)
        }
    }

    public func deleteDeviceTrack(_ uuid: String, relativePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM device_track WHERE deviceUUID = ? AND relativePath = ?",
                           arguments: [uuid, relativePath])
        }
    }

    /// Re-key managed-track rows from a stale device id onto `uuid` when the file they describe is
    /// actually present on this device. Needed because FAT32 volume UUIDs aren't stable (see
    /// `DeviceIdentity`): without it, a remount under a new UUID orphans every row, the library
    /// shows nothing as on-device, and the next sync recopies the whole device. Returns the number
    /// of rows adopted.
    @discardableResult
    public func adoptDeviceTracks(uuid: String, presentPaths: Set<String>) throws -> Int {
        guard !presentPaths.isEmpty else { return 0 }
        // Compare in NFC: the device hands back decomposed names (see `DeviceManager`), and older
        // rows may have been written either way.
        let present = Set(presentPaths.map { $0.precomposedStringWithCanonicalMapping })
        return try dbQueue.write { db in
            // Bring this device's own rows into NFC first, so the duplicate check below is exact.
            for var row in try DeviceTrackRow.filter(Column("deviceUUID") == uuid).fetchAll(db) {
                let nfc = row.relativePath.precomposedStringWithCanonicalMapping
                guard nfc != row.relativePath else { continue }
                row.relativePath = nfc
                try? row.update(db)
            }
            let stale = try DeviceTrackRow.filter(Column("deviceUUID") != uuid).fetchAll(db)
            var adopted = 0
            for var row in stale {
                let path = row.relativePath.precomposedStringWithCanonicalMapping
                guard present.contains(path) else { continue }
                // A row already keyed to this device wins; the stale duplicate is dropped.
                let claimed = try DeviceTrackRow
                    .filter(Column("deviceUUID") == uuid && Column("relativePath") == path)
                    .fetchCount(db) > 0
                if let id = row.id { _ = try DeviceTrackRow.deleteOne(db, key: id) }
                guard !claimed else { continue }
                row.id = nil; row.deviceUUID = uuid; row.relativePath = path
                try row.insert(db)
                adopted += 1
            }
            return adopted
        }
    }

    /// Mark managed tracks stale so the next sync re-pushes them. Used when the *way* device files
    /// are produced changes (e.g. cover art is now embedded) and the master itself hasn't. Clearing
    /// the stored content hash is enough: `SyncEngine.plan` then treats the file as out of date.
    public static let staleHash = "needs-refresh"

    @discardableResult
    public func invalidateDeviceTracks(uuid: String, assetIDs: Set<Int64>) throws -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var touched = 0
            for var row in try DeviceTrackRow.filter(Column("deviceUUID") == uuid).fetchAll(db)
            where assetIDs.contains(row.assetID) && row.contentHash != Self.staleHash {
                row.contentHash = Self.staleHash
                try row.update(db)
                touched += 1
            }
            return touched
        }
    }

    /// What a replacement changed, for the message shown afterwards.
    public struct ReplacementResult: Sendable, Equatable {
        public var playlists = 0        // playlist entries moved to the new file
        public var wasPinned = false    // the old file was set to go to the device
        public var deviceRows = 0       // device copies marked stale, so the next sync re-sends
        public init() {}
    }

    /// Swap a new asset in for an old one everywhere the library refers to it, then delete the old
    /// row. The caller trashes the old file — the store never touches the filesystem.
    ///
    /// Everything that made the old file *reachable* has to move, or a replacement would silently
    /// drop the track out of its playlists and off the device: playlist entries, the pin that marks
    /// it for syncing, and the device rows (cleared so the next sync re-sends rather than trusting a
    /// hash that now describes a file that no longer exists).
    @discardableResult
    public func replaceAsset(old oldID: Int64, with newID: Int64) throws -> ReplacementResult {
        guard oldID != newID else { return ReplacementResult() }
        return try dbQueue.write { db in
            var result = ReplacementResult()

            // Playlist entries move across, keeping their position — unless the new asset is
            // already in that playlist, in which case the old entry just goes.
            let rows = try PlaylistItem.filter(Column("assetID") == oldID).fetchAll(db)
            for var row in rows {
                let clash = try PlaylistItem
                    .filter(Column("playlistID") == row.playlistID && Column("assetID") == newID)
                    .fetchCount(db) > 0
                if clash {
                    try row.delete(db)
                } else {
                    row.assetID = newID
                    try row.update(db)
                    result.playlists += 1
                }
            }

            // The pin is what puts a track on the device, so it has to follow the replacement.
            // `pinned_asset` has no record type of its own — it is a bare join table.
            let pinned = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pinned_asset WHERE assetID = ?", arguments: [oldID]) ?? 0
            if pinned > 0 {
                result.wasPinned = true
                try db.execute(sql: "DELETE FROM pinned_asset WHERE assetID = ?", arguments: [oldID])
                try db.execute(sql: "INSERT OR IGNORE INTO pinned_asset(assetID) VALUES (?)",
                               arguments: [newID])
            }

            // Any device copy of the old file is now wrong. Clearing the hash marks it stale; the
            // device path comes from the identity, so a same-titled replacement overwrites the file
            // in place and a differently-titled one is removed and re-added.
            for var row in try DeviceTrackRow.filter(Column("assetID") == oldID).fetchAll(db) {
                row.assetID = newID
                row.contentHash = Self.staleHash
                try row.update(db)
                result.deviceRows += 1
            }

            try AudioAsset.deleteOne(db, key: oldID)
            return result
        }
    }

    // MARK: wishlist

    @discardableResult
    public func addWish(_ wish: WishItem) throws -> Int64 {
        try dbQueue.write { db in var w = wish; try w.insert(db); return w.id! }
    }
    public func allWishes() throws -> [WishItem] {
        try dbQueue.read { db in try WishItem.order(Column("id").desc).fetchAll(db) }
    }
    public func updateWish(_ wish: WishItem) throws {
        try dbQueue.write { db in try wish.update(db) }
    }
    public func deleteWish(_ id: Int64) throws {
        _ = try dbQueue.write { db in try WishItem.deleteOne(db, key: id) }
    }

    // MARK: device

    @discardableResult
    public func upsertDevice(_ device: DeviceRecord) throws -> Int64 {
        try dbQueue.write { db in
            if let existing = try DeviceRecord
                .filter(Column("volumeUUID") == device.volumeUUID).fetchOne(db) {
                var updated = device; updated.id = existing.id
                try updated.update(db); return existing.id!
            }
            var d = device
            try d.insert(db); return d.id!
        }
    }
}
