import Foundation
import XCTest
@testable import RimeEngine

final class SchemeQualityReportTests: XCTestCase {
    private struct Case { let schema: String; let keys: String; let expected: String }
    private struct Outcome { let testCase: Case; let rank: Int?; let top: [String] }

    private func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/quality-cases.tsv")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return p.count == 3 ? Case(schema: p[0], keys: p[1], expected: p[2]) : nil
        }
    }

    private func type(_ runtime: RimeRuntime, _ schema: String, _ keys: String) throws -> [String] {
        let session = try runtime.makeSession(schema: schema)
        for key in keys { _ = session.processKey(Int32(key.asciiValue!)) }
        return session.state.candidates
    }

    /// Count of distinct single characters whose category column is utf8 in the McBopomofo base table.
    private func utf8Singles() throws -> Int {
        let text = try String(contentsOf: Repo.root.appending(path: "build/rime/src/mcbopomofo/BPMFBase.txt"), encoding: .utf8)
        let rows = text.split(separator: "\n").filter { $0.split(separator: " ").last == "utf8" }
        return Set(rows.compactMap { $0.split(separator: " ").first.map(String.init) }).count
    }

    func testQualityReport() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        let big5 = Set(try QuickTable.load(Repo.root.appending(path: "iOS/RemoteKeyboardExtension/Resources/quick-table.txt"))
            .byCode.flatMap(\.characters))
        var outcomes: [Outcome] = []
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 56, "quality-cases.tsv rows must be scheme<TAB>keys<TAB>expected")
        for c in cases {
            let got = try type(runtime, c.schema, c.keys)
            outcomes.append(Outcome(testCase: c, rank: got.firstIndex(of: c.expected).map { $0 + 1 }, top: Array(got.prefix(5))))
        }
        let schemas = ["quick5", "cangjie5", "zhuyin", "pinyin", "jyutping"]
        var md = "# Scheme quality report\n\n| scheme | first | top 5 | total |\n|---|---|---|---|\n"
        var failures: [String] = []
        for s in schemas {
            let rows = outcomes.filter { $0.testCase.schema == s }
            let first = rows.filter { $0.rank == 1 }.count
            let top5 = rows.filter { ($0.rank ?? 99) <= 5 }.count
            md += "| \(s) | \(first) | \(top5) | \(rows.count) |\n"
            if s == "quick5" {
                if let miss = rows.first(where: { $0.rank == nil }) { failures.append("quick5 \(miss.testCase.keys) missing") }
            } else if rows.isEmpty || Double(top5) / Double(rows.count) < 0.8 {
                failures.append("\(s) top-5 \(top5)/\(rows.count) is below 80%")
            }
        }
        md += "\n## Cases\n\n| scheme | keys | expected | rank | top 5 |\n|---|---|---|---|---|\n"
        for o in outcomes {
            md += "| \(o.testCase.schema) | \(o.testCase.keys) | \(o.testCase.expected) | \(o.rank.map(String.init) ?? "無") | \(o.top.joined(separator: " ")) |\n"
        }
        md += "\n## Spot check (not counted)\n\n| scheme | keys | expected | rank |\n|---|---|---|---|\n"
        let lve = try type(runtime, "pinyin", "lve").firstIndex(of: "略").map { $0 + 1 }
        md += "| pinyin | lve | 略 | \(lve.map(String.init) ?? "無") |\n"
        md += "\n## Quick codes with Hong Kong characters (first 10, * = not in Big5)\n\n"
        for code in ["ru", "rm", "ri", "rn", "rf"] {
            let got = Array(try type(runtime, "quick5", code).prefix(10))
            md += "- \(code): " + got.map { big5.contains($0) ? $0 : "\($0)*" }.joined(separator: " ") + "\n"
        }
        md += "\n## utf8 category singles in McBopomofo base table (includes Simplified)\n\n\(try utf8Singles())\n"
        let path = ProcessInfo.processInfo.environment["RIME_QUALITY_REPORT"] ?? Repo.root.appending(path: "build/rime/quality-report.md").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try md.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(failures, [])
    }
}
