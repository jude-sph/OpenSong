import SwiftUI
import OpenSongCore

struct MatchReviewView: View {
    let wishID: Int64
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var pasteURL = ""

    private var wish: WishItem? { store.wishItems.first { $0.id == wishID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.sep)
            switch store.matchStep {
            case .loading: centered(spinner: true, "Searching YouTube via yt-dlp…")
            case .error: errorState
            case .downloading: centered(spinner: true, "yt-dlp → ffmpeg → tagging → verify…")
            case .done: doneState
            case .results: results
            }
        }
        .onDisappear { store.candidatePreview.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { store.activeView = .wishlist } label: {
                Image(systemName: "chevron.left").font(.system(size: 13))
            }.buttonStyle(.plain).foregroundStyle(theme.text2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finding a source").font(.system(size: 12)).foregroundStyle(theme.text3)
                Text("\(wish?.title ?? "") — \(wish?.artist ?? "")")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14).background(theme.header)
    }

    private var results: some View {
        HStack(alignment: .top, spacing: 0) {
            // Candidate cards
            ScrollOrStack(alignment: .leading) {
                VStack(spacing: 8) {
                    ForEach(store.matchCandidates) { rc in candidateCard(rc) }
                    HStack(spacing: 6) {
                        Group {
                            if renderMode {
                                Text("Paste a YouTube or SoundCloud link…").foregroundStyle(theme.text3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField("Paste a YouTube or SoundCloud link…", text: $pasteURL).textFieldStyle(.plain)
                            }
                        }
                        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
                        Button("Use") { store.pasteCustomURL(pasteURL) }.buttonStyle(SoftButton())
                    }.padding(.top, 4)
                }.padding(20)
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(theme.sep)

            // Metadata + download
            VStack(alignment: .leading, spacing: 12) {
                Text("METADATA").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(theme.text3)
                editableMetaField("Title", Binding(get: { wish?.title ?? "" },
                                                   set: { store.updateWishMeta(wishID, title: $0) }))
                editableMetaField("Artist", Binding(get: { wish?.artist ?? "" },
                                                    set: { store.updateWishMeta(wishID, artist: $0) }))
                editableMetaField("Album", Binding(get: { wish?.album ?? "" },
                                                   set: { store.updateWishMeta(wishID, album: $0) }))
                Label(wish?.source == .appleMusic ? "Pre-filled from Apple Music — edit freely"
                                                  : "Pre-filled from iTunes — edit freely",
                      systemImage: "square.and.pencil")
                    .font(.system(size: 11)).foregroundStyle(theme.text3)
                Spacer()
                Button { store.candidatePreview.stop(); store.acquireSelected() } label: {
                    Text("Download & tag").frame(maxWidth: .infinity)
                }.buttonStyle(AccentButton()).disabled(store.selectedCandidateID == nil)
            }
            .padding(20).frame(width: 300)
        }
    }

    private func candidateCard(_ rc: RankedCandidate) -> some View {
        let selected = store.selectedCandidateID == rc.id
        let (confLabel, confColor): (String, Color) = {
            switch rc.confidence {
            case .high: return ("High", theme.green)
            case .medium: return ("Medium", theme.amber)
            case .low: return ("Low", theme.text3)
            }
        }()
        let preview = store.candidatePreview
        let isPreviewing = preview.playingID == rc.id
        return VStack(spacing: 7) {
            HStack(spacing: 10) {
                Circle().fill(selected ? theme.accent : Color.clear)
                    .overlay(Circle().stroke(selected ? theme.accent : theme.text3, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                previewThumb(rc.candidate)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rc.candidate.title).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(rc.candidate.channel).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                        Text(confLabel).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(confColor.opacity(0.15), in: Capsule()).foregroundStyle(confColor)
                        if let q = store.candidateQuality[rc.candidate.videoID] {
                            Text(q).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(theme.chip, in: Capsule())
                        }
                        if rc.durationDelta.isFinite {
                            Text(rc.durationDelta <= 2 ? "≈ duration match" : "Δ\(Int(rc.durationDelta))s")
                                .font(.system(size: 10)).foregroundStyle(theme.text3)
                        }
                    }
                }
                Spacer()
                Text(timeLabel(rc.candidate.durationSec)).font(.system(size: 11)).foregroundStyle(theme.text3).monospacedDigit()
            }
            if isPreviewing { previewScrubber(preview) }
        }
        .padding(10)
        .background(selected ? theme.selSoft : theme.stripe, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedCandidateID = rc.id }
        .contextMenu {
            Button("Download separately (into library only)") { store.acquireSideCandidate(rc) }
            Button("Preview") { store.candidatePreview.toggle(id: rc.id, url: rc.candidate.url, knownDuration: rc.candidate.durationSec) }
        }
    }

    /// A minimal scrubber shown under the candidate that's currently previewing.
    private func previewScrubber(_ preview: CandidatePreviewModel) -> some View {
        HStack(spacing: 8) {
            Text(timeLabel(preview.currentTime)).font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.text3).frame(width: 30, alignment: .trailing)
            DragBar(value: preview.progress, onChange: { preview.seek(toFraction: $0) }, height: 3)
            Text(timeLabel(preview.duration)).font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.text3).frame(width: 30, alignment: .leading)
        }
        .padding(.leading, 24).padding(.trailing, 4)
    }

    /// Square preview of the cover art this candidate would produce, doubling as a listen/preview
    /// button. `RemoteThumbnail` fills + clips, so a square frame reproduces the exact centered
    /// square crop `AcquireCoordinator.squareCropEmbeddedArt` embeds on download (side = height,
    /// centered horizontally — matching `ArtworkCrop.squareCrop`'s 0.5 offset).
    private func previewThumb(_ c: Candidate) -> some View {
        let preview = store.candidatePreview
        let isPlaying = preview.playingID == c.id
        let isLoading = preview.loadingID == c.id
        return Button {
            preview.toggle(id: c.id, url: c.url, knownDuration: c.durationSec)
        } label: {
            RemoteThumbnail(url: thumbURL(c), seed: c.videoID, width: 48, height: 48, corner: 5)
                .overlay(Color.black.opacity(isPlaying ? 0.35 : 0.22))
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14)).foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    /// YouTube video still: use yt-dlp's thumbnail when present, else the standard i.ytimg URL
    /// derived from the 11-char video ID. Nil for pasted custom URLs (no derivable ID).
    private func thumbURL(_ c: Candidate) -> URL? {
        if let t = c.thumbnailURL { return t }
        let vid = c.videoID
        guard vid.count == 11, !vid.contains("/"), !vid.contains(":"), !vid.contains(".") else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
    }

    private func editableMetaField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            if renderMode {
                Text(text.wrappedValue.isEmpty ? "—" : text.wrappedValue)
                    .font(.system(size: 13)).foregroundStyle(theme.text)
            } else {
                TextField(label, text: text)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(theme.text)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 1))
            }
        }
    }

    private var doneState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(theme.green)
            Text("Downloaded & verified").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            if let v = store.matchVerify {
                Text(verifyLabel(v)).font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Button("Back to Pending") { store.activeView = .wishlist }.buttonStyle(AccentButton())
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(theme.red)
            Text(store.matchError == nil ? "No confident matches" : "Download failed")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(store.matchError ?? "Paste a YouTube or SoundCloud link, or go back and try a different title.")
                .font(.system(size: 12)).foregroundStyle(theme.text3)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 8) {
                if store.matchError != nil {
                    Button("Try again") { store.matchStep = .results }.buttonStyle(SoftButton())
                }
                Button("Back to Pending") { store.activeView = .wishlist }.buttonStyle(SoftButton())
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered(spinner: Bool, _ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if spinner { ProgressView().controlSize(.large) }
            Text(text).font(.system(size: 13)).foregroundStyle(theme.text2)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func verifyLabel(_ v: VerifyResult) -> String {
        var parts = ["Quality \(v.spectralVerdict.isGood ? "OK" : "suspect")",
                     v.durationOK ? "duration ✓" : "duration ✗"]
        return parts.joined(separator: " · ")
    }

    private func timeLabel(_ s: Double) -> String {
        let n = Int(s.rounded()); return String(format: "%d:%02d", n / 60, n % 60)
    }
}
