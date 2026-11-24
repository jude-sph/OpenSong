import Foundation

public struct AppleMusicTrack: Sendable, Equatable {
    public var name: String
    public var artist: String
    public var album: String
    public var albumArtist: String   // "" when Music has none (falls back to track artist for grouping)
    public var trackNumber: Int?     // nil when Music reports 0/unknown
    public var discNumber: Int?
    public var durationSec: Double
    public var location: String?    // POSIX path when a local (non-DRM) file exists
    public var isCloud: Bool
    /// When Music says the track was added to the library, as epoch seconds. nil when Music has no
    /// date for it — which happens, so callers must cope rather than substituting "now".
    public var addedAt: Double?
    public init(name: String, artist: String, album: String, albumArtist: String = "",
                trackNumber: Int? = nil, discNumber: Int? = nil,
                durationSec: Double, location: String? = nil, isCloud: Bool = false,
                addedAt: Double? = nil) {
        self.name = name; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.trackNumber = trackNumber; self.discNumber = discNumber
        self.durationSec = durationSec; self.location = location; self.isCloud = isCloud
        self.addedAt = addedAt
    }
    /// The artist to file this track's album under (album artist if known, else track artist).
    public var effectiveAlbumArtist: String { albumArtist.isEmpty ? artist : albumArtist }
    /// The identity this track resolves to (authoritative — everything is already known).
    public var identity: TrackIdentity {
        TrackIdentity(title: name, artist: artist, albumArtist: albumArtist.isEmpty ? artist : albumArtist,
                      album: album.isEmpty ? nil : album, trackNumber: trackNumber, discNumber: discNumber,
                      durationSec: durationSec, provenance: .appleMusic)
    }
    public var wishItem: WishItem {
        WishItem(title: name, artist: artist, album: album.isEmpty ? nil : album,
                 trackNumber: trackNumber, discNumber: discNumber,
                 durationSec: durationSec, source: .appleMusic, state: .wishlist)
    }
    /// Importable when there's a real local file that isn't a cloud/DRM entry.
    public var isImportableLocal: Bool { !isCloud && (location?.isEmpty == false) }
}

public enum AppleMusicKind: String, Sendable, Equatable { case playlist, album, artist }

public struct AppleMusicCollection: Sendable, Equatable, Identifiable {
    /// Playlists are unique by name; albums can share a name across artists, so include the
    /// album artist to keep list identity (and SwiftUI ForEach keys) stable.
    public var id: String {
        kind == .album ? "album:\(name):\(tracks.first?.effectiveAlbumArtist ?? "")"
                       : "\(kind.rawValue):\(name)"
    }
    public var name: String
    public var kind: AppleMusicKind
    public var tracks: [AppleMusicTrack]
    public var smart: Bool
    public var cls: String        // Music's class display string, e.g. "user playlist", "subscription playlist"
    public init(name: String, kind: AppleMusicKind, tracks: [AppleMusicTrack],
                smart: Bool = false, cls: String = "") {
        self.name = name; self.kind = kind; self.tracks = tracks; self.smart = smart; self.cls = cls
    }

    /// A short tag when the playlist wasn't hand-made by the user (smart, or added from the
    /// Apple Music catalog / another user). nil for a normal user playlist.
    public var originTag: String? {
        let c = cls.lowercased()
        if c.contains("subscription") || c.contains("radio") { return "Apple Music" }
        if smart { return "Smart" }
        if c.contains("genius") { return "Genius" }
        return nil
    }
    public var isUserMade: Bool { originTag == nil }

    /// The artist to show under an album collection (album artist of its tracks; blank for playlists).
    public var albumArtist: String {
        kind == .album ? (tracks.first?.effectiveAlbumArtist ?? "") : ""
    }

    /// When this collection last gained a track, as epoch seconds — the sensible reading of "date
    /// added" for an album, since Music dates tracks rather than albums, and an album ripped over
    /// two sessions should sort by when it was finished. nil when none of its tracks carry a date.
    public var addedAt: Double? { tracks.compactMap(\.addedAt).max() }
}

