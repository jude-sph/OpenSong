import SwiftUI
import OpenSongCore

struct MetadataEditorView: View {
    let songID: Int64
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var track = ""
    @State private var genre = ""
    @State private var year = ""

    private var song: SongRow? { store.song(songID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Metadata").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ArtworkThumbnail(path: song?.path ?? "", seed: album, size: 120, corner: 8)
                    Button("Replace artwork") {}.buttonStyle(SoftButton())
                }
                VStack(spacing: 10) {
                    field("Title", $title)
                    field("Artist", $artist)
                    field("Album", $album)
                    HStack(spacing: 10) {
                        field("Track #", $track)
                        field("Genre", $genre)
                        field("Year", $year)
                    }
                    if let s = song {
                        VStack(alignment: .leading, spacing: 3) {
                            infoLine("Format", "\(s.format.uppercased()) · \(s.kbps) kbps")
                            infoLine("Size", byteLabel(s.sizeBytes))
                            infoLine("Path", s.path)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.header, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Save to file tags") {
                    store.saveMetadata(songID: songID, title: title, artist: artist, album: album,
                                       track: track, genre: genre, year: year)
                    store.openSheet = nil
                }.buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 560)
        .background(theme.sheet)
        .onAppear {
            if let s = song {
                title = s.title; artist = s.artist; album = s.album
                track = s.track.map(String.init) ?? ""; genre = s.genre ?? ""
                year = s.year.map(String.init) ?? ""
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 28)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
        }
    }
    private func infoLine(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(theme.text3); Spacer(); Text(v).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.head) }
            .font(.system(size: 11))
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button { store.openSheet = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 14)
            ScrollOrStack(alignment: .leading) {
                settingsGroups()
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("OpenSong \(appVersionString)").font(.system(size: 11))
            }
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 620)
        .background(theme.sheet)
    }

    @ViewBuilder private func settingsGroups() -> some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 18) {
            group("Master Library") {
                pathRow(store.settings.libraryPath) { store.chooseLibraryFolder() }
            }
            group("Device Format") {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("Format").font(.system(size: 12)).foregroundStyle(theme.text2)
                        SegmentedControl(options: [("MP3", "mp3"), ("AAC", "aac")],
                                         selection: $store.settings.deviceFormat)
                    }
                    HStack(spacing: 8) {
                        Text("Bitrate").font(.system(size: 12)).foregroundStyle(theme.text2)
                        SegmentedControl(options: [("128", 128), ("192", 192), ("256", 256), ("320", 320)],
                                         selection: $store.settings.bitrateKbps)
                    }
                }
                ToggleRow(label: "Loudness normalization (EBU R128)", isOn: $store.settings.loudnessNormalize)
                ToggleRow(label: "iPod shuffle VoiceOver (spoken track & playlist names)", isOn: $store.settings.shuffleVoiceOver)
                Text("The NW-E394 plays MP3/AAC only — Opus and lossless are never sent to the device. iPod shuffle uses the same target format and reads its own iTunesSD playlists.")
                    .font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            group("Tool Paths") {
                pathRow(store.settings.ytDlpPath) { store.chooseToolPath(\.ytDlpPath) }
                ytDlpUpdateRow
                pathRow(store.settings.ffmpegPath) { store.chooseToolPath(\.ffmpegPath) }
            }
            group("Spotify") {
                Text("Free app credentials from developer.spotify.com → Dashboard → Create app.")
                    .font(.system(size: 11)).foregroundStyle(theme.text3)
                secretField("Client ID", $store.settings.spotifyClientID, placeholder: "paste Client ID", mask: false)
                secretField("Client Secret", $store.settings.spotifyClientSecret, placeholder: "paste Client Secret", mask: true)
                spotifySignInRow
            }
            group("Smart Features") {
                ToggleRow(label: "Audio quality checking (spectral)", isOn: $store.settings.qualityCheck)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 8)
    }

    /// Version plus an update button. YouTube changes often enough that an out-of-date yt-dlp is
    /// the usual reason a download that worked last month doesn't today.
    private var ytDlpUpdateRow: some View {
        HStack(spacing: 10) {
            Text(store.ytDlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp — checking…")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.text3)
            Spacer()
            if store.updatingYtDlp {
                Text("Updating…").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Button("Update yt-dlp") { store.updateYtDlp() }
                .buttonStyle(AccentButton())
                .disabled(store.updatingYtDlp)
        }
        .onAppear { if store.ytDlpVersion == nil { store.refreshYtDlpVersion() } }
    }

    /// Sign-in state plus the redirect URI to register. Since February 2026 a playlist's contents
    /// need a signed-in account — app credentials alone return no tracks.
    private var spotifySignInRow: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: store.spotifySignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 12))
                    .foregroundStyle(store.spotifySignedIn ? theme.green : theme.text3)
                Text(store.spotifySignedIn ? "Signed in — playlist links can be imported"
                                           : "Not signed in — needed to read playlist contents")
                    .font(.system(size: 11)).foregroundStyle(theme.text2)
                Spacer()
                if store.spotifySignedIn {
                    Button("Sign Out") { store.spotifySignOut() }.buttonStyle(SoftButton())
                } else {
                    Button(store.spotifySigningIn ? "Waiting for browser…" : "Sign in to Spotify") {
                        store.spotifySignIn()
                    }
                    .buttonStyle(AccentButton()).disabled(store.spotifySigningIn)
                }
            }
            // Spotify rejects the sign-in unless this exact string is registered on the app, saying
            // only "redirect_uri: Not matching configuration" — so it is editable (an app may
            // already have one registered) and copyable.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Redirect URI — must be registered on your Spotify app:")
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.spotifyRedirectURI, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(theme.text3).help("Copy")
                }
                secretField("", $store.settings.spotifyRedirectURI,
                            placeholder: SpotifyAuth.defaultRedirectURI, mask: false)
                Text("Dashboard → your app → Settings → Edit → Redirect URIs → Add → Save. "
                     + "Spotify requires 127.0.0.1 rather than localhost.")
                    .font(.system(size: 10)).foregroundStyle(theme.text3)
            }
        }
        .onAppear { store.refreshSpotifySignInState() }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String
        let b = info?["CFBundleVersion"] as? String
        if let v, let b { return "v\(v) (build \(b))" }
        return "dev build"
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
            content()
        }
    }
    private func secretField(_ label: String, _ text: Binding<String>, placeholder: String, mask: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            Group {
                if renderMode {
                    Text(text.wrappedValue.isEmpty ? "not set" : (mask ? "••••••••" : text.wrappedValue))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if mask {
                    SecureField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12))
                } else {
                    TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
        }
    }
    private func pathRow(_ path: String, _ choose: @escaping () -> Void) -> some View {
        HStack {
            Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.head)
            Spacer()
            Button("Choose…") { choose() }.buttonStyle(SoftButton())
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
    }
}

