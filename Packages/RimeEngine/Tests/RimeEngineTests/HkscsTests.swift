import XCTest
@testable import RimeEngine

final class HkscsTests: XCTestCase {
    /// Big5 characters are the ones the current Swift Quick table holds.
    private func big5() throws -> Set<String> {
        let table = try QuickTable.load(Repo.root.appending(path: "iOS/RemoteKeyboardExtension/Resources/quick-table.txt"))
        return Set(table.byCode.flatMap(\.characters))
    }

    func testHongKongCharactersAreTypableAndComeAfterBig5() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        let big5 = try big5()
        let cases = [("quick5", "ru", "嘅"), ("quick5", "rm", "咗"), ("quick5", "ri", "啲"), ("quick5", "rn", "嘢"),
                     ("quick5", "rf", "喺"), ("cangjie5", "rhpu", "嘅"), ("cangjie5", "rkm", "咗"),
                     ("cangjie5", "rhai", "啲"), ("cangjie5", "rwgn", "嘢"), ("cangjie5", "rohf", "喺")]
        for (schema, code, character) in cases {
            let session = try runtime.makeSession(schema: schema)
            for key in code { _ = session.processKey(Int32(key.asciiValue!)) }
            let got = session.state.candidates
            XCTAssertTrue(got.contains(character), "\(schema) \(code)")
            XCTAssertEqual(got, got.filter { big5.contains($0) } + got.filter { !big5.contains($0) }, "\(schema) \(code)")
        }
    }
}
