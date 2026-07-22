import Foundation
import OpenSongCore

private let cannedAcoustID = """
{"status":"ok","results":[
  {"id":"x","score":0.98,"recordings":[
    {"title":"Vordhosbn","artists":[{"name":"Aphex Twin"}]}
  ]}
]}
""".data(using: .utf8)!

func registerFingerprinterTests() {
    t.test("fpcalc produces a fingerprint + duration") {
        let dir = try TestSupport.tempDir("fp")
        let f = dir.appendingPathComponent("tone.mp3")
        try TestSupport.makeMP3(at: f, title: "T", artist: "A", bitrateKbps: 192, seconds: 5, tone: true)
        let fp = try Fingerprinter(fpcalcPath: "/opt/homebrew/bin/fpcalc").fingerprint(f)
        try t.expect(!fp.fingerprint.isEmpty, "non-empty fingerprint")
        try t.expect(fp.durationSec >= 4 && fp.durationSec <= 6, "duration ~5s (got \(fp.durationSec))")
    }
    t.test("AcoustID JSON parses recordings + score") {
        let recs = AcoustIDClient.parse(cannedAcoustID)
        try t.expectEqual(recs.count, 1, "one recording")
        try t.expectEqual(recs[0].title, "Vordhosbn", "title")
        try t.expectEqual(recs[0].artist, "Aphex Twin", "artist")
        try t.expect(abs(recs[0].score - 0.98) < 0.001, "score")
    }
    t.test("AcoustID client uses stub http") {
        let client = AcoustIDClient(http: TestSupport.StubHTTPClient(data: cannedAcoustID))
        let recs = try awaitSync { try await client.lookup(Fingerprint(fingerprint: "abc", durationSec: 291), apiKey: "test") }
        try t.expectEqual(recs.first?.title, "Vordhosbn", "resolved via client")
    }
}
