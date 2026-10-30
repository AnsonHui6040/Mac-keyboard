import Foundation
import OSLog
import os

/// Notice-level lifecycle log. Notice level persists into a device sysdiagnose, which is what the device test needs.
/// Carries counters, owner tokens and sizes only, never text. Only the fixed `Event` cases can be logged, so no free
/// string (a typed character, a key, an app name) can be passed in by mistake.
enum KeyboardLifecycleLog {
    enum Event {
        case ownerChanged(owner: UUID, hadPrevious: Bool)
        case ownerReleasedByDeinit(owner: UUID)
        case staleDisappearIgnored(owner: UUID)
        case vacantOwnerReclaimed(owner: UUID)
        case managerCreated
        /// Full Access is off: the peripheral manager of an earlier controller was torn down.
        case managerReleasedNoFullAccess
        case removeAllServicesBeforeAdd
        case addService
        case removeAllServices
        case staleDidAddIgnored(ok: Bool)
        case subscribed(maxUpdateValueLength: Int)
        case unsubscribed(maxUpdateValueLength: Int)
        case pairKeyMissing
        case handshakeStarted
        case handshakeAuthenticated
        case handshakeFailed
        /// A liveness probe left because a keyboard appeared on a link that looked connected.
        case probeSent
        case probeAnswered
        case probeExpired
        /// The Mac said goodbye (sealed `bye`).
        case byeReceived
        /// The service is published again from scratch (after a goodbye or an unanswered probe).
        case linkReset
    }

    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "lifecycle")
    private static let live = OSAllocatedUnfairLock(initialState: 0)

    static func note(_ event: Event) {
        switch event {
        case .ownerChanged(let owner, let hadPrevious):
            logger.notice("owner changed to \(owner.uuidString.prefix(8), privacy: .public) hadPrevious=\(hadPrevious, privacy: .public)")
        case .ownerReleasedByDeinit(let owner):
            logger.notice("owner released by deinit \(owner.uuidString.prefix(8), privacy: .public)")
        case .staleDisappearIgnored(let owner):
            logger.notice("disappear ignored for stale \(owner.uuidString.prefix(8), privacy: .public)")
        case .vacantOwnerReclaimed(let owner):
            logger.notice("vacant owner reclaimed by \(owner.uuidString.prefix(8), privacy: .public)")
        case .managerCreated:
            logger.notice("manager created")
        case .managerReleasedNoFullAccess:
            logger.notice("manager released, no Full Access")
        case .removeAllServicesBeforeAdd:
            logger.notice("removeAllServices before add")
        case .addService:
            logger.notice("addService")
        case .removeAllServices:
            logger.notice("removeAllServices")
        case .staleDidAddIgnored(let ok):
            logger.notice("stale didAdd ignored ok=\(ok, privacy: .public)")
        case .subscribed(let length):
            logger.notice("subscribed maxUpdateValueLength=\(length, privacy: .public)")
        case .unsubscribed(let length):
            logger.notice("unsubscribed maxUpdateValueLength=\(length, privacy: .public)")
        case .pairKeyMissing:
            logger.notice("no pair key")
        case .handshakeStarted:
            logger.notice("handshake started")
        case .handshakeAuthenticated:
            logger.notice("handshake authenticated")
        case .handshakeFailed:
            logger.notice("handshake failed")
        case .probeSent:
            logger.notice("liveness probe sent")
        case .probeAnswered:
            logger.notice("liveness probe answered")
        case .probeExpired:
            logger.notice("liveness probe unanswered")
        case .byeReceived:
            logger.notice("goodbye received")
        case .linkReset:
            logger.notice("link reset")
        }
    }

    static func controllerCreated(token: UUID) {
        let count = live.withLock { value -> Int in value += 1; return value }
        logger.notice("controller init \(token.uuidString.prefix(8), privacy: .public) live=\(count, privacy: .public)")
    }

    static func controllerDestroyed(token: UUID) {
        let count = live.withLock { value -> Int in value -= 1; return value }
        logger.notice("controller deinit \(token.uuidString.prefix(8), privacy: .public) live=\(count, privacy: .public)")
    }
}

/// Lives exactly as long as one `KeyboardViewController`. Counts it, and on deinit gives up peripheral ownership if
/// the controller still held it. The token (not an object address) identifies the owner, so a late release can never
/// hit a newer controller that happens to reuse the address.
final class ControllerLifecycle: @unchecked Sendable {
    let token = UUID()

    init() { KeyboardLifecycleLog.controllerCreated(token: token) }

    deinit {
        let token = token
        KeyboardLifecycleLog.controllerDestroyed(token: token)
        Task { @MainActor in KeyboardBLEPeripheral.shared.release(owner: token) }
    }
}
