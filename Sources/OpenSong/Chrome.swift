import SwiftUI

/// Custom 44px title bar: traffic-light gutter, centered title, light/dark toggle, settings.
struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Text("OpenSong").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            HStack {
                Spacer().frame(width: 72) // traffic-light gutter
                Spacer()
                HStack(spacing: 8) {
                    // Light/Dark segmented toggle
                    HStack(spacing: 2) {
                        segmentButton("sun.max", isOn: !store.dark) { store.dark = false }
                        segmentButton("moon", isOn: store.dark) { store.dark = true }
                    }
                    .padding(2)
                    .background(theme.chip, in: RoundedRectangle(cornerRadius: 7))

                    Button { store.openSheet = .settings } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text2)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .background(theme.titlebar)
    }

    private func segmentButton(_ icon: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 18)
                .background(isOn ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(isOn ? theme.accentText : theme.text2)
        }
        .buttonStyle(.plain)
    }
}

/// Persistent bottom activity bar.
struct ActivityBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if store.activity.isEmpty {
                Text("No background activity").font(.system(size: 12)).foregroundStyle(theme.text3)
            } else {
                ForEach(store.activity) { task in
                    HStack(spacing: 8) {
                        Text(task.label).font(.system(size: 12)).foregroundStyle(theme.text2)
                        ProgressBar(value: task.progress).frame(width: 90)
                    }
                }
            }
            Spacer()
            Text(store.libraryTotalsLabel).font(.system(size: 12)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(theme.titlebar)
    }
}
