import SwiftUI
import AVFoundation
import MediaPlayer
import OpenSongCore

/// Bridges AVAudioPlayer's Obj-C delegate (which fires on an arbitrary thread) back to the
/// MainActor model, so end-of-track is detected reliably instead of by polling currentTime
/// (which AVAudioPlayer resets to 0 on finish, hiding the "song ended" transition).
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @Sendable (Bool) -> Void
    init(onFinish: @escaping @Sendable (Bool) -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish(flag)
    }
}

@Observable
@MainActor
final class PreviewPlayerModel {
    var current: SongRow?
    var isPlaying = false
    var progress: Double = 0        // 0...1
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Double = 0.8 { didSet { player?.volume = Float(volume) } }
    /// Normal play, repeat the queue, or repeat this track. Remembered between launches — it is a
    /// listening preference, not a per-session one.
    var repeatMode: RepeatMode = RepeatMode(rawValue:
        UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    var showArtWindow = false          // album-art-only takeover mode
    var showVisualiser = false { didSet { syncSampler() } }   // oscilloscope window
    /// Decoded audio for the visualiser — the *only* strong reference to it, so dropping it here
    /// frees the ~20 MB it holds. Nil unless the visualiser window is open.
    private(set) var sampler: ScopeSampler?
    private var mutedFrom: Double? = nil
    private var finished = false     // playback reached the end of the current track

    private var queue: [SongRow] = []
    private var index: Int = 0
    private var player: AVAudioPlayer?
    private var delegate: PlayerDelegate?
    private var tickTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    /// Bumped on every track change; a decode that finishes late compares it and drops its result
    /// rather than installing a sampler for a track that is no longer playing.
    private var samplerGeneration = 0
    private var remoteConfigured = false

    /// The true playhead, read straight from the audio player — the visualiser samples this every
    /// frame, so it must not be the 250 ms `currentTime` tick.
    var audioTime: Double { player?.currentTime ?? 0 }

    func play(_ song: SongRow, in queue: [SongRow] = []) {
        self.queue = queue.isEmpty ? [song] : queue
        self.index = self.queue.firstIndex(where: { $0.id == song.id }) ?? 0
        start(song)
    }

    private func start(_ song: SongRow) {
        let path = (song.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            current = song; isPlaying = false; progress = 0; duration = 0; currentTime = 0; finished = false
            return
        }
        player?.stop()
        let del = PlayerDelegate { [weak self] ok in
            Task { @MainActor in self?.handleFinish(ok) }
        }
        p.delegate = del
        delegate = del
        current = song
        player = p
        finished = false
        p.volume = Float(volume)
        p.play()
        duration = p.duration
        currentTime = 0
        progress = 0
        isPlaying = true
        configureRemoteCommandsIfNeeded()
        updateNowPlaying()
        startTicking()
        // Deliberately last, and off the main actor: the music is already playing by the time the
        // visualiser starts decoding, and the scope shows its centre dot until this lands.
        syncSampler()
    }

    // MARK: visualiser samples

    /// Load or drop the decoded audio to match the current state: decode only while the visualiser
    /// window is open and something is playing, and never hold more than one track's worth.
    private func syncSampler() {
        decodeTask?.cancel()
        decodeTask = nil
        samplerGeneration &+= 1
        sampler = nil                        // free the old track before decoding the next
        guard showVisualiser, let song = current else { return }
        let path = (song.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let generation = samplerGeneration
        decodeTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> ScopeSampler? in
                try? ScopeSampler.decode(URL(fileURLWithPath: path))
            }.value
            guard let self, !Task.isCancelled, generation == self.samplerGeneration else { return }
            self.sampler = decoded
        }
    }

    /// Release everything the visualiser holds (window closed, playback stopped, app quitting).
    func releaseSampler() {
        decodeTask?.cancel(); decodeTask = nil
        samplerGeneration &+= 1
        sampler = nil
    }

