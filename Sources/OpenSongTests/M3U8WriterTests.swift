import Foundation
import OpenSongCore

/// The 9 entries of the real device playlist `device-brazil.m3u8`, reconstructed as
/// identities so we can assert the writer reproduces the device bytes exactly.
private func brazilEntries() -> [(identity: TrackIdentity, durationSec: Int)] {
    func e(_ artist: String, _ album: String, _ title: String, _ dur: Int)
        -> (identity: TrackIdentity, durationSec: Int) {
        (TrackIdentity(title: title, artist: artist, albumArtist: artist, album: album,
                       durationSec: Double(dur)), dur)
    }
    return [
        e("Sérgio Mendes", "Unknown Album", "Triste", 127),
        e("Jorge Ben", "Samba Esquema Novo", "Tim Dom Dom", 139),
        e("Caterina Valente", "Unknown Album", "Samba Di Una Nota", 105),
        e("Stan Getz", "The Best Of Two Worlds", "Retrato Em Branco e Preto (feat. Stan Getz)", 244),
        e("Herbie Mann & Antonio Carlos Jobim", "Recorded In Rio (Original Bossa Nova Album 1962)", "One Note Samba", 202),
        e("Vanessa da Mata", "Unknown Album", "não me deixe só", 189),
        e("Jorge Ben & Toquinho", "Brazilian Beats 1 (Mr Bongo presents)", "Carolina Carol Bela", 188),
        e("Sérgio Mendes", "Unknown Album", "Agua De Beber", 149),
        e("Latejapride_", "Efecto Dominó", "Acuarela (feat. Luisa Pereira)", 263),
    ]
}

func registerM3U8WriterTests() {
    t.test("writer reproduces device bytes exactly (golden)") {
        let golden = try Data(contentsOf: fixtureURL("device-brazil.m3u8"))
        let produced = M3U8Writer.data(entries: brazilEntries())
        try t.expect(produced == golden,
                     "byte mismatch: produced \(produced.count) bytes, golden \(golden.count) bytes")
    }
    t.test("writer starts with UTF-8 BOM and CRLF") {
        let d = M3U8Writer.data(entries: brazilEntries())
        try t.expect(Array(d.prefix(3)) == [0xEF, 0xBB, 0xBF], "BOM prefix")
        // "#EXTM3U" then CRLF: bytes 3..9 == '#EXTM3U', 10..11 == 0D 0A
        try t.expect(Array(d[10...11]) == [0x0D, 0x0A], "CRLF after header")
    }
}
