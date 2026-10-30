import XCTest
@testable import RemoteKeyboardCore

final class BurstFormatTests: XCTestCase {
    private func text(_ numbers: [Int]) -> String { numbers.map(BurstFormat.line).joined() }

    func testLineFormat() {
        XCTAssertEqual(BurstFormat.line(1), "#1\n")
        XCTAssertEqual(BurstFormat.line(10_000), "#10000\n")
    }

    func testCleanRunReportsNothing() {
        let report = BurstFormat.verify(text(Array(1...10_000)), expected: 10_000)
        XCTAssertEqual(report, BurstReport(missing: [], duplicated: [], outOfOrder: []))
        XCTAssertTrue(report.isClean)
    }

    func testVerifyFindsMissingDuplicateAndOrder() {
        // 4 never arrives, 7 arrives twice, 2 arrives after 3.
        let report = BurstFormat.verify(text([1, 3, 2, 5, 6, 7, 7, 8, 9, 10]), expected: 10)
        XCTAssertEqual(report.missing, [4])
        XCTAssertEqual(report.duplicated, [7])
        XCTAssertEqual(report.outOfOrder, [2])
        XCTAssertFalse(report.isClean)
    }

    func testMissingTailIsReported() {
        let report = BurstFormat.verify(text([1, 2, 3]), expected: 5)
        XCTAssertEqual(report.missing, [4, 5])
        XCTAssertTrue(report.duplicated.isEmpty)
        XCTAssertTrue(report.outOfOrder.isEmpty)
    }

    func testEmptyTextMissesEverything() {
        XCTAssertEqual(BurstFormat.verify("", expected: 3).missing, [1, 2, 3])
    }

    func testDuplicateIsNotAlsoOutOfOrder() {
        let report = BurstFormat.verify(text([1, 2, 3, 2, 4]), expected: 4)
        XCTAssertEqual(report.duplicated, [2])
        XCTAssertTrue(report.outOfOrder.isEmpty)
        XCTAssertTrue(report.missing.isEmpty)
    }

    func testLinesThatAreNotBurstLinesAreIgnored() {
        let report = BurstFormat.verify("hello\n" + text([1, 2]) + "\n#x\n#3 \n\r\n" + BurstFormat.line(3), expected: 3)
        XCTAssertTrue(report.isClean)
    }

    func testCarriageReturnLineEndingsAreAccepted() {
        XCTAssertTrue(BurstFormat.verify("#1\r\n#2\r\n", expected: 2).isClean)
    }

    func testNumbersOutsideTheExpectedRangeAreIgnored() {
        XCTAssertTrue(BurstFormat.verify(text([1, 2, 99]), expected: 2).isClean)
    }
}