    private func handleFinish(_ ok: Bool) {
        guard let nextIndex = PlaybackQueue.afterFinishing(index: index, count: queue.count,
                                                           repeatMode: repeatMode) else {
            // End of queue: stop cleanly and show a paused (replay-ready) state at the end.
            isPlaying = false
            finished = true
            currentTime = duration
            progress = 1
            tickTask?.cancel()
            updateNowPlaying()
            return
        }
        // Landing on the track that just played — repeat-one, or repeat-all with a queue of one —
        // rewinds the file already loaded instead of reopening it, so the gap is as short as the
        // player can make it and the visualiser keeps the samples it has decoded.
        let sameTrack = nextIndex == index
        index = nextIndex
        if sameTrack, let p = player {
            p.currentTime = 0
            currentTime = 0; progress = 0; finished = false
            p.play(); isPlaying = true
            startTicking(); updateNowPlaying()
            return
        }
        start(queue[nextIndex])
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause(); isPlaying = false
        } else {
            if finished { p.currentTime = 0; currentTime = 0; progress = 0; finished = false }
            p.play(); isPlaying = true
            startTicking()
        }
        updateNowPlaying()
    }

    func next() {
        guard let i = PlaybackQueue.afterSkip(index: index, count: queue.count,
                                              repeatMode: repeatMode) else { return }
        index = i; start(queue[i])
    }

    func previous() {
        if currentTime > 3 { seek(toFraction: 0); return }   // restart if past the intro
        guard let i = PlaybackQueue.beforeSkip(index: index, count: queue.count,
                                               repeatMode: repeatMode) else {
            seek(toFraction: 0); return
        }
        index = i; start(queue[i])
    }

    var hasNext: Bool {
        PlaybackQueue.afterSkip(index: index, count: queue.count, repeatMode: repeatMode) != nil
    }
    var hasPrevious: Bool {
        PlaybackQueue.beforeSkip(index: index, count: queue.count, repeatMode: repeatMode) != nil
    }

    /// Step the button through normal → repeat queue → repeat one.
    func cycleRepeatMode() { repeatMode = repeatMode.next }

    /// Replace the queue and start playing (optionally shuffled).
    func playAll(_ songs: [SongRow], shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        let q = shuffled ? songs.shuffled() : songs
        play(q[0], in: q)
    }

    /// Insert songs to play right after the current track (or start playing if idle).
    func playNext(_ songs: [SongRow]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty || current == nil { playAll(songs); return }
        queue.insert(contentsOf: songs, at: min(index + 1, queue.count))
    }

    /// Upcoming songs (after the current one), for the queue viewer.
    var upNext: [SongRow] {
        guard index + 1 < queue.count else { return [] }
        return Array(queue[(index + 1)...])
    }

    /// Remove an upcoming song from the queue (won't touch the current/played portion).
    func removeFromQueue(_ id: Int64) {
        if let i = queue.firstIndex(where: { $0.id == id }), i > index { queue.remove(at: i) }
    }

    func seek(toFraction f: Double) {
        guard let p = player, duration > 0 else { return }
        let t = max(0, min(1, f)) * duration
        p.currentTime = t
        currentTime = t
        progress = duration > 0 ? t / duration : 0
        finished = false
        updateNowPlaying()
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
                guard let self, let p = self.player, self.isPlaying else { continue }
                self.currentTime = p.currentTime
                self.progress = self.duration > 0 ? p.currentTime / self.duration : 0
            }
        }
    }

    // MARK: - System media keys / Now Playing

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }; return .success
        }
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(toFraction: e.positionTime / self.duration)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = current else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if !song.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = song.album }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

/// Streams a YouTube candidate's audio (via a resolved direct URL) so the user can listen to
/// each search result before committing to a full download. Independent of the library player.
@Observable
@MainActor
final class CandidatePreviewModel {
    private(set) var playingID: String?
    private(set) var loadingID: String?
    private(set) var progress: Double = 0     // 0...1 of the previewing candidate
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var timeObserver: Any?
    /// The candidate's real length from search metadata. AVFoundation misreads YouTube's
    /// fragmented-MP4 audio duration (often exactly 2×), so we trust this instead when available.
    private var knownDuration: Double = 0
    /// Resolves a candidate video URL to a directly-streamable audio URL (injected by AppStore).
    var resolver: (@Sendable (URL) async -> URL?)?
    /// Called just before playback starts (used to pause the library player so audio doesn't overlap).
    var onStart: (() -> Void)?

    private var avPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    var isBusy: Bool { playingID != nil || loadingID != nil }

