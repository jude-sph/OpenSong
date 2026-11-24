import Foundation
import OpenSongCore

func registerShellTests() {
    t.test("shell captures stdout and zero status") {
        let r = try Shell.run("/bin/echo", ["hi"])
        try t.expectEqual(r.status, 0, "status")
        try t.expectEqual(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "hi", "stdout")
    }
    t.test("shell reports nonzero status") {
        let r = try Shell.run("/usr/bin/false", [])
        try t.expectEqual(r.status, 1, "false exits 1")
    }
    t.test("shell feeds stdin") {
        let r = try Shell.run("/bin/cat", [], stdin: Data("piped".utf8))
        try t.expectEqual(r.stdoutString, "piped", "stdin echoed")
    }
    t.test("shell handles large output without deadlock") {
        // 300 KB would overflow a pipe buffer (~64 KB) and deadlock if stdout is not
        // drained concurrently with the process running. `head` produces then exits.
        let r = try Shell.run("/usr/bin/head", ["-c", "300000", "/dev/zero"])
        try t.expectEqual(r.status, 0, "status")
        try t.expectEqual(r.stdout.count, 300_000, "all bytes captured")
    }
    t.test("child tools see Homebrew bin dirs on PATH") {
        // GUI apps start with a bare PATH; yt-dlp must still find deno in /opt/homebrew/bin.
        let r = try Shell.run("/bin/sh", ["-c", "echo $PATH"])
        let dirs = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        try t.expect(dirs.contains("/opt/homebrew/bin"), "has /opt/homebrew/bin")
        try t.expect(dirs.contains("/usr/local/bin"), "has /usr/local/bin")
    }
    t.test("runAsync doesn't starve other tasks while children run") {
        // 20 slow children: blocking `run` would park every cooperative thread for 2 s.
        let t0 = Date()
        let kids = (0..<20).map { _ in Task { try await Shell.runAsync("/bin/sleep", ["2"]) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let waited = await Task.detached { Date().timeIntervalSince(t0) }.value
        for k in kids { _ = try await k.value }
        try t.expect(waited < 1.0, "other work started after \(waited)s")
    }
}
