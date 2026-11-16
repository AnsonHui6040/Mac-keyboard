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

/// A phone on a plain BSD socket, so a test controls exactly which datagrams come back, zero-length ones included. It answers each
/// datagram it receives with the lengths `script` gives for the nth one (1-based), to the source that sent it. Every access to its
/// state goes through a lock; the receive loop runs on its own thread.
private final class RawLoopbackPhone: @unchecked Sendable {
    static func reply(_ length: Int) -> Data { length == 0 ? Data() : Data([0x03]) + Data(repeating: 0x42, count: length - 1) }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var count = 0
    private var ports: Set<UInt16> = []
    private var stopped = false

    init(script: @escaping @Sendable (Int) -> [Int]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in loop(script) }
    }

    var received: Int { lock.withLock { count } }
    /// The distinct source ports the datagrams came from: one per connection of the Receiver that probed.
    var sourcePorts: Set<UInt16> { lock.withLock { ports } }

    func stop() { lock.withLock { stopped = true } }

    private func loop(_ script: @Sendable (Int) -> [Int]) {
        var buffer = [UInt8](repeating: 0, count: 70_000)
        while !lock.withLock({ stopped }) {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard n >= 0 else { continue }
            let source = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
            let nth = lock.withLock { () -> Int in
                count += 1
                ports.insert(source)
                return count
            }
            for length in script(nth) {
                let datagram = [UInt8](Self.reply(length))
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, datagram, datagram.count, 0, $0, fromLength) }
                }
            }
        }
        close(fd)
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

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private static let probe = Data(repeating: 0x05, count: 41)

    /// A zero-length datagram on a connected UDP connection ends its message stream: every receive after it fails with ENODATA while
    /// the connection still looks ready. Anybody who can spoof the phone's address could freeze the touchpad with one.
    func testAZeroLengthDatagramDoesNotLeaveTheReceivePathDeadForever() async throws {
        let phone = try RawLoopbackPhone { $0 == 1 ? [0, 41] : [41] }
        defer { phone.stop() }
        var lines: [String] = []
        let transport = NWWifiProbeTransport(log: { lines.append($0) }, rebuildInterval: 0.25)
        defer { transport.close() }
        let target = WifiTarget(address: "127.0.0.1", port: phone.port)
        var answers: [Data] = []
        transport.onDatagram = { source, data in
            XCTAssertEqual(source, target)
            answers.append(data)
        }
        transport.open([target])
        // The link sends a probe every 250 ms; so does this loop.
        let end = Date().addingTimeInterval(5)
        while phone.sourcePorts.count < 2 || answers.isEmpty, Date() < end {
            transport.send(Self.probe)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(phone.sourcePorts.count, 2, "the connection was rebuilt: the phone saw a second source port")
        XCTAssertFalse(answers.isEmpty, "an answer to a probe sent after the rebuild reaches the link")
        XCTAssertTrue(answers.allSatisfy { $0.count == 41 })
        XCTAssertTrue(lines.contains("wifi_path rebuild"), lines.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(transport.rebuilds, 1)
    }

    func testATargetWithADeadReceivePathGetsNoProbesUntilItIsRebuilt() async throws {
        let phone = try RawLoopbackPhone { $0 == 1 ? [0] : [] }
        defer { phone.stop() }
        let transport = NWWifiProbeTransport(log: { _ in }, rebuildInterval: 0.6)
        defer { transport.close() }
        transport.open([WifiTarget(address: "127.0.0.1", port: phone.port)])
        transport.send(Self.probe)
        let died = await waitUntil(3) { transport.liveConnectionCount == 0 }
        XCTAssertTrue(died, "the empty datagram marks the receive path dead")
        let seen = phone.received
        transport.send(Self.probe)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(phone.received, seen, "nothing is sent to a target whose receive path is dead")
        let rebuilt = await waitUntil(3) { transport.liveConnectionCount == 1 }
        XCTAssertTrue(rebuilt)
        transport.send(Self.probe)
        let reached = await waitUntil(3) { phone.received > seen }
        XCTAssertTrue(reached, "probes go out again on the new connection")
    }

    func testRebuildsAreRateLimitedPerTarget() async throws {
        // Every datagram is answered with an empty one: the path dies again and again.
        let phone = try RawLoopbackPhone { _ in [0] }
        defer { phone.stop() }
        let transport = NWWifiProbeTransport(log: { _ in }, rebuildInterval: 0.4)
        defer { transport.close() }
        transport.open([WifiTarget(address: "127.0.0.1", port: phone.port)])
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            transport.send(Self.probe)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(transport.rebuilds, 2, "it does recover each time")
        XCTAssertLessThanOrEqual(transport.rebuilds, 6, "at most one rebuild per 0.4 s in 2 s")
        XCTAssertLessThanOrEqual(phone.received, 8, "no flood of probes from the rebuilds")
    }

    func testTheSameTargetTwiceIsOneConnection() async throws {
        let phone = try RawLoopbackPhone { _ in [] }
        defer { phone.stop() }
        let transport = NWWifiProbeTransport(log: { _ in })
        defer { transport.close() }
        let target = WifiTarget(address: "127.0.0.1", port: phone.port)
        transport.open([target, target])
        XCTAssertEqual(transport.liveConnectionCount, 1)
        transport.send(Self.probe)
        let reached = await waitUntil(3) { phone.received >= 1 }
        XCTAssertTrue(reached)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(phone.received, 1, "one probe, one connection")
        XCTAssertEqual(phone.sourcePorts.count, 1)
    }

    func testAnAddressThatIsNotIPv4IsSkippedAndNeverCrashes() {
        let transport = NWWifiProbeTransport(log: { _ in })
        transport.open([WifiTarget(address: "not an address", port: 9), WifiTarget(address: "::1", port: 9)])
        transport.send(Data(repeating: 0x05, count: 41))
        transport.close()
    }
}
