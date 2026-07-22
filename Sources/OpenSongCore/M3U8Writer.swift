import Foundation

/// Writes `.m3u8` playlist files in the *exact* byte format the NW-E394 uses
/// (empirically verified against the device): UTF-8 with BOM, CRLF line endings,
/// `#EXTM3U` header, and per entry `#EXTINF:<seconds>,<Title>` followed by a
/// backslash-separated path relative to the MUSIC directory.
public enum M3U8Writer {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let crlf: [UInt8] = [0x0D, 0x0A]

    public static func data(entries: [(identity: TrackIdentity, durationSec: Int)]) -> Data {
        var out = Data(bom)
        func line(_ s: String) {
            out.append(Data(s.utf8))
            out.append(contentsOf: crlf)
        }
        line("#EXTM3U")
        for e in entries {
            line("#EXTINF:\(e.durationSec),\(e.identity.title)")
            line(DeviceRelativePath.backslashPath(for: e.identity))
        }
        return out
    }
}
