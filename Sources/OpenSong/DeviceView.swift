import SwiftUI
import AppKit

struct CapacityRing: View {
    var fraction: Double
    var centerTop: String
    var centerBottom: String
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: 9)
            Circle().trim(from: 0, to: max(0.01, min(1, fraction)))
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centerTop).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
                Text(centerBottom).font(.system(size: 9)).foregroundStyle(theme.text3)
            }
        }
    }
}

/// The Device screen. One layout whether the device is plugged in or not: while it's unplugged,
/// what's recorded on it is assumed unchanged, edits queue up as the pending diff, and one Sync on
/// reconnect applies them (the live plan then catches any drift).
struct DeviceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    /// Songs the user asked to take off the device that a syncing playlist holds — they need an
    /// explicit choice (stop syncing the playlist, or remove them from it).
    @State private var removeRequest: [DeviceSongRow]? = nil

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: headerTitle, subtitle: statusLine) { EmptyView() }
            Divider().overlay(theme.sep)
            if store.device.connected || store.device.known { content } else { neverSeen }
        }
        .onAppear { store.buildSyncPreview() }
        .confirmationDialog("On the device through a playlist",
                            isPresented: Binding(get: { removeRequest != nil },
                                                 set: { if !$0 { removeRequest = nil } }),
                            presenting: removeRequest) { rows in
            removalChoices(rows)
        } message: { _ in
            Text("Choose how to take these songs off the device. A playlist only changes if you pick that.")
        }
    }

    // MARK: header

    private var headerTitle: String {
        let d = store.device
        guard d.connected || d.known else { return "Device" }
        return store.deviceKind == .shuffle || d.name.hasPrefix("iPod") ? d.name : "Sony \(d.name)"
    }

    private var statusLine: String {
        let d = store.device
        if d.connected { return "Connected" }
        guard let seen = d.lastSeen else { return "Not connected" }
        return "Not connected · last seen \(Self.relative.localizedString(for: seen, relativeTo: Date()))"
    }
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    private var syncButtonLabel: String {
        store.syncStatus.map { "Syncing \(Int(($0.fraction * 100).rounded()))%" } ?? "Syncing…"
    }

    // MARK: never-seen placeholder

    private var neverSeen: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.sepStrong, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(width: 92, height: 130)
                .overlay(Image(systemName: "ipod").font(.system(size: 34)).foregroundStyle(theme.text3))
            Text("No device connected").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text("Plug in your Walkman NW-E394 or an iPod shuffle to sync music.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)
            Button("Simulate connect") { store.simulateDevice() }
                .buttonStyle(AccentButton())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: main layout

    /// Flat children of the (lazy) scroll stack, so a long "On device" list only builds the rows
    /// on screen. The long list goes last so the pending diff and playlist toggles stay in reach.
    private var content: some View {
        let preview = store.syncPreview
        return ScrollOrStack(alignment: .leading) {
            deviceCard.padding(.horizontal, 20).padding(.top, 20)
            if let s = store.syncStatus { syncPanel(s).padding(.horizontal, 20).padding(.top, 16) }
            capacityForecast(freeBytes: store.device.totalBytes - projectedUsed)
                .padding(.horizontal, 20).padding(.top, 16)

            DeviceSongSection(
                title: "Will add on next sync", color: theme.accent, rows: preview?.willAdd ?? [],
                emptyText: "Nothing to add. Pin songs or tick a playlist to send them here.",
                actionLabel: { rows in rows.count == 1 ? "Undo" : "Undo \(rows.count)" },
                perform: requestRemoval, trailing: { byteLabel($0.sizeBytes) })
            if let updates = preview?.willUpdate, !updates.isEmpty {
                DeviceSongSection(
                    title: "Will update on next sync", color: theme.amber, rows: updates,
                    subtitle: "Already on the device, but out of date (edited, or a new bitrate) — re-sent.",
                    actionLabel: { _ in nil }, perform: { _ in })
            }
            DeviceSongSection(
                title: "Will remove on next sync", color: theme.red, rows: preview?.willRemove ?? [],
                emptyText: "Nothing to remove.",
                actionLabel: keepLabel, perform: { store.keepOnDevice(keepable($0).map(\.assetID)) },
                trailing: { $0.replaced ? "replaced by a new copy" : ($0.song == nil ? "no longer in library" : "") })

            playlistsHeader
            ForEach(store.playlists) { pl in playlistRow(pl) }
            if store.playlists.isEmpty {
                Text("No playlists yet.").font(.system(size: 12)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 33).padding(.vertical, 4)
            }

            DeviceSongSection(
                title: "On device", color: theme.text3, rows: preview?.onDevice ?? [],
                emptyText: "Nothing recorded on the device yet.", searchable: true, marksRemovals: true,
                actionLabel: onDeviceLabel, perform: onDeviceAction)

            Color.clear.frame(height: 24)
        }
    }

    private var projectedUsed: Int64 { store.syncPreview?.projectedUsedBytes ?? store.device.usedBytes }

    private var deviceCard: some View {
        let d = store.device
        let projected = projectedUsed
        let frac = Double(projected) / Double(max(d.totalBytes, 1))
        let pending = store.syncPreview?.pendingCount ?? 0
        return HStack(spacing: 18) {
            CapacityRing(fraction: frac, centerTop: byteLabel(projected),
                         centerBottom: "of \(byteLabel(d.totalBytes))")
                .frame(width: 82, height: 82)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(headerTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                    Text(d.connected ? "Connected" : "Not connected")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((d.connected ? theme.green : theme.text3).opacity(0.15), in: Capsule())
                        .foregroundStyle(d.connected ? theme.green : theme.text3)
                }
                Text("\(byteLabel(d.totalBytes - projected)) free after sync · \(d.songCount) songs · Target \(store.settings.deviceFormat.uppercased()) \(store.settings.bitrateKbps)k"
                     + (store.deviceKind == .shuffle && store.settings.shuffleVoiceOver ? " · VoiceOver on" : ""))
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
                if !d.connected {
                    Text("Showing what was on it at the last sync. Changes here are applied the next time it's plugged in.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.text3)
                }
                HStack(spacing: 8) {
                    if d.connected {
                        if store.deviceKind != .shuffle {
                            Button("Import from device") { store.adoptFromDevice() }.buttonStyle(SoftButton())
                        }
                        Button("Rebuild device copies") { store.rebuildDeviceCopies() }
                            .buttonStyle(SoftButton()).disabled(store.syncing)
                            .help("Force every managed track to be re-sent on the next sync. Not usually needed — a sync already rebuilds anything out of date.")
                    }
                    Button("Bitrate & format…") { store.openSheet = .settings }.buttonStyle(SoftButton())
                    if d.connected {
                        Button("Eject") { store.device.connected = false }.buttonStyle(SoftButton())
                    }
                }.padding(.top, 4)
            }
            Spacer()
            if d.connected {
                Button(store.syncing ? syncButtonLabel : "Sync") { store.runSync() }
                    .buttonStyle(AccentButton()).disabled(store.syncing)
            } else {
                Button(pending > 0 ? "Connect to sync · \(pending) change\(pending == 1 ? "" : "s") pending"
                                   : "Connect to sync") {}
                    .buttonStyle(InertAccentButton()).disabled(true)
                    .help("Plug the device in, then Sync applies every pending change at once.")
            }
        }
        .padding(16)
        .background(theme.header, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: actions

    /// Take songs off the device. Pinned-only songs are simply unpinned; anything a syncing
    /// playlist holds asks first (stop syncing it, or remove the songs from it).
    private func requestRemoval(_ rows: [DeviceSongRow]) {
        if rows.allSatisfy({ $0.viaPlaylists.isEmpty }) {
            store.removeFromDevice(rows.map(\.assetID))
        } else {
            removeRequest = rows
        }
    }

    @ViewBuilder private func removalChoices(_ rows: [DeviceSongRow]) -> some View {
        let unpin = rows.filter(\.pinned).map(\.assetID)
        let lists = Self.playlists(in: rows)
        ForEach(lists) { pl in
            Button("Stop syncing “\(pl.name)”") {
                store.stopSyncingPlaylists([pl.id], unpin: unpin); removeRequest = nil
            }
            let members = rows.filter { $0.viaPlaylists.contains(pl) }.map(\.assetID)
            Button("Remove \(members.count == 1 ? "it" : "\(members.count) songs") from “\(pl.name)”") {
                store.removeFromPlaylist(pl.id, songIDs: members, unpin: unpin); removeRequest = nil
            }
        }
        if lists.count > 1 {
            Button("Stop syncing all \(lists.count) playlists") {
                store.stopSyncingPlaylists(lists.map(\.id), unpin: unpin); removeRequest = nil
            }
        }
        Button("Cancel", role: .cancel) { removeRequest = nil }
    }

    /// Distinct playlists holding any of `rows`, in first-seen order.
    private static func playlists(in rows: [DeviceSongRow]) -> [DevicePlaylistRef] {
        var seen = Set<Int64>(); var out: [DevicePlaylistRef] = []
        for r in rows { for p in r.viaPlaylists where seen.insert(p.id).inserted { out.append(p) } }
        return out
    }

    /// Removals that can be undone: the song is still in the library and isn't just being moved.
    private func keepable(_ rows: [DeviceSongRow]) -> [DeviceSongRow] {
        rows.filter { $0.song != nil && !$0.replaced }
    }
    private func keepLabel(_ rows: [DeviceSongRow]) -> String? {
        let n = keepable(rows).count
        return n == 0 ? nil : (rows.count == 1 ? "Keep" : "Keep \(n)")
    }

    /// "On device" rows: remove the ones staying, keep (undo) the ones already queued to go.
    private func onDeviceLabel(_ rows: [DeviceSongRow]) -> String? {
        let staying = rows.filter { !$0.pendingRemoval }
        if staying.isEmpty { return keepLabel(rows) }
        return rows.count == 1 ? "Remove" : "Remove \(staying.count)"
    }
    private func onDeviceAction(_ rows: [DeviceSongRow]) {
        let staying = rows.filter { !$0.pendingRemoval && $0.song != nil }
        if staying.isEmpty { store.keepOnDevice(keepable(rows).map(\.assetID)) } else { requestRemoval(staying) }
    }

    // MARK: playlists

    private var playlistsHeader: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.accent.opacity(0.6)).frame(width: 7, height: 7)
            Text("Playlists on device (\(store.playlists.filter(\.syncToDevice).count) of \(store.playlists.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
    }

    private func playlistRow(_ pl: PlaylistRow) -> some View {
        let dev = store.playlistDeviceState(pl)
        return HStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 11)).foregroundStyle(theme.text3)
            Text(pl.name).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text("\(dev.total) songs · \(dev.onDevice) on device")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
            Spacer()
            SwitchToggle(isOn: Binding(get: { pl.syncToDevice },
                                       set: { _ in store.togglePlaylistDeviceSync(pl.id) }))
                .scaleEffect(0.8)
                .help(pl.syncToDevice ? "Stop syncing this playlist to the device" : "Sync this playlist to the device")
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(theme.stripe, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20).padding(.vertical, 1.5)
    }

    // MARK: sync progress + forecast

    /// Live sync progress: percentage bar, the step being worked on, and time remaining
    /// (extrapolated from how much duration-weighted work is done so far).
    private func syncPanel(_ s: SyncStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(theme.accent)
                Text("Syncing").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
                Spacer()
                Text("\(Int((s.fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(theme.text)
            }
            ProgressBar(value: s.fraction).frame(height: 6)
            HStack(alignment: .firstTextBaseline) {
                Text(s.label).font(.system(size: 12)).foregroundStyle(theme.text2).lineLimit(1)
                Spacer()
                Text(s.countsLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.text3)
            }
        }
        .padding(14)
        .background(theme.header, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.35), lineWidth: 1))
    }

    /// Estimate how many more songs fit in the free space at each quality level, using the
    /// library's average track length (a rough but useful "should I go 320 or 192?" gauge).
    private func capacityForecast(freeBytes: Int64) -> some View {
        let durations = store.songs.map { $0.durationSec }.filter { $0 > 0 }
        let avgSec = durations.isEmpty ? 210.0 : durations.reduce(0, +) / Double(durations.count)
        let free = Double(max(0, freeBytes))
        func fits(_ kbps: Int) -> Int {
            let perSong = Double(kbps) * 1000.0 / 8.0 * avgSec
            return perSong > 0 ? Int(free / perSong) : 0
        }
        let levels = [128, 192, 256, 320]
        let current = store.settings.bitrateKbps
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(theme.text3)
                Text("Free space fits about — at avg \(Int(avgSec / 60)):\(String(format: "%02d", Int(avgSec) % 60)) per track")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
            }
            HStack(spacing: 8) {
                ForEach(levels, id: \.self) { kbps in
                    VStack(spacing: 2) {
                        Text("~\(fits(kbps))").font(.system(size: 15, weight: .bold)).foregroundStyle(kbps == current ? theme.accent : theme.text)
                        Text("\(kbps)k").font(.system(size: 10)).foregroundStyle(theme.text3)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(kbps == current ? theme.accent.opacity(0.12) : theme.stripe, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(kbps == current ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
                }
            }
        }
    }
}

