import SwiftUI
import AppKit
import OpenSongCore

/// The visualiser's own window: the oscilloscope with no chrome until you hover.
///
/// Deliberately a plain `NSWindow`, never an `NSPanel` — with Stage Manager on, macOS treats
/// panel-class windows as auxiliary and re-places them after a drag (see FEEDBACK v0.3.37). Unlike
/// the art window it has no aspect-ratio lock and allows native fullscreen, so it can fill a 16:9
/// second display.
final class VisualiserPanel: NSWindow {
    /// Minimising is refused while fullscreen, which is what the system does for every other
    /// fullscreen window (its yellow button is greyed out). A fullscreen window has a Space to
    /// itself; taking the window out of that Space leaves the Space behind as an empty black
    /// desktop and drops you back on the previous one. Ours allowed it because the visualiser draws
    /// its own chrome and so had the button enabled.
    override func miniaturize(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen) else { return }
        super.miniaturize(sender)
    }
    /// The traffic-light button and ⌘M both come through here rather than `miniaturize`.
    override func performMiniaturize(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen) else { return }
        super.performMiniaturize(sender)
    }
}

struct VisualiserPresenter: NSViewRepresentable {
    var show: Bool
    let model: PreviewPlayerModel
    let theme: Theme

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(show: show, model: model, theme: theme)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private var window: VisualiserPanel?
        private weak var model: PreviewPlayerModel?
        /// Act only on a real show/hide change: `updateNSView` runs on every SwiftUI update, and
        /// re-ordering a window mid-drag cancels the drag.
        private var shown = false
        /// Set when the window has to leave fullscreen before it can be hidden.
        private var hideAfterExitingFullScreen = false

        func sync(show: Bool, model: PreviewPlayerModel, theme: Theme) {
            self.model = model
            guard show else { if shown { dismiss() }; return }
            guard !shown else { return }
            if window == nil {
                let debugBig = ProcessInfo.processInfo.environment["OPENSONG_VIS_BIG"] == "1"
                let w = VisualiserPanel(contentRect: NSRect(x: 0, y: 0, width: debugBig ? 1300 : 620, height: debugBig ? 900 : 420),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                                    .fullSizeContentView],
                                        backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.title = "Visualiser"
                w.isMovableByWindowBackground = false      // dragging is handled by WindowDragLayer
                w.isReleasedWhenClosed = false
                w.hidesOnDeactivate = false
                w.minSize = NSSize(width: 240, height: 180)
                w.backgroundColor = NSColor(red: 0.02, green: 0.03, blue: 0.035, alpha: 1)
                w.collectionBehavior.insert(.fullScreenPrimary)   // fills a second monitor
                w.delegate = self
                w.contentView = NSHostingView(rootView:
                    VisualiserWindowView(model: model, onClose: { [weak self] in self?.dismiss() })
                        .environment(\.theme, theme))
                if let saved = Self.savedFrame() { w.setFrame(saved, display: false) } else { w.center() }
                window = w
            }
            shown = true
            window?.makeKeyAndOrderFront(nil)
            if ScopeView.debug {
                // Measuring only works on a window macOS is actually drawing: an occluded window's
                // rendering is suspended, which is why the harness saw zero frames.
                window?.level = .floating
                window?.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        private func dismiss() {
            shown = false
            model?.showVisualiser = false
            guard let w = window, w.isVisible else { return }
            if w.styleMask.contains(.fullScreen) {
                // Same trap as minimising: ordering a fullscreen window out would strand its Space
                // as an empty black desktop. Leave fullscreen first and hide once that finishes.
                hideAfterExitingFullScreen = true
                w.toggleFullScreen(nil)
            } else {
                w.orderOut(nil)
            }
        }

        // The system greys out minimise for fullscreen windows; ours draws its own chrome, so it
        // has to say so itself.
        func windowDidEnterFullScreen(_ notification: Notification) {
            window?.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        }
        func windowDidExitFullScreen(_ notification: Notification) {
            window?.standardWindowButton(.miniaturizeButton)?.isEnabled = true
            if hideAfterExitingFullScreen {
                hideAfterExitingFullScreen = false
                window?.orderOut(nil)
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

        // Position is saved by hand rather than with `setFrameAutosaveName`, whose stale value was
        // what the art window kept snapping back to.
        private static let frameKey = "visualiserFrame"
        func windowDidMove(_ notification: Notification) { saveFrame() }
        func windowDidResize(_ notification: Notification) { saveFrame() }
        private func saveFrame() {
            guard let f = window?.frame, window?.styleMask.contains(.fullScreen) == false else { return }
            UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.frameKey)
        }
        static func savedFrame() -> NSRect? {
            guard let s = UserDefaults.standard.string(forKey: frameKey) else { return nil }
            let r = NSRectFromString(s)
            guard r.width >= 240, r.height >= 180,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return nil }
            return r
        }
    }
}

/// Window contents: the scope, with title and transport fading in on hover.
struct VisualiserWindowView: View {
    let model: PreviewPlayerModel
    var onClose: () -> Void = {}
    /// The pointer is inside the window.
    @State private var hovering = false
    /// …and has moved recently. Fullscreen has no "outside" to move the pointer to, so hover alone
    /// would leave the chrome up for good; stillness is what means "done with the controls".
    @State private var moving = false
    @State private var lastPoint = CGPoint.zero
    @State private var idleTask: Task<Void, Never>?
    /// Owned here so it lives exactly as long as the window's content.
    @State private var clock = ScopeClock()

