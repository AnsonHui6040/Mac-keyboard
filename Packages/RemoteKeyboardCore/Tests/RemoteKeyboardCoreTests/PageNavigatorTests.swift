import XCTest
@testable import RemoteKeyboardCore

final class PageNavigatorTests: XCTestCase {
    func testEmailFieldOpensEnglish() {
        XCTAssertEqual(PageNavigator(lastPage: .chinese, field: .emailOrURL, chineseAvailable: true).page, .english)
    }

    func testNumberFieldOpensSymbols() {
        XCTAssertEqual(
            PageNavigator(lastPage: .english, field: .number, chineseAvailable: true).page, .symbols(origin: .english))
        XCTAssertEqual(
            PageNavigator(lastPage: nil, field: .number, chineseAvailable: false).page, .symbols(origin: .english))
    }

    func testNumberFieldOriginIsThePageTheTextRuleWouldOpen() {
        XCTAssertEqual(
            PageNavigator(lastPage: .chinese, field: .number, chineseAvailable: true).page, .symbols(origin: .chinese))
    }

    func testTextFieldOpensTheLastPage() {
        XCTAssertEqual(PageNavigator(lastPage: .english, field: .text, chineseAvailable: true).page, .english)
        XCTAssertEqual(PageNavigator(lastPage: .chinese, field: .text, chineseAvailable: true).page, .chinese)
    }

    func testNoLastPageOpensChineseWhenAvailableElseEnglish() {
        XCTAssertEqual(PageNavigator(lastPage: nil, field: .text, chineseAvailable: true).page, .chinese)
        XCTAssertEqual(PageNavigator(lastPage: nil, field: .text, chineseAvailable: false).page, .english)
    }

    func testChineseSavedWhileUnavailableOpensEnglish() {
        XCTAssertEqual(PageNavigator(lastPage: .chinese, field: .text, chineseAvailable: false).page, .english)
    }

    func testSymbolsKeyReturnsToOriginPage() {
        var nav = PageNavigator(lastPage: .chinese, field: .text, chineseAvailable: true)
        nav.switchSymbols()
        XCTAssertEqual(nav.page, .symbols(origin: .chinese))
        nav.switchSymbols()
        XCTAssertEqual(nav.page, .chinese)

        nav = PageNavigator(lastPage: .english, field: .text, chineseAvailable: true)
        nav.switchSymbols()
        XCTAssertEqual(nav.page, .symbols(origin: .english))
        nav.switchSymbols()
        XCTAssertEqual(nav.page, .english)
    }

    func testChineseEnglishDisabledWithoutChinese() {
        var nav = PageNavigator(lastPage: .english, field: .text, chineseAvailable: false)
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .english)
    }

    func testChineseEnglishSwitchesBothWaysWhenAvailable() {
        var nav = PageNavigator(lastPage: .english, field: .text, chineseAvailable: true)
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .chinese)
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .english)
    }

    func testChineseEnglishOnSymbolsGoesToTheOtherLetterPage() {
        var nav = PageNavigator(lastPage: .english, field: .text, chineseAvailable: true)
        nav.switchSymbols()
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .chinese)

        nav = PageNavigator(lastPage: .chinese, field: .text, chineseAvailable: true)
        nav.switchSymbols()
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .english)
    }

    func testChineseEnglishOnSymbolsWithoutChineseChangesNothing() {
        var nav = PageNavigator(lastPage: nil, field: .number, chineseAvailable: false)
        nav.switchChineseEnglish()
        XCTAssertEqual(nav.page, .symbols(origin: .english))
    }

    func testPersistablePageMapsSymbolsToItsOrigin() {
        var nav = PageNavigator(lastPage: .chinese, field: .text, chineseAvailable: true)
        XCTAssertEqual(nav.persistablePage, .chinese)
        nav.switchSymbols()
        XCTAssertEqual(nav.persistablePage, .chinese)
        nav = PageNavigator(lastPage: nil, field: .number, chineseAvailable: false)
        XCTAssertEqual(nav.persistablePage, .english)
    }

    func testStoredValueRoundTripsOnlyLetterPages() {
        XCTAssertEqual(KeyboardPage.stored(rawValue: KeyboardPage.chinese.storageValue), .chinese)
        XCTAssertEqual(KeyboardPage.stored(rawValue: KeyboardPage.english.storageValue), .english)
        XCTAssertEqual(KeyboardPage.symbols(origin: .chinese).storageValue, "chinese")
        XCTAssertEqual(KeyboardPage.symbols(origin: .english).storageValue, "english")
        XCTAssertNil(KeyboardPage.stored(rawValue: nil))
        XCTAssertNil(KeyboardPage.stored(rawValue: "symbols"))
    }

    func testTransmitModeRawValuesAreStable() {
        XCTAssertEqual(TransmitMode.instant.rawValue, "instant")
        XCTAssertEqual(TransmitMode.draft.rawValue, "draft")
        XCTAssertEqual(TransmitMode.stored(rawValue: "draft"), .draft)
        XCTAssertEqual(TransmitMode.stored(rawValue: nil), .instant)
        XCTAssertEqual(TransmitMode.stored(rawValue: "zzz"), .instant)
    }
}
