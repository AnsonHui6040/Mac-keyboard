import Foundation
import Network
import XCTest
@testable import MacReceiver

/// A stand-in for the iPhone's `NWListener` on the loopback interface: it records what reaches it and answers every datagram with
/// a pointer-shaped reply on the same connection, the way the keyboard extension answers a probe.
@MainActor
private final class LoopbackPhone {
    static let reply = Data([0x03]) + Data(repeating: 0x42, count: 40)

    private let listener: NWListener
    private var peers: [NWConnection] = []
    private(set) var received: [Data] = []
    var onReceive: (@MainActor () -> Void)?

    init() throws {
        listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start(ready: XCTestExpectation) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for peer in peers { peer.cancel() }
    }

    /// The phone sends one more datagram to whoever probed it last.
    func sendAgain() { peers.last?.send(content: Self.reply, completion: .idempotent) }

    private func accept(_ connection: NWConnection) {
        peers.append(connection)
        connection.start(queue: .main)
        listen(on: connection)
    }

    private func listen(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return }
                if let data, !data.isEmpty {
                    self.received.append(data)
                    connection.send(content: Self.reply, completion: .idempotent)
                    self.onReceive?()
                }
                self.listen(on: connection)
            }
        }
    }
}

/// The real transport against a listener on this machine. Loopback needs no local network permission, so this runs anywhere.
@MainActor
final class NWWifiProbeTransportTests: XCTestCase {
    private func startedPhone() async throws -> LoopbackPhone {
        let phone = try LoopbackPhone()
        let ready = expectation(description: "listener ready")
        phone.start(ready: ready)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(phone.port, 0)
        return phone
    }

    func testAProbeReachesTheListenerAndTheAnswerComesBackAsFromTheTarget() async throws {
        let phone = try await startedPhone()
        defer { phone.stop() }
        let transport = NWWifiProbeTransport(log: { _ in })
        defer { transport.close() }
        let target = WifiTarget(address: "127.0.0.1", port: phone.port)
        let probe = Data(repeating: 0x05, count: 41)
        let atPhone = expectation(description: "probe at the phone")
        phone.onReceive = { atPhone.fulfill() }
        let answered = expectation(description: "answer at the Receiver")
        var answers: [(WifiTarget, Data)] = []
        transport.onDatagram = {
            answers.append(($0, $1))
            answered.fulfill()
        }

        transport.open([target])
        transport.send(probe)
        await fulfillment(of: [atPhone, answered], timeout: 5)

        XCTAssertEqual(phone.received, [probe])
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, target, "reported with the target it came from")
        XCTAssertEqual(answers.first?.1, LoopbackPhone.reply)
    }

    func testNothingIsReportedAfterTheTransportIsClosed() async throws {
        let phone = try await startedPhone()
        defer { phone.stop() }
        let transport = NWWifiProbeTransport(log: { _ in })
        let atPhone = expectation(description: "probe at the phone")
        phone.onReceive = { atPhone.fulfill() }
        let answered = expectation(description: "first answer")
        var answers = 0
        transport.onDatagram = { _, _ in
            answers += 1
            answered.fulfill()
        }
        transport.open([WifiTarget(address: "127.0.0.1", port: phone.port)])
        transport.send(Data(repeating: 0x05, count: 41))
        await fulfillment(of: [atPhone, answered], timeout: 5)

        transport.close()
        phone.sendAgain()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(answers, 1, "a closed transport reports nothing")
    }

    func testOpeningAgainMovesToTheNewTargetsAndLeavesTheOldOnesAlone() async throws {
        let first = try await startedPhone()
        let second = try await startedPhone()
        defer {
            first.stop()
            second.stop()
        }
        let transport = NWWifiProbeTransport(log: { _ in })
        defer { transport.close() }
        let atSecond = expectation(description: "probe at the second phone")
        second.onReceive = { atSecond.fulfill() }

        transport.open([WifiTarget(address: "127.0.0.1", port: first.port)])
        transport.open([WifiTarget(address: "127.0.0.1", port: second.port)])
        transport.send(Data(repeating: 0x05, count: 41))
        await fulfillment(of: [atSecond], timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(second.received.count, 1)
        XCTAssertTrue(first.received.isEmpty, "the replaced target gets nothing")
    }

    func testAnAddressThatIsNotIPv4IsSkippedAndNeverCrashes() {
        let transport = NWWifiProbeTransport(log: { _ in })
        transport.open([WifiTarget(address: "not an address", port: 9), WifiTarget(address: "::1", port: 9)])
        transport.send(Data(repeating: 0x05, count: 41))
        transport.close()
    }
}
