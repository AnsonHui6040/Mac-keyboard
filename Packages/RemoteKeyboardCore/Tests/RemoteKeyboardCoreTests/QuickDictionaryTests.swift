import XCTest
@testable import RemoteKeyboardCore

final class QuickDictionaryTests: XCTestCase {
    func testCodeABListsMingFirstFromFixture() throws {
        let dictionary = try QuickDictionary(tableText: "ab\t明\nab\t盟\nyl\t速\n")
        XCTAssertEqual(dictionary.candidates(for: "ab"), ["明", "盟"])
        XCTAssertEqual(dictionary.candidates(for: "yl"), ["速"])
    }

    func testUnknownCodeHasNoCandidates() throws {
        let dictionary = try QuickDictionary(tableText: "ab\t明\n")
        XCTAssertEqual(dictionary.candidates(for: "zz"), [])
        XCTAssertEqual(dictionary.candidates(for: ""), [])
    }

    func testSameCodeKeepsFileOrder() throws {
        let dictionary = try QuickDictionary(tableText: "ab\t丙\nab\t乙\nab\t甲\n")
        XCTAssertEqual(dictionary.candidates(for: "ab"), ["丙", "乙", "甲"])
    }

    func testBlankLinesAndTrailingNewlinesAreIgnored() throws {
        let dictionary = try QuickDictionary(tableText: "\nab\t明\n\n")
        XCTAssertEqual(dictionary.candidates(for: "ab"), ["明"])
    }

    func testMalformedTableLineThrows() {
        XCTAssertThrowsError(try QuickDictionary(tableText: "ab明\n"))
        XCTAssertThrowsError(try QuickDictionary(tableText: "ab\t\n"))
        XCTAssertThrowsError(try QuickDictionary(tableText: "\t明\n"))
        XCTAssertThrowsError(try QuickDictionary(tableText: "abc\t明\n"))
        XCTAssertThrowsError(try QuickDictionary(tableText: "A1\t明\n"))
        XCTAssertThrowsError(try QuickDictionary(tableText: "ab\t明\textra\n"))
    }

    func testGeneratorTakesFirstAndLastCode() {
        XCTAssertEqual(QuickDictionary.quickCode(fromCangjie: "amr"), "ar")
        XCTAssertEqual(QuickDictionary.quickCode(fromCangjie: "a"), "a")
        XCTAssertEqual(QuickDictionary.quickCode(fromCangjie: "ab"), "ab")
        XCTAssertEqual(QuickDictionary.quickCode(fromCangjie: "hapi"), "hi")
        XCTAssertNil(QuickDictionary.quickCode(fromCangjie: ""))
        XCTAssertNil(QuickDictionary.quickCode(fromCangjie: "NA"))
        XCTAssertNil(QuickDictionary.quickCode(fromCangjie: "a1"))
    }

    // MARK: Bundled table

    private static var bundledTableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/RemoteKeyboardExtension/Resources/quick-table.txt")
    }

    func testBundledTableLoadsUnder200ms() throws {
        let text = try String(contentsOf: Self.bundledTableURL, encoding: .utf8)
        let lines = text.split(separator: "\n").count
        let start = ContinuousClock.now
        let dictionary = try QuickDictionary(tableText: text)
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("quick-table lines=\(lines) parse=\(String(format: "%.1f", milliseconds)) ms")
        XCTAssertGreaterThan(lines, 10_000)
        XCTAssertLessThan(milliseconds, 200)
        XCTAssertEqual(dictionary.candidates(for: "ab").first, "明")
    }

    func testBundledTableSampleOfCommonCharacters() throws {
        let dictionary = try QuickDictionary(tableText: String(contentsOf: Self.bundledTableURL, encoding: .utf8))
        let samples: [(String, String)] = [
            ("明", "ab"), ("速", "yl"), ("成", "is"), ("你", "of"), ("我", "hi"),
            ("他", "od"), ("的", "hi"), ("是", "ao"), ("中", "l"), ("國", "wm")
        ]
        for (character, code) in samples {
            XCTAssertTrue(dictionary.candidates(for: code).contains(character), "\(character) missing under \(code)")
        }
    }
}
