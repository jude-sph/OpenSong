import SwiftUI
import AppKit
import OpenSongCore

struct AppleMusicDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var selection: Set<Int> = []
    @State private var anchor: Int? = nil

    private var col: AppleMusicCollection? { store.amDetail }

    var body: some View {
        VStack(spacing: 0) {
            if let col {
                header(col)
                Divider().overlay(theme.sep)
                ScrollOrStack(alignment: .leading) {
                    ForEach(Array(col.tracks.enumerated()), id: \.offset) { idx, track in
                        trackRow(track, index: idx)
                        Divider().overlay(theme.sep)
                    }
                }
            } else {
                Text("No playlist selected").foregroundStyle(theme.text3)
            }
        }
    }

    /// The target set: the selected tracks, or all tracks when nothing is selected.
    private func targetIndices(_ col: AppleMusicCollection) -> [Int] {
        selection.isEmpty ? Array(col.tracks.indices) : selection.sorted()
    }
    private func addable(_ col: AppleMusicCollection) -> [AppleMusicTrack] {
        targetIndices(col).map { col.tracks[$0] }.filter { !store.isOwned($0) && !store.isPending($0) }
    }
    private func removable(_ col: AppleMusicCollection) -> [AppleMusicTrack] {
        targetIndices(col).map { col.tracks[$0] }.filter { store.isPending($0) }
    }

    private func header(_ col: AppleMusicCollection) -> some View {
        let own = store.ownership(col)
        let add = addable(col)
        let remove = removable(col)
        let scope = selection.isEmpty ? "all" : "\(selection.count) selected"
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
                Text("\(col.tracks.count) tracks · owned \(own.owned), \(own.missing.count) missing"
                     + (selection.isEmpty ? "" : " · \(selection.count) selected"))
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer()
            // Smart action button: acts on the target set (selected, or all).
            if !add.isEmpty {
                Button("Add \(add.count) to Pending") {
                    store.addTracksToPending(add, group: col.name); selection = []
                }.buttonStyle(AccentButton())
            } else if !remove.isEmpty {
                Button("Remove \(remove.count) from Pending") {
                    store.removeTracksFromPending(remove); selection = []
                }.buttonStyle(SoftButton())
            } else {
                Text(scope == "all" ? "All in library" : "Nothing to add").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(20).background(theme.header)
    }

    private func trackRow(_ track: AppleMusicTrack, index: Int) -> some View {
        let owned = store.isOwned(track)
        let pending = store.isPending(track)
        let selected = selection.contains(index)
        let (dotColor, filled): (Color, Bool) = owned ? (theme.green, true)
            : pending ? (theme.amber, true) : (theme.text3, false)
        return HStack(spacing: 12) {
            Circle().fill(filled ? dotColor : Color.clear)
                .overlay(Circle().stroke(filled ? Color.clear : theme.text3, lineWidth: 1.2))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 13))
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
            let lo = min(a, index), hi = max(a, index)
            selection.formUnion(Set(lo...hi))
        } else if mods.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else {
            selection = [index]; anchor = index
        }
    }
}
