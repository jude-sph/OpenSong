import Foundation
import OpenSongCore

func registerDeviceRelativePathTests() {
    t.test("backslashPath builds Artist\\Album\\Title.mp3") {
        let i = TrackIdentity(title: "Vordhosbn", artist: "Aphex Twin",
                              albumArtist: "Aphex Twin", album: "Drukqs", durationSec: 291)
        try t.expectEqual(DeviceRelativePath.backslashPath(for: i),
                          "Aphex Twin\\Drukqs\\Vordhosbn.mp3", "backslash path")
    }
    t.test("missing album -> Unknown Album segment") {
        let i = TrackIdentity(title: "T69 Collapse", artist: "Aphex Twin", durationSec: 318)
        try t.expectEqual(DeviceRelativePath.backslashPath(for: i),
                          "Aphex Twin\\Unknown Album\\T69 Collapse.mp3", "unknown album")
    }
    t.test("fileURL uses forward slashes on disk") {
        let i = TrackIdentity(title: "Vordhosbn", artist: "Aphex Twin",
                              albumArtist: "Aphex Twin", album: "Drukqs", durationSec: 291)
        let url = DeviceRelativePath.fileURL(under: URL(fileURLWithPath: "/M"), for: i)
        try t.expectEqual(url.path, "/M/Aphex Twin/Drukqs/Vordhosbn.mp3", "disk url")
    }
    t.test("illegal chars sanitized in path") {
        let i = TrackIdentity(title: "AC/DC Mix", artist: "V/A", album: "Best: Of", durationSec: 100)
        try t.expectEqual(DeviceRelativePath.backslashPath(for: i),
                          "V A\\Best Of\\AC DC Mix.mp3", "sanitized components")
    }
}
