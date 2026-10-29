import Foundation
import OSLog
import os

/// Notice-level lifecycle log. Notice level persists into a device sysdiagnose, which is what the device test needs.
/// Carries counters, owner changes and sizes only, never text.
enum KeyboardLifecycleLog {
    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "lifecycle")
    private static let live = OSAllocatedUnfairLock(initialState: 0)

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
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
