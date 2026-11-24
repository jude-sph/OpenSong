import Foundation
import OpenSongCore

func registerToolUpdateTests() {
    t.test("a pip install is upgraded through the interpreter that owns it") {
        // A machine can have several Pythons — this one has python.org's and Homebrew's — so the
        // upgrade has to run through the exact interpreter named in the script's shebang, or it
        // updates a copy of yt-dlp the app isn't using.
        let plan = ToolUpdate.ytDlpPlan(
            path: "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp",
            shebang: "#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        try t.expectEqual(plan.method, .pip, "recognised as pip")
        try t.expectEqual(plan.executable,
                          "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14",
                          "runs that interpreter, not whichever python is first on PATH")
        try t.expectEqual(plan.arguments, ["-m", "pip", "install", "--upgrade", "yt-dlp"], "pip upgrade")
    }

    t.test("an env shebang keeps env as the launcher") {
        let plan = ToolUpdate.ytDlpPlan(path: "/usr/local/bin/yt-dlp",
                                        shebang: "#!/usr/bin/env python3")
        try t.expectEqual(plan.method, .pip, "still pip")
        try t.expectEqual(plan.executable, "/usr/bin/env", "env resolves the interpreter itself")
        try t.expectEqual(plan.arguments, ["python3", "-m", "pip", "install", "--upgrade", "yt-dlp"],
                          "the interpreter is env's first argument")
    }

    t.test("a Homebrew install is upgraded with brew") {
        for path in ["/opt/homebrew/bin/yt-dlp",
                     "/opt/homebrew/Cellar/yt-dlp/2026.7.4/bin/yt-dlp"] {
            let plan = ToolUpdate.ytDlpPlan(path: path, shebang: nil)
            try t.expectEqual(plan.method, .homebrew, "\(path): recognised as Homebrew")
            try t.expectEqual(plan.executable, "/opt/homebrew/bin/brew", "runs brew")
            try t.expectEqual(plan.arguments, ["upgrade", "yt-dlp"], "brew upgrade")
        }
    }

    t.test("a standalone binary uses its own updater") {
        let plan = ToolUpdate.ytDlpPlan(path: "/Users/someone/bin/yt-dlp", shebang: nil)
        try t.expectEqual(plan.method, .selfUpdate, "nothing else claims it")
        try t.expectEqual(plan.executable, "/Users/someone/bin/yt-dlp", "the tool updates itself")
        try t.expectEqual(plan.arguments, ["-U"], "with -U")
    }

    t.test("a shebang that isn't Python doesn't get treated as pip") {
        // A wrapper shell script would otherwise be handed to `sh -m pip`, which fails obscurely.
        let plan = ToolUpdate.ytDlpPlan(path: "/Users/someone/bin/yt-dlp", shebang: "#!/bin/sh")
        try t.expectEqual(plan.method, .selfUpdate, "falls back rather than guessing pip")
    }

    t.test("pip's two common refusals map to the argument that fixes them") {
        try t.expectEqual(
            ToolUpdate.pipRetryArguments(forStderr: "error: externally-managed-environment"),
            ["--break-system-packages"], "the managed-environment refusal")
        try t.expectEqual(
            ToolUpdate.pipRetryArguments(forStderr: "Permission denied: '/Library/Frameworks'"),
            ["--user"], "a read-only install location")
        try t.expect(ToolUpdate.pipRetryArguments(forStderr: "no network") == nil,
                     "anything else is a real failure, not something to retry blindly")
    }

    t.test("the shebang is read from a real file, and only from a script") {
        let dir = try TestSupport.tempDir("shebang")
        let script = dir.appendingPathComponent("yt-dlp")
        try "#!/usr/bin/env python3\nimport sys\n".write(to: script, atomically: true, encoding: .utf8)
        try t.expectEqual(ToolUpdate.shebang(ofFileAt: script.path), "#!/usr/bin/env python3",
                          "first line of a script")
        let binary = dir.appendingPathComponent("binary")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]).write(to: binary)
        try t.expect(ToolUpdate.shebang(ofFileAt: binary.path) == nil, "a Mach-O binary has none")
        try t.expect(ToolUpdate.shebang(ofFileAt: dir.appendingPathComponent("nope").path) == nil,
                     "a missing file is nil, not a crash")
    }
}
