import XCTest
@testable import RemoteKeyboardCore

final class KeyFeedbackSettingsTests: XCTestCase {
    func testNotSetMeansBothOn() {
        let s = KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: true)
        XCTAssertTrue(s.sound); XCTAssertTrue(s.haptics)
    }

    func testExplicitOffTurnsEachOffOnItsOwn() {
        let soundOff = KeyFeedbackSettings(storedSound: false, storedHaptics: true, hasFullAccess: true)
        XCTAssertFalse(soundOff.sound); XCTAssertTrue(soundOff.haptics)
        let hapticsOff = KeyFeedbackSettings(storedSound: true, storedHaptics: false, hasFullAccess: true)
        XCTAssertTrue(hapticsOff.sound); XCTAssertFalse(hapticsOff.haptics)
        let bothOff = KeyFeedbackSettings(storedSound: false, storedHaptics: false, hasFullAccess: true)
        XCTAssertFalse(bothOff.sound); XCTAssertFalse(bothOff.haptics)
    }

    func testHapticsNeedFullAccess() {
        let s = KeyFeedbackSettings(storedSound: nil, storedHaptics: true, hasFullAccess: false)
        XCTAssertFalse(s.haptics)
        XCTAssertFalse(KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: false).haptics)
    }

    func testSoundIgnoresFullAccess() {
        XCTAssertTrue(KeyFeedbackSettings(storedSound: true, storedHaptics: nil, hasFullAccess: false).sound)
        XCTAssertTrue(KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: false).sound)
        XCTAssertFalse(KeyFeedbackSettings(storedSound: false, storedHaptics: nil, hasFullAccess: false).sound)
    }

    func testNonBoolValuesAreTheDefault() {
        let s = KeyFeedbackSettings(storedSound: "no", storedHaptics: "off", hasFullAccess: true)
        XCTAssertTrue(s.sound); XCTAssertTrue(s.haptics)
    }
}
