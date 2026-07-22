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

    private var disconnected: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.sepStrong, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(width: 92, height: 130)
                .overlay(Image(systemName: "ipod").font(.system(size: 34)).foregroundStyle(theme.text3))
            Text("No device connected").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text("Plug in your Walkman NW-E394 to sync music.")
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
                        Text("Sony \(d.name)").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                        Text("\(byteLabel(d.totalBytes - projected)) free · Target \(store.settings.deviceFormat.uppercased()) \(store.settings.bitrateKbps)k")
                            .font(.system(size: 12)).foregroundStyle(theme.text3)
                        HStack(spacing: 8) {
                            Button("Bitrate & format…") { store.openSheet = .settings }.buttonStyle(SoftButton())
                            Button("Eject") { store.device.connected = false }.buttonStyle(SoftButton())
                        }.padding(.top, 4)
                    }
                    Spacer()
                    Button(store.syncing ? "Syncing…" : "Sync") { store.runSync() }
                        .buttonStyle(AccentButton()).disabled(store.syncing)
                }
                .padding(16)
                .background(theme.header, in: RoundedRectangle(cornerRadius: 10))

                if let preview = store.syncPreview {
                    diffGroup("Will add", color: theme.accent, rows: preview.willAdd.map { ($0.title, $0.artist, byteLabel(Int64(Double(store.settings.bitrateKbps) * 1000 / 8 * $0.durationSec))) })
                    diffGroup("Will remove", color: theme.red, rows: preview.willRemove.map { ($0, "", "") })
                    diffGroup("Up to date", color: theme.text3, rows: preview.upToDate.map { ($0.title, $0.artist, "") })
                }
            }
            .padding(20)
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
