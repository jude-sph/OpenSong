// TinyTest — a minimal test harness.
// XCTest and swift-testing are unavailable under Command Line Tools (no Xcode),
// so tests register closures here and run via `swift run OpenSongTests`.
// A failed assertion throws; the runner reports PASS/FAIL and exits nonzero on any failure.

import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class TinyTest {
    private struct Case { let name: String; let body: () throws -> Void }
    private var cases: [Case] = []

    /// Register a test.
    func test(_ name: String, _ body: @escaping () throws -> Void) {
        cases.append(Case(name: name, body: body))
    }

    // MARK: assertions

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw TestFailure(message: message()) }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String) throws {
        if a != b { throw TestFailure(message: "\(message()) — expected \(b), got \(a)") }
    }

    func expectThrows(_ message: @autoclosure () -> String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw TestFailure(message: "\(message()) — expected an error but none was thrown")
    }

    /// Skip a test at runtime (e.g. live-network tests when the env flag is unset).
    struct Skip: Error { let reason: String }
    func skip(_ reason: String) throws -> Never { throw Skip(reason: reason) }

    // MARK: runner

    func runAll() -> Never {
        var passed = 0, failed = 0, skipped = 0
        var failures: [(String, String)] = []
        for c in cases {
            do {
                try c.body()
                passed += 1
                print("PASS  \(c.name)")
            } catch let s as Skip {
                skipped += 1
                print("SKIP  \(c.name) — \(s.reason)")
            } catch {
                failed += 1
                failures.append((c.name, "\(error)"))
                print("FAIL  \(c.name) — \(error)")
            }
        }
        print(String(repeating: "─", count: 48))
        print("\(passed) passed, \(failed) failed, \(skipped) skipped, \(cases.count) total")
        if !failures.isEmpty {
            print("\nFailures:")
            for (name, msg) in failures { print("  ✘ \(name): \(msg)") }
        }
        exit(failed == 0 ? 0 : 1)
    }
}

/// Global harness used by all test files.
/// `nonisolated(unsafe)`: the runner executes test cases sequentially on one thread,
/// so there is no concurrent access to guard against.
nonisolated(unsafe) let t = TinyTest()

/// Locate a file under Tests/Fixtures relative to this source file's location,
/// so tests can load golden fixtures regardless of CWD.
func fixtureURL(_ name: String) -> URL {
    // This file lives at <repo>/Sources/OpenSongTests/TinyTest.swift
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot = thisFile
        .deletingLastPathComponent()   // OpenSongTests
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // repo root
    return repoRoot.appendingPathComponent("Tests/Fixtures/\(name)")
}
