import Foundation
import OpenSongCore

extension AppStore {
    /// Seed a fresh library with representative sample tracks so the UI is populated
    /// on first launch (replaced by the user's real library once they import/adopt).
    func seedSampleData(_ store: LibraryStore) throws {
        struct S { let title: String; let artist: String; let album: String; let dur: Double
                   let fmt: String; let kbps: Int; let track: Int; let year: Int; let genre: String }
        let samples: [S] = [
            S(title: "We Are the Music Makers", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", dur: 463, fmt: "flac", kbps: 1005, track: 1, year: 1992, genre: "Electronic"),
            S(title: "Vordhosbn", artist: "Aphex Twin", album: "Drukqs", dur: 291, fmt: "flac", kbps: 1005, track: 2, year: 2001, genre: "Electronic"),
            S(title: "Avril 14th", artist: "Aphex Twin", album: "Drukqs", dur: 125, fmt: "flac", kbps: 1005, track: 3, year: 2001, genre: "Electronic"),
            S(title: "Triste", artist: "Sérgio Mendes", album: "Brasileiro", dur: 127, fmt: "mp3", kbps: 320, track: 1, year: 1992, genre: "Bossa Nova"),
            S(title: "Água de Beber", artist: "Sérgio Mendes", album: "Brasileiro", dur: 149, fmt: "mp3", kbps: 320, track: 4, year: 1992, genre: "Bossa Nova"),
            S(title: "Feel Good Inc.", artist: "Gorillaz", album: "Demon Days", dur: 222, fmt: "mp3", kbps: 320, track: 6, year: 2005, genre: "Alternative"),
            S(title: "Dare", artist: "Gorillaz", album: "Demon Days", dur: 245, fmt: "mp3", kbps: 256, track: 11, year: 2005, genre: "Alternative"),
            S(title: "Nikes", artist: "Frank Ocean", album: "Blonde", dur: 314, fmt: "alac", kbps: 940, track: 1, year: 2016, genre: "R&B"),
            S(title: "Ivy", artist: "Frank Ocean", album: "Blonde", dur: 249, fmt: "alac", kbps: 940, track: 2, year: 2016, genre: "R&B"),
            S(title: "Self Control", artist: "Frank Ocean", album: "Blonde", dur: 249, fmt: "alac", kbps: 940, track: 8, year: 2016, genre: "R&B"),
            S(title: "Redbone", artist: "Childish Gambino", album: "Awaken, My Love!", dur: 327, fmt: "mp3", kbps: 320, track: 5, year: 2016, genre: "Funk"),
            S(title: "Peaceland", artist: "Nujabes", album: "Modal Soul", dur: 201, fmt: "mp3", kbps: 320, track: 4, year: 2005, genre: "Hip-Hop"),
            S(title: "Aruarian Dance", artist: "Nujabes", album: "Departure", dur: 244, fmt: "mp3", kbps: 320, track: 7, year: 2003, genre: "Hip-Hop"),
            S(title: "Helmet", artist: "Steve Lacy", album: "Gemini Rights", dur: 173, fmt: "mp3", kbps: 256, track: 4, year: 2022, genre: "R&B"),
            S(title: "Bad Habit", artist: "Steve Lacy", album: "Gemini Rights", dur: 232, fmt: "mp3", kbps: 256, track: 6, year: 2022, genre: "R&B"),
        ]

        var idsByTitle: [String: Int64] = [:]
        for (i, s) in samples.enumerated() {
            let ident = TrackIdentity(title: s.title, artist: s.artist, albumArtist: s.artist,
                                      album: s.album, trackNumber: s.track, discNumber: 1,
                                      genre: s.genre, year: s.year, durationSec: s.dur,
                                      provenance: .itunesResolved)
            let identID = try store.upsertIdentity(ident)
            let asset = AudioAsset(identityID: identID,
                                   masterPath: "~/Music/OpenSong Library/\(s.artist)/\(s.album)/\(s.title).\(s.fmt)",
                                   format: s.fmt, bitrateKbps: s.kbps, sampleRate: 44100,
                                   sizeBytes: Int64(Double(s.kbps) * 1000 / 8 * s.dur),
                                   contentHash: "sample-\(i)", source: .importedLoose)
            let assetID = try store.insertAsset(asset)
            idsByTitle[s.title] = assetID
        }

        // A couple of playlists.
        let chill = try store.createPlaylist(name: "late night", syncToDevice: true)
        for (pos, title) in ["Ivy", "Self Control", "Aruarian Dance", "Peaceland"].enumerated() {
            if let a = idsByTitle[title] { try store.addToPlaylist(playlistID: chill, assetID: a, position: pos) }
        }
        let energy = try store.createPlaylist(name: "bangers", syncToDevice: false)
        for (pos, title) in ["Feel Good Inc.", "Redbone", "Bad Habit", "Dare"].enumerated() {
            if let a = idsByTitle[title] { try store.addToPlaylist(playlistID: energy, assetID: a, position: pos) }
        }

        // Pin a few as "on device set".
        for title in ["Vordhosbn", "Feel Good Inc.", "Redbone"] {
            if let a = idsByTitle[title] { try store.pin(assetID: a, true) }
        }
    }
}
