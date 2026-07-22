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
}