/// One Device-screen song list (header + rows) with multi-select: click, ⇧-click for a range,
/// ⌘-click to toggle. Each row has its own action button; with a selection, the header offers the
/// same action for all of it in one batch (one store write pass, one preview rebuild).
///
/// The body is a header plus a `ForEach`, not wrapped in a stack, so inside the lazy scroll stack
/// each row is its own lazily-built child.
private struct DeviceSongSection: View {
    let title: String
    let color: Color
    let rows: [DeviceSongRow]
    var subtitle: String? = nil
    var emptyText: String = "None"
    var searchable: Bool = false
    /// Mark rows queued for removal (the "On device" list, where they're still present).
    var marksRemovals: Bool = false
    /// Button label for acting on these rows, or nil when there's nothing to do for them.
    let actionLabel: ([DeviceSongRow]) -> String?
    let perform: ([DeviceSongRow]) -> Void
    /// Small trailing note per row (size, "replaced by a new copy", …).
    var trailing: (DeviceSongRow) -> String = { _ in "" }

    @Environment(\.theme) private var theme
    @State private var selection: Set<String> = []
    @State private var anchor: Int? = nil
    @State private var query = ""

    private var visible: [DeviceSongRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard searchable, !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                || ($0.song?.album.localizedCaseInsensitiveContains(q) ?? false)
                || $0.viaPlaylists.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }
    private var selectedRows: [DeviceSongRow] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        let shown = visible
        header
        if let subtitle {
            Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.text3)
                .padding(.horizontal, 33).padding(.bottom, 4)
        }
        if shown.isEmpty {
            Text(rows.isEmpty ? emptyText : "No matches.").font(.system(size: 12)).foregroundStyle(theme.text3)
                .padding(.horizontal, 33).padding(.vertical, 4)
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
            row(r, index: i, in: shown)
        }
    }

    private var header: some View {
        let sel = selectedRows
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) (\(rows.count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
            Spacer()
            if !sel.isEmpty {
                Text("\(sel.count) selected").font(.system(size: 11)).foregroundStyle(theme.text3)
                if let label = actionLabel(sel) {
                    Button(label) { perform(sel); selection = [] }.buttonStyle(SoftButton())
                }
                Button("Clear") { selection = []; anchor = nil }.buttonStyle(SoftButton())
            }
            if searchable { SearchField(text: $query) }
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
    }

    private func row(_ r: DeviceSongRow, index: Int, in shown: [DeviceSongRow]) -> some View {
        let selected = selection.contains(r.id)
        let note = trailing(r)
        return HStack(spacing: 8) {
            Text(r.title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
                .strikethrough(marksRemovals && r.pendingRemoval, color: theme.text3)
            if !r.artist.isEmpty {
                Text(r.artist).font(.system(size: 12)).foregroundStyle(theme.text3).lineLimit(1)
            }
            ForEach(r.reasonLabels, id: \.self) { chip($0, theme.green) }
            if marksRemovals && r.pendingRemoval { chip("Will be removed", theme.red) }
            Spacer(minLength: 8)
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(theme.text3) }
            if let label = actionLabel([r]) {
                Button(label) { perform([r]) }.buttonStyle(MiniButton())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(selected ? theme.selSoft : theme.stripe, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(r.id, index: index, in: shown) }
        .padding(.horizontal, 20).padding(.vertical, 1.5)
    }

    private func chip(_ text: String, _ c: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.13), in: Capsule())
            .foregroundStyle(c)
    }

    private func handleTap(_ id: String, index: Int, in shown: [DeviceSongRow]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let a = anchor, a < shown.count {
            let (lo, hi) = (min(a, index), max(a, index))
            selection.formUnion(shown[lo...hi].map(\.id))
        } else if mods.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = index
        } else {
            selection = selection == [id] ? [] : [id]
            anchor = index
        }
    }
}

/// Compact per-row action button ("Undo", "Remove", "Keep").
struct MiniButton: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(theme.chip, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(theme.text2)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct AccentButton: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(theme.accentText)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The Sync button's look while the device is unplugged: same shape as `AccentButton`, visibly
/// inert, so the pending-change count reads as status rather than an action.
struct InertAccentButton: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(theme.chip, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent.opacity(0.35), lineWidth: 1))
            .foregroundStyle(theme.text2)
    }
}

struct SoftButton: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.chip, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(theme.text)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
