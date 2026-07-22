import OpenSongCore

func registerPathSanitizerTests() {
    t.test("sanitizer keeps interior dot, trims trailing dot") {
        try t.expectEqual(PathSanitizer.component("Richard D. James Album", fallback: "X"),
                          "Richard D. James Album", "interior dot kept")
        try t.expectEqual(PathSanitizer.component("Latejapride.", fallback: "X"),
                          "Latejapride", "trailing dot trimmed")
    }
    t.test("sanitizer removes FAT-illegal separators") {
        try t.expectEqual(PathSanitizer.component("AC/DC", fallback: "X"), "AC DC", "slash -> space")
        try t.expectEqual(PathSanitizer.component("a\\b", fallback: "X"), "a b", "backslash -> space")
        try t.expectEqual(PathSanitizer.component("a:b*c?d\"e<f>g|h", fallback: "X"),
                          "a b c d e f g h", "all illegal -> spaces, collapsed")
    }
    t.test("sanitizer preserves Unicode") {
        try t.expectEqual(PathSanitizer.component("Sérgio Mendes", fallback: "X"), "Sérgio Mendes", "accents kept")
        try t.expectEqual(PathSanitizer.component("half•alive", fallback: "X"), "half•alive", "bullet kept")
        try t.expectEqual(PathSanitizer.component("não me deixe só", fallback: "X"), "não me deixe só", "tilde kept")
    }
    t.test("sanitizer falls back when empty") {
        try t.expectEqual(PathSanitizer.component("", fallback: "Unknown Artist"), "Unknown Artist", "empty -> fallback")
        try t.expectEqual(PathSanitizer.component("...", fallback: "Unknown Album"), "Unknown Album", "dots-only -> fallback")
        try t.expectEqual(PathSanitizer.component("   ", fallback: "Unknown Album"), "Unknown Album", "spaces-only -> fallback")
    }
    t.test("sanitizer collapses whitespace and trims") {
        try t.expectEqual(PathSanitizer.component("  Two   Spaces  ", fallback: "X"), "Two Spaces", "collapsed + trimmed")
    }
}
