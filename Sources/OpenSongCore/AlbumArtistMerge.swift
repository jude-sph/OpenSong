import Foundation

/// Re-joins albums that got split apart by per-track collaboration credits.
///
/// Tagged files often credit one album's tracks inconsistently — "Gorillaz", "Gorillaz & De La
/// Soul", "Gorillaz & MF DOOM" — which fragments *Demon Days* into three albums. Stripping every
/// "&" would be wrong: plenty of acts legitimately have one in their name (Simon & Garfunkel,
/// Earth, Wind & Fire). So a credit only collapses when the album itself provides the evidence:
/// another track on the same album is credited to exactly the leading part of it.
public enum AlbumArtistMerge {
    /// Collaboration separators (regex alternatives) that may follow the primary artist.
    private static let separators = #"&|and\b|\+|x\b|×|with\b|vs\.?|,|/|feat\.?|ft\.?|featuring\b"#

    /// Given every artist credit found on tracks that share one album title, returns the credits
    /// that should be filed under a different (primary) artist, as `credit → canonical`.
    /// Credits absent from the result stand on their own.
    public static func canonicalArtists(_ artists: [String]) -> [String: String] {
        // De-duplicate case-insensitively, keeping the first spelling seen for each credit.
        var distinct: [String] = []
        var seen = Set<String>()
        for a in artists {
            let k = fold(a)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k); distinct.append(a)
        }
        // Direct parent for each credit: the shortest album-mate it collaborates on top of.
        var parent: [String: String] = [:]
        for credit in distinct {
            let bases = distinct.filter { isCollaboration(credit, on: $0) }
            if let best = bases.min(by: { ($0.count, fold($0)) < ($1.count, fold($1)) }) {
                parent[credit] = best
            }
        }
        // Follow chains ("A & B & C" → "A & B" → "A"), guarding against cycles.
        var out: [String: String] = [:]
        for credit in parent.keys {
            var cur = credit
            var hops = 0
            while let next = parent[cur], hops < distinct.count {
                if fold(next) == fold(credit) { break }   // cycle: leave the credit alone
                cur = next; hops += 1
            }
            if fold(cur) != fold(credit) { out[credit] = cur }
        }
        return out
    }

    /// True when `credit` is `base` plus a collaboration suffix — "Gorillaz & De La Soul" on
    /// "Gorillaz". Requires a real separator *and* a named collaborator after it, so "Gorillazz"
    /// or a trailing "Gorillaz &" don't match.
    public static func isCollaboration(_ credit: String, on base: String) -> Bool {
        let c = fold(credit), b = fold(base)
        guard !b.isEmpty, c.count > b.count, c.hasPrefix(b) else { return false }
        let rest = String(c.dropFirst(b.count))
        return rest.range(of: #"^\s*(?:\#(separators))\s*\S"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Comparison form: lowercased, whitespace-collapsed, trimmed.
    private static func fold(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