    func toggle(id: String, url: URL, knownDuration: Double = 0) {
        if playingID == id { stop(); return }
        stop()
        self.knownDuration = knownDuration
        loadingID = id
        Task { [weak self] in
            guard let self else { return }
            let resolved = await (self.resolver?(url)) ?? url
            guard self.loadingID == id else { return }   // superseded/canceled while resolving
            self.onStart?()
            let item = AVPlayerItem(url: resolved)
            let p = AVPlayer(playerItem: item)
            self.clearObservers()
            self.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            // If the stream can't be decoded/played, don't leave the row stuck on "pause".
            self.failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            self.avPlayer = p
            self.progress = 0; self.currentTime = 0; self.duration = 0
            // Update the scrubber ~4×/sec while playing.
            self.timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                Task { @MainActor in self?.tick(t) }
            }
            p.play()
            self.playingID = id
            self.loadingID = nil
        }
    }

    private func tick(_ t: CMTime) {
        guard let p = avPlayer else { return }
        currentTime = t.seconds.isFinite ? t.seconds : 0   // AVPlayer's elapsed is real seconds
        // Prefer the search-metadata length; AVPlayer's reported duration is unreliable here.
        if knownDuration > 0 { duration = knownDuration }
        else if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        progress = duration > 0 ? min(1, currentTime / duration) : 0
    }

    /// Seek the previewing candidate to a fraction of its length.
    func seek(toFraction f: Double) {
        guard let p = avPlayer, duration > 0 else { return }
        let t = max(0, min(1, f)) * duration
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        currentTime = t
        progress = f
    }

    func stop() {
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs); timeObserver = nil }
        avPlayer?.pause()
        avPlayer = nil
        clearObservers()
        playingID = nil
        loadingID = nil
        progress = 0; currentTime = 0; duration = 0; knownDuration = 0
    }

    private func clearObservers() {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        if let obs = failObserver { NotificationCenter.default.removeObserver(obs); failObserver = nil }
    }
}

/// Module-wide (not file-private) because the visualiser window's scrubber labels use it too.
func timeStr(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let n = Int(s); return String(format: "%d:%02d", n / 60, n % 60)
}

