import Foundation
import OpenSongCore

func registerArtworkResolverTests() {
    let art = ArtworkResolver(ffmpegPath: TestSupport.ffmpeg)

    t.test("extractEmbedded returns false when no art") {
        let dir = try TestSupport.tempDir("art")
        let mp3 = dir.appendingPathComponent("plain.mp3")
        try TestSupport.makeMP3(at: mp3, title: "No Art", artist: "A", seconds: 1)
        let out = dir.appendingPathComponent("cover.png")
        try t.expect(try art.extractEmbedded(from: mp3, to: out) == false, "no embedded art")
    }
    t.test("embed then extract round-trips art") {
        let dir = try TestSupport.tempDir("art")
        let mp3 = dir.appendingPathComponent("song.mp3")
        let png = dir.appendingPathComponent("in.png")
        try TestSupport.makeMP3(at: mp3, title: "Has Art", artist: "A", seconds: 1)
        try TestSupport.makePNG(at: png, color: "blue", size: 64)
        try art.embed(png, into: mp3)
        let out = dir.appendingPathComponent("out.png")
        try t.expect(try art.extractEmbedded(from: mp3, to: out) == true, "art now present")
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        try t.expect(size > 0, "extracted art non-empty")
    }
    t.test("download writes bytes from http client") {
        let dir = try TestSupport.tempDir("art")
        let png = dir.appendingPathComponent("src.png")
        try TestSupport.makePNG(at: png, color: "green", size: 32)
        let bytes = try Data(contentsOf: png)
        let resolver = ArtworkResolver(ffmpegPath: TestSupport.ffmpeg,
                                       http: TestSupport.StubHTTPClient(data: bytes))
        let dst = dir.appendingPathComponent("downloaded.png")
        try await resolver.download(URL(string: "https://example.com/x.png")!, to: dst)
        try t.expectEqual(try Data(contentsOf: dst), bytes, "downloaded bytes match")
    }
}
