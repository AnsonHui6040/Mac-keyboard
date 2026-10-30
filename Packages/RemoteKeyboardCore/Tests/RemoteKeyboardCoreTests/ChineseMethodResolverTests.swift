import XCTest
@testable import RemoteKeyboardCore

final class ChineseMethodResolverTests: XCTestCase {
    func testResolverHandwritingNeedsFullAccess() {
        XCTAssertEqual(
            ChineseMethodResolver.effective(
                saved: .handwriting, hasFullAccess: false, handwritingNeedsFullAccess: true, installed: [.handwriting, .quick]),
            .quick)
        XCTAssertNil(
            ChineseMethodResolver.effective(
                saved: .handwriting, hasFullAccess: false, handwritingNeedsFullAccess: true, installed: [.handwriting]))
    }

    func testResolverAppleHandwritingWorksWithoutFullAccess() {
        XCTAssertEqual(
            ChineseMethodResolver.effective(
                saved: .handwriting, hasFullAccess: false, handwritingNeedsFullAccess: false, installed: [.handwriting]),
            .handwriting)
    }

    func testResolverMissingSettingUsesHandwritingWhenAllowed() {
        XCTAssertEqual(
            ChineseMethodResolver.effective(
                saved: nil, hasFullAccess: true, handwritingNeedsFullAccess: true, installed: [.handwriting]),
            .handwriting)
        XCTAssertNil(
            ChineseMethodResolver.effective(
                saved: nil, hasFullAccess: false, handwritingNeedsFullAccess: true, installed: [.handwriting]))
    }

    func testResolverSavedQuickIsUsedOnlyWhenInstalled() {
        XCTAssertEqual(
            ChineseMethodResolver.effective(
                saved: .quick, hasFullAccess: true, handwritingNeedsFullAccess: true, installed: [.handwriting, .quick]),
            .quick)
        // Quick is not installed yet (T12): the saved choice falls back to handwriting.
        XCTAssertEqual(
            ChineseMethodResolver.effective(
                saved: .quick, hasFullAccess: true, handwritingNeedsFullAccess: true, installed: [.handwriting]),
            .handwriting)
    }

    func testResolverNothingInstalledIsNil() {
        XCTAssertNil(
            ChineseMethodResolver.effective(
                saved: .handwriting, hasFullAccess: true, handwritingNeedsFullAccess: true, installed: []))
    }

    func testStoredRawValueDecoding() {
        XCTAssertEqual(ChineseInputMethodID.stored(rawValue: "handwriting"), .handwriting)
        XCTAssertEqual(ChineseInputMethodID.stored(rawValue: "quick"), .quick)
        XCTAssertNil(ChineseInputMethodID.stored(rawValue: "cangjie"))
        XCTAssertNil(ChineseInputMethodID.stored(rawValue: nil))
    }

    func testAppGroupKeyName() {
        XCTAssertEqual(AppGroup.Key.chineseMethod, "rk.chineseMethod")
    }
}
