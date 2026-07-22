import SwiftUI
import OpenSongCore

struct WishlistView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Pending", subtitle: "\(store.wishItems.count) items") {
                Button { store.openSheet = .addWish } label: {
                    Label("Custom Item", systemImage: "plus")
                }.buttonStyle(SoftButton())
            }
            Divider().overlay(theme.sep)
            if store.wishItems.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bookmark").font(.system(size: 34)).foregroundStyle(theme.text3)
                    Text("Nothing pending").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Add a custom item to find and download it from YouTube.")
                        .font(.system(size: 12)).foregroundStyle(theme.text3)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollOrStack(alignment: .leading) {
                    let groups = Dictionary(grouping: store.wishItems.filter { $0.playlistName != nil },
                                            by: { $0.playlistName! })
                    let loose = store.wishItems.filter { $0.playlistName == nil }
                    ForEach(groups.keys.sorted(), id: \.self) { name in
                        groupHeader(name, groups[name] ?? [])
                        ForEach(groups[name] ?? [], id: \.id) { wish in row(wish, indented: true) }
                    }
                    if !loose.isEmpty {
                        if !groups.isEmpty { sectionLabel("Songs") }
                        ForEach(loose, id: \.id) { wish in row(wish) }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4)
            .foregroundStyle(theme.text3).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ name: String, _ items: [WishItem]) -> some View {
        let downloaded = items.filter { $0.state == .downloaded }.count
        let pending = items.filter { $0.state != .downloaded }
        return HStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 13)).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Text("\(items.count) tracks · \(downloaded) downloaded").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Spacer()
            if let first = pending.first, let id = first.id {
                Button("Review \(pending.count)") { store.beginMatch(id) }.buttonStyle(SoftButton())
            } else {
                Label("Complete", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.green)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }

    private func row(_ wish: WishItem, indented: Bool = false) -> some View {
        HStack(spacing: 12) {
            if indented { Color.clear.frame(width: 16) }
            statePill(wish.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(wish.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                Text(wish.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            }
            Spacer()
            sourceBadge(wish.source)
            switch wish.state {
            case .wishlist, .matching:
                Button("Review") { if let id = wish.id { store.beginMatch(id) } }.buttonStyle(AccentButton())
            case .downloaded:
                Label("Verified", systemImage: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(theme.green)
            }
            Button { if let id = wish.id { store.deleteWish(id) } } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func statePill(_ state: WishState) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .wishlist: return ("Wishlist", theme.text3)
            case .matching: return ("Matching", theme.amber)
            case .downloaded: return ("Downloaded", theme.green)
            }
        }()
        return Text(label).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .frame(width: 92, alignment: .leading)
    }

    private func sourceBadge(_ source: WishSource) -> some View {
        let (label, color): (String, Color) = source == .appleMusic
            ? ("Apple Music", Color(hex: 0x2e7bd6)) : ("Custom", theme.text3)
        return Text(label).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

struct AddWishView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Custom Item").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            field("Title", $title)
            field("Artist", $artist)
            field("Album (optional)", $album)
            HStack {
                Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Add") {
                    store.addCustomWish(title: title, artist: artist, album: album)
                    store.openSheet = nil
                }.buttonStyle(AccentButton())
            }
        }
        .padding(22).frame(width: 420)
        .background(theme.sheet)
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
}
