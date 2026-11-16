import Foundation
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// A transport that records what the link asked for and lets a test play the phone's replies.
@MainActor
final class FakeWifiTransport: WifiProbeTransport {
    var onDatagram: (@MainActor (WifiTarget, Data) -> Void)?
    private(set) var opened: [[WifiTarget]] = []
    private(set) var sent: [Data] = []
    private(set) var closes = 0

    func open(_ targets: [WifiTarget]) { opened.append(targets) }
    func send(_ datagram: Data) { sent.append(datagram) }
    func close() { closes += 1 }

    /// The phone answers from `target`.
    func deliver(from target: WifiTarget, _ data: Data) { onDatagram?(target, data) }
}

/// Timers that fire only when a test says so.
@MainActor
final class ManualWifiTimers {
    final class Entry {
        let interval: TimeInterval
        let fire: @MainActor () -> Void
        var cancelled = false
        init(interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.fire = fire
        }
    }

    private(set) var entries: [Entry] = []
    var active: [Entry] { entries.filter { !$0.cancelled } }

    func make(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let entry = Entry(interval: interval, fire: fire)
        entries.append(entry)
        return { entry.cancelled = true }
    }

    /// One interval passes.
    func tick() {
        for entry in active { entry.fire() }
    }
}

enum WifiTestData {
    static let target = WifiTarget(address: "192.168.1.23", port: 50_123)
    static let second = WifiTarget(address: "10.0.0.5", port: 50_123)
    static let offer = WifiOffer(addrs: ["192.168.1.23", "10.0.0.5"], port: 50_123)!
    static let otherOffer = WifiOffer(addrs: ["172.16.0.9"], port: 4_000)!
}

/// The link on its own: a fake transport, manual timers and the channel sets of one real handshake.
@MainActor
final class WifiLinkRig {
    let pointerRig = PointerRig()
    let transport = FakeWifiTransport()
    let timers = ManualWifiTimers()
    private(set) var logLines: [String] = []
    private(set) var packets: [Data] = []
    var channelOpen = true
    private(set) var link: WifiProbeLink!

    init() {
        link = WifiProbeLink(transport: transport, makeTimer: { [timers] in timers.make($0, $1) }, log: { [unowned self] in logLines.append($0) })
        link.onPointerPacket = { [unowned self] in packets.append($0) }
        link.isChannelOpen = { [unowned self] in channelOpen }
    }

    func start(_ offer: WifiOffer = WifiTestData.offer) {
        link.start(offer: offer, sealer: pointerRig.mac.sealer(.wifiProbe))
    }

    /// What the phone makes of the probes sent so far: each must open with the connection's probe key.
    func openedByPhone() -> [Result<Data, ChannelOpenError>] {
        let opener = pointerRig.phone.opener(.wifiProbe)
        return transport.sent.map { opener.open($0) }
    }

    /// A 41-byte datagram that starts with 0x03: the shape the link lets through. Its content is not checked by the link.
    static func pointerShaped(_ fill: UInt8 = 0x11) -> Data { Data([0x03]) + Data(repeating: fill, count: 40) }
}

@MainActor
final class WifiProbeLinkTests: XCTestCase {
    func testStartingOpensTheTargetsAndSendsOneProbeAtOnce() {
        let r = WifiLinkRig()
        r.start()
        XCTAssertEqual(r.transport.opened, [[WifiTestData.target, WifiTestData.second]], "every address with the offered port")
        XCTAssertEqual(r.transport.sent.count, 1, "the first probe does not wait for a timer")
        XCTAssertEqual(r.logLines, ["wifi_probe_start targets=2"])
        XCTAssertTrue(r.link.isProbing)
    }

    func testTheNextProbesComeEvery250MillisecondsEachFreshlySealed() throws {
        let r = WifiLinkRig()
        r.start()
        let timer = try XCTUnwrap(r.timers.active.first)
        XCTAssertEqual(r.timers.active.count, 1)
        XCTAssertEqual(timer.interval, 0.25, "Provisional: no measurement behind it (spec section 8)")
        XCTAssertEqual(WifiProbeLink.probeInterval, 0.25)
        r.timers.tick()
        r.timers.tick()
        XCTAssertEqual(r.transport.sent.count, 3)
        XCTAssertEqual(Set(r.transport.sent).count, 3, "no probe is the same bytes twice")

        let opened = r.openedByPhone()
        for case .success(let plain) in opened { XCTAssertEqual(plain, Data(count: 16), "16 zero bytes") }
        XCTAssertEqual(opened.count, 3)
        XCTAssertTrue(opened.allSatisfy { if case .success = $0 { true } else { false } }, "the phone opens every probe with the probe key")
        XCTAssertEqual(r.pointerRig.phone.opener(.wifiProbe).lastOpenedCounter, 3)
        XCTAssertEqual(r.transport.sent.first?.first, 0x05)
        XCTAssertEqual(r.transport.sent.first?.count, 41)
    }