struct ImportReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Review").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
            Text("Review the canonical metadata (from the iTunes catalog, duration-matched) before importing. Toggle a row to keep your original tags instead.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)

            HStack(spacing: 0) {
                Text("").frame(width: 28)
                Text("ORIGINAL").frame(maxWidth: .infinity, alignment: .leading)
                Text("SUGGESTED").frame(maxWidth: .infinity, alignment: .leading)
                Text("USE").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
            .padding(.horizontal, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($store.importRows) { $row in
                        HStack(spacing: 0) {
                            Toggle("", isOn: $row.include).labelsHidden().toggleStyle(.checkbox).frame(width: 28)
                            metaCell(row.candidate.original)
                            metaCell(row.candidate.suggested, placeholder: "no catalog match")
                            SegmentedControl(options: [("Orig", false), ("Sug", true)], selection: $row.useSuggested)
                                .frame(width: 90).disabled(row.candidate.suggested == nil).opacity(row.candidate.suggested == nil ? 0.4 : 1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(theme.stripe.opacity(row.include ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
                        Divider().overlay(theme.sep)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("\(store.importRows.filter { $0.include }.count) of \(store.importRows.count) selected")
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
                Spacer()
                Button("Cancel") { store.openSheet = nil; store.importRows = [] }.buttonStyle(SoftButton())
                Button("Import \(store.importRows.filter { $0.include }.count)") { store.commitImport() }
                    .buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 720, height: 560)
        .background(theme.sheet)
    }

    private func metaCell(_ ident: TrackIdentity?, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let ident {
                Text(ident.title).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1)
                Text("\(ident.artist)\(ident.album.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            } else {
                Text(placeholder).font(.system(size: 11)).foregroundStyle(theme.text3).italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
