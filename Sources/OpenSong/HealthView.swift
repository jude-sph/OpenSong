import SwiftUI
import OpenSongCore

/// Library health: surfaces low-quality masters (low bitrate, or re-encodes caught by the deep
/// spectral scan) with a one-click re-acquire, and probable duplicates with keep-best dedupe.
struct HealthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var low: [SongRow] { store.lowQualitySongs }
    private var dupes: [[SongRow]] { store.duplicateGroups }

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Library Health",
                          subtitle: store.healthIssueCount == 0 ? "No issues found" : "\(store.healthIssueCount) issue(s)") {
                Button { store.backfillMissingArtwork() } label: {
                    Label(store.artBackfilling ? "Fixing artwork…" : "Fix missing artwork", systemImage: "photo.badge.plus")
                }.buttonStyle(SoftButton()).disabled(store.artBackfilling)
                Button { store.backfillAllTrackNumbers() } label: {
                    Label(store.trackBackfilling ? "Fixing…" : "Fix track numbers", systemImage: "list.number")
                }.buttonStyle(SoftButton()).disabled(store.trackBackfilling)
                Button { store.scanSpectral() } label: {
                    Label(store.healthScanning ? "Scanning…" : "Deep scan", systemImage: "waveform.badge.magnifyingglass")
                }.buttonStyle(SoftButton()).disabled(store.healthScanning)
            }
            Divider().overlay(theme.sep)
            if low.isEmpty && dupes.isEmpty {
                healthy
            } else {
                ScrollOrStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 18) {
                        if !low.isEmpty { lowQualitySection }
                        if !dupes.isEmpty { duplicatesSection }
                    }.padding(20)
                }
            }
        }
    }

    private var healthy: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(theme.green)
            Text("Your library looks healthy").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text("No low-bitrate masters or duplicates. Run a deep scan to also catch high-bitrate re-encodes by their frequency cutoff.")
                .font(.system(size: 12)).foregroundStyle(theme.text3).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { store.scanSpectral() } label: {
                Label(store.healthScanning ? "Scanning…" : "Deep quality scan", systemImage: "waveform.badge.magnifyingglass")
            }.buttonStyle(AccentButton()).disabled(store.healthScanning)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lowQualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Low quality", low.count, color: theme.amber)
            ForEach(low) { song in
                HStack(spacing: 12) {
                    ArtworkThumbnail(path: song.path, seed: song.album, size: 34, corner: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                        Text(song.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    }
                    Spacer()
                    Text(reason(song)).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.amber)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.amber.opacity(0.14), in: Capsule())
                    Text(song.kindLabel).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 74, alignment: .trailing)
                    Button("Find better source") { store.findBetterSource(song) }.buttonStyle(SoftButton())
                }
                .padding(.horizontal, 12).frame(height: 48)
                .background(theme.stripe, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Possible duplicates", dupes.count, color: theme.accent)
            ForEach(Array(dupes.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(group.first?.title ?? "") — \(group.first?.artist ?? "")")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                        Spacer()
                        Button("Keep best, remove \(group.count - 1)") { store.dedupeKeepBest(group) }.buttonStyle(SoftButton())
                    }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                    ForEach(Array(group.enumerated()), id: \.element.id) { i, song in
                        HStack(spacing: 10) {
                            Image(systemName: i == 0 ? "star.fill" : "doc.on.doc")
                                .font(.system(size: 10)).foregroundStyle(i == 0 ? theme.green : theme.text3).frame(width: 16)
                            Text(i == 0 ? "Keep" : "Duplicate").font(.system(size: 11)).foregroundStyle(i == 0 ? theme.green : theme.text3).frame(width: 64, alignment: .leading)
                            Text(song.album).font(.system(size: 12)).foregroundStyle(theme.text2).lineLimit(1)
                            Spacer()
                            Text(song.kindLabel).font(.system(size: 11)).foregroundStyle(theme.text3).monospacedDigit()
                            Text(byteLabel(song.sizeBytes)).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 64, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                    }
                    Spacer().frame(height: 6)
                }
                .background(theme.stripe, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) (\(count))").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text2)
        }
    }

    private func reason(_ song: SongRow) -> String {
        if store.spectralVerdicts[song.id] == false { return "re-encode?" }
        return "low bitrate"
    }
}