    func testStoppingEndsTheTimerAndTheTransportAndSaysWhyOnce() {
        let r = WifiLinkRig()
        r.start()
        r.link.stop(why: "close")
        XCTAssertFalse(r.link.isProbing)
        XCTAssertTrue(r.timers.active.isEmpty)
        XCTAssertEqual(r.transport.closes, 1)
        r.timers.tick()
        XCTAssertEqual(r.transport.sent.count, 1, "nothing is sent after the stop")
        r.link.stop(why: "disconnect")
        XCTAssertEqual(r.logLines, ["wifi_probe_start targets=2", "wifi_probe_stop why=close"], "a stop with nothing to stop is silent")
        XCTAssertEqual(r.transport.closes, 1)
    }

    func testAnOfferWhileProbingReplacesTheTargetsAndKeepsTheProbeCounter() {
        let r = WifiLinkRig()
        r.start()
        r.start(WifiTestData.otherOffer)
        XCTAssertEqual(r.transport.opened.last, [WifiTarget(address: "172.16.0.9", port: 4_000)])
        XCTAssertEqual(r.timers.active.count, 1, "one timer, not two")
        XCTAssertEqual(r.timers.entries.count, 2)
        XCTAssertEqual(r.transport.sent.count, 2, "the replacement is probed at once")
        r.timers.tick()
        XCTAssertEqual(r.transport.sent.count, 3)
        let counters = r.openedByPhone().compactMap { try? $0.get() }.count
        XCTAssertEqual(counters, 3, "one counter for the connection: no probe is a replay of another")
        XCTAssertEqual(r.logLines.filter { $0.hasPrefix("wifi_probe_start") }, ["wifi_probe_start targets=2", "wifi_probe_start targets=1"])
    }

    func testAChannelThatIsNoLongerOpenEndsTheProbesAtTheNextTick() {
        let r = WifiLinkRig()
        r.start()
        r.channelOpen = false
        r.timers.tick()
        XCTAssertFalse(r.link.isProbing)
        XCTAssertEqual(r.transport.sent.count, 1, "no probe once the channel is gone")
        XCTAssertEqual(r.logLines.last, "wifi_probe_stop why=closed")
        XCTAssertTrue(r.timers.active.isEmpty)
    }

    // MARK: Which datagrams are let in (spec W9)

    func testADatagramFromAProbedTargetWithTheShapeOfAPointerPacketIsHandedOn() {
        let r = WifiLinkRig()
        r.start()
        let datagram = WifiLinkRig.pointerShaped()
        r.transport.deliver(from: WifiTestData.target, datagram)
        r.transport.deliver(from: WifiTestData.second, datagram)
        XCTAssertEqual(r.packets, [datagram, datagram])
    }

    func testADatagramFromAnySourceThatIsNotATargetIsIgnored() {
        let r = WifiLinkRig()
        r.start()
        let datagram = WifiLinkRig.pointerShaped()
        r.transport.deliver(from: WifiTarget(address: "192.168.1.23", port: 50_124), datagram)
        r.transport.deliver(from: WifiTarget(address: "192.168.1.24", port: 50_123), datagram)
        XCTAssertTrue(r.packets.isEmpty, "same host with another port, and another host with the same port")
    }

    func testADatagramThatIsNotExactly41BytesWithMagic03IsIgnored() {
        let r = WifiLinkRig()
        r.start()
        let good = WifiLinkRig.pointerShaped()
        r.transport.deliver(from: WifiTestData.target, good.dropLast())
        r.transport.deliver(from: WifiTestData.target, good + Data([0]))
        r.transport.deliver(from: WifiTestData.target, Data([0x05]) + good.dropFirst())
        r.transport.deliver(from: WifiTestData.target, Data())
        XCTAssertTrue(r.packets.isEmpty)
        r.transport.deliver(from: WifiTestData.target, good)
        XCTAssertEqual(r.packets.count, 1)
    }

    func testNothingIsHandedOnBeforeTheFirstProbeOrAfterTheStop() {
        let r = WifiLinkRig()
        r.transport.deliver(from: WifiTestData.target, WifiLinkRig.pointerShaped())
        r.start()
        r.link.stop(why: "close")
        r.transport.deliver(from: WifiTestData.target, WifiLinkRig.pointerShaped())
        XCTAssertTrue(r.packets.isEmpty)
    }

    func testTheStopCountsWhatWasDroppedAndNeverWhereItCameFrom() {
        let r = WifiLinkRig()
        r.start()
        let stranger = WifiTarget(address: "203.0.113.7", port: 9)
        r.transport.deliver(from: stranger, WifiLinkRig.pointerShaped())
        r.transport.deliver(from: stranger, WifiLinkRig.pointerShaped())
        r.transport.deliver(from: WifiTestData.target, Data([1, 2, 3]))
        r.link.stop(why: "close")
        XCTAssertTrue(r.logLines.contains("wifi_drops source=2 shape=1"), r.logLines.joined(separator: "\n"))
        for line in r.logLines {
            XCTAssertFalse(line.contains("203.0.113.7") || line.contains("192.168") || line.contains("10.0.0.5"), "no address in the log: \(line)")
        }
    }

    // MARK: The prompt the Mac shows once

    func testTheInfoPlistExplainsTheLocalNetworkPromptInTaiwanChinese() throws {
        let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String)
        XCTAssertTrue(text.contains("Wi-Fi"), text)
        XCTAssertTrue(text.contains("游標"), text)
    }
}
