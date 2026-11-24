import Foundation

/// Reads the cover-art frame straight out of an MP3's ID3v2 tag, so tests can assert the exact
/// shape the Walkman needs (front-cover type, baseline 4:2:0 JPEG, bounded size) rather than
/// trusting ffprobe's summary.
enum APICInspector {
    struct Cover {
        var mime: String
        var pictureType: Int      // ID3 APIC picture type; 3 = cover (front)
        var width: Int
        var height: Int
        var baseline: Bool        // JPEG SOF0 (not SOF2 progressive)
        var chroma420: Bool       // sampling factors 0x22
    }

    enum Failure: Error, CustomStringConvertible {
        case notID3, noAPIC, noJPEG
        public var description: String {
            switch self {
            case .notID3: return "file has no ID3v2 tag"
            case .noAPIC: return "ID3 tag has no APIC frame"
            case .noJPEG: return "APIC frame holds no JPEG"
            }
        }
    }

    static func read(_ url: URL) throws -> Cover {
        let d = try Data(contentsOf: url)
        guard d.count > 10, d[0...2] == Data("ID3".utf8) else { throw Failure.notID3 }
        // Tag size is 4 sync-safe bytes (7 bits each).
        let tagSize = (Int(d[6] & 0x7f) << 21) | (Int(d[7] & 0x7f) << 14)
            | (Int(d[8] & 0x7f) << 7) | Int(d[9] & 0x7f)
        var i = 10
        while i + 10 <= min(d.count, tagSize + 10) {
            let id = String(decoding: d[i..<i+4], as: UTF8.self)
            let size = d[(i+4)..<(i+8)].reduce(0) { $0 << 8 | Int($1) }   // ID3v2.3 frame size
            if size <= 0 { break }
            if id == "APIC" {
                return try parseAPIC(Array(d[(i+10)..<min(d.count, i + 10 + size)]))
            }
            i += 10 + size
        }
        throw Failure.noAPIC
    }

    /// APIC body: encoding byte, MIME (null-terminated), picture type byte, description, image.
    private static func parseAPIC(_ b: [UInt8]) throws -> Cover {
        guard let mimeEnd = b[1...].firstIndex(of: 0) else { throw Failure.noAPIC }
        let mime = String(decoding: b[1..<mimeEnd], as: UTF8.self)
        let type = Int(b[mimeEnd + 1])
        guard let start = firstSOI(b) else { throw Failure.noJPEG }
        let (w, h, baseline, chroma420) = try readSOF(Array(b[start...]))
        return Cover(mime: mime, pictureType: type, width: w, height: h,
                     baseline: baseline, chroma420: chroma420)
    }

    private static func firstSOI(_ b: [UInt8]) -> Int? {
        for i in 0..<max(0, b.count - 1) where b[i] == 0xFF && b[i + 1] == 0xD8 { return i }
        return nil
    }

    /// Walk JPEG markers to the start-of-frame, which carries size and chroma sampling.
    private static func readSOF(_ j: [UInt8]) throws -> (Int, Int, Bool, Bool) {
        var p = 2
        while p + 9 < j.count {
            guard j[p] == 0xFF else { p += 1; continue }
            let marker = j[p + 1]
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                let h = Int(j[p + 5]) << 8 | Int(j[p + 6])
                let w = Int(j[p + 7]) << 8 | Int(j[p + 8])
                let sampling = j[p + 11]              // first component's H/V sampling factors
                return (w, h, marker != 0xC2, sampling == 0x22)
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { p += 2; continue }
            p += 2 + (Int(j[p + 2]) << 8 | Int(j[p + 3]))
        }
        throw Failure.noJPEG
    }
}
