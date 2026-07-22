import Foundation

/// Crops a (typically 16:9) YouTube thumbnail to a square cover. `offsetFraction` slides
/// the crop window horizontally (0 = left, 0.5 = centered, 1 = right).
public enum ArtworkCrop {
    public static func squareCrop(of image: URL, to dst: URL,
                                  ffmpegPath: String = "/opt/homebrew/bin/ffmpeg",
                                  offsetFraction: Double = 0.5) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // crop=w=ih:h=ih:x=(iw-ih)*offset:y=0  → square of side = height, slid horizontally.
        let off = max(0, min(1, offsetFraction))
        let filter = "crop=w=ih:h=ih:x=(iw-ih)*\(off):y=0"
        let r = try Shell.run(ffmpegPath, ["-y", "-hide_banner", "-i", image.path, "-vf", filter, dst.path])
        guard r.status == 0 else {
            throw NSError(domain: "ArtworkCrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
    }
}
