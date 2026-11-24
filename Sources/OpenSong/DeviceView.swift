import SwiftUI

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

struct DeviceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Device", subtitle: store.device.connected ? "Connected" : "Not connected") {
                EmptyView()
            }
            Divider().overlay(theme.sep)
            if store.device.connected { connected } else { disconnected }
        }
        .onAppear { store.buildSyncPreview() }
    }

    private var syncButtonLabel: String {
        store.syncStatus.map { "Syncing \(Int(($0.fraction * 100).rounded()))%" } ?? "Syncing…"
    }

    private var disconnected: some View {
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

    private var connected: some View {
        let d = store.device
        let projected = store.syncPreview?.projectedUsedBytes ?? d.usedBytes
        let frac = Double(projected) / Double(max(d.totalBytes, 1))
        return ScrollOrStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    CapacityRing(fraction: frac,
                                 centerTop: byteLabel(projected),
                                 centerBottom: "of \(byteLabel(d.totalBytes))")
                        .frame(width: 82, height: 82)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.deviceKind == .shuffle ? d.name : "Sony \(d.name)")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                        Text("\(byteLabel(d.totalBytes - projected)) free · Target \(store.settings.deviceFormat.uppercased()) \(store.settings.bitrateKbps)k"
                             + (store.deviceKind == .shuffle && store.settings.shuffleVoiceOver ? " · VoiceOver on" : ""))
                            .font(.system(size: 12)).foregroundStyle(theme.text3)
                        HStack(spacing: 8) {
                            if store.deviceKind != .shuffle {
                                Button("Import from device") { store.adoptFromDevice() }.buttonStyle(SoftButton())
                            }
                            Button("Rebuild device copies") { store.rebuildDeviceCopies() }
                                .buttonStyle(SoftButton()).disabled(store.syncing)
                                .help("Force every managed track to be re-sent on the next sync. Not usually needed — a sync already rebuilds anything out of date.")
                            Button("Bitrate & format…") { store.openSheet = .settings }.buttonStyle(SoftButton())
                            Button("Eject") { store.device.connected = false }.buttonStyle(SoftButton())
                        }.padding(.top, 4)
                    }
                    Spacer()
                    Button(store.syncing ? syncButtonLabel : "Sync") { store.runSync() }
                        .buttonStyle(AccentButton()).disabled(store.syncing)
                }
                .padding(16)
                .background(theme.header, in: RoundedRectangle(cornerRadius: 10))

                if let s = store.syncStatus { syncPanel(s) }

                capacityForecast(freeBytes: d.totalBytes - projected)

                if let preview = store.syncPreview {
                    diffGroup("Will add", color: theme.accent, rows: preview.willAdd.map { ($0.title, $0.artist, byteLabel(Int64(Double(store.settings.bitrateKbps) * 1000 / 8 * $0.durationSec))) })
                    diffGroup("Will remove", color: theme.red, rows: preview.willRemove.map { ($0, "", "") })
                    diffGroup("Up to date", color: theme.text3, rows: preview.upToDate.map { ($0.title, $0.artist, "") })
                }
            }
            .padding(20)
        }
    }

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

    private func diffGroup(_ title: String, color: Color, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(title) (\(rows.count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
            }
            if rows.isEmpty {
                Text("None").font(.system(size: 12)).foregroundStyle(theme.text3).padding(.leading, 13)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(theme.text)
                        if !r.1.isEmpty { Text(r.1).font(.system(size: 12)).foregroundStyle(theme.text3) }
                        Spacer()
                        if !r.2.isEmpty { Text(r.2).font(.system(size: 11)).foregroundStyle(theme.text3) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(theme.stripe, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
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