    /// How long the pointer has to sit still before the chrome fades.
    private let idleDelay = Duration.seconds(2.5)
    private var chromeVisible: Bool { hovering && moving }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ScopeView(sampler: model.sampler,
                          playhead: { model.audioTime },
                          isPlaying: model.isPlaying,
                          clock: clock)
                WindowDragLayer()      // drag from anywhere on the trace
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .top) { header.frame(width: geo.size.width) }
            .overlay(alignment: .bottom) { controls.frame(width: geo.size.width) }
        }
        .ignoresSafeArea()
        .background(TrafficLightHider(hovering: chromeVisible))
        // Tick only while there's something to animate; a paused track holds its last sweep.
        .onAppear { if model.isPlaying { clock.start() } }
        .onDisappear { clock.stop(); idleTask?.cancel() }
        .onChange(of: model.isPlaying) { _, playing in playing ? clock.start() : clock.stop() }
        // `onContinuousHover` reports the pointer's position, which is what tells movement from mere
        // presence; plain `onHover` only fires on enter and exit.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hovering = true
                // A couple of points of slack, so a trembling hand doesn't count as movement.
                if abs(point.x - lastPoint.x) > 2 || abs(point.y - lastPoint.y) > 2 {
                    lastPoint = point
                    wake()
                }
            case .ended:
                hovering = false
                idleTask?.cancel()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
    }

    /// Show the chrome and start the clock that hides it again once the pointer settles. In
    /// fullscreen the pointer is hidden along with it, so nothing sits over the trace.
    private func wake() {
        moving = true
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            moving = false
            // Only in fullscreen, and only this window's state — `keyWindow` could be the main
            // window while the pointer rests over the visualiser. In a normal window the pointer
            // has to stay: it is how you reach everything else.
            let visualiser = NSApp.windows.first { $0 is VisualiserPanel }
            if visualiser?.styleMask.contains(.fullScreen) == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.current?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let artist = model.current?.artist, !artist.isEmpty {
                    Text(artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if model.sampler == nil, model.current != nil {
                Text("warming up…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        // Leading inset clears the traffic lights, which sit in the same corner and appear at the
        // same time (both are revealed on hover).
        .padding(.leading, 78).padding(.trailing, 20).padding(.top, 14).padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear],
                                   startPoint: .top, endPoint: .bottom))
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 26) {
                button("backward.fill", 15) { model.previous() }
                button(model.isPlaying ? "pause.fill" : "play.fill", 22) { model.toggle() }
                button("forward.fill", 15) { model.next() }
            }
            // Same scrubber as the art window, so seeking works the same in either view. Only
            // shown with a track loaded: a bar with nothing behind it invites a drag that can't
            // do anything.
            if model.current != nil {
                HStack(spacing: 10) {
                    timeLabel(model.currentTime, alignment: .leading)
                    DragBar(value: model.progress, onChange: { model.seek(toFraction: $0) }, height: 4)
                    timeLabel(model.duration, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom))
        // A faded-out view still takes clicks in SwiftUI, so the scrubber's drag gesture would
        // otherwise swallow presses in the bottom strip and break dragging the window by the trace.
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    private func timeLabel(_ t: Double, alignment: Alignment) -> some View {
        Text(timeStr(t))
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).fixedSize()
            .frame(width: 34, alignment: alignment)
    }

    private func button(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}
