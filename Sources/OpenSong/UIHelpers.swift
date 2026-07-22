import SwiftUI

/// True when rendering screens offscreen (OPENSONG_RENDER=1). ImageRenderer can't
/// rasterize ScrollView content or AppKit-backed controls, so those fall back to
/// static equivalents while rendering. The real app uses the interactive versions.
let renderMode = ProcessInfo.processInfo.environment["OPENSONG_RENDER"] == "1"

/// ScrollView in the app; a plain stack while rendering (so content rasterizes).
struct ScrollOrStack<C: View>: View {
    var alignment: HorizontalAlignment = .center
    @ViewBuilder var content: C
    var body: some View {
        if renderMode {
            VStack(alignment: alignment, spacing: 0) { content }
        } else {
            ScrollView { VStack(alignment: alignment, spacing: 0) { content } }
        }
    }
}

/// Custom segmented control (matches the design; renders offscreen unlike Picker).
struct SegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let on = opt.value == selection
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 22)
                        .background(on ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(on ? theme.accentText : theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Custom progress bar (ProgressView renders as a placeholder offscreen).
struct ProgressBar: View {
    var value: Double
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule().fill(theme.accent).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}
