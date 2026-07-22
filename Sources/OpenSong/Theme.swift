import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1)
    }
}

/// Design tokens from the OpenSong design docs. British Racing Green accent, with a
/// light and dark value for every token (and the accent's text color flips with it).
struct Theme: Sendable {
    let dark: Bool

    var desk: Color        { dark ? Color(hex: 0x0d0d0f) : Color(hex: 0xc9c9cd) }
    var content: Color     { dark ? Color(hex: 0x1c1c1f) : Color(hex: 0xffffff) }
    var sheet: Color       { dark ? Color(hex: 0x26262b) : Color(hex: 0xffffff) }
    var sidebar: Color     { dark ? Color(hex: 0x201f24) : Color(hex: 0xe8e7ea) }
    var titlebar: Color    { dark ? Color(hex: 0x2a2830) : Color(hex: 0xedecef) }
    var header: Color      { dark ? Color(hex: 0x242327) : Color(hex: 0xf7f6f8) }
    var text: Color        { dark ? Color(hex: 0xf2f2f5) : Color(hex: 0x1d1d1f) }
    var text2: Color       { dark ? Color(hex: 0xa0a0a8) : Color(hex: 0x65656c) }
    var text3: Color       { dark ? Color(hex: 0x6f6f77) : Color(hex: 0x9b9ba2) }
    var sep: Color         { (dark ? Color.white : Color.black).opacity(dark ? 0.09 : 0.09) }
    var sepStrong: Color   { (dark ? Color.white : Color.black).opacity(dark ? 0.16 : 0.14) }
    // British Racing Green — the SAME accent in light and dark (user preference).
    var accent: Color      { Color(hex: 0x12452b) }
    var accentText: Color  { Color(hex: 0xffffff) }
    var selText: Color     { Color(hex: 0xffffff) }
    var selSoft: Color     { Color(hex: 0x12452b).opacity(dark ? 0.30 : 0.11) }
    var hover: Color       { (dark ? Color.white : Color.black).opacity(dark ? 0.06 : 0.05) }
    var stripe: Color      { (dark ? Color.white : Color.black).opacity(dark ? 0.025 : 0.02) }
    var field: Color       { dark ? Color(hex: 0x2c2c31) : Color(hex: 0xffffff) }
    var fieldBorder: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.18 : 0.16) }
    var chip: Color        { (dark ? Color.white : Color.black).opacity(dark ? 0.09 : 0.06) }
    var track: Color       { (dark ? Color.white : Color.black).opacity(dark ? 0.14 : 0.10) }
    var amber: Color       { dark ? Color(hex: 0xe0a63a) : Color(hex: 0xa8680a) }
    var red: Color         { dark ? Color(hex: 0xff6a5a) : Color(hex: 0xc2331f) }
    var green: Color       { dark ? Color(hex: 0x54c98a) : Color(hex: 0x1f7a45) }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(dark: false)
}
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// A deterministic gradient placeholder keyed by a string (albums/artists without art).
func placeholderGradient(_ seed: String) -> LinearGradient {
    var hash = 5381
    for b in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
    let hue = Double(abs(hash) % 360) / 360.0
    let c1 = Color(hue: hue, saturation: 0.55, brightness: 0.52)
    let c2 = Color(hue: (hue + 0.066).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.32)
    return LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
}
