import SwiftUI
import OpenSongCore

struct AppleMusicView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Apple Music", subtitle: "\(store.appleMusic.count) playlists") {
                Button { store.loadAppleMusic() } label: {
                    Label(store.appleMusicLoading ? "Loading…" : "Refresh", systemImage: "arrow.clockwise")
                }.buttonStyle(SoftButton()).disabled(store.appleMusicLoading)
            }
            Divider().overlay(theme.sep)
            if store.appleMusic.isEmpty {
                emptyState
            } else {
                ScrollOrStack(alignment: .leading) {
                    ForEach(store.appleMusic) { col in row(col) }
                }
            }
        }
        .onAppear { if store.appleMusic.isEmpty && !renderMode { store.loadAppleMusic() } }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.on.square").font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Compare with Apple Music").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.appleMusicError ?? "Load your Apple Music playlists to see what you already own and mark the rest to acquire.")
                .font(.system(size: 12)).foregroundStyle(store.appleMusicError == nil ? theme.text3 : theme.red)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Grant access & load") { store.loadAppleMusic() }.buttonStyle(AccentButton())
            Text("First use asks macOS for permission to control Music.")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ col: AppleMusicCollection) -> some View {
        let own = store.ownership(col)
        let frac = own.total > 0 ? Double(own.owned) / Double(own.total) : 0
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(placeholderGradient(col.name)).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(col.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    Text(col.kind.rawValue.capitalized).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.chip, in: Capsule()).foregroundStyle(theme.text3)
                }
                Text("owned \(own.owned) of \(own.total)").font(.system(size: 11)).foregroundStyle(theme.text3)
                ProgressBar(value: frac).frame(width: 260)
            }
            Spacer()
            if own.missing.isEmpty {
                Label("Complete", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.green)
            } else {
                Button("Mark \(own.missing.count) missing") { store.markMissing(col) }.buttonStyle(AccentButton())
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}
