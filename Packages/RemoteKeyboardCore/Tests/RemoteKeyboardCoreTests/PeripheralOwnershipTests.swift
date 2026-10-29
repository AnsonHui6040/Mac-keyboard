import XCTest
@testable import RemoteKeyboardCore

final class PeripheralOwnershipTests: XCTestCase {
    func testFirstClaimBecomesOwner() {
        var o = PeripheralOwnership<Int>()
        XCTAssertNil(o.owner)
        XCTAssertTrue(o.claim(1))
        XCTAssertTrue(o.isOwner(1))
    }

    func testClaimingAgainByTheOwnerChangesNothing() {
        var o = PeripheralOwnership<Int>()
        o.claim(1)
        XCTAssertFalse(o.claim(1))
    }

    func testLaterClaimantTakesOver() {
        var o = PeripheralOwnership<Int>()
        o.claim(1)
        XCTAssertTrue(o.claim(2))
        XCTAssertTrue(o.isOwner(2))
        XCTAssertFalse(o.isOwner(1))
    }

    func testStaleDisappearIsNotHonoredAndDoesNotDisturbTheNewOwner() {
        var o = PeripheralOwnership<Int>()
        o.claim(1)
        o.claim(2)
        XCTAssertFalse(o.release(1))
        XCTAssertEqual(o.owner, 2)
    }

    func testOwnerDisappearIsHonoredOnce() {
        var o = PeripheralOwnership<Int>()
        o.claim(1)
        XCTAssertTrue(o.release(1))
        XCTAssertNil(o.owner)
        XCTAssertFalse(o.release(1))
    }

    func testReleaseWithNoOwnerIsIgnored() {
        var o = PeripheralOwnership<Int>()
        XCTAssertFalse(o.release(7))
    }

    func testReclaimAfterReleaseIsAChange() {
        var o = PeripheralOwnership<Int>()
        o.claim(1); o.release(1)
        XCTAssertTrue(o.claim(1))
    }
}
