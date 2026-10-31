import CoreGraphics
import XCTest
@testable import RemoteKeyboardCore

final class PointerAccelerationTests: XCTestCase {
    func testGainAtRestIsBaseGain() {
        XCTAssertEqual(PointerAcceleration.gain(speed: 0), 1.25, accuracy: 1e-12)
    }

    func testGainIsMonotonicallyIncreasingAndBounded() {
        var previous = PointerAcceleration.gain(speed: 0)
        for v in stride(from: 1.0, through: 5_000.0, by: 25.0) {
            let g = PointerAcceleration.gain(speed: v)
            XCTAssertGreaterThan(g, previous, "v=\(v)")
            XCTAssertLessThan(g, 3.5)
            previous = g
        }
    }

    func testGainAtTheKneeIsHalfWay() {
        // v = v0: 1.25 + 2.25 * 0.5
        XCTAssertEqual(PointerAcceleration.gain(speed: 550), 2.375, accuracy: 1e-9)
    }

    func testDtIsClampedToFiveToOneFiftyMilliseconds() {
        XCTAssertEqual(PointerAcceleration.seconds(fromTenthsOfMs: 0), 0.005, accuracy: 1e-12)
        XCTAssertEqual(PointerAcceleration.seconds(fromTenthsOfMs: 49), 0.005, accuracy: 1e-12)
        XCTAssertEqual(PointerAcceleration.seconds(fromTenthsOfMs: 167), 0.0167, accuracy: 1e-12)
        XCTAssertEqual(PointerAcceleration.seconds(fromTenthsOfMs: 60_000), 0.150, accuracy: 1e-12)
    }

    func testScaledDeltaUsesSpeedFromDisplacementAndDt() {
        // 16 pt in 16 ms is 1,000 pt/s.
        let scaled = PointerAcceleration.scaled(dxSixteenths: 256, dySixteenths: 0, dtTenthsOfMs: 160)
        let gain = PointerAcceleration.gain(speed: 1_000)
        XCTAssertEqual(scaled.dx, 16 * gain, accuracy: 1e-9)
        XCTAssertEqual(scaled.dy, 0, accuracy: 1e-12)
    }
}

final class PointerScreenClampTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    private let right = CGRect(x: 1_000, y: -200, width: 600, height: 1_000)

    func testPointInsideStaysWhereItIs() {
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: 10.5, y: 20.25), to: [main]), CGPoint(x: 10.5, y: 20.25))
    }

    func testPointOutsideIsPulledToTheNearestEdgeOfASingleScreen() {
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: -50, y: 400), to: [main]), CGPoint(x: 0, y: 400))
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: 400, y: 5_000), to: [main]), CGPoint(x: 400, y: 799))
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: 5_000, y: -9), to: [main]), CGPoint(x: 999, y: 0))
    }

    func testUnionOfScreensAllowsCrossingBetweenThem() {
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: 1_200, y: -100), to: [main, right]), CGPoint(x: 1_200, y: -100))
        // Above the main screen but still inside the union is allowed over the second screen only.
        let clamped = PointerScreenClamp.clamp(CGPoint(x: 500, y: -100), to: [main, right])
        XCTAssertEqual(clamped, CGPoint(x: 500, y: 0))
    }

    func testNoScreensLeavesThePointAlone() {
        XCTAssertEqual(PointerScreenClamp.clamp(CGPoint(x: -5, y: -5), to: []), CGPoint(x: -5, y: -5))
    }
}
