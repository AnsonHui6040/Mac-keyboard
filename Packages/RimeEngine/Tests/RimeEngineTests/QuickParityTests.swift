import XCTest
@testable import RimeEngine

// Note: librime runs once per test process, so quick5 shares the compiled fixture directory with the Task 2
// fixtures (RimeFixture also copies ime/rime/*.yaml; the fixture default.yaml lists fixture, broken and quick5).
// `Repo.quickData()` therefore returns the same compiled paths as `RimeFixture.compiled`.

enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func quickData() throws -> RimePaths { try RimeFixture.compiled("quick5") }
}

/// Reads `code<TAB>character`, keeping file order.
struct QuickTable {
    let count: Int
    let byCode: [(code: String, characters: [String])]
    static func load(_ url: URL) throws -> QuickTable {
        let text = try String(contentsOf: url, encoding: .utf8)
        var order: [String] = []
        var groups: [String: [String]] = [:]
        var count = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let code = String(parts[0])
            if groups[code] == nil { order.append(code) }
            groups[code, default: []].append(String(parts[1]))
            count += 1
        }
        return QuickTable(count: count, byCode: order.map { ($0, groups[$0]!) })
    }
}

final class QuickParityTests: XCTestCase {
    /// Every code of the current Quick table gives the same leading candidates, in the same order, from librime:
    /// the first N candidates (N = the code's count in quick-table.txt) are the Big5 characters, unchanged; the
    /// HKSCS characters added from words.hk come only after them.
    func testEveryQuickCodeMatchesCurrentTable() throws {
        let expected = try QuickTable.load(Repo.root.appending(path: "iOS/RemoteKeyboardExtension/Resources/quick-table.txt"))
        let session = try RimeRuntime.start(Repo.quickData()).makeSession(schema: "quick5")
        XCTAssertEqual(expected.count, 13_980)
        var mismatches: [String] = []
        for (code, characters) in expected.byCode {
            session.clear()
            for key in code { _ = session.processKey(Int32(key.asciiValue!)) }
            if Array(session.state.candidates.prefix(characters.count)) != characters { mismatches.append(code) }
        }
        XCTAssertEqual(mismatches, [], "codes whose leading candidates differ: \(mismatches.prefix(20))")
    }
}
