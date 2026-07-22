import SwiftUI
import AppKit

/// Ensures the main window activates and comes to the front on launch. Under the
/// screenshot flag it also joins all Spaces so an automated `screencapture` on any
/// active Space catches it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        if ProcessInfo.processInfo.environment["OPENSONG_RENDER"] == "1" {
            MainActor.assumeIsolated { renderScreens() }
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let screenshotMode = ProcessInfo.processInfo.environment["OPENSONG_SCREENSHOT"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for window in NSApp.windows where (window.contentView?.frame.height ?? 0) > 300 {
                if screenshotMode { window.collectionBehavior.insert(.canJoinAllSpaces) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct OpenSongApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.theme, Theme(dark: store.dark))
                .preferredColorScheme(store.dark ? .dark : .light)
                .frame(minWidth: 980, minHeight: 640)
                .ignoresSafeArea()   // outermost: no titlebar dead-strip above the custom TitleBar
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 770)

        MenuBarExtra("OpenSong", systemImage: "headphones") {
            MenuBarExtraView().environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
