import Foundation

/// All device file operations, scoped strictly to the `MUSIC/` folder. Refuses to write
/// or delete anything outside `MUSIC/` or any known device system item.
public struct DeviceManager: Sendable {
    public var volume: Volume
    public init(volume: Volume) { self.volume = volume }

    /// Device system files/dirs OpenSong must never touch (they live at the volume root,
    /// but we also refuse them as path components defensively).
    public static let systemNames: Set<String> = [
        "DCIM", "PICTURE", "Video", "FOR_MAC", "FOR_WINDOWS", "Help_Guide",
        "System Volume Information", ".fseventsd", "default-capability.xml",
        "DevIcon.fil", "DevLogo.fil", "nmdsdcid", "WMPInfo.xml",
    ]

    public enum DeviceError: Error, CustomStringConvertible {
        case outsideScope(String)
        case invalidName(String)
        public var description: String {
            switch self {
            case .outsideScope(let p): return "refused write outside MUSIC/: \(p)"
            case .invalidName(let n): return "invalid name: \(n)"
            }
        }
    }

    /// Backslash relative paths of every `.mp3` currently under MUSIC/.
    public func listManagedTracks() throws -> [String] {
        let music = volume.musicDir
        guard let en = FileManager.default.enumerator(at: music,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "mp3" {
            out.append(Self.relativeBackslash(of: url, under: music))
        }
        return out.sorted()
    }

    /// Copy an audio file to the device at the identity's canonical location.
    public func write(assetFile: URL, to identity: TrackIdentity) throws {
        let dest = DeviceRelativePath.fileURL(under: volume.musicDir, for: identity)
        try assertUnderMusic(dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: assetFile, to: dest)
    }

    /// Remove a managed track by its backslash relative path.
    public func remove(relative: String) throws {
        let comps = relative.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        if comps.contains("..") || comps.contains(where: { Self.systemNames.contains($0) }) {
            throw DeviceError.outsideScope(relative)
        }
        let url = comps.reduce(volume.musicDir) { $0.appendingPathComponent($1) }
        try assertUnderMusic(url)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        pruneEmptyParents(of: url)
    }

    /// Write a `.m3u8` playlist file into MUSIC/ (bytes come from M3U8Writer).
    public func writePlaylist(name: String, data: Data) throws {
        if name.contains("/") || name.contains("\\") || name.contains("..") {
            throw DeviceError.invalidName(name)
        }
        let filename = name.hasSuffix(".m3u8") ? name : "\(name).m3u8"
        let file = volume.musicDir.appendingPathComponent(filename)
        try assertUnderMusic(file)
        try FileManager.default.createDirectory(at: volume.musicDir, withIntermediateDirectories: true)
        try data.write(to: file)
    }

    public func removePlaylist(name: String) throws {
        let filename = name.hasSuffix(".m3u8") ? name : "\(name).m3u8"
        let file = volume.musicDir.appendingPathComponent(filename)
        try assertUnderMusic(file)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func existingPlaylists() throws -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: volume.musicDir,
            includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "m3u8" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    // MARK: internals

    private func assertUnderMusic(_ url: URL) throws {
        let music = volume.musicDir.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p == music || p.hasPrefix(music + "/") else { throw DeviceError.outsideScope(p) }
    }

    /// Delete now-empty artist/album directories left behind after a removal.
    private func pruneEmptyParents(of url: URL) {
        var dir = url.deletingLastPathComponent()
        let musicPath = volume.musicDir.standardizedFileURL.path
        while dir.standardizedFileURL.path != musicPath,
              dir.standardizedFileURL.path.hasPrefix(musicPath + "/") {
            let empty = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty) ?? false
            if empty { try? FileManager.default.removeItem(at: dir) } else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    static func relativeBackslash(of url: URL, under base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        if p.hasPrefix(basePath + "/") { p.removeFirst(basePath.count + 1) }
        return p.replacingOccurrences(of: "/", with: "\\")
    }
}
