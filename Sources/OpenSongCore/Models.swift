import Foundation

/// Where a track's metadata came from — drives whether the MetadataResolver runs and
/// whether the match/download screen shows fields as locked or editable.
public enum MetadataProvenance: String, Codable, Sendable {
    case appleMusic       // authoritative, from Apple Music
    case itunesResolved   // resolved from the iTunes catalog
    case userEdited       // user typed/confirmed
    case unresolved       // messy import / custom, needs resolution
}

/// "What song is this." Resolved once, up front.
public struct TrackIdentity: Codable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    public var artist: String
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?
    public var year: Int?
    public var durationSec: Double
    public var provenance: MetadataProvenance
    public var artworkPath: String?

    public init(id: Int64? = nil, title: String, artist: String, albumArtist: String? = nil,
                album: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                genre: String? = nil, year: Int? = nil, durationSec: Double,
                provenance: MetadataProvenance = .unresolved, artworkPath: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.albumArtist = albumArtist
        self.album = album; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.genre = genre; self.year = year; self.durationSec = durationSec
        self.provenance = provenance; self.artworkPath = artworkPath
    }
}

/// Where the audio file came from.
public enum AudioSource: String, Codable, Sendable {
    case importedLoose
    case adoptedFromDevice
    case downloaded
}

/// "The actual audio." References a TrackIdentity.
public struct AudioAsset: Codable, Equatable, Sendable {
    public var id: Int64?
    public var identityID: Int64
    public var masterPath: String
    public var format: String        // e.g. "mp3", "flac"
    public var bitrateKbps: Int
    public var sampleRate: Int
    public var sizeBytes: Int64
    public var contentHash: String
    public var source: AudioSource

    public init(id: Int64? = nil, identityID: Int64, masterPath: String, format: String,
                bitrateKbps: Int, sampleRate: Int, sizeBytes: Int64, contentHash: String,
                source: AudioSource) {
        self.id = id; self.identityID = identityID; self.masterPath = masterPath
        self.format = format; self.bitrateKbps = bitrateKbps; self.sampleRate = sampleRate
        self.sizeBytes = sizeBytes; self.contentHash = contentHash; self.source = source
    }
}

public struct Playlist: Codable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var syncToDevice: Bool
    public init(id: Int64? = nil, name: String, syncToDevice: Bool = false) {
        self.id = id; self.name = name; self.syncToDevice = syncToDevice
    }
}

public struct PlaylistItem: Codable, Equatable, Sendable {
    public var id: Int64?
    public var playlistID: Int64
    public var assetID: Int64
    public var position: Int
    public init(id: Int64? = nil, playlistID: Int64, assetID: Int64, position: Int) {
        self.id = id; self.playlistID = playlistID; self.assetID = assetID; self.position = position
    }
}

public enum WishSource: String, Codable, Sendable { case custom, appleMusic }
public enum WishState: String, Codable, Sendable { case wishlist, matching, downloaded }

/// A track the user wants to acquire (Phase 2). Identity is known up front; acquisition
/// fulfills it. `assetID` links to the created master once downloaded.
public struct WishItem: Codable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    public var artist: String
    public var album: String?
    public var durationSec: Double?
    public var source: WishSource
    public var state: WishState
    public var chosenURL: String?
    public var assetID: Int64?
    /// When set, this wish belongs to a wishlist "playlist" group (e.g. an Apple Music
    /// playlist) that OpenSong recreates once all its tracks are downloaded.
    public var playlistName: String?
    public init(id: Int64? = nil, title: String, artist: String, album: String? = nil,
                durationSec: Double? = nil, source: WishSource = .custom,
                state: WishState = .wishlist, chosenURL: String? = nil, assetID: Int64? = nil,
                playlistName: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.durationSec = durationSec; self.source = source; self.state = state
        self.chosenURL = chosenURL; self.assetID = assetID; self.playlistName = playlistName
    }
    /// The identity this wish resolves to (for search + metadata stamping).
    public var identity: TrackIdentity {
        TrackIdentity(title: title, artist: artist, albumArtist: artist, album: album,
                      durationSec: durationSec ?? 0,
                      provenance: source == .appleMusic ? .appleMusic : .userEdited)
    }
}

public struct DeviceRecord: Codable, Equatable, Sendable {
    public var id: Int64?
    public var volumeUUID: String
    public var name: String
    public var targetBitrateKbps: Int
    public var targetFormat: String
    public init(id: Int64? = nil, volumeUUID: String, name: String,
                targetBitrateKbps: Int = 192, targetFormat: String = "mp3") {
        self.id = id; self.volumeUUID = volumeUUID; self.name = name
        self.targetBitrateKbps = targetBitrateKbps; self.targetFormat = targetFormat
    }
}

// MARK: - Effective display/path values

/// Album-artist for tree/device placement (compilations use the album artist, not the
/// per-track artist, so they don't scatter). Falls back to artist, then "Unknown Artist".
public func effectiveAlbumArtist(_ i: TrackIdentity) -> String {
    let candidate = (i.albumArtist?.isEmpty == false ? i.albumArtist! : i.artist)
    return candidate.isEmpty ? "Unknown Artist" : candidate
}

public func effectiveAlbum(_ i: TrackIdentity) -> String {
    guard let a = i.album, !a.isEmpty else { return "Unknown Album" }
    return a
}
