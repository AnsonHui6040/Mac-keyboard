import XCTest
@testable import RemoteKeyboardCore

final class AppAboutTests: XCTestCase {
    func testLinksPointAtTheRepository() {
        XCTAssertEqual(AppAbout.githubURL, "https://github.com/AnsonHui6040/Mac-keyboard")
        XCTAssertEqual(AppAbout.manualURL, "https://github.com/AnsonHui6040/Mac-keyboard/blob/main/docs/manual/README.md")
        XCTAssertNotNil(URL(string: AppAbout.githubURL))
        XCTAssertNotNil(URL(string: AppAbout.manualURL))
    }

    func testCopyrightNamesTheAuthorAndReservesRights() {
        XCTAssertEqual(AppAbout.copyright, "© 2026 AnsonHui6040。保留所有權利。")
        XCTAssertTrue(AppAbout.rights.hasPrefix("© 2026 AnsonHui6040"))
    }

    func testTextsAreTaiwanTraditionalAndNotEmpty() {
        for text in [AppAbout.disclaimer, AppAbout.rights, AppAbout.thirdParty] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(" · "))
        }
        XCTAssertTrue(AppAbout.disclaimer.contains("依現狀提供"))
        XCTAssertTrue(AppAbout.thirdParty.contains("沒有關聯"))
    }
}
