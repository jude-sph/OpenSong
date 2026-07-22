import Foundation
import OpenSongCore

func registerArtworkCropTests() {
    t.test("crops a 16:9 thumbnail to a square") {
        let dir = try TestSupport.tempDir("crop")
        let thumb = dir.appendingPathComponent("thumb.png")
        // 320x180 (16:9)
        let r = try Shell.run(TestSupport.ffmpeg, ["-y", "-f", "lavfi", "-i",
            "color=c=blue:s=320x180", "-frames:v", "1", thumb.path])
        try t.expectEqual(r.status, 0, "made 16:9 thumb")
        let out = dir.appendingPathComponent("cover.png")
        try ArtworkCrop.squareCrop(of: thumb, to: out, ffmpegPath: TestSupport.ffmpeg)
        let probe = try Shell.run(TestSupport.ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", out.path])
        let dims = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        try t.expectEqual(dims, "180,180", "square output (got \(dims))")
    }
}
