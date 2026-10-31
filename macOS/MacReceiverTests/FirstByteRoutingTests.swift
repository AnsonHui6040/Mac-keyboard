import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// A notification is routed by its first byte: 0x02 frames to the reassembler, 0x03 to the pointer hook, 0x7E (Debug
/// builds only) to the measurement hook, anything else is skipped. Only 0x02 may touch the reassembler.
@MainActor
final class FirstByteRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var driver: RecordingDriver!

    override func setUp() async throws {
        let name = "rk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        driver = RecordingDriver()
    }

    private func readyCentral() -> ReceiverBLECentral {
        let central = ReceiverBLECentral(defaults: defaults, makeDriver: { [unowned self] _ in driver })
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        return central
    }

    func testNon02FrameDoesNotTouchReassembler() throws {
        let central = readyCentral()
        var messages: [Data] = []
        var pointer: [Data] = []
        central.eventHandler = { messages.append($0) }
        central.pointerHandler = { pointer.append($0) }
        let payload = Data((0..<400).map { UInt8(truncatingIfNeeded: $0) })
        let frames = try FrameCodec.split(payload, messageId: 9, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 3)
        let measure = Data([0x7E]) + Data(repeating: 1, count: 40)
        let counterPacket = Data([0x03]) + Data(repeating: 2, count: 40)
        central.receive(eventData: frames[0])
        central.receive(eventData: measure)
        central.receive(eventData: counterPacket)
        central.receive(eventData: Data([0x55, 1, 2, 3]))
        central.receive(eventData: Data())
        central.receive(eventData: frames[1])
        XCTAssertTrue(messages.isEmpty, "the message is still incomplete")
        central.receive(eventData: frames[2])
        XCTAssertEqual(messages, [payload], "the long message survived the packets between its frames")
        XCTAssertEqual(pointer, [counterPacket])
    }

    func testPointerPacketsReachOnlyThePointerHook() {
        let central = readyCentral()
        var messages: [Data] = []
        var pointer: [Data] = []
        central.eventHandler = { messages.append($0) }
        central.pointerHandler = { pointer.append($0) }
        let packet = Data([0x03]) + Data(repeating: 9, count: 40)
        central.receive(eventData: packet)
        XCTAssertEqual(pointer, [packet])
        XCTAssertTrue(messages.isEmpty)
    }

    func testPointerPacketWithoutAHookIsDropped() {
        let central = readyCentral()
        var messages: [Data] = []
        central.eventHandler = { messages.append($0) }
        central.receive(eventData: Data([0x03]) + Data(repeating: 9, count: 40))
        XCTAssertTrue(messages.isEmpty)
    }

    func testNothingIsRoutedUnlessTheLinkIsReady() {
        let central = ReceiverBLECentral(defaults: defaults, makeDriver: { [unowned self] _ in driver })
        var pointer = 0
        central.pointerHandler = { _ in pointer += 1 }
        central.receive(eventData: Data([0x03]) + Data(repeating: 9, count: 40))
        XCTAssertEqual(pointer, 0)
    }

    #if DEBUG
    func testMeasurePacketsReachOnlyTheMeasureHook() {
        let central = readyCentral()
        var messages: [Data] = []
        var measured: [Data] = []
        central.eventHandler = { messages.append($0) }
        central.measureHandler = { measured.append($0) }
        let packet = Data([0x7E]) + Data(repeating: 9, count: 40)
        central.receive(eventData: packet)
        XCTAssertEqual(measured, [packet])
        XCTAssertTrue(messages.isEmpty)
    }

    func testMeasureIgnoredWhenRoutingDisabled() {
        let central = readyCentral()
        var measured = 0
        central.measureHandler = { _ in measured += 1 }
        // What a Release build is: the same code with the measurement route off.
        central.measureEnabled = false
        central.receive(eventData: Data([0x7E]) + Data(repeating: 9, count: 40))
        XCTAssertEqual(measured, 0, "not decrypted, not answered")
        XCTAssertTrue(driver.controlWrites.isEmpty)
    }
    #endif
}
