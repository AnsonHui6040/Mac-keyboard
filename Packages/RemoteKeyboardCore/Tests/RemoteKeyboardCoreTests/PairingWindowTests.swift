import XCTest
@testable import RemoteKeyboardCore

final class PairingWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testClosedUntilOpened() {
        let window = PairingWindow()
        XCTAssertFalse(window.isOpen(at: t0))
        XCTAssertNil(window.remaining(at: t0))
    }

    func testOpensForOneHundredTwentySeconds() {
        var window = PairingWindow()
        window.open(now: t0)
        XCTAssertEqual(PairingWindow.duration, 120)
        XCTAssertTrue(window.isOpen(at: t0))
        XCTAssertTrue(window.isOpen(at: t0.addingTimeInterval(119.9)))
        XCTAssertFalse(window.isOpen(at: t0.addingTimeInterval(120)), "the deadline itself is already closed")
        XCTAssertFalse(window.isOpen(at: t0.addingTimeInterval(500)))
        XCTAssertEqual(window.remaining(at: t0.addingTimeInterval(20)), 100)
        XCTAssertEqual(window.remaining(at: t0.addingTimeInterval(500)), 0)
    }

    func testCloseEndsTheWindowAtOnce() {
        var window = PairingWindow()
        window.open(now: t0)
        window.close()
        XCTAssertFalse(window.isOpen(at: t0))
        XCTAssertNil(window.deadline)
    }

    func testOpeningAgainRestartsTheFullDuration() {
        var window = PairingWindow()
        window.open(now: t0)
        window.open(now: t0.addingTimeInterval(100))
        XCTAssertTrue(window.isOpen(at: t0.addingTimeInterval(200)))
        XCTAssertFalse(window.isOpen(at: t0.addingTimeInterval(220)))
    }

    func testAClockThatMovedBackwardsDoesNotKeepTheWindowOpenForever() {
        var window = PairingWindow()
        window.open(now: t0)
        // More than one full duration before the opening time cannot be a valid reading of an open window.
        XCTAssertFalse(window.isOpen(at: t0.addingTimeInterval(-1000)))
    }
}
