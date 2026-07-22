import Foundation

/// Parses a messy YouTube video title into a clean artist/title and a search query.
/// No LLM — regex heuristics feed the iTunes resolver, which provides canonical metadata.
public enum TitleCleaner {
    // Noise removed anywhere in the title.
    private static let noisePatterns: [String] = [
        #"\((?:official\s+)?(?:music\s+)?video\)"#,
        #"\(official\s+audio\)"#, #"\(official\s+lyric[s]?\s+video\)"#, #"\(lyric[s]?\)"#,
        #"\(audio\)"#, #"\(visualizer\)"#, #"\(explicit\)"#, #"\(hd\)"#, #"\(4k\)"#,
        #"\[[^\]]*\]"#,                              // any [ ... ]
        #"\bofficial\s+video\b"#, #"\bofficial\s+audio\b"#,
        #"\b(?:hd|hq|4k|8k|remaster(?:ed)?(?:\s+\d{4})?)\b"#,
        #"\bfull\s+album\b"#,
    ]

    public static func parse(_ raw: String) -> (artist: String?, title: String, query: String) {
        var s = raw
        // Drop a trailing "| Label/Channel" segment.
        if let bar = s.firstIndex(of: "|") { s = String(s[..<bar]) }
        // Strip noise (case-insensitive).
        for pat in noisePatterns {
            s = s.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Normalize featuring markers to a consistent token we keep in the title.
        s = collapseSpaces(s)

        // Split "Artist - Title" (first hyphen/en-dash with surrounding spaces).
        var artist: String? = nil
        var title = s
        if let range = s.range(of: #"\s[-–—]\s"#, options: .regularExpression) {
            let left = String(s[s.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && !right.isEmpty {
                artist = left
                title = right
            }
        }
        title = collapseSpaces(title).trimmingCharacters(in: CharacterSet(charactersIn: " -–—\"'"))
        let query = collapseSpaces("\(artist ?? "") \(title)").trimmingCharacters(in: .whitespaces)
        return (artist, title.isEmpty ? raw : title, query.isEmpty ? raw : query)
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
