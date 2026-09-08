import Foundation

// Minimal XCTest-free test runner (same pattern as FreeFlow's Tests/TestMain):
// each test throws on failure; the runner counts and exits non-zero on any
// failure. Run via `make test`.

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) throws {
    if a != b { throw TestFailure("\(label): expected \(b), got \(a)") }
}
func expectTrue(_ cond: Bool, _ label: String) throws {
    if !cond { throw TestFailure(label) }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

final class TestRunner {
    static var failures = 0
    static var passed = 0
    static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failures += 1
            print("FAIL \(name): \(error)")
        }
    }
}

// tiny optional-unwrap helper for tests
infix operator ?!
func ?!<T>( _ v: T?, _ msg: String) throws -> T {
    guard let v else { throw TestFailure(msg) }
    return v
}
