import XCTest
@testable import RemoteKeyboardCore

/// Pins the trackpad feel constants to docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md.
/// Changing any value needs the spec, this test and new device evidence to change together.
final class TrackpadFeelBaselineTests: XCTestCase {
    func testFeelBaselineGestureThresholds() {
        XCTAssertEqual(TrackpadGesture.tapMaxMicros, 200_000)
        XCTAssertEqual(TrackpadGesture.travelThreshold, 8.0)
        XCTAssertEqual(TrackpadGesture.longPressMicros, 400_000)
        XCTAssertEqual(TrackpadGesture.doubleTapMaxMicros, 500_000)
        XCTAssertEqual(TrackpadGesture.doubleTapMaxDistance, 12.0)
        XCTAssertEqual(TrackpadGesture.twoFingerTapMaxMicros, 300_000)
        XCTAssertEqual(TrackpadGesture.twoFingerTapMaxTravel, 12.0)
    }

    func testFeelBaselineSensitivity() {
        XCTAssertEqual(TrackpadSensitivity.defaultValue, 1.0)
        XCTAssertEqual(TrackpadSensitivity.minimum, 0.2)
        XCTAssertEqual(TrackpadSensitivity.maximum, 3.0)
        XCTAssertEqual(TrackpadSensitivity.step, 0.1)
    }

    func testFeelBaselineSendRate() {
        XCTAssertEqual(TrackpadSendRate.automatic, 0)
        XCTAssertEqual(TrackpadSendRate.defaultValue, 0)
        XCTAssertEqual(TrackpadSendRate.minimum, 20)
        XCTAssertEqual(TrackpadSendRate.maximum, 120)
        XCTAssertEqual(TrackpadSendRate.step, 10)
    }

    func testFeelBaselinePointerSender() {
        XCTAssertEqual(PointerSender.moveIntervalMicros, 16_667)
        XCTAssertEqual(PointerSender.heartbeatIntervalMicros, 100_000)
        XCTAssertEqual(PointerSender.maxSplit, 8)
    }

    func testFeelBaselineWifiAssistDefault() {
        XCTAssertTrue(WifiPointerSetting.defaultValue)
    }

    func testFeelBaselineAcceleration() {
        XCTAssertEqual(PointerAcceleration.baseGain, 1.25)
        XCTAssertEqual(PointerAcceleration.maxGain, 3.5)
        XCTAssertEqual(PointerAcceleration.kneeSpeed, 550.0)
        XCTAssertEqual(PointerAcceleration.minDtSeconds, 0.005)
        XCTAssertEqual(PointerAcceleration.maxDtSeconds, 0.150)
    }

    func testFeelBaselinePlayout() {
        XCTAssertEqual(PointerPlayout.maxLagMicros, 20_000)
        XCTAssertEqual(PointerPlayout.minSpanMicros, 4_000)
        XCTAssertEqual(PointerPlayout.maxSpanMicros, 50_000)
        XCTAssertEqual(PointerPlayout.defaultSpanMicros, 8_000)
        XCTAssertEqual(PointerPlayout.lagMarginMicros, 5_000)
        XCTAssertEqual(PointerPlayout.maxAdaptiveLagMicros, 60_000)
        XCTAssertEqual(PointerPlayout.burstGapMicros, 4_000)
        XCTAssertEqual(PointerPlayout.maxPeriodGapMicros, 100_000)
        XCTAssertEqual(PointerPlayout.forgetGapMicros, 300_000)
        XCTAssertEqual(PointerPlayout.periodHistory, 8)
        XCTAssertEqual(PointerPlayout.maxJitterMicros, 80_000)
        XCTAssertEqual(PointerPlayout.jitterDecayHalfLifeMicros, 5_000_000)
        XCTAssertEqual(PointerPlayout.jitterFloorMicros, 5_000)
        XCTAssertEqual(PointerPlayout.refillStretch, 1.25)
        XCTAssertEqual(PointerPlayout.pauseThresholdMicros, 20_000)
        XCTAssertEqual(PointerPlayout.pausesBeforeRelearning, 3)
        XCTAssertEqual(PointerPlayout.strokeGapMicros, 100_000)
    }

    func testFeelBaselineWatchdogs() {
        XCTAssertEqual(PointerEngine.buttonWatchdogMicros, 350_000)
        XCTAssertEqual(PointerEngine.scrollWatchdogMicros, 150_000)
    }
}
