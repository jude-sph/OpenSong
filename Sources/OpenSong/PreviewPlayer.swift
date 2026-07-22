import SwiftUI
import AVFoundation

@Observable
@MainActor
final class PreviewPlayerModel {
    var current: SongRow?
    var isPlaying = false
    var progress: Double = 0
    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    func play(_ song: SongRow) {
        let path = (song.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            current = song; isPlaying = false; progress = 0
            return
        }
        player?.stop()
        current = song
        player = p
        p.play()
        isPlaying = true
        startTicking()
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, let p = self.player else { continue }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying && self.isPlaying && p.currentTime >= p.duration - 0.05 {
                    self.isPlaying = false
                }
            }
        }
    }
}

/// Persistent transport bar above the activity bar.
struct PreviewPlayerBar: View {
    @Environment(\.theme) private var theme
    let model: PreviewPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            if let song = model.current {
                ArtworkThumbnail(path: song.path, seed: song.album, size: 34, corner: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    Text(song.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                }.frame(width: 160, alignment: .leading)
            } else {
                Image(systemName: "music.note").foregroundStyle(theme.text3)
                Text("Nothing playing").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Button { model.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(model.current == nil ? theme.text3 : theme.text)
            .disabled(model.current == nil)
            ProgressBar(value: model.progress).frame(maxWidth: .infinity)
            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(theme.header)
    }
}

struct MenuBarExtraView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenSong").font(.headline)
            if store.device.connected {
                Text("Walkman: \(store.device.songCount) songs · \(byteLabel(store.device.freeBytes)) free")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Sync now") { store.runSync() }
            } else {
                Text("Walkman — Offline").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            Text("\(store.songs.count) songs in library").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 240)
    }
}
