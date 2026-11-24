import Foundation

/// A device volume OpenSong can sync to. Abstracted so tests can run the whole sync
/// engine against a temp directory instead of physical hardware.
public protocol Volume: Sendable {
    var musicDir: URL { get }
    var uuid: String { get }
    var name: String { get }
    func capacity() throws -> (totalBytes: Int64, freeBytes: Int64)
}

/// A real mounted volume (e.g. `/Volumes/WALKMAN`).
public struct DiskVolume: Volume {
    public let mountPoint: URL
    public let uuid: String
    public let name: String
    public init(mountPoint: URL, uuid: String, name: String) {
        self.mountPoint = mountPoint; self.uuid = uuid; self.name = name
    }
    public var musicDir: URL { mountPoint.appendingPathComponent("MUSIC") }
    public func capacity() throws -> (totalBytes: Int64, freeBytes: Int64) {
        let vals = try mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return (Int64(vals.volumeTotalCapacity ?? 0), Int64(vals.volumeAvailableCapacity ?? 0))
    }
}

/// A temp-directory-backed volume for tests, with injectable capacity.
public struct TempVolume: Volume {
    public let root: URL
    public let uuid: String
    public let name: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public init(root: URL, uuid: String = "TEST-UUID", name: String = "WALKMAN",
                totalBytes: Int64 = 7_363_067_904, freeBytes: Int64 = 5_338_390_528) throws {
        self.root = root; self.uuid = uuid; self.name = name
        self.totalBytes = totalBytes; self.freeBytes = freeBytes
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MUSIC"),
                                                withIntermediateDirectories: true)
    }
    public var musicDir: URL { root.appendingPathComponent("MUSIC") }
    public func capacity() throws -> (totalBytes: Int64, freeBytes: Int64) { (totalBytes, freeBytes) }
}

/// Finds a connected Walkman by scanning `/Volumes` (FAT volume named WALKMAN, or any
/// volume containing a MUSIC folder). Reads the volume UUID for stable identification.
public enum DeviceDetector {
    public static func connectedWalkman() -> DiskVolume? {
        let fm = FileManager.default
        guard let vols = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                     includingPropertiesForKeys: nil) else { return nil }
        func makeVolume(_ v: URL) -> DiskVolume {
            let uuid = (try? v.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil
            return DiskVolume(mountPoint: v, uuid: uuid ?? "", name: v.lastPathComponent)
        }
        // Prefer an exact WALKMAN name.
        if let walkman = vols.first(where: { $0.lastPathComponent == "WALKMAN" }) {
            return makeVolume(walkman)
        }
        // Otherwise the first volume that has a MUSIC folder — but never an iPod (it has an
        // iPod_Control folder and is handled separately).
        for v in vols {
            var isDir: ObjCBool = false
            let music = v.appendingPathComponent("MUSIC")
            let ipod = v.appendingPathComponent("iPod_Control")
            if fm.fileExists(atPath: music.path, isDirectory: &isDir), isDir.boolValue,
               !fm.fileExists(atPath: ipod.path) {
                return makeVolume(v)
            }
        }
        return nil
    }
}

/// A connected iPod (mass-storage; identified by the `iPod_Control` folder). The Shuffle
/// stores music under `iPod_Control/Music` and playlists in a binary `iTunesSD`, so it's
/// handled by `ShuffleSyncEngine` rather than the Walkman path.
public struct ShuffleDevice: Sendable, Equatable {
    public let mountPoint: URL
    public let uuid: String
    public let name: String
    public init(mountPoint: URL, uuid: String, name: String) {
        self.mountPoint = mountPoint; self.uuid = uuid; self.name = name
    }
    public var layout: ShuffleLayout { ShuffleLayout(mountPoint: mountPoint) }
}

public extension DeviceDetector {
    /// First mounted volume that looks like an iPod (contains `iPod_Control`).
    static func connectedShuffle() -> ShuffleDevice? {
        let fm = FileManager.default
        guard let vols = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                     includingPropertiesForKeys: nil) else { return nil }
        for v in vols where fm.fileExists(atPath: v.appendingPathComponent("iPod_Control").path) {
            let uuid = ((try? v.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil) ?? ""
            return ShuffleDevice(mountPoint: v, uuid: uuid, name: v.lastPathComponent)
        }
        return nil
    }
}
