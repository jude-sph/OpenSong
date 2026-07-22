import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Thread-safe one-shot container for a pipe's drained bytes.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum Shell {
    public enum ShellError: Error, CustomStringConvertible {
        case launchFailed(String)
        public var description: String {
            switch self { case .launchFailed(let m): return "launch failed: \(m)" }
        }
    }

    /// Run a subprocess to completion, draining stdout and stderr concurrently
    /// (so neither pipe's buffer can fill and deadlock the child).
    public static func run(_ launchPath: String, _ args: [String], stdin: Data? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do { try process.run() }
        catch { throw ShellError.launchFailed("\(launchPath): \(error)") }

        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "opensong.shell.read", attributes: .concurrent)
        queue.async(group: group) { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        queue.async(group: group) { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()) }
        group.wait()
        process.waitUntilExit()

        return ProcessResult(status: process.terminationStatus, stdout: outBox.value, stderr: errBox.value)
    }
}
