import Foundation

/// A device id that survives remounts.
///
/// The Walkman and the iPod shuffle are FAT32 volumes, and macOS *synthesizes* their
/// `volumeUUIDString` — it can change between mounts (and does change if the player rewrites its
/// FAT serial or is reformatted). Keying `device_track` rows on it means the app silently forgets
/// everything it has already synced: nothing shows as on-device and the next sync recopies the
/// whole library. So the id lives in a hidden marker file on the device itself, seeded with the
/// volume UUID the first time so existing rows keep matching.
public enum DeviceIdentity {
    public static let markerName = ".opensong-device-id"

    /// The device's stable id, creating the marker if it's missing. Falls back to `fallback`
    /// (normally the volume UUID) when the volume can't be written to.
    public static func stableID(mountPoint: URL, fallback: String) -> String {
        let marker = mountPoint.appendingPathComponent(markerName)
        if let raw = try? String(contentsOf: marker, encoding: .utf8) {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = fallback.isEmpty ? UUID().uuidString : fallback
        try? id.write(to: marker, atomically: true, encoding: .utf8)
        return id
    }
}
