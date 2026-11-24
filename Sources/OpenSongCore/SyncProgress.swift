import Foundation

/// A step-level progress report from a sync run.
///
/// `fraction` is weighted by track duration rather than by step count: a 6-minute transcode
/// costs far more wall clock than copying an already-MP3 file, so a step-count bar sits still
/// for minutes and then jumps. Weighting keeps the bar moving at a roughly honest rate, which
/// also makes a time-remaining estimate (elapsed ÷ fraction) usable.
public struct SyncProgress: Sendable {
    public var done: Int          // steps finished
    public var total: Int         // steps in the run (adds + removals)
    public var fraction: Double   // 0…1, duration-weighted
    public var label: String      // what's happening right now

    public init(done: Int, total: Int, fraction: Double, label: String) {
        self.done = done; self.total = total; self.fraction = fraction; self.label = label
    }

    /// Weight (in "seconds of audio" units) charged to non-transfer steps, so a run that is
    /// mostly deletions or database writes still advances.
    public static let removeWeight: Double = 2
    public static let finalizeWeight: Double = 8
    /// Floor on a track's weight, so tracks with unknown/zero duration still count.
    public static let minTrackWeight: Double = 30
}
