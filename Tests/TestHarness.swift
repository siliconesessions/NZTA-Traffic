import Foundation

// Minimal dependency-free test harness. The project deliberately avoids
// SwiftPM and XCTest, so tests are a plain swiftc-built executable that
// exercises the pure logic in Models.swift and exits non-zero on failure.
final class TestRunner {
    private var passed = 0
    private var failed = 0
    private var currentGroup = ""

    func group(_ name: String) {
        currentGroup = name
    }

    func check(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            FileHandle.standardError.write(Data("  ✘ [\(currentGroup)] \(message)\n".utf8))
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message) — got \(actual), expected \(expected)")
    }

    func nearlyEqual(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001, _ message: String) {
        guard let actual else {
            check(false, "\(message) — got nil, expected \(expected)")
            return
        }
        check(abs(actual - expected) <= tolerance, "\(message) — got \(actual), expected ~\(expected)")
    }

    func finish() -> Int32 {
        let total = passed + failed
        print("\nTests: \(passed)/\(total) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

// Decode a model from a JSON literal, failing the test (not crashing) on error.
func decodeModel<T: Decodable>(_ type: T.Type, _ json: String, _ runner: TestRunner) -> T? {
    do {
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    } catch {
        runner.check(false, "decode \(T.self) failed: \(error)")
        return nil
    }
}
