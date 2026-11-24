import Foundation

/// Working out how to update a command-line tool, which depends entirely on how it was installed.
///
/// yt-dlp is the one that matters: YouTube changes things often enough that an out-of-date copy is a
/// common cause of "the download failed". Its self-update (`yt-dlp -U`) only works for the standalone
/// binary — a pip install refuses and tells you to use pip, and a Homebrew install refuses and tells
/// you to use brew. Picking the wrong one produces a confusing error rather than an update, so the
/// choice is made here, from evidence, and tested.
public enum ToolUpdate {
    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// How the tool was installed, for the message shown to the user.
        public let method: Method
        public init(executable: String, arguments: [String], method: Method) {
            self.executable = executable; self.arguments = arguments; self.method = method
        }
    }

    public enum Method: String, Equatable, Sendable {
        case pip, homebrew, selfUpdate

        public var label: String {
            switch self {
            case .pip: return "pip"
            case .homebrew: return "Homebrew"
            case .selfUpdate: return "its own updater"
            }
        }
    }

    /// The first line of a file, if it is a `#!` script. Callers pass this in so the decision itself
    /// stays a pure function.
    public static func shebang(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 256) else { return nil }
        try? handle.close()
        guard data.starts(with: Array("#!".utf8)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// How to update the yt-dlp at `path`.
    ///
    /// A pip install is a short Python script whose shebang names the interpreter that owns it —
    /// which is exactly the interpreter the upgrade has to run through, since a machine can easily
    /// have several (this one has both a python.org Python and Homebrew's).
    public static func ytDlpPlan(path: String, shebang: String?,
                                 brewPath: String = "/opt/homebrew/bin/brew") -> Plan {
        if let interpreter = pythonInterpreter(fromShebang: shebang) {
            return Plan(executable: interpreter.executable,
                        arguments: interpreter.leadingArguments
                            + ["-m", "pip", "install", "--upgrade", "yt-dlp"],
                        method: .pip)
        }
        if isHomebrew(path) {
            return Plan(executable: brewPath, arguments: ["upgrade", "yt-dlp"], method: .homebrew)
        }
        return Plan(executable: path, arguments: ["-U"], method: .selfUpdate)
    }

    /// Extra arguments to retry with when pip refuses. Both refusals are common on a Mac and both
    /// are recoverable, so the caller tries them in turn rather than handing the user a stack trace.
    public static func pipRetryArguments(forStderr stderr: String) -> [String]? {
        if stderr.contains("externally-managed-environment") { return ["--break-system-packages"] }
        if stderr.contains("Permission denied") || stderr.contains("--user") { return ["--user"] }
        return nil
    }

    private static func pythonInterpreter(fromShebang shebang: String?)
        -> (executable: String, leadingArguments: [String])? {
        guard let line = shebang?.dropFirst(2).trimmingCharacters(in: .whitespaces), !line.isEmpty
        else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        // `#!/usr/bin/env python3` — the interpreter is the argument, not the executable.
        if first.hasSuffix("/env") {
            guard let named = parts.dropFirst().first, named.contains("python") else { return nil }
            return (first, [named])
        }
        guard first.contains("python") else { return nil }
        return (first, [])
    }

    private static func isHomebrew(_ path: String) -> Bool {
        path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Homebrew/")
    }
}