/// Persistent transport bar above the activity bar.
struct PreviewPlayerBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    let model: PreviewPlayerModel
    @State private var showQueue = false

    var body: some View {
        HStack(spacing: 12) {
            // Now playing (art click opens the mini art window)
            HStack(spacing: 10) {
                if let song = model.current {
                    Button { model.showArtWindow = true } label: {
                        ArtworkThumbnail(path: song.path, seed: song.album, size: 36, corner: 4, version: store.artVersion)
                    }.buttonStyle(.plain).help("Open album art view")
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
                repeatButton
            }

            // Scrubber + times
            Text(timeStr(model.currentTime)).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.text3).frame(width: 34, alignment: .trailing)
            DragBar(value: model.progress, onChange: { model.seek(toFraction: $0) })
                .frame(maxWidth: .infinity)
                .disabled(model.current == nil)
            Text(timeStr(model.duration)).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.text3).frame(width: 34, alignment: .leading)

            // Visualiser (its own window; can be open alongside the art window)
            Button { model.showVisualiser.toggle() } label: {
                Image(systemName: "waveform.circle").font(.system(size: 13))
                    .foregroundStyle(model.showVisualiser ? theme.accent : theme.text3)
            }.buttonStyle(.plain).help("Open the visualiser")

            // Queue
            Button { showQueue.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 13)).foregroundStyle(model.upNext.isEmpty ? theme.text3 : theme.text2)
            }.buttonStyle(.plain).disabled(model.upNext.isEmpty && !showQueue)
                .popover(isPresented: $showQueue, arrowEdge: .top) { queuePopover }

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

    /// Scrollable "Up next" list; each row has a minus button to drop it from the queue.
    private var queuePopover: some View {
        let up = model.upNext
        return VStack(alignment: .leading, spacing: 0) {
            Text("Up Next").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider().overlay(theme.sep)
            if up.isEmpty {
                Text("Queue is empty").font(.system(size: 12)).foregroundStyle(theme.text3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(up) { song in
                            HStack(spacing: 8) {
                                ArtworkThumbnail(path: song.path, seed: song.album, size: 26, corner: 3, version: store.artVersion)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(song.title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
                                    Text(song.artist).font(.system(size: 10)).foregroundStyle(theme.text3).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button { model.removeFromQueue(song.id) } label: {
                                    Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(theme.text3)
                                }.buttonStyle(.plain).help("Remove from queue")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .frame(width: 300)
        .background(theme.sheet)
    }

    /// Normal → repeat queue → repeat one. Off is drawn in the dim colour and the two repeat modes
    /// in the accent, so the state reads at a glance without a label.
    private var repeatButton: some View {
        let mode = model.repeatMode
        let (icon, help): (String, String) = {
            switch mode {
            case .off: return ("repeat", "Play through once — click to repeat the queue")
            case .all: return ("repeat", "Repeating the queue — click to repeat this track")
            case .one: return ("repeat.1", "Repeating this track — click to play through once")
            }
        }()
        return Button { model.cycleRepeatMode() } label: {
            Image(systemName: icon).font(.system(size: 12, weight: mode == .off ? .regular : .semibold))
                .foregroundStyle(mode == .off ? theme.text3 : theme.accent)
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(help)
    }

    private func transportButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundStyle(theme.text2)
    }
}

/// Album-art-only takeover: fills the window with just the current track's cover (whole cover,
/// centered on black — a square tile). Transport controls + a return button fade in on hover.
struct ArtWindowView: View {
    let model: PreviewPlayerModel
    var onReturn: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        // Everything is laid out against the window's own size, taken from a GeometryReader.
        // Without that, a `resizable().aspectRatio()` image reports its *pixel* size as the ideal
        // one, the stack grows to match, and the overlays are centred on that larger box — pushing
        // the scrubber's time labels off the window (visibly worse the wider the cover: ~50pt for a
        // 600px square, clean off-screen for a 1280px video thumbnail).
        GeometryReader { geo in
            artwork
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(alignment: .topTrailing) { returnButton }
                .overlay(alignment: .bottom) {
                    // Invisible controls must not take clicks: a faded-out view is still
                    // hit-testable in SwiftUI, so the scrubber's drag gesture would claim presses
                    // in the bottom strip and interrupt a window drag.
                    if model.current != nil {
                        controls
                            .frame(width: geo.size.width)
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                    }
                }
        }
        .ignoresSafeArea()
        .background(TrafficLightHider(hovering: hovering))   // hide close/min/zoom unless hovering
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: hovering)
    }

    /// A square tile of the cover, centered, with a blurred fill of the same art behind it so there
    /// are no black bars — regardless of the (freely resizable) window's shape.
    private var artwork: some View {
        ZStack {
            if let song = model.current {
                FillArtwork(path: song.path, seed: song.album, contentMode: .fill)
                    .blur(radius: 44).opacity(0.55)
                    .overlay(Color.black.opacity(0.35))
                FillArtwork(path: song.path, seed: song.album, contentMode: .fit)   // whole cover
            } else {
                Color.black
            }
            WindowDragLayer()   // drag the window from anywhere on the artwork
        }
    }

    private var returnButton: some View {
        Button { onReturn() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(9).background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain).padding(14)
        .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 30) {
                Button { model.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 16)) }
                Button { model.toggle() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24)) }
                Button { model.next() } label: { Image(systemName: "forward.fill").font(.system(size: 16)) }
            }.foregroundStyle(.white).buttonStyle(.plain)
            HStack(spacing: 10) {
                timeLabel(model.currentTime, alignment: .leading)
                DragBar(value: model.progress, onChange: { model.seek(toFraction: $0) }, height: 4)
                timeLabel(model.duration, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 18)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
    }

    private func timeLabel(_ t: Double, alignment: Alignment) -> some View {
        Text(timeStr(t))
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).fixedSize()
            .frame(width: 34, alignment: alignment)
    }
}

