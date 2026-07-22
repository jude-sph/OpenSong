import SwiftUI
import OpenSongCore

struct AppleMusicDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var col: AppleMusicCollection? { store.amDetail }

    var body: some View {
        VStack(spacing: 0) {
            if let col {
                header(col)
                Divider().overlay(theme.sep)
                ScrollOrStack(alignment: .leading) {
                    ForEach(Array(col.tracks.enumerated()), id: \.offset) { _, track in
                        trackRow(track, group: col.name)
                        Divider().overlay(theme.sep)
                    }
                }
            } else {
                Text("No playlist selected").foregroundStyle(theme.text3)
            }
        }
    }

    private func header(_ col: AppleMusicCollection) -> some View {
        let own = store.ownership(col)
        return HStack(spacing: 14) {
            Button { store.activeView = .appleMusic } label: {
                Image(systemName: "chevron.left").font(.system(size: 13))
            }.buttonStyle(.plain).foregroundStyle(theme.text2)
            AppleMusicArt(name: col.name, size: 60)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(col.name).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                    if let tag = col.originTag {
                        Text(tag).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(hex: 0x2e7bd6).opacity(0.16), in: Capsule())
                            .foregroundStyle(Color(hex: 0x2e7bd6))
                    }
                }
                Text("\(col.tracks.count) tracks · owned \(own.owned), \(own.missing.count) missing")
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            if !own.missing.isEmpty {
                Button("Mark \(own.missing.count) missing") { store.markMissing(col) }.buttonStyle(AccentButton())
            }
        }
        .padding(20).background(theme.header)
    }

    private func trackRow(_ track: AppleMusicTrack, group: String) -> some View {
        let owned = store.isOwned(track)
        let pending = store.isPending(track)
        return HStack(spacing: 12) {
            Circle()
                .fill(owned ? theme.green : Color.clear)
                .overlay(Circle().stroke(owned ? Color.clear : theme.text3, lineWidth: 1.2))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 13)).foregroundStyle(owned ? theme.text3 : theme.text).lineLimit(1)
                Text(track.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            }
            Spacer()
            if owned {
                Label("In library", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(theme.green)
            } else if pending {
                Text("Pending").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.amber.opacity(0.15), in: Capsule()).foregroundStyle(theme.amber)
            } else {
                Button("Add") { store.addTrackToPending(track, group: group) }.buttonStyle(SoftButton())
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
    }
}
