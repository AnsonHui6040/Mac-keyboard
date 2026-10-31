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

final class KeyFeedbackLevelTests: XCTestCase {
    func testDefaultsWhenNotSet() {
        let s = KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: true)
        XCTAssertEqual(s.soundVolume, 1.4, accuracy: 1e-9)
        XCTAssertEqual(s.hapticIntensity, 0.7, accuracy: 1e-9)
    }

    func testStoredValuesInRangeAreKept() {
        let s = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: 0.5, storedIntensity: 0.25, hasFullAccess: true)
        XCTAssertEqual(s.soundVolume, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.hapticIntensity, 0.25, accuracy: 1e-9)
    }

    func testZeroIsKeptAndIsNotTheDefault() {
        let s = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: 0.0, storedIntensity: 0.0, hasFullAccess: true)
        XCTAssertEqual(s.soundVolume, 0.0)
        XCTAssertEqual(s.hapticIntensity, 0.0)
    }

    func testOutOfRangeIsClamped() {
        let high = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: 3.0, storedIntensity: 5.0, hasFullAccess: true)
        XCTAssertEqual(high.soundVolume, 2.0)
        XCTAssertEqual(high.hapticIntensity, 1.0)
        let low = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: -1.0, storedIntensity: -0.5, hasFullAccess: true)
        XCTAssertEqual(low.soundVolume, 0.0)
        XCTAssertEqual(low.hapticIntensity, 0.0)
    }

    func testNonNumbersNaNAndInfinityUseTheDefault() {
        for bad: Any in ["loud", Double.nan, Double.infinity, -Double.infinity, [1.0], Date()] {
            let s = KeyFeedbackSettings(
                storedSound: nil, storedHaptics: nil, storedVolume: bad, storedIntensity: bad, hasFullAccess: true)
            XCTAssertEqual(s.soundVolume, 1.4, accuracy: 1e-9, "\(bad)")
            XCTAssertEqual(s.hapticIntensity, 0.7, accuracy: 1e-9, "\(bad)")
        }
    }

    func testIntegerNumbersAreAccepted() {
        let s = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: 1 as Int, storedIntensity: 1 as Int, hasFullAccess: true)
        XCTAssertEqual(s.soundVolume, 1.0)
        XCTAssertEqual(s.hapticIntensity, 1.0)
    }

    func testBoolIsNotALevel() {
        let s = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: true, storedIntensity: false, hasFullAccess: true)
        XCTAssertEqual(s.soundVolume, 1.4, accuracy: 1e-9)
        XCTAssertEqual(s.hapticIntensity, 0.7, accuracy: 1e-9)
    }

    func testCustomSoundNeedsSwitchAndFullAccess() {
        XCTAssertTrue(KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: true).customSound)
        XCTAssertFalse(KeyFeedbackSettings(storedSound: nil, storedHaptics: nil, hasFullAccess: false).customSound)
        XCTAssertFalse(KeyFeedbackSettings(storedSound: false, storedHaptics: nil, hasFullAccess: true).customSound)
    }

    func testOutputMapping() {
        let zero = KeyFeedbackSettings.output(forVolume: 0)
        XCTAssertEqual(zero.nodeVolume, 0); XCTAssertEqual(zero.gainDB, 0)
        let half = KeyFeedbackSettings.output(forVolume: 0.5)
        XCTAssertEqual(half.nodeVolume, 0.5, accuracy: 1e-6); XCTAssertEqual(half.gainDB, 0)
        let unity = KeyFeedbackSettings.output(forVolume: 1.0)
        XCTAssertEqual(unity.nodeVolume, 1); XCTAssertEqual(unity.gainDB, 0)
        let def = KeyFeedbackSettings.output(forVolume: 1.4)
        XCTAssertEqual(def.nodeVolume, 1); XCTAssertEqual(def.gainDB, 2.9226, accuracy: 1e-3)
        let max = KeyFeedbackSettings.output(forVolume: 2.0)
        XCTAssertEqual(max.nodeVolume, 1); XCTAssertEqual(max.gainDB, 6.0206, accuracy: 1e-3)
    }

    func testOutputClampsOutOfRange() {
        XCTAssertEqual(KeyFeedbackSettings.output(forVolume: 9).gainDB, 6.0206, accuracy: 1e-3)
        XCTAssertEqual(KeyFeedbackSettings.output(forVolume: -1).nodeVolume, 0)
        XCTAssertEqual(KeyFeedbackSettings.output(forVolume: .nan).nodeVolume, 0)
    }

    func testSettingsOutputUsesItsVolume() {
        let s = KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil, storedVolume: 2.0, storedIntensity: nil, hasFullAccess: true)
        XCTAssertEqual(s.soundOutput.gainDB, 6.0206, accuracy: 1e-3)
    }
}
