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
                healthRow()

                // Fixed navigation sits above the (potentially long) playlist/album lists so it
                // never gets pushed off-screen.
                section("DEVICE")
                deviceRow()

                section("WISHLIST")
                row("Pending", "bookmark", view: .wishlist)
                section("APPLE MUSIC")
                row("Compare", "square.on.square", view: .appleMusic)
                section("SPOTIFY")
                row("Import playlists", "music.note.list", view: .spotify)
                section("YOUTUBE")
                row("Import playlist", "play.rectangle", view: .youtube)

                playlistsHeader
                ForEach(store.sidebarPlaylists) { pl in
                    playlistSidebarRow(pl)
                        .contextMenu {
                            Button(pl.syncToDevice ? "Don't sync to device" : "Sync to device") {
                                store.togglePlaylistDeviceSync(pl.id)
                            }
                            Button("Add songs to Apple Music") {
                                store.addToAppleMusic(pl.songIDs, label: "Adding “\(pl.name)” to Apple Music…")
                            }
                            Button("Rename…") { store.openSheet = .renamePlaylist(pl.id) }
                            Button("Delete Playlist", role: .destructive) { store.deletePlaylist(pl.id) }
                        }
                }
                // Imported playlists with nothing downloaded yet — dimmed, opens Pending.
                // (Albums aren't listed here at all: they live in LIBRARY ▸ Albums, and the device
                // browses them as Artist/Album folders, so a sidebar copy was pure duplication.)
                ForEach(store.formingRealPlaylists) { fp in formingRow(fp) }
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

    private var playlistsHeader: some View {
        HStack {
            Text("PLAYLISTS").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(theme.text3)
            Spacer()
            Button { store.openSheet = .newPlaylist([]) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    private func isActive(_ view: ActiveView) -> Bool { store.activeView == view }

    private func row(_ title: String, _ icon: String, view: ActiveView, dot: Bool = false) -> some View {
        Button {
            store.activeView = view
            store.filterAlbumID = nil
            store.filterArtist = nil
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

    /// Library health row with a live issue-count badge.
    private func healthRow() -> some View {
        let count = store.healthIssueCount
        return Button { store.activeView = .health; store.filterAlbumID = nil } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").font(.system(size: 13)).frame(width: 18)
                Text("Health").font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive(.health) ? theme.selText : theme.amber)
                }
            }
            .foregroundStyle(isActive(.health) ? theme.selText : theme.text)
            .padding(.horizontal, 8).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive(.health) ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// "On the device" marker for a sidebar collection: filled when it's all there (or flagged to
    /// sync), hollow when only some of it is. Albums count too — sending one to the device pins its
    /// tracks rather than setting the playlist's sync flag, so keying off the flag alone left every
    /// album in the sidebar looking as if it wasn't on the device.
    @ViewBuilder private func deviceDot(_ pl: PlaylistRow, active: Bool) -> some View {
        let dev = store.playlistDeviceState(pl)
        let colour = active ? theme.selText : theme.accent
        if pl.syncToDevice || (dev.total > 0 && dev.onDevice == dev.total) {
            Circle().fill(colour).frame(width: 6, height: 6)
        } else if dev.onDevice > 0 {
            Circle().stroke(colour, lineWidth: 1.2).frame(width: 6, height: 6)
                .help("\(dev.onDevice) of \(dev.total) tracks on the device")
        }
    }

    /// Playlist row with a sync dot and, while it's still filling from an import, a "+N" badge
    /// showing how many of its tracks are still downloading.
    private func playlistSidebarRow(_ pl: PlaylistRow) -> some View {
        let view = ActiveView.playlist(pl.id)
        let pending = store.pendingCount(forPlaylist: pl.name)
        let active = isActive(view)
        return Button { store.activeView = view; store.filterAlbumID = nil; store.filterArtist = nil } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list").font(.system(size: 13)).frame(width: 18)
                Text(pl.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if pending > 0 {
                    Text("+\(pending)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(active ? theme.selText : theme.text3)
                } else {
                    deviceDot(pl, active: active)
                }
            }
            .foregroundStyle(active ? theme.selText : theme.text)
            .padding(.horizontal, 8).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pending > 0 ? "\(pending) still downloading" : "")
    }

    /// A dimmed sidebar row for an imported playlist that's still downloading, with an "N/total"
    /// progress badge. Tapping opens Pending (where its tracks can be reviewed/acquired).
    private func formingRow(_ fp: AppStore.FormingPlaylist) -> some View {
        Button { store.activeView = .wishlist; store.filterAlbumID = nil; store.filterArtist = nil } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13)).frame(width: 18)
                Text(fp.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(fp.downloaded)/\(fp.total)").font(.system(size: 10, weight: .semibold))
                    .monospacedDigit().foregroundStyle(theme.text3)
            }
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 8).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Downloading \(fp.downloaded) of \(fp.total) — opens Pending")
    }

    private func deviceRow() -> some View {
        Button { store.activeView = .device } label: {
            HStack(spacing: 8) {
                Image(systemName: "ipod").font(.system(size: 13)).frame(width: 18)
                Text(store.device.connected ? store.device.name : "Walkman — Offline")
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
