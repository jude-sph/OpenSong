import SwiftUI

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
                    RoundedRectangle(cornerRadius: 8).fill(placeholderGradient(album))
                        .frame(width: 120, height: 120)
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
                Button("Save to file tags") { store.openSheet = nil }.buttonStyle(AccentButton())
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button { store.openSheet = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(theme.text3)
            }
            group("Master Library") {
                pathRow(store.settings.libraryPath)
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
                Text("The NW-E394 plays MP3/AAC only — Opus and lossless are never sent to the device.")
                    .font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            group("Tool Paths") {
                pathRow(store.settings.ytDlpPath)
                pathRow(store.settings.ffmpegPath)
            }
            group("Smart Features") {
                ToggleRow(label: "AI metadata cleanup", isOn: $store.settings.aiCleanup)
                ToggleRow(label: "Fingerprint match verification", isOn: $store.settings.fingerprint)
                ToggleRow(label: "Audio quality checking", isOn: $store.settings.qualityCheck)
            }
            Spacer()
        }
        .padding(22).frame(width: 520, height: 560)
        .background(theme.sheet)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
            content()
        }
    }
    private func pathRow(_ path: String) -> some View {
        HStack {
            Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.head)
            Spacer()
            Button("Choose…") {}.buttonStyle(SoftButton())
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Review").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
            Text("Point OpenSong at a folder of loose files; review canonical suggestions before importing.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)
            Spacer()
            HStack { Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Choose folder…") {}.buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 640, height: 460)
        .background(theme.sheet)
    }
}
