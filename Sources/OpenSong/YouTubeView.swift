import SwiftUI
import AppKit
import OpenSongCore

/// Paste a YouTube playlist link → see every video (with thumbnail + already-added status) →
/// select which to queue. Because these are already source URLs, queued videos download directly
/// (the acquire screen skips its search step).
struct YouTubeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var selection: Set<Int> = []
    @State private var anchor: Int? = nil

    private var entries: [Candidate] { store.youtubeEntries }

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            ContentHeader(title: "YouTube", subtitle: store.youtubeTitle.isEmpty ? "Import a playlist" : store.youtubeTitle) {
                HStack(spacing: 8) {
                    pasteField($store.youtubeInput)
                    Button { selection = []; store.loadYouTube(store.youtubeInput) } label: {
                        Label(store.youtubeLoading ? "Loading…" : "Load", systemImage: "arrow.down.circle")
                    }.buttonStyle(AccentButton()).disabled(store.youtubeLoading)
                }
            }
            Divider().overlay(theme.sep)
            if store.youtubeLoading && entries.isEmpty {
                centered { ProgressView().controlSize(.large); Text("Reading playlist via yt-dlp…").font(.system(size: 13)).foregroundStyle(theme.text2) }
            } else if entries.isEmpty {
                emptyState
            } else {
                header
                Divider().overlay(theme.sep)
                ScrollOrStack(alignment: .leading) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, c in
                        row(c, index: idx)
                        Divider().overlay(theme.sep)
                    }
                }
            }
        }
    }

    /// Smart add button: acts on the selection, or all not-yet-added entries when nothing's picked.
    private var header: some View {
        let targets = selection.isEmpty ? Array(entries.indices) : selection.sorted()
        let addable = targets.map { entries[$0] }.filter { store.youtubeStatus($0) == .none }
        let added = entries.filter { store.youtubeStatus($0) != .none }.count
        return HStack(spacing: 12) {
            Text("\(entries.count) videos · \(added) already added"
                 + (selection.isEmpty ? "" : " · \(selection.count) selected"))
                .font(.system(size: 12)).foregroundStyle(theme.text3)
            Spacer()
            if !addable.isEmpty {
                Button("Add \(addable.count) to Pending") {
                    store.addYouTubeToPending(addable, group: store.youtubeTitle); selection = []
                }.buttonStyle(AccentButton())
            } else {
                Text("All added").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(theme.header)
    }

    private func row(_ c: Candidate, index: Int) -> some View {
        let status = store.youtubeStatus(c)
        let selected = selection.contains(index)
        return HStack(spacing: 12) {
            RemoteThumbnail(url: thumbURL(c), seed: c.videoID, width: 64, height: 40, corner: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13))
                    .foregroundStyle(selected ? theme.selText : (status == .inLibrary ? theme.text3 : theme.text)).lineLimit(1)
                Text(c.channel).font(.system(size: 11))
                    .foregroundStyle(selected ? theme.selText.opacity(0.85) : theme.text3).lineLimit(1)
            }
            Spacer()
            switch status {
            case .inLibrary:
                Label("In library", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(selected ? theme.selText : theme.green)
            case .pending:
                Text("Pending").font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? theme.selText : theme.amber)
            case .none:
                if c.durationSec > 0 {
                    Text(timeLabel(c.durationSec)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(selected ? theme.selText : theme.text3)
                }
            }
        }
        .padding(.horizontal, 20).frame(height: 48)
        .background(selected ? theme.accent : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(index) }
    }

    private var emptyState: some View {
        centered {
            Image(systemName: "play.rectangle").font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Import a YouTube playlist").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.youtubeError ?? "Paste a public YouTube playlist link. Pick the videos you want — the ones you already have are marked, and new picks download straight from their source.")
                .font(.system(size: 12)).foregroundStyle(store.youtubeError == nil ? theme.text3 : theme.red)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private func pasteField(_ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(theme.text3)
            if renderMode {
                Text(text.wrappedValue.isEmpty ? "Paste a YouTube playlist link…" : text.wrappedValue)
                    .font(.system(size: 12)).foregroundStyle(text.wrappedValue.isEmpty ? theme.text3 : theme.text)
                    .frame(width: 240, alignment: .leading)
            } else {
                TextField("Paste a YouTube playlist link…", text: text)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 240)
                    .onSubmit { store.loadYouTube(store.youtubeInput) }
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
    }

    private func thumbURL(_ c: Candidate) -> URL? {
        if let t = c.thumbnailURL { return t }
        let vid = c.videoID
        guard vid.count == 11, !vid.contains("/"), !vid.contains(":"), !vid.contains(".") else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
    }
    private func timeLabel(_ s: Double) -> String { let n = Int(s.rounded()); return String(format: "%d:%02d", n / 60, n % 60) }

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

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
