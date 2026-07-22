import Foundation

/// Produces FAT/exFAT-safe path components for the device and the master tree.
///
/// The NW-E394 is FAT32. Illegal path characters (`\ / : * ? " < > |`) and control
/// characters are replaced with spaces; runs of whitespace are collapsed; leading and
/// trailing whitespace and trailing dots are trimmed (Windows/FAT forbids trailing dots).
/// Unicode/accented characters are preserved — the device handles them, and they match
/// the ID3 tags it displays. If nothing usable remains, `fallback` is returned.
public enum PathSanitizer {
    private static let illegal: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    public static func component(_ raw: String, fallback: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if illegal.contains(ch) || scalar.properties.generalCategory == .control {
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        // Collapse whitespace runs to single spaces.
        let collapsed = String(String.UnicodeScalarView(out))
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        // Trim trailing dots (and any resulting trailing spaces).
        var trimmed = collapsed
        while let last = trimmed.last, last == "." || last == " " {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
