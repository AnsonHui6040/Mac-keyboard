import XCTest
@testable import RemoteKeyboardCore

final class TrackpadPageTests: XCTestCase {
    private func status(grant: UInt32?) -> ReceiverStatus {
        ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1, pointerGrant: grant)
    }

    func testOfflineWheneverTheLinkIsNotConnected() {
        for phase in [PointerChannelPhase.closed, .opening, .open, .denied] {
            XCTAssertEqual(
                TrackpadPage.availability(linkConnected: false, status: status(grant: 1), channel: phase), .offline, "\(phase)")
        }
        XCTAssertEqual(TrackpadPage.message(for: .offline), "尚未連線 Mac")
    }

    func testReadyOnlyWhileTheChannelIsOpen() {
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: 1), channel: .open), .ready)
        XCTAssertNil(TrackpadPage.message(for: .ready))
    }

    func testOpeningAndAnAboutToOpenChannelShowConnecting() {
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: 1), channel: .opening), .connecting)
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: 1), channel: .closed), .connecting)
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: nil, channel: .closed), .connecting, "no status yet")
        XCTAssertEqual(TrackpadPage.message(for: .connecting), "正在連接觸控板…")
    }

    func testAMacWithoutAGrantOrThatRefusedShowsDenied() {
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: nil), channel: .closed), .denied)
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: 4), channel: .denied), .denied)
        XCTAssertEqual(TrackpadPage.message(for: .denied), "Mac 未允許觸控板控制")
    }

    func testTwoUnansweredOpensShowTheRetryHint() {
        XCTAssertEqual(TrackpadPage.availability(linkConnected: true, status: status(grant: 1), channel: .timedOut), .failed)
        XCTAssertEqual(TrackpadPage.message(for: .failed), "無法連接觸控板，請按鍵盤再按觸控板重試")
        XCTAssertEqual(TrackpadPage.availability(linkConnected: false, status: status(grant: 1), channel: .timedOut), .offline)
    }
}
