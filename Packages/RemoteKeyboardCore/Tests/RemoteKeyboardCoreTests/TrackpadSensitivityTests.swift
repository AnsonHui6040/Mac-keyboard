import XCTest
@testable import RemoteKeyboardCore

final class TrackpadSensitivityTests: XCTestCase {
    func test_defaultIsOne() {
        XCTAssertEqual(TrackpadSensitivity.defaultValue, 1.0)
        XCTAssertEqual(TrackpadSensitivity.clamped(1.0), 1.0)
    }

    func test_clampsToRange() {
        XCTAssertEqual(TrackpadSensitivity.clamped(0.0), 0.2)
        XCTAssertEqual(TrackpadSensitivity.clamped(-5), 0.2)
        XCTAssertEqual(TrackpadSensitivity.clamped(3.7), 3.0)
        XCTAssertEqual(TrackpadSensitivity.clamped(.infinity), 3.0)
        XCTAssertEqual(TrackpadSensitivity.clamped(-.infinity), 0.2)
    }

    func test_garbageFallsBackToDefault() {
        XCTAssertEqual(TrackpadSensitivity.clamped(.nan), 1.0)
        XCTAssertEqual(TrackpadSensitivity.clamped(nil), 1.0)
    }

    func test_clampedSnapsToTenthGrid() {
        XCTAssertEqual(TrackpadSensitivity.clamped(1.04), 1.0)
        XCTAssertEqual(TrackpadSensitivity.clamped(1.26), 1.3)
    }

    func test_stepsStayOnTheGrid() {
        var value = TrackpadSensitivity.defaultValue
        for _ in 0..<2 { value = TrackpadSensitivity.stepped(value, by: -1) }
        XCTAssertEqual(value, 0.8)
        value = 0.2
        for _ in 0..<1 { value = TrackpadSensitivity.stepped(value, by: 1) }
        value = TrackpadSensitivity.stepped(value, by: 1)
        XCTAssertEqual(value, 0.4)
        value = 0.1 + 0.2  // 0.30000000000000004 as stored input
        XCTAssertEqual(TrackpadSensitivity.stepped(value, by: 1), 0.4)
        // Walking all the way up never drifts off the grid.
        var walk = 0.2
        for _ in 0..<40 { walk = TrackpadSensitivity.stepped(walk, by: 1) }
        XCTAssertEqual(walk, 3.0)
        for tenths in 2...30 {
            XCTAssertEqual(TrackpadSensitivity.stepped(Double(tenths) / 10, by: 0), Double(tenths) / 10)
        }
    }

    func test_stepsStopAtTheEnds() {
        XCTAssertEqual(TrackpadSensitivity.stepped(0.2, by: -1), 0.2)
        XCTAssertEqual(TrackpadSensitivity.stepped(3.0, by: 1), 3.0)
    }

    func test_displayHasOneDecimal() {
        XCTAssertEqual(TrackpadSensitivity.displayText(1.0), "1.0")
        XCTAssertEqual(TrackpadSensitivity.displayText(0.30000000000000004), "0.3")
        XCTAssertEqual(TrackpadSensitivity.displayText(3.0), "3.0")
    }

    func test_scalingMultipliesBothAxes() {
        let scaled = TrackpadSensitivity.scaled(dx: 10, dy: -4, by: 1.5)
        XCTAssertEqual(scaled.dx, 15)
        XCTAssertEqual(scaled.dy, -6)
        let same = TrackpadSensitivity.scaled(dx: 3.5, dy: 2, by: 1.0)
        XCTAssertEqual(same.dx, 3.5)
        XCTAssertEqual(same.dy, 2)
    }
}
