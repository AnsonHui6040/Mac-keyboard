import XCTest
@testable import MacReceiver

/// Pins the Mac receiver timing constants to docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md.
@MainActor
final class PointerReceiverFeelBaselineTests: XCTestCase {
    func testFeelBaselineWatchdogInterval() {
        XCTAssertEqual(PointerReceiver.watchdogInterval, 0.05)
    }

    func testFeelBaselineFrameStall() {
        XCTAssertEqual(PointerReceiver.frameStallMicros, 200_000)
    }
}
