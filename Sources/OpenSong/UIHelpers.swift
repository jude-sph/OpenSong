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
            // LazyVStack so off-screen rows don't run their artwork-extraction .task.
            ScrollView { LazyVStack(alignment: alignment, spacing: 0) { content } }
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

/// Custom switch (Toggle(.switch) renders as a placeholder offscreen; also matches
/// the design's 38×22 track / 18px knob).
struct SwitchToggle: View {
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? theme.accent : theme.track).frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A labeled setting row with a trailing switch.
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(theme.text)
            Spacer()
            SwitchToggle(isOn: $isOn)
        }
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
