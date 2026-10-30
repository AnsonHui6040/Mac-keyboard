import XCTest
@testable import RemoteKeyboardCore

private func advertisingMachine() -> KeyboardLinkStateMachine {
    var m = KeyboardLinkStateMachine()
    _ = m.handle(.power(.poweredOn))
    _ = m.handle(.appeared(hasFullAccess: true))
    _ = m.handle(.serviceAdded(ok: true))
    _ = m.handle(.advertisingStarted(ok: true))
    return m
}

private func connectedMachine() -> KeyboardLinkStateMachine {
    var m = advertisingMachine()
    _ = m.handle(.subscribed)
    return m
}

private func publishingMachine() -> KeyboardLinkStateMachine {
    var m = KeyboardLinkStateMachine()
    _ = m.handle(.power(.poweredOn))
    _ = m.handle(.appeared(hasFullAccess: true))
    return m
}

final class KeyboardLinkStateMachineTests: XCTestCase {
    func testAppearWithoutFullAccessDoesNothing() {
        var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.poweredOn))
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: false)), [])
        XCTAssertEqual(m.state, .noFullAccess)
    }
    func testAppearPoweredOnPublishesThenAdvertises() {
        var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.poweredOn))
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [.addService])
        XCTAssertEqual(m.handle(.serviceAdded(ok: true)), [.startAdvertising])
        _ = m.handle(.advertisingStarted(ok: true)); XCTAssertEqual(m.state, .advertising)
    }
    func testAppearBeforePowerPublishesWhenPoweredOn() {
        var m = KeyboardLinkStateMachine()
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [])
        XCTAssertEqual(m.handle(.power(.poweredOn)), [.addService])
    }
    func testSubscribeConnectsAndStopsAdvertising() {
        var m = advertisingMachine()
        XCTAssertEqual(m.handle(.subscribed), [.stopAdvertising]); XCTAssertEqual(m.state, .connected)
    }
    func testUnsubscribeResumesAdvertising() {
        var m = connectedMachine()
        XCTAssertEqual(m.handle(.unsubscribed), [.startAdvertising]); XCTAssertEqual(m.state, .advertising)
    }
    func testDisappearStopsAndRemoves() {
        var m = connectedMachine()
        XCTAssertEqual(m.handle(.disappeared), [.stopAdvertising, .removeServices]); XCTAssertEqual(m.state, .idle)
    }
    func testUnauthorizedPowerShowsUnavailableAndNoEffects() {
        var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.unauthorized))
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [])
        XCTAssertEqual(m.state, .unavailable(.unauthorized))
    }
    func testPowerOffWhileConnectedThenOnRepublishes() {
        var m = connectedMachine(); _ = m.handle(.power(.poweredOff))
        XCTAssertEqual(m.state, .unavailable(.poweredOff))
        XCTAssertEqual(m.handle(.power(.poweredOn)), [.addService])
    }
    func testServiceAddFailureFails() { var m = publishingMachine(); _ = m.handle(.serviceAdded(ok: false)); XCTAssertEqual(m.state, .failed(.addService)) }
    func testDuplicateAppearIgnored() { var m = advertisingMachine(); XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), []) }

    func testAdvertiseFailureFails() {
        var m = publishingMachine(); _ = m.handle(.serviceAdded(ok: true))
        _ = m.handle(.advertisingStarted(ok: false))
        XCTAssertEqual(m.state, .failed(.advertise))
    }
    func testDisappearAfterFailureReturnsToIdle() {
        var m = publishingMachine(); _ = m.handle(.serviceAdded(ok: false))
        _ = m.handle(.disappeared)
        XCTAssertEqual(m.state, .idle)
    }
    func testDisappearWithoutFullAccessReturnsToIdle() {
        var m = KeyboardLinkStateMachine(); _ = m.handle(.appeared(hasFullAccess: false))
        XCTAssertEqual(m.handle(.disappeared), []); XCTAssertEqual(m.state, .idle)
    }
    func testPowerWhileHiddenDoesNotPublish() {
        var m = KeyboardLinkStateMachine()
        XCTAssertEqual(m.handle(.power(.poweredOn)), []); XCTAssertEqual(m.state, .idle)
    }
    func testReappearAfterDisappearPublishesAgain() {
        var m = connectedMachine(); _ = m.handle(.disappeared)
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [.addService])
    }
    func testStateNamesMatchAccessibilityValues() {
        XCTAssertEqual(KeyboardLinkState.idle.name, "idle")
        XCTAssertEqual(KeyboardLinkState.noFullAccess.name, "no-full-access")
        XCTAssertEqual(KeyboardLinkState.unavailable(.poweredOff).name, "unavailable")
        XCTAssertEqual(KeyboardLinkState.publishing.name, "publishing")
        XCTAssertEqual(KeyboardLinkState.advertising.name, "advertising")
        XCTAssertEqual(KeyboardLinkState.connected.name, "connected")
        XCTAssertEqual(KeyboardLinkState.failed(.advertise).name, "failed")
        XCTAssertEqual(KeyboardLinkState.advertising.statusText, "BLE: advertising")
        XCTAssertEqual(KeyboardLinkState.failed(.addService).statusText, "BLE: failed (addService)")
        XCTAssertEqual(KeyboardLinkState.failed(.advertise).statusText, "BLE: failed (advertise)")
    }

    // MARK: T06 reconnect cycles

    func testTwentyAppearDisappearCyclesRepublishEachTime() {
        var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.poweredOn))
        for _ in 0..<20 {
            XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [.addService])
            _ = m.handle(.serviceAdded(ok: true))
            _ = m.handle(.advertisingStarted(ok: true))
            _ = m.handle(.subscribed)
            XCTAssertEqual(m.handle(.disappeared), [.stopAdvertising, .removeServices])
            XCTAssertEqual(m.state, .idle)
        }
    }

    func testRapidDisappearAppearDoesNotDuplicatePublish() {
        var m = publishingMachine()
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [])
        XCTAssertEqual(m.state, .publishing)
    }

    func testDisappearThenAppearBeforeServiceAddedPublishesOnceMore() {
        var m = publishingMachine()
        XCTAssertEqual(m.handle(.disappeared), [.stopAdvertising, .removeServices])
        XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [.addService])
        // Filtering a stale didAdd is PendingServiceTracker's job; the machine advances on the one it is given.
        XCTAssertEqual(m.handle(.serviceAdded(ok: true)), [.startAdvertising])
    }

    // MARK: Link reset (goodbye or failed liveness probe)

    func testLinkResetFromConnectedRepublishes() {
        var m = connectedMachine()
        let effects = m.handle(.linkReset)
        XCTAssertEqual(effects, [.stopAdvertising, .removeServices, .addService])
        XCTAssertEqual(m.state, .publishing)
        // Then the normal flow: the new service is added, advertising starts, the Mac subscribes again.
        XCTAssertEqual(m.handle(.serviceAdded(ok: true)), [.startAdvertising])
        _ = m.handle(.advertisingStarted(ok: true))
        XCTAssertEqual(m.state, .advertising)
        XCTAssertEqual(m.handle(.subscribed), [.stopAdvertising])
        XCTAssertEqual(m.state, .connected)
    }

    func testLinkResetFromAdvertisingAndPublishingRepublishes() {
        var advertising = advertisingMachine()
        XCTAssertEqual(advertising.handle(.linkReset), [.stopAdvertising, .removeServices, .addService])
        XCTAssertEqual(advertising.state, .publishing)
        var publishing = publishingMachine()
        XCTAssertEqual(publishing.handle(.linkReset), [.stopAdvertising, .removeServices, .addService])
        XCTAssertEqual(publishing.state, .publishing)
    }

    func testLinkResetRepublishesAFailedLinkToo() {
        var m = publishingMachine()
        _ = m.handle(.serviceAdded(ok: true))
        _ = m.handle(.advertisingStarted(ok: false))
        XCTAssertEqual(m.state, .failed(.advertise))
        XCTAssertEqual(m.handle(.linkReset), [.removeServices, .addService])
        XCTAssertEqual(m.state, .publishing)
    }

    func testLinkResetIsIgnoredWhenNothingIsPublished() {
        var idle = KeyboardLinkStateMachine()
        XCTAssertEqual(idle.handle(.linkReset), [])
        XCTAssertEqual(idle.state, .idle)
        var noAccess = KeyboardLinkStateMachine(); _ = noAccess.handle(.power(.poweredOn))
        _ = noAccess.handle(.appeared(hasFullAccess: false))
        XCTAssertEqual(noAccess.handle(.linkReset), [])
        XCTAssertEqual(noAccess.state, .noFullAccess)
        var off = KeyboardLinkStateMachine(); _ = off.handle(.power(.poweredOff))
        _ = off.handle(.appeared(hasFullAccess: true))
        XCTAssertEqual(off.handle(.linkReset), [])
        XCTAssertEqual(off.state, .unavailable(.poweredOff))
    }

    func testLinkResetAfterDisappearDoesNotPublish() {
        var m = connectedMachine()
        _ = m.handle(.disappeared)
        XCTAssertEqual(m.handle(.linkReset), [])
        XCTAssertEqual(m.state, .idle)
    }
}
