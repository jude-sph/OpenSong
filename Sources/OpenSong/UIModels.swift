import Foundation

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

    var kindLabel: String { "\(format.uppercased()) \(kbps)" }
    var timeLabel: String {
        let s = Int(durationSec.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
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
}

enum ActiveView: Hashable {
    case allSongs, albums, artists, device, wishlist, appleMusic
    case playlist(Int64)
    case match(Int64)
}

struct DeviceState {
    var connected: Bool = false
    var name: String = "Walkman NW-E394"
    var totalBytes: Int64 = 7_363_067_904
    var freeBytes: Int64 = 5_338_390_528
    var usedBytes: Int64 { totalBytes - freeBytes }
    var songCount: Int = 0
}

struct AppSettings: Codable {
    var libraryPath: String = "~/Music/OpenSong Library"
    var deviceFormat: String = "mp3"      // MP3 or AAC only (device constraint)
    var bitrateKbps: Int = 192
    var loudnessNormalize: Bool = true
    var ytDlpPath: String = "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp"
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    var aiCleanup: Bool = true
    var fingerprint: Bool = true
    var qualityCheck: Bool = true
    var acoustidAPIKey: String = ""
    var searchLimit: Int = 8
}

struct ActivityTask: Identifiable {
    var id = UUID()
    var label: String
    var progress: Double   // 0...1
}
