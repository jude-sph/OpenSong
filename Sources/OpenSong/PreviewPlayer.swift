import SwiftUI
import AVFoundation

@Observable
@MainActor
final class PreviewPlayerModel {
    var current: SongRow?
    var isPlaying = false
    var progress: Double = 0        // 0...1
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Double = 0.8 { didSet { player?.volume = Float(volume) } }
    private var mutedFrom: Double? = nil

    private var queue: [SongRow] = []
    private var index: Int = 0
    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    func play(_ song: SongRow, in queue: [SongRow] = []) {
        self.queue = queue.isEmpty ? [song] : queue
        self.index = self.queue.firstIndex(where: { $0.id == song.id }) ?? 0
        start(song)
    }

    private func start(_ song: SongRow) {
        let path = (song.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            current = song; isPlaying = false; progress = 0; duration = 0; currentTime = 0
            return
        }
        player?.stop()
        current = song
        player = p
        p.volume = Float(volume)
        p.play()
        duration = p.duration
        isPlaying = true
        startTicking()
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
    }

    func next() {
        guard index + 1 < queue.count else { return }
        index += 1; start(queue[index])
    }

    func previous() {
        if currentTime > 3 { seek(toFraction: 0); return }   // restart if past the intro
        guard index - 1 >= 0 else { seek(toFraction: 0); return }
        index -= 1; start(queue[index])
    }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }

    func seek(toFraction f: Double) {
        guard let p = player, duration > 0 else { return }
        let t = max(0, min(1, f)) * duration
        p.currentTime = t
        currentTime = t
        progress = duration > 0 ? t / duration : 0
    }

    func toggleMute() {
        if let m = mutedFrom { volume = m; mutedFrom = nil }
        else { mutedFrom = volume; volume = 0 }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let p = self.player else { continue }
                self.currentTime = p.currentTime
                self.progress = self.duration > 0 ? p.currentTime / self.duration : 0
                if self.isPlaying && !p.isPlaying && p.currentTime >= self.duration - 0.1 {
                    self.next()   // auto-advance
                }
            }
        }
    }
}

private func timeStr(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let n = Int(s); return String(format: "%d:%02d", n / 60, n % 60)
}

/// Persistent transport bar above the activity bar.
struct PreviewPlayerBar: View {
    @Environment(\.theme) private var theme
    let model: PreviewPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            // Now playing
            HStack(spacing: 10) {
                if let song = model.current {
                    ArtworkThumbnail(path: song.path, seed: song.album, size: 36, corner: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                        Text(song.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    }
                } else {
                    Image(systemName: "music.note").foregroundStyle(theme.text3)
                    Text("Nothing playing").font(.system(size: 12)).foregroundStyle(theme.text3)
                }
            }
            .frame(width: 210, alignment: .leading)

            // Transport
            HStack(spacing: 14) {
                transportButton("backward.fill") { model.previous() }.disabled(!model.hasPrevious && model.currentTime <= 3)
                Button { model.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                }.buttonStyle(.plain).foregroundStyle(model.current == nil ? theme.text3 : theme.text).disabled(model.current == nil)
                transportButton("forward.fill") { model.next() }.disabled(!model.hasNext)
            }

            // Scrubber + times
            Text(timeStr(model.currentTime)).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.text3).frame(width: 34, alignment: .trailing)
            DragBar(value: model.progress, onChange: { model.seek(toFraction: $0) })
                .frame(maxWidth: .infinity)
                .disabled(model.current == nil)
            Text(timeStr(model.duration)).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.text3).frame(width: 34, alignment: .leading)

            // Volume
            HStack(spacing: 6) {
                Button { model.toggleMute() } label: {
                    Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12)).foregroundStyle(theme.text3)
                }.buttonStyle(.plain)
                DragBar(value: model.volume, onChange: { model.volume = $0 }, height: 3).frame(width: 64)
            }
        }
        .padding(.horizontal, 16).frame(height: 56)
        .background(theme.header)
    }

    private func transportButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundStyle(theme.text2)
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
