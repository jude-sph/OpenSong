import Foundation

public struct M3U8Entry: Equatable, Sendable {
    public var title: String?        // from #EXTINF, if present
    public var durationSec: Int?     // from #EXTINF, if present
    public var artist: String        // from path segment 1
    public var album: String         // from path segment 2
    public var titleFromPath: String // path filename with .mp3 stripped
    public var relativePath: String  // original backslash path

    public init(title: String?, durationSec: Int?, artist: String, album: String,
                titleFromPath: String, relativePath: String) {
        self.title = title; self.durationSec = durationSec; self.artist = artist
        self.album = album; self.titleFromPath = titleFromPath; self.relativePath = relativePath
    }
}

/// Parses a device `.m3u8` file back into entries (for the adopt-from-device flow).
/// Handles the device's format: optional UTF-8 BOM, CRLF or LF lines, `#EXTINF` lines
/// paired with the following path line, backslash-separated `Artist\Album\File.mp3`.
public enum M3U8Parser {
    public static func parse(_ data: Data) -> [M3U8Entry] {
        var bytes = data
        // Strip UTF-8 BOM if present.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.subdata(in: 3..<bytes.count) }
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }

        let lines = text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" })
            .map(String.init)

        var entries: [M3U8Entry] = []
        var pendingTitle: String?
        var pendingDuration: Int?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if line.isEmpty { continue }
            if line == "#EXTM3U" { continue }
            if line.hasPrefix("#EXTINF:") {
                // Format: #EXTINF:<seconds>,<title>
                let rest = String(line.dropFirst("#EXTINF:".count))
                if let comma = rest.firstIndex(of: ",") {
                    pendingDuration = Int(rest[rest.startIndex..<comma].trimmingCharacters(in: .whitespaces))
                    pendingTitle = String(rest[rest.index(after: comma)...])
                } else {
                    pendingDuration = Int(rest.trimmingCharacters(in: .whitespaces))
                    pendingTitle = nil
                }
                continue
            }
            if line.hasPrefix("#") { continue } // other directives ignored

            // Path line.
            let segments = line.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            let file = segments.last ?? line
            let stem = file.hasSuffix(".mp3") ? String(file.dropLast(4)) : file
            let artist = segments.count >= 3 ? segments[segments.count - 3] : "Unknown Artist"
            let album = segments.count >= 2 ? segments[segments.count - 2] : "Unknown Album"
            entries.append(M3U8Entry(title: pendingTitle, durationSec: pendingDuration,
                                     artist: artist, album: album, titleFromPath: stem,
                                     relativePath: line))
            pendingTitle = nil; pendingDuration = nil
        }
        return entries
    }
}
