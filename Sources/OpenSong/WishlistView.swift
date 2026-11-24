import SwiftUI
import OpenSongCore

struct WishlistView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var expandedComplete: Set<String> = []   // completed groups the user re-opened

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Pending", subtitle: "\(store.wishItems.count) items") {
                HStack(spacing: 8) {
                    Button { store.openSheet = .addURL } label: {
                        Label("Paste URL", systemImage: "link")
                    }.buttonStyle(AccentButton())
                    Button { store.openSheet = .addWish } label: {
                        Label("Custom Item", systemImage: "plus")
                    }.buttonStyle(SoftButton())
                }
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
                        let items = groups[name] ?? []
                        let complete = !items.contains { $0.state != .downloaded }
                        let expanded = !complete || expandedComplete.contains(name)
                        groupHeader(name, items, complete: complete, expanded: expanded)
                        if expanded {
                            ForEach(items, id: \.id) { wish in row(wish, indented: true) }
                        }
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

    private func groupHeader(_ name: String, _ items: [WishItem], complete: Bool, expanded: Bool) -> some View {
        let downloaded = items.filter { $0.state == .downloaded }.count
        let pending = items.filter { $0.state != .downloaded }
        return HStack(spacing: 10) {
            // Chevron only for completed groups (they collapse).
            Image(systemName: complete ? (expanded ? "chevron.down" : "chevron.right") : "music.note.list")
                .font(.system(size: complete ? 11 : 13, weight: complete ? .semibold : .regular))
                .foregroundStyle(complete ? theme.text3 : theme.accent).frame(width: 16)
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard complete else { return }
            if expandedComplete.contains(name) { expandedComplete.remove(name) } else { expandedComplete.insert(name) }
        }
    }

    private func row(_ wish: WishItem, indented: Bool = false) -> some View {
        let error = wish.id.flatMap { store.downloadErrors[$0] }
        return HStack(spacing: 12) {
            if indented { Color.clear.frame(width: 16) }
            if let error {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.red)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.red.opacity(0.14), in: Capsule())
                    .frame(width: 92, alignment: .leading)
                    .help(error)
            } else {
                statePill(wish.state)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(wish.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                    // A replacement looks like any other pending item, so say which it is: choosing
                    // a version here discards the copy already in the library.
                    if wish.isReplacement {
                        Text("replacing")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().stroke(theme.accent, lineWidth: 1))
                            .help("The version you pick replaces the file already in your library.")
                    }
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(theme.red).lineLimit(1)
                } else {
                    Text(wish.artist).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                }
            }
            Spacer()
            sourceBadge(wish.source)
            switch wish.state {
            case .wishlist, .matching:
                Button(error == nil ? "Review" : "Retry") { if let id = wish.id { store.beginMatch(id) } }.buttonStyle(AccentButton())
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

/// Paste a YouTube or SoundCloud link to download a single track directly (skips the search), with a chance to
/// tidy the metadata first.
struct AddURLView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var url = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var fetching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add from a link").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            Text("Paste a YouTube or SoundCloud track link to grab it directly — then tidy the title/artist below before it downloads.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)
            HStack(alignment: .bottom, spacing: 8) {
                field("YouTube or SoundCloud link", $url)
                Button(fetching ? "Fetching…" : "Fetch info") { fetch() }
                    .buttonStyle(SoftButton()).disabled(url.isEmpty || fetching)
            }
            field("Title", $title)
            field("Artist", $artist)
            field("Album (optional)", $album)
            HStack {
                Spacer()
                Button("Cancel") { store.openSheet = nil }.buttonStyle(SoftButton())
                Button("Download") {
                    store.addFromURL(urlString: url, title: title, artist: artist, album: album)
                    store.openSheet = nil
                }.buttonStyle(AccentButton()).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 480)
        .background(theme.sheet)
    }

    private func fetch() {
        fetching = true
        Task {
            if let m = await store.fetchURLMetadata(url) {
                title = m.title; artist = m.artist
            }
            fetching = false
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
        }
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
