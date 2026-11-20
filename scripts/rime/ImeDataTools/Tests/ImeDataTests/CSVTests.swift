import XCTest
@testable import ImeData

final class CSVTests: XCTestCase {
    func testQuotedNewlineAndComma() {
        XCTAssertEqual(CSV.rows("Source,x\n\"\n\",5\n\",\",3\n\"a\"\"b\",1\n"),
                       [["Source", "x"], ["\n", "5"], [",", "3"], ["a\"b", "1"]])
    }
    func testCRLFRowsAndQuotedCarriageReturn() {
        XCTAssertEqual(CSV.rows("a,b\r\n\"\r\",7\r\nc,d\r\n"), [["a", "b"], ["\r", "7"], ["c", "d"]])
    }
    func testFrequencySkipsSourceRow() {
        XCTAssertEqual(WordsHKFrequency.parse("Source,https://x\r\n嘅,900\r\n啱,50\r\n"), ["嘅": 900, "啱": 50])
    }
}
