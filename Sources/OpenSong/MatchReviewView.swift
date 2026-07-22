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
                                Text("Paste a YouTube URL…").foregroundStyle(theme.text3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField("Paste a YouTube URL…", text: $pasteURL).textFieldStyle(.plain)
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
                metaField("Title", wish?.title ?? "")
                metaField("Artist", wish?.artist ?? "")
                metaField("Album", wish?.album ?? "—")
                if wish?.source == .appleMusic {
                    Label("Locked (from Apple Music)", systemImage: "lock.fill")
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                } else {
                    Label("From iTunes catalog", systemImage: "sparkles")
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                Spacer()
                Button { store.acquireSelected() } label: {
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
        return Button { store.selectedCandidateID = rc.id } label: {
            HStack(spacing: 10) {
                Circle().fill(selected ? theme.accent : Color.clear)
                    .overlay(Circle().stroke(selected ? theme.accent : theme.text3, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(placeholderGradient(rc.candidate.videoID))
                    .frame(width: 68, height: 40)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(rc.candidate.title).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(rc.candidate.channel).font(.system(size: 11)).foregroundStyle(theme.text3)
                        Text(confLabel).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(confColor.opacity(0.15), in: Capsule()).foregroundStyle(confColor)
                        if rc.durationDelta.isFinite {
                            Text(rc.durationDelta <= 2 ? "≈ duration match" : "Δ\(Int(rc.durationDelta))s")
                                .font(.system(size: 10)).foregroundStyle(theme.text3)
                        }
                    }
                }
                Spacer()
                Text(timeLabel(rc.candidate.durationSec)).font(.system(size: 11)).foregroundStyle(theme.text3).monospacedDigit()
            }
            .padding(10)
            .background(selected ? theme.selSoft : theme.stripe, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
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
            Text("No confident matches").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text("Paste a YouTube URL, or go back and try a different title.").font(.system(size: 12)).foregroundStyle(theme.text3)
            Button("Back to Pending") { store.activeView = .wishlist }.buttonStyle(SoftButton())
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

    private func metaField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3)
            Text(value).font(.system(size: 13)).foregroundStyle(theme.text)
        }
    }

    private func verifyLabel(_ v: VerifyResult) -> String {
        var parts = ["Quality \(v.spectralVerdict.isGood ? "OK" : "suspect")",
                     v.durationOK ? "duration ✓" : "duration ✗"]
        if let s = v.acoustidScore { parts.append("AcoustID \(Int(s * 100))%") }
        return parts.joined(separator: " · ")
    }

    private func timeLabel(_ s: Double) -> String {
        let n = Int(s.rounded()); return String(format: "%d:%02d", n / 60, n % 60)
    }
}