/// Presents the album-art view in its own dedicated, square (1:1), small-min panel — a separate
/// window from the main one, so it can have a totally different minimum size and shape without
/// fighting the main window's larger min. Kept in sync with `model.showArtWindow`.
/// The art window.
///
/// A plain `NSWindow`, deliberately *not* an `NSPanel`: with Stage Manager enabled, macOS's window
/// manager treats panels as auxiliary/dialog windows anchored to the app's stage, and re-places them
/// after you drag them — the window server moves the window back without `NSWindow`'s frame ever
/// changing, which is the "springs back like elastic" bug (a standard window, like the app's main
/// one, drags freely under Stage Manager).
///
/// With `OPENSONG_DEBUG_ART=1` it traces every frame change and the code that caused it — the only
/// practical way to diagnose this, since synthetic mouse events aren't delivered to other apps, so
/// a human has to do the dragging.
/// Usage: `OPENSONG_DEBUG_ART=1 ~/Applications/OpenSong.app/Contents/MacOS/OpenSong 2>art.log`
final class ArtPanel: NSWindow {
    static let debug = ProcessInfo.processInfo.environment["OPENSONG_DEBUG_ART"] == "1"
    static func log(_ s: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[art] \(s)\n".utf8))
    }
    private func trace(_ what: String, _ r: NSRect) {
        guard Self.debug else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(7)
            .map { $0.split(separator: " ").dropFirst(3).prefix(4).joined(separator: " ") }
        Self.log("\(what) → \(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))\n        "
                 + frames.joined(separator: "\n        "))
    }
    override func setFrame(_ frameRect: NSRect, display: Bool) {
        trace("setFrame", frameRect); super.setFrame(frameRect, display: display)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        trace("setFrameOrigin", NSRect(origin: point, size: frame.size)); super.setFrameOrigin(point)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let out = super.constrainFrameRect(frameRect, to: screen)
        if Self.debug, out != frameRect {
            Self.log("constrained \(Int(frameRect.origin.x)),\(Int(frameRect.origin.y)) → \(Int(out.origin.x)),\(Int(out.origin.y))")
        }
        return out
    }
    /// Poll the live frame: AppKit moves titled windows without going through the setters above,
    /// so this is what shows a move actually happening — and then being undone.
    func startFrameWatch() {
        guard Self.debug else { return }
        var last = NSRect.zero
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.frame != last else { return }
                last = self.frame
                Self.log("frame \(Int(last.origin.x)),\(Int(last.origin.y)) \(Int(last.width))x\(Int(last.height))"
                         + " tiled=\(self.isTiled) key=\(self.isKeyWindow)")
            }
        }
    }
    /// Whether macOS has tiled this window to a screen edge (Sequoia's drag-to-edge tiling, which
    /// restores the pre-tile frame when you drag the window away again — a plausible "spring back").
    private var isTiled: Bool {
        guard let screen = screen else { return false }
        let f = frame, v = screen.visibleFrame
        return abs(f.height - v.height) < 2 && abs(f.width - v.width / 2) < 2
    }
}

/// A transparent AppKit layer that drags the window via `performDrag(with:)`.
///
/// This has to be AppKit, not a SwiftUI gesture. Dragging the panel through SwiftUI
/// (`WindowDragGesture`) or through `isMovableByWindowBackground` moved it at the window-server
/// level *without* `NSWindow` updating its own cached frame — so the next time AppKit asserted that
/// cache (on the next hover/re-render) the window jumped back to the last frame AppKit itself had
/// set, which is why it always snapped to the same spot. `performDrag(with:)` runs AppKit's own
/// drag loop, so the frame, the delegate callbacks and the saved position all stay in step.
///
/// Sits above the artwork and below the controls in the ZStack, so the transport buttons and
/// scrubber still get their clicks first.
struct WindowDragLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
        override var mouseDownCanMoveWindow: Bool { false }   // we do it ourselves, above
    }
}

struct ArtPanelPresenter: NSViewRepresentable {
    var show: Bool
    let model: PreviewPlayerModel
    let theme: Theme
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(show: show, model: model, theme: theme, mainWindow: nsView.window)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: ArtPanel?
        private weak var model: PreviewPlayerModel?
        private weak var mainWindow: NSWindow?
        /// Whether the panel is currently presented. `sync` runs on every SwiftUI update of the
        /// main window — which happens 4×/second while a track plays (the elapsed-time tick) — so
        /// it must only act on an actual change. Re-ordering the panel front mid-drag cancels the
        /// drag and AppKit snaps the window back to where it started.
        private var shown = false

