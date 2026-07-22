import SwiftUI

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollOrStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                section("LIBRARY")
                row("All Songs", "music.note", view: .allSongs)
                row("Albums", "square.stack", view: .albums)
                row("Artists", "person.crop.circle", view: .artists)

                section("PLAYLISTS")
                ForEach(store.playlists) { pl in
                    row(pl.name, "music.note.list", view: .playlist(pl.id), dot: pl.syncToDevice)
                }

                section("DEVICE")
                deviceRow()

                section("WISHLIST")
                row("Pending", "bookmark", view: .wishlist)
                section("APPLE MUSIC")
                row("Compare", "square.on.square", view: .appleMusic)
            }
            .padding(10)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    private func isActive(_ view: ActiveView) -> Bool { store.activeView == view }

    private func row(_ title: String, _ icon: String, view: ActiveView, dot: Bool = false) -> some View {
        Button {
            store.activeView = view
            store.filterAlbumID = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if dot {
                    Circle().fill(theme.accent).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isActive(view) ? theme.selText : theme.text)
            .padding(.horizontal, 8).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive(view) ? theme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceRow() -> some View {
        Button { store.activeView = .device } label: {
            HStack(spacing: 8) {
                Image(systemName: "ipod").font(.system(size: 13)).frame(width: 18)
                Text(store.device.connected ? "Walkman NW-E394" : "Walkman — Offline")
                    .font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if store.device.connected {
                    MiniRing(fraction: Double(store.device.usedBytes) / Double(max(store.device.totalBytes, 1)))
                        .frame(width: 16, height: 16)
                }
            }
            .foregroundStyle(isActive(.device) ? theme.selText
                             : (store.device.connected ? theme.text : theme.text3))
            .padding(.horizontal, 8).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive(.device) ? theme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dimRow(_ title: String, _ icon: String, badge: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
            if let badge, badge > 0 {
                Text("\(badge)").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(theme.chip, in: Capsule())
            }
        }
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 8).frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tiny capacity ring for the sidebar.
struct MiniRing: View {
    var fraction: Double
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
