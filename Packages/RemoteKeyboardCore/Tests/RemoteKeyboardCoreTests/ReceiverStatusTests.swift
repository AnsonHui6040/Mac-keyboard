import XCTest
@testable import RemoteKeyboardCore

final class ReceiverStatusTests: XCTestCase {
    func testStatusWithoutMeasureEncodesSameBytesAsBefore() throws {
        let status = ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1)
        XCTAssertFalse(status.measure)
        let bytes = try ControlCodec.encode(.status(status))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"status":{"_0":{"appName":"Notes","focusEpoch":1,"ready":true}}}"#)
        let explicit = try ControlCodec.encode(.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1, measure: false)))
        XCTAssertEqual(bytes, explicit)
    }

    func testOldStatusBytesDecodeMeasureFalse() throws {
        let old = Data(#"{"status":{"_0":{"appName":"Notes","focusEpoch":1,"ready":true}}}"#.utf8)
        guard case .status(let status) = try ControlCodec.decode(old) else { return XCTFail("not a status") }
        XCTAssertFalse(status.measure)
        XCTAssertTrue(status.trusted)
    }

    func testMeasureTrueRoundTrips() throws {
        let status = ReceiverStatus(ready: false, appName: nil, focusEpoch: 2, trusted: false, measure: true)
        let bytes = try ControlCodec.encode(.status(status))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""measure":true"#))
        XCTAssertEqual(try ControlCodec.decode(bytes), .status(status))
    }
}
