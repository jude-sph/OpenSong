import Foundation

public struct AppleMusicTrack: Sendable, Equatable {
    public var name: String
    public var artist: String
    public var album: String
    public var durationSec: Double
    public var location: String?    // POSIX path when a local (non-DRM) file exists
    public var isCloud: Bool
    public init(name: String, artist: String, album: String, durationSec: Double,
                location: String? = nil, isCloud: Bool = false) {
        self.name = name; self.artist = artist; self.album = album
        self.durationSec = durationSec; self.location = location; self.isCloud = isCloud
    }
    /// The identity this track resolves to (authoritative — everything is already known).
    public var identity: TrackIdentity {
        TrackIdentity(title: name, artist: artist, albumArtist: artist,
                      album: album.isEmpty ? nil : album, durationSec: durationSec,
                      provenance: .appleMusic)
    }
    public var wishItem: WishItem {
        WishItem(title: name, artist: artist, album: album.isEmpty ? nil : album,
                 durationSec: durationSec, source: .appleMusic, state: .wishlist)
    }
    /// Importable when there's a real local file that isn't a cloud/DRM entry.
    public var isImportableLocal: Bool { !isCloud && (location?.isEmpty == false) }
}

public enum AppleMusicKind: String, Sendable, Equatable { case playlist, album, artist }

public struct AppleMusicCollection: Sendable, Equatable, Identifiable {
    public var id: String { "\(kind.rawValue):\(name)" }
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
}

/// Parses the JSON our JXA script emits from Music.app.
public enum AppleMusicParser {
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
                    durationSec: (t["duration"] as? Double) ?? Double((t["duration"] as? Int) ?? 0),
                    location: (t["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    isCloud: (t["cloud"] as? Bool) ?? false)
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
        guard normalize(am.name) == normalize(lib.title),
              normalize(am.artist) == normalize(lib.artist) else { return false }
        let albumMatch = normalize(am.album) == normalize(lib.album)
        let durMatch = am.durationSec > 0 && abs(am.durationSec - lib.durationSec) <= 4
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
