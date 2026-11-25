import Foundation
import OpenSongCore

/// UI-facing row models (mirror the design docs' data model).
struct SongRow: Identifiable, Hashable {
    var id: Int64
    var identityID: Int64
    var title: String
    var artist: String
    var album: String
    var durationSec: Double
    var format: String     // "mp3", "flac"
    var kbps: Int
    var onDevice: Bool
    var track: Int?
    var genre: String?
    var year: Int?
    var path: String
    var sizeBytes: Int64
    var addedAt: Double = 0   // Unix time added to the OpenSong library
    /// Artist this song is filed under for album/artist grouping. Set during reload, where
    /// collaboration credits ("Gorillaz & MF DOOM") collapse onto the album's primary artist.
    var albumArtist: String = ""

    /// Grouping artist, falling back to the feat.-stripped credit when not resolved yet.
    var groupArtist: String { albumArtist.isEmpty ? TitleCleaner.baseArtist(artist) : albumArtist }

    var kindLabel: String { "\(format.uppercased()) \(kbps)" }
    var timeLabel: String {
        let s = Int(durationSec.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
    /// Short "date added" label (e.g. "7/24/26"), or "—" if unknown.
    var addedLabel: String {
        guard addedAt > 0 else { return "—" }
        return SongRow.addedFormatter.string(from: Date(timeIntervalSince1970: addedAt))
    }
    private static let addedFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()
}

struct AlbumRow: Identifiable, Hashable {
    var id: String            // "artist␟album"
    var name: String
    var artist: String
    var year: Int?
    var songIDs: [Int64]
}

struct ArtistRow: Identifiable, Hashable {
    var id: String
    var name: String
    var albumCount: Int
    var songCount: Int
}

struct PlaylistRow: Identifiable, Hashable {
    var id: Int64
    var name: String
    var syncToDevice: Bool
    var songIDs: [Int64]
    /// Carried through so the detail view shows the right cover: a name alone doesn't identify a
    /// playlist, and a Spotify import was borrowing the Apple Music cover of a same-named one.
    var source: PlaylistSource = .manual
    var artworkURL: String? = nil
}

enum ActiveView: Hashable {
    case allSongs, albums, artists, health, device, wishlist, appleMusic, appleMusicDetail
    case spotify, spotifyDetail
    case youtube
    case playlist(Int64)
    case match(Int64)
}

enum AMSort: String, CaseIterable { case name = "Name", recent = "Date Added", def = "Default" }

/// Sort order for the Albums grid. `.device` puts fully-synced albums first, then partial ones.
enum AlbumSort: String, CaseIterable { case name = "Name", recent = "Recent", device = "Device" }

/// Whether the Apple Music view is browsing playlists or the library's albums.
enum AMBrowse: String, CaseIterable { case playlists = "Playlists", albums = "Albums" }

/// Column sort for the Songs table. `column == nil` keeps the natural (library) order.
struct SongSort: Equatable {
    enum Column: Hashable { case device, title, artist, album, time, kind, dateAdded }
    var column: Column? = nil
    var ascending: Bool = true

    /// Toggle: first click sorts ascending; clicking the active column flips direction.
    mutating func toggle(_ c: Column) {
        if column == c { ascending.toggle() } else { column = c; ascending = true }
    }
}

struct DeviceState {
    var connected: Bool = false
    var name: String = "Walkman NW-E394"
    var totalBytes: Int64 = 7_363_067_904
    var freeBytes: Int64 = 5_338_390_528
    var usedBytes: Int64 { totalBytes - freeBytes }
    var songCount: Int = 0
    /// Unplugged, but a device has been seen before (remembered, or has `device_track` rows): the
    /// Device screen shows what's on it and lets it be edited offline.
    var known: Bool = false
    /// When it was last connected; nil when connected now, or never recorded.
    var lastSeen: Date? = nil
}

/// What was last seen of a device while it was plugged in, so the Device screen can show it (and
/// plan against its capacity) while it's unplugged. Persisted per device id.
struct RememberedDevice: Codable, Equatable {
    var kind: String            // "walkman" | "shuffle"
    var name: String
    var totalBytes: Int64
    var freeBytes: Int64
    var lastSeen: Date

    var deviceKind: DeviceKind { kind == "shuffle" ? .shuffle : .walkman }
}

/// A playlist that puts a song on the device (it is ticked to sync).
struct DevicePlaylistRef: Hashable, Identifiable {
    var id: Int64
    var name: String
}

/// One song in a Device screen list — on the device, about to be added, or about to be removed —
/// with the reasons it is (or was) wanted there.
struct DeviceSongRow: Identifiable, Hashable {
    /// Unique within its list: the device path for recorded tracks, "asset:<id>" for additions.
    var id: String
    var assetID: Int64
    /// The library song; nil when the asset has since been deleted from the library.
    var song: SongRow?
    var title: String
    var artist: String
    var pinned: Bool
    var viaPlaylists: [DevicePlaylistRef]
    /// On the device but queued for removal by the next sync.
    var pendingRemoval: Bool = false
    /// A removal that only happens because the same song is being re-sent under a new path.
    var replaced: Bool = false
    var sizeBytes: Int64 = 0

    var wanted: Bool { pinned || !viaPlaylists.isEmpty }
    /// "Pinned · via late night · via bangers" — why the song is on the device.
    var reasonLabels: [String] {
        (pinned ? ["Pinned"] : []) + viaPlaylists.map { "via \($0.name)" }
    }
}

/// The Device screen's model: what's recorded on the device, and the diff the next sync applies.
/// Built from the live plan when the device is mounted, else from the offline plan (the recorded
/// rows + remembered capacity).
struct SyncPreview {
    var onDevice: [DeviceSongRow]
    var willAdd: [DeviceSongRow]
    /// On the device already, but out of date (master edited, bitrate/recipe changed) — re-sent.
    var willUpdate: [DeviceSongRow]
    var willRemove: [DeviceSongRow]
    var upToDateCount: Int
    var projectedUsedBytes: Int64

    var pendingCount: Int { willAdd.count + willUpdate.count + willRemove.count }
}

struct AppSettings: Codable {
    var libraryPath: String = "~/Music/OpenSong Library"
    var deviceFormat: String = "mp3"      // MP3 or AAC only (device constraint)
    var bitrateKbps: Int = 192
    var loudnessNormalize: Bool = true
    var ytDlpPath: String = "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp"
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    var aiCleanup: Bool = true
    var qualityCheck: Bool = true
    var searchLimit: Int = 8
    var spotifyClientID: String = ""
    var spotifyClientSecret: String = ""
    /// Spotify users worth coming back to, newest first (see `SpotifyBookmarks`).
    var savedSpotifyUsers: [String] = []
    /// Must match a Redirect URI registered on the Spotify app exactly, so it is editable: an app
    /// may already have one registered, and Spotify's only complaint is "Not matching configuration".
    var spotifyRedirectURI: String = SpotifyAuth.defaultRedirectURI
    var shuffleVoiceOver: Bool = true   // generate spoken track/playlist names for iPod Shuffle
}

/// Which kind of device is currently connected (they sync completely differently).
enum DeviceKind: Equatable { case none, walkman, shuffle }

struct ActivityTask: Identifiable {
    var id = UUID()
    var label: String
    var progress: Double   // 0...1
    var detail: String = ""   // second line, e.g. "12/48 · about 3 min left"
}

/// Live state of a running device sync, for the Device screen's progress panel.
struct SyncStatus {
    var label: String        // current step ("Transcoding Feel Good Inc. → MP3 192k")
    var fraction: Double     // 0…1
    var done: Int
    var total: Int
    var etaSec: Double?      // nil until there's enough progress to extrapolate

    /// "12 of 48 · about 3 min left" — the counts/ETA line.
    var countsLabel: String {
        var parts: [String] = []
        if total > 0 { parts.append("\(min(done + 1, total)) of \(total)") }
        if let eta = etaSec { parts.append("about \(SyncStatus.durationLabel(eta)) left") }
        return parts.joined(separator: " · ")
    }

    static func durationLabel(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        if s < 60 { return "\(max(1, s))s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%dh %dm", s / 3600, (s % 3600) / 60)
    }
}
