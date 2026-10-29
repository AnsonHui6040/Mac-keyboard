import XCTest
@testable import RemoteKeyboardCore

final class BuildStampTests: XCTestCase {
    func testFormatsFixedDateInFixedTimeZone() {
        // 2026-10-29T18:45:30Z is 10/30 02:45 in Taipei (UTC+8).
        let date = Date(timeIntervalSince1970: 1_793_299_530)
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        XCTAssertEqual(BuildStamp.text(for: date, timeZone: taipei), "10/30 02:45")
    }

    func testNilDateIsUnknown() {
        XCTAssertEqual(BuildStamp.text(for: nil), "未知")
    }
}
