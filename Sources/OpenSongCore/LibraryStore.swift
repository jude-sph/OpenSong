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
            let assets = try AudioAsset.order(Column("id")).fetchAll(db)
            var result: [(AudioAsset, TrackIdentity)] = []
            for a in assets {
                if let ident = try TrackIdentity.filter(key: a.identityID).fetchOne(db) {
                    result.append((a, ident))
                }
            }
            return result
        }
    }

    public func findAssetByHash(_ hash: String) throws -> AudioAsset? {
        try dbQueue.read { db in
            try AudioAsset.filter(Column("contentHash") == hash).fetchOne(db)
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
    public func createPlaylist(name: String, syncToDevice: Bool) throws -> Int64 {
        try dbQueue.write { db in
            var p = Playlist(name: name, syncToDevice: syncToDevice)
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
            let items = try PlaylistItem
                .filter(Column("playlistID") == playlistID)
                .order(Column("position"))
                .fetchAll(db)
            var assets: [AudioAsset] = []
            for it in items {
                if let a = try AudioAsset.filter(key: it.assetID).fetchOne(db) { assets.append(a) }
            }
            return assets
        }
    }

    public func devicePlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try Playlist.filter(Column("syncToDevice") == true).order(Column("name")).fetchAll(db)
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
