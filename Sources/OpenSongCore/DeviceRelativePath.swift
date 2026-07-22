import Foundation

/// Computes a track's canonical location on the device, in exactly one place, so the
/// file writer and the playlist writer never disagree.
///
/// Layout: `MUSIC/<AlbumArtist>/<Album>/<Title>.mp3`, all components sanitized.
/// - `components` → `[artist, album, "title.mp3"]` (sanitized, for disk placement)
/// - `backslashPath` → `artist\album\title.mp3` (relative to MUSIC/, for `.m3u8` files)
/// - `fileURL(under:)` → an on-disk URL under the given music directory
public enum DeviceRelativePath {
    /// Sanitized `[artist, album, "title.<ext>"]`. Device files are always `mp3`;
    /// master-tree files keep their original extension (pass `ext`).
    public static func components(for i: TrackIdentity, ext: String = "mp3") -> [String] {
        let artist = PathSanitizer.component(effectiveAlbumArtist(i), fallback: "Unknown Artist")
        let album = PathSanitizer.component(effectiveAlbum(i), fallback: "Unknown Album")
        let title = PathSanitizer.component(i.title, fallback: "Untitled")
        return [artist, album, "\(title).\(ext)"]
    }

    public static func backslashPath(for i: TrackIdentity) -> String {
        components(for: i).joined(separator: "\\")
    }

    /// On-disk URL under the device MUSIC directory (always `.mp3`).
    public static func fileURL(under musicDir: URL, for i: TrackIdentity) -> URL {
        components(for: i).reduce(musicDir) { $0.appendingPathComponent($1) }
    }

    /// On-disk URL under the master library root, keeping the original extension.
    public static func masterURL(under libraryRoot: URL, for i: TrackIdentity, ext: String) -> URL {
        components(for: i, ext: ext).reduce(libraryRoot) { $0.appendingPathComponent($1) }
    }
}
