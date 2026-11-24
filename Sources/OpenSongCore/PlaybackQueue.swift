import Foundation

/// What happens when the current track ends.
public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    /// Play the queue through once, then stop.
    case off
    /// Wrap round to the start of the queue and keep going.
    case all
    /// Play the same track over and over.
    case one

    /// The order the player's button cycles through.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the playhead goes next, given a queue position and a repeat mode.
///
/// Kept apart from the player so the rules are testable without an audio device: they are easy to
/// get subtly wrong at the ends of the queue, and the difference between a track *finishing* and the
/// user *pressing skip* is the sort of thing that only shows up in use.
public enum PlaybackQueue {
    /// The index to play when the current track finishes on its own, or nil to stop at the end.
    public static func afterFinishing(index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        switch repeatMode {
        case .one:
            return index                       // the same track again
        case .all:
            return (index + 1) % count         // wrap round, forever
        case .off:
            return index + 1 < count ? index + 1 : nil
        }
    }

    /// The index for an explicit skip forward.
    ///
    /// Repeat-one deliberately does *not* apply here: pressing skip means "play something else", so
    /// it advances like repeat-all and the mode stays on for whatever lands next. A skip button that
    /// replayed the same track would look broken.
    public static func afterSkip(index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        if index + 1 < count { return index + 1 }
        return repeatMode == .off ? nil : 0
    }

    /// The index for an explicit skip backward — the mirror of `afterSkip`, wrapping to the end of
    /// the queue when repeating. (Restarting the current track when it is already a few seconds in
    /// is the player's business, not this one's.)
    public static func beforeSkip(index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        if index - 1 >= 0 { return index - 1 }
        return repeatMode == .off ? nil : count - 1
    }
}

/// Where a dragged row lands.
///
/// Split out of the view because it is the arithmetic that decides whether a drag feels reliable:
/// it must depend only on where the pointer is *now*, relative to where the drag started, so that
/// overshooting, doubling back, or pausing mid-drag all give the same answer.
public enum RowDrag {
    /// The index a row dragged `translation` points from `startIndex` should occupy, clamped to the
    /// list. `rowStride` is one row's height including any separator.
    public static func targetIndex(startIndex: Int, translation: Double,
                                   rowStride: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard rowStride > 0 else { return min(max(startIndex, 0), count - 1) }
        let moved = Int((translation / rowStride).rounded())
        return min(max(startIndex + moved, 0), count - 1)
    }

    /// The list with the row at `startIndex` moved to `target`.
    public static func reorder<T>(_ items: [T], from startIndex: Int, to target: Int) -> [T] {
        guard items.indices.contains(startIndex), items.indices.contains(target),
              startIndex != target else { return items }
        var out = items
        let moved = out.remove(at: startIndex)
        out.insert(moved, at: target)
        return out
    }
}