        func sync(show: Bool, model: PreviewPlayerModel, theme: Theme, mainWindow: NSWindow?) {
            self.model = model
            if let mainWindow { self.mainWindow = mainWindow }
            guard show else { if shown { dismiss() }; return }
            guard !shown else { return }
            if panel == nil {
                let p = ArtPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                            .fullSizeContentView],
                                backing: .buffered, defer: false)
                p.titlebarAppearsTransparent = true
                p.titleVisibility = .hidden
                // Dragging is handled by `WindowDragLayer` (AppKit's own drag loop). The background
                // -drag path moved the window without NSWindow tracking it, which is what let the
                // frame snap back to AppKit's cached one.
                p.isMovableByWindowBackground = false
                p.isReleasedWhenClosed = false
                p.hidesOnDeactivate = false
                p.minSize = NSSize(width: 200, height: 200)             // its own (small) minimum
                p.contentAspectRatio = NSSize(width: 1, height: 1)      // always square
                p.delegate = self
                p.contentView = NSHostingView(rootView:
                    ArtWindowView(model: model, onReturn: { [weak self] in self?.dismiss() })
                        .environment(\.theme, theme))
                // Reopen where it was left last time; centre it only on a first run. Saved by hand
                // (see `windowDidMove`) rather than with `setFrameAutosaveName`: AppKit's autosave
                // string was the frame the window kept snapping back to, and it never updated.
                if let saved = Self.savedFrame() { p.setFrame(saved, display: false) } else { p.center() }
                p.startFrameWatch()
                panel = p
            }
            // Show the art panel INSTEAD of the main window (one window at a time). The presenter's
            // view can still be window-less the first time this runs, so fall back to finding the
            // app's main window — otherwise both windows end up on screen, stacked.
            shown = true
            panel?.makeKeyAndOrderFront(nil)
            if self.mainWindow == nil {
                self.mainWindow = NSApp.windows.first {
                    $0 !== panel && ($0.contentView?.frame.height ?? 0) > 300
                }
            }
            self.mainWindow?.orderOut(nil)
        }

        /// Close the art panel and bring the main window back.
        private func dismiss() {
            shown = false
            model?.showArtWindow = false
            if panel?.isVisible == true { panel?.orderOut(nil) }
            mainWindow?.makeKeyAndOrderFront(nil)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

        // MARK: remembering where the user put it

        private static let frameKey = "artPanelFrame"

        func windowDidMove(_ notification: Notification) { saveFrame() }
        func windowDidResize(_ notification: Notification) { saveFrame() }

        private func saveFrame() {
            guard let f = panel?.frame else { return }
            UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.frameKey)
        }

        static func savedFrame() -> NSRect? {
            guard let s = UserDefaults.standard.string(forKey: frameKey) else { return nil }
            let r = NSRectFromString(s)
            guard r.width >= 200, r.height >= 200 else { return nil }
            // Only reuse it if it's still on a screen — displays come and go.
            guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return nil }
            return r
        }
    }
}

/// Hides the window's traffic-light buttons (close/minimize/zoom) unless the mouse is over the
/// window — for the distraction-free album-art and visualiser views.
///
/// Does nothing in fullscreen, where macOS hides the whole titlebar itself and reveals it when the
/// pointer reaches the top of the screen. Managing the buttons there fought the system and inverted
/// them: moving the pointer up to the titlebar takes it *out* of the SwiftUI content view, so hover
/// ended, so the buttons were hidden at exactly the moment they were reached for — and shown again
/// on the way back down, where they couldn't be clicked.
struct TrafficLightHider: NSViewRepresentable {
    var hovering: Bool
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let show = hovering
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            let fullScreen = w.styleMask.contains(.fullScreen)
            for b in Self.buttons { w.standardWindowButton(b)?.isHidden = fullScreen ? false : !show }
        }
    }
}

/// Loads embedded cover art (like ArtworkThumbnail) for the full-window art view, at a given
/// content mode (`.fill` for a blurred background layer, `.fit` for the sharp centered cover).
struct FillArtwork: View {
    let path: String
    let seed: String
    var contentMode: ContentMode = .fill
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else { Rectangle().fill(placeholderGradient(seed)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { return }
        let cache = ArtworkCache.cacheURL(forMaster: expanded)
        if await ArtworkCache.ensure(master: expanded, cache: cache, ffmpegPath: ffmpegPath) {
            image = NSImage(contentsOf: cache)
        }
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
