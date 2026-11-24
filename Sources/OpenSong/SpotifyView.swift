import SwiftUI
import AppKit
import OpenSongCore

/// Paste a public Spotify playlist or profile link → compare against the library → send the
/// missing tracks to Pending. Spotify only supplies the track list (no audio); acquisition is
/// the usual yt-dlp path.
struct SpotifyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            ContentHeader(title: "Spotify",
                          subtitle: store.spotifySourceLabel.isEmpty ? "Your playlists"
                                                                     : store.spotifySourceLabel) {
                // No link to paste: signing in lists the account's own playlists, which is what the
                // removed profile-link flow was for.
                HStack(spacing: 8) {
                    if store.spotifySignedIn {
                        Button { store.loadMySpotifyPlaylists() } label: {
                            Label(store.spotifyLoading ? "Loading…" : "Refresh",
                                  systemImage: "arrow.clockwise")
                        }.buttonStyle(SoftButton()).disabled(store.spotifyLoading)
                    } else {
                        Button { store.spotifySignIn() } label: {
                            Label(store.spotifySigningIn ? "Waiting for browser…" : "Sign in",
                                  systemImage: "person.crop.circle")
                        }.buttonStyle(AccentButton()).disabled(store.spotifySigningIn)
                    }
                }
            }
            savedUsers
            Divider().overlay(theme.sep)
            if store.spotifyLoading && store.spotifyPlaylists.isEmpty {
                centered { ProgressView().controlSize(.large); Text("Reading from Spotify…").font(.system(size: 13)).foregroundStyle(theme.text2) }
            } else if store.spotifyPlaylists.isEmpty {
                emptyState
            } else {
                ScrollOrStack(alignment: .leading) {
                    ForEach(store.spotifyPlaylists) { pl in row(pl) }
                }
            }
        }
        // Signed in? Show the account's own playlists straight away — no link to paste.
        .onAppear { store.spotifyViewAppeared() }
    }

    /// Saved profiles, newest first. Click to load, right-click to forget.
    @ViewBuilder private var savedUsers: some View {
        if !store.savedSpotifyUsers.isEmpty {
            Divider().overlay(theme.sep)
            // Horizontal scroll for real use; a plain row when rendering screenshots, matching how
            // ScrollOrStack avoids ScrollView under ImageRenderer.
            chipScroller {
                HStack(spacing: 8) {
                    Text("SAVED").font(.system(size: 10, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(theme.text3)
                    ForEach(store.savedSpotifyUsers, id: \.self) { id in
                        // Opens in Spotify rather than trying to load: the endpoint that listed a
                        // user's playlists is gone, so loading could only ever show an error.
                        Button {
                            if let u = URL(string: "https://open.spotify.com/user/\(id)") {
                                NSWorkspace.shared.open(u)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "person.crop.circle").font(.system(size: 10))
                                Text(id).font(.system(size: 12)).lineLimit(1)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(theme.header, in: Capsule())
                            .overlay(Capsule().stroke(theme.sep, lineWidth: 1))
                            .foregroundStyle(theme.text2)
                        }
                        .buttonStyle(.plain)
                        .help("Open “\(id)” in Spotify — copy a playlist link from there to import it")
                        .contextMenu {
                            Button("Forget", role: .destructive) { store.removeSavedSpotifyUser(id) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func chipScroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if renderMode { content() } else { ScrollView(.horizontal, showsIndicators: false) { content() } }
    }

    private func pasteField(_ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(theme.text3)
            if renderMode {
                Text(text.wrappedValue.isEmpty ? "Paste a Spotify playlist or profile link…" : text.wrappedValue)
                    .font(.system(size: 12)).foregroundStyle(text.wrappedValue.isEmpty ? theme.text3 : theme.text)
                    .frame(width: 240, alignment: .leading)
            } else {
                TextField("Paste a Spotify playlist or profile link…", text: text)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 240)
                    .onSubmit { store.loadSpotify(store.spotifyInput) }
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
    }

    private var emptyState: some View {
        centered {
            Image(systemName: "music.note.list").font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Import from Spotify").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.spotifyError ?? (store.spotifySignedIn
                 ? "Your Spotify playlists appear here. You can also paste a link to any playlist — OpenSong shows what you already have and queues the rest to Pending."
                 : "Sign in to Spotify to see your own playlists, or paste a link to one. OpenSong shows what you already have and queues the rest to Pending."))
                .font(.system(size: 12)).foregroundStyle(store.spotifyError == nil ? theme.text3 : theme.red)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if store.settings.spotifyClientID.isEmpty || store.settings.spotifyClientSecret.isEmpty {
                Button("Add Spotify credentials…") { store.openSheet = .settings }.buttonStyle(SoftButton())
                Text("Free — developer.spotify.com → Create app → copy Client ID + Secret into Settings.")
                    .font(.system(size: 11)).foregroundStyle(theme.text3)
            } else if !store.spotifySignedIn {
                Button("Sign in to Spotify") { store.spotifySignIn() }.buttonStyle(AccentButton())
            }
        }
    }

    private func row(_ pl: SpotifyPlaylist) -> some View {
        let loaded = !pl.tracks.isEmpty
        let own = loaded ? store.spotifyOwnership(pl) : nil
        return HStack(spacing: 12) {
            RemoteThumbnail(url: pl.imageURL, seed: pl.name, width: 46, height: 46, corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(pl.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                if let own {
                    Text("owned \(own.owned) of \(own.total) · by \(pl.owner)").font(.system(size: 11)).foregroundStyle(theme.text3)
                    ProgressBar(value: own.total > 0 ? Double(own.owned) / Double(own.total) : 0).frame(width: 260)
                } else {
                    Text("\(pl.trackCount) tracks · by \(pl.owner)").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            }
            Spacer()
            if let own {
                if own.missing.isEmpty {
                    Label("Complete", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.green)
                } else {
                    Button("Mark \(own.missing.count) missing") { store.markSpotifyMissing(pl) }.buttonStyle(AccentButton())
                }
            } else {
                Text("Open to compare").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 20).frame(height: 66)
        .contentShape(Rectangle())
        .onTapGesture { store.openSpotifyDetail(pl) }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Spotify playlist's tracks with owned/missing status + the same multi-select "smart add"
/// button as the Apple Music detail screen.
struct SpotifyDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var selection: Set<Int> = []
    @State private var anchor: Int? = nil

    private var pl: SpotifyPlaylist? { store.spotifyDetail }

    var body: some View {
        VStack(spacing: 0) {
            if let pl {
                header(pl)
                Divider().overlay(theme.sep)
                if store.spotifyLoading && pl.tracks.isEmpty {
                    VStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollOrStack(alignment: .leading) {
                        ForEach(Array(pl.tracks.enumerated()), id: \.offset) { idx, track in
                            trackRow(track, index: idx)
                            Divider().overlay(theme.sep)
                        }
                    }
                }
            } else {
                Text("No playlist selected").foregroundStyle(theme.text3)
            }
        }
    }

    private func targetIndices(_ pl: SpotifyPlaylist) -> [Int] {
        selection.isEmpty ? Array(pl.tracks.indices) : selection.sorted()
    }
    private func addable(_ pl: SpotifyPlaylist) -> [SpotifyTrack] {
        targetIndices(pl).map { pl.tracks[$0] }.filter { !store.isOwnedSpotify($0) && !store.isPendingSpotify($0) }
    }
    private func removable(_ pl: SpotifyPlaylist) -> [SpotifyTrack] {
        targetIndices(pl).map { pl.tracks[$0] }.filter { store.isPendingSpotify($0) }
    }

    private func header(_ pl: SpotifyPlaylist) -> some View {
        let own = store.spotifyOwnership(pl)
        let add = addable(pl)
        let remove = removable(pl)
        return HStack(spacing: 14) {
            Button { store.activeView = .spotify } label: {
                Image(systemName: "chevron.left").font(.system(size: 13))
            }.buttonStyle(.plain).foregroundStyle(theme.text2)
            RemoteThumbnail(url: pl.imageURL, seed: pl.name, width: 60, height: 60, corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(pl.name).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                Text("\(pl.tracks.count) tracks · owned \(own.owned), \(own.missing.count) missing"
                     + (selection.isEmpty ? "" : " · \(selection.count) selected"))
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            if !add.isEmpty {
                Button("Add \(add.count) to Pending") {
                    store.addSpotifyTracksToPending(add, group: pl.name); selection = []
                }.buttonStyle(AccentButton())
            } else if !remove.isEmpty {
                Button("Remove \(remove.count) from Pending") {
                    store.removeSpotifyTracksFromPending(remove); selection = []
                }.buttonStyle(SoftButton())
            } else {
                Text(selection.isEmpty ? "All in library" : "Nothing to add").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(20).background(theme.header)
    }

    private func trackRow(_ track: SpotifyTrack, index: Int) -> some View {
        let owned = store.isOwnedSpotify(track)
        let pending = store.isPendingSpotify(track)
        let selected = selection.contains(index)
        let (dotColor, filled): (Color, Bool) = owned ? (theme.green, true)
            : pending ? (theme.amber, true) : (theme.text3, false)
        return HStack(spacing: 12) {
            Circle().fill(filled ? dotColor : Color.clear)
                .overlay(Circle().stroke(filled ? Color.clear : theme.text3, lineWidth: 1.2))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 13))
                    .foregroundStyle(selected ? theme.selText : (owned ? theme.text3 : theme.text)).lineLimit(1)
                Text(track.artist).font(.system(size: 11))
                    .foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text3).lineLimit(1)
            }
            Spacer()
            if owned {
                Label("In library", systemImage: "checkmark").font(.system(size: 11))
                    .foregroundStyle(selected ? theme.selText : theme.green)
            } else if pending {
                Text("Pending").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? theme.selText : theme.amber)
            }
        }
        .padding(.horizontal, 20).frame(height: 40)
        .background(selected ? theme.accent : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(index) }
    }

    private func handleTap(_ index: Int) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let a = anchor {
            selection.formUnion(Set(min(a, index)...max(a, index)))
        } else if mods.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else {
            selection = [index]; anchor = index
        }
    }
}