/// Groups a flat list of Apple Music library tracks into album collections. Albums are keyed by
/// (normalized album, normalized album artist) so featured artists don't split an album, and two
/// different artists' same-named albums stay distinct. Tracks with a blank album are dropped.
public enum AppleMusicAlbums {
    public static func group(_ tracks: [AppleMusicTrack]) -> [AppleMusicCollection] {
        var order: [String] = []
        var byKey: [String: [AppleMusicTrack]] = [:]
        for t in tracks where !t.album.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = AppleMusicCompare.normalize(t.album) + "␟" + AppleMusicCompare.normalize(t.effectiveAlbumArtist)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(t)
        }
        return order.map { key in
            let group = byKey[key]!
            // Display the album name/artist as first seen (preserve original casing/spelling).
            return AppleMusicCollection(name: group[0].album, kind: .album, tracks: group)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Parses the JSON our JXA script emits from Music.app.
public enum AppleMusicParser {
    /// A positive integer from a JSON number (Int/Double/NSNumber); nil for 0/absent (Music's
    /// "unknown" track/disc value).
    private static func positiveInt(_ any: Any?) -> Int? {
        let n: Int?
        if let i = any as? Int { n = i }
        else if let d = any as? Double { n = Int(d) }
        else { n = nil }
        return (n ?? 0) > 0 ? n : nil
    }
    /// Epoch seconds from a JSON number; nil for 0/absent, since Music reports no date that way.
    private static func positiveDouble(_ any: Any?) -> Double? {
        let d: Double?
        if let x = any as? Double { d = x }
        else if let i = any as? Int { d = Double(i) }
        else { d = nil }
        return (d ?? 0) > 0 ? d : nil
    }

    public static func parse(_ data: Data) -> [AppleMusicCollection] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cols = obj["collections"] as? [[String: Any]] else { return [] }
        return cols.compactMap { col in
            guard let name = col["name"] as? String,
                  let kindStr = col["kind"] as? String,
                  let kind = AppleMusicKind(rawValue: kindStr) else { return nil }
            let tracks = (col["tracks"] as? [[String: Any]] ?? []).map { t in
                AppleMusicTrack(
                    name: (t["name"] as? String) ?? "",
                    artist: (t["artist"] as? String) ?? "",
                    album: (t["album"] as? String) ?? "",
                    albumArtist: (t["albumArtist"] as? String) ?? "",
                    trackNumber: positiveInt(t["track"]),
                    discNumber: positiveInt(t["disc"]),
                    durationSec: (t["duration"] as? Double) ?? Double((t["duration"] as? Int) ?? 0),
                    location: (t["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    isCloud: (t["cloud"] as? Bool) ?? false,
                    addedAt: positiveDouble(t["added"]))
            }
            return AppleMusicCollection(name: name, kind: kind, tracks: tracks,
                                        smart: (col["smart"] as? Bool) ?? false,
                                        cls: (col["cls"] as? String) ?? "")
        }
    }
}

/// Compares Apple Music tracks against the local library (owned vs missing).
public enum AppleMusicCompare {
    /// Normalize for fuzzy matching: lowercase, drop feat./remaster/brackets, strip punctuation.
    public static func normalize(_ s: String) -> String {
        var x = s.lowercased()
        for pat in [#"\(feat[^)]*\)"#, #"\(.*remaster.*\)"#, #"\[[^\]]*\]"#, #"feat\.?.*$"#] {
            x = x.replacingOccurrences(of: pat, with: " ", options: [.regularExpression])
        }
        x = x.replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
        return x.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public struct LibraryTrack: Sendable {
        public var title: String; public var artist: String; public var album: String; public var durationSec: Double
        public init(title: String, artist: String, album: String, durationSec: Double) {
            self.title = title; self.artist = artist; self.album = album; self.durationSec = durationSec
        }
    }

    public static func matches(_ am: AppleMusicTrack, _ lib: LibraryTrack) -> Bool {
        matches(name: am.name, artist: am.artist, album: am.album, durationSec: am.durationSec, lib)
    }

    /// Source-neutral fuzzy match (reused by Spotify): title + artist must match, and either the
    /// album or the duration (±4s) must corroborate.
    public static func matches(name: String, artist: String, album: String, durationSec: Double,
                               _ lib: LibraryTrack) -> Bool {
        guard normalize(name) == normalize(lib.title),
              normalize(artist) == normalize(lib.artist) else { return false }
        let albumMatch = normalize(album) == normalize(lib.album)
        let durMatch = durationSec > 0 && abs(durationSec - lib.durationSec) <= 4
        return albumMatch || durMatch
    }

    /// Returns (ownedCount, missingTracks) for a collection against the library.
    public static func ownership(of tracks: [AppleMusicTrack], in library: [LibraryTrack])
        -> (owned: Int, missing: [AppleMusicTrack]) {
        var owned = 0
        var missing: [AppleMusicTrack] = []
        for am in tracks {
            if library.contains(where: { matches(am, $0) }) { owned += 1 } else { missing.append(am) }
        }
        return (owned, missing)
    }
}
