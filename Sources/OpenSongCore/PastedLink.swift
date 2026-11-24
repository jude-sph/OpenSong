import Foundation

/// What a pasted link points at. Downloads go through yt-dlp, which handles YouTube and SoundCloud
/// alike; this only decides whether the link is a *single track* we can grab, and where the artist
/// name should come from when "Fetch info" pre-fills the form.
public enum PastedLink: Sendable, Equatable {
    case youtube
    case soundcloudTrack
    case soundcloudCollection   // a set (playlist), profile, likes/reposts page, …
    case other

    public static func classify(_ raw: String) -> PastedLink {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return .other }
        if host == "youtu.be" || host.hasSuffix("youtube.com") { return .youtube }
        // Short share links (on.soundcloud.com/xyz) can be either kind; yt-dlp resolves them, and
        // the fetch step catches a set by it returning more than one entry.
        if host == "on.soundcloud.com" || host == "snd.sc" { return .soundcloudTrack }
        guard host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") else { return .other }
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        // A track is exactly /artist/track. Private tracks add a secret token: /artist/track/s-AbC.
        let collectionWords: Set<String> = ["sets", "likes", "reposts", "tracks", "albums",
                                            "popular-tracks", "followers", "following", "comments"]
        if parts.count == 2, !collectionWords.contains(parts[1]) { return .soundcloudTrack }
        if parts.count == 3, parts[2].hasPrefix("s-"), !collectionWords.contains(parts[1]) { return .soundcloudTrack }
        return .soundcloudCollection
    }

    public var isSoundCloud: Bool { self == .soundcloudTrack || self == .soundcloudCollection }

    /// Pick title/artist for the form. YouTube titles usually read "Artist - Title"; SoundCloud
    /// titles usually don't, so there the uploader (or the track's own artist tag) fills the gap.
    public static func suggestedMeta(rawTitle: String, artistTag: String, uploader: String,
                                     link: PastedLink) -> (title: String, artist: String) {
        let parsed = TitleCleaner.parse(rawTitle)
        if let a = parsed.artist, !a.isEmpty { return (parsed.title, a) }
        guard link.isSoundCloud else { return (parsed.title, "") }
        func clean(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t == "NA" || t == "None") ? "" : t   // yt-dlp prints NA for missing fields
        }
        let tag = clean(artistTag), up = clean(uploader)
        return (parsed.title, tag.isEmpty ? up : tag)
    }
}
