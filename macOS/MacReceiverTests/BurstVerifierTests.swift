#if DEBUG
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

private struct FakeReader: BurstTextReading {
    let result: BurstTextReadResult
    func read() -> BurstTextReadResult { result }
}

@MainActor
final class BurstVerifierTests: XCTestCase {
    func testCleanDocumentShowsOnlyZeros() {
        let text = (1...20).map(BurstFormat.line).joined()
        XCTAssertEqual(
            BurstVerifier.message(for: .text(text), expected: 20), "預期 20 行，遺漏 0，重複 0，亂序 0")
    }

    func testDamagedDocumentShowsCountsNotText() {
        let text = [1, 3, 2, 3, 5].map(BurstFormat.line).joined() + "secret words\n"
        let message = BurstVerifier.message(for: .text(text), expected: 5)
        XCTAssertEqual(message, "預期 5 行，遺漏 1，重複 1，亂序 1")
        XCTAssertFalse(message.contains("secret"))
    }

    func testUnreadableResultsHaveOwnMessages() {
        XCTAssertEqual(BurstVerifier.message(for: .notTrusted, expected: 5), "Mac 未授權輔助使用")
        XCTAssertEqual(BurstVerifier.message(for: .noTextEdit, expected: 5), "找不到 TextEdit")
        XCTAssertEqual(BurstVerifier.message(for: .noDocument, expected: 5), "TextEdit 沒有可讀的文件")
    }

    func testVerifyPublishesMessageFromReader() async {
        let verifier = BurstVerifier(
            reader: FakeReader(result: .text(BurstFormat.line(1) + BurstFormat.line(2))), expected: 2)
        XCTAssertEqual(verifier.status, "尚未驗證")
        verifier.verify()
        for _ in 0..<100 where verifier.isRunning || verifier.status == "尚未驗證" || verifier.status == "驗證中…" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(verifier.status, "預期 2 行，遺漏 0，重複 0，亂序 0")
        XCTAssertFalse(verifier.isRunning)
    }
}
#endif
