import Foundation
import OpenSongCore

func registerDeviceManagerTests() {
    t.test("write places file, listManagedTracks finds it, remove deletes it") {
        let root = try TestSupport.tempDir("dev")
        let volume = try TempVolume(root: root)
        let manager = DeviceManager(volume: volume)

        // Make a source mp3 to push.
        let src = try TestSupport.tempDir("src").appendingPathComponent("s.mp3")
        try TestSupport.makeMP3(at: src, title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs", seconds: 1)
        let ident = TrackIdentity(title: "Vordhosbn", artist: "Aphex Twin",
                                  albumArtist: "Aphex Twin", album: "Drukqs", durationSec: 1)

        try manager.write(assetFile: src, to: ident)
        let expected = volume.musicDir.appendingPathComponent("Aphex Twin/Drukqs/Vordhosbn.mp3")
        try t.expect(FileManager.default.fileExists(atPath: expected.path), "written to device")

        let tracks = try manager.listManagedTracks()
        try t.expectEqual(tracks, ["Aphex Twin\\Drukqs\\Vordhosbn.mp3"], "listed with backslash path")

        try manager.remove(relative: "Aphex Twin\\Drukqs\\Vordhosbn.mp3")
        try t.expect(!FileManager.default.fileExists(atPath: expected.path), "removed")
        try t.expectEqual(try manager.listManagedTracks().count, 0, "empty after remove")
    }

    t.test("writePlaylist writes .m3u8 bytes into MUSIC") {
        let root = try TestSupport.tempDir("dev")
        let volume = try TempVolume(root: root)
        let manager = DeviceManager(volume: volume)
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("#EXTM3U\r\n".utf8)
        try manager.writePlaylist(name: "mix", data: bytes)
        let file = volume.musicDir.appendingPathComponent("mix.m3u8")
        try t.expectEqual(try Data(contentsOf: file), bytes, "playlist bytes written")
        try t.expectEqual(try manager.existingPlaylists().count, 1, "one playlist")
    }

    t.test("scope guard rejects path traversal and system files") {
        let root = try TestSupport.tempDir("dev")
        let volume = try TempVolume(root: root)
        // Plant a system file at the volume root to ensure it survives.
        let wmp = root.appendingPathComponent("WMPInfo.xml")
        try Data("keep".utf8).write(to: wmp)
        let manager = DeviceManager(volume: volume)

        try t.expectThrows("traversal to sibling must be refused") {
            try manager.remove(relative: "..\\WMPInfo.xml")
        }
        try t.expect(FileManager.default.fileExists(atPath: wmp.path), "system file untouched")
        try t.expectThrows("invalid playlist name refused") {
            try manager.writePlaylist(name: "../evil", data: Data())
        }
    }
}
