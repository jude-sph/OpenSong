import SwiftUI
import AppKit
import OpenSongCore

/// Sheet for replacing an album's cover art: searches iTunes for candidate covers, shows a grid,
/// and re-embeds the chosen one into every track of the album (via AppStore.applyArtwork).
struct FindArtworkView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var artist = ""
    @State private var album = ""
    @State private var seeded = false

    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace artwork").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            if let t = store.artFinderTarget {
                let n = t.songIDs.count
                Text("Pick a cover for “\(t.title)” — it's embedded into \(n == 1 ? "this track" : "all \(n) tracks").")
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            HStack(alignment: .bottom, spacing: 8) {
                field("Artist", $artist)
                field("Album", $album)
                Button(store.artFinderLoading ? "Searching…" : "Search") {
                    store.runArtworkSearch(artist: artist, album: album)
                }.buttonStyle(SoftButton()).disabled(store.artFinderLoading)
            }
            results
            HStack {
                if store.artFinderApplying {
                    ProgressView().controlSize(.small)
                    Text("Embedding artwork…").font(.system(size: 12)).foregroundStyle(theme.text3)
                }
                Spacer()
                Button("Close") { store.openSheet = nil; store.artFinderTarget = nil }.buttonStyle(SoftButton())
            }
        }
        .padding(22).frame(width: 560, height: 520)
        .background(theme.sheet)
        .onAppear {
            if !seeded, let t = store.artFinderTarget { artist = t.artist; album = t.searchAlbum; seeded = true }
        }
    }

    @ViewBuilder private var results: some View {
        if store.artFinderLoading {
            centered { ProgressView().controlSize(.large) }
        } else if let err = store.artFinderError, store.artFinderResults.isEmpty {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26)).foregroundStyle(theme.text3)
                    Text(err).font(.system(size: 12)).foregroundStyle(theme.text3).multilineTextAlignment(.center)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(store.artFinderResults) { cand in candidate(cand) }
                }.padding(.vertical, 4)
            }
        }
    }

    private func candidate(_ cand: ArtworkFinder.Candidate) -> some View {
        Button {
            store.applyArtwork(cand)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                RemoteThumbnail(url: cand.thumbURL, seed: cand.collection, width: 108, height: 108, corner: 6)
                Text(cand.collection).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                // Year included: it's often the only way to tell an original from a reissue.
                Text("\(cand.artist)\(cand.year.map { " · \($0)" } ?? "")")
                    .font(.system(size: 10)).foregroundStyle(theme.text3).lineLimit(1)
            }
            .frame(width: 108)
        }
        .buttonStyle(.plain)
        .disabled(store.artFinderApplying)
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { store.runArtworkSearch(artist: artist, album: album) }
                .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
        }
    }
}
