#if DEBUG
import Foundation
import os
import RemoteKeyboardCore

/// T15 burst: sends `#1` ... `#10000` (text `#n` plus a return key per line) through the normal send path, so the Mac types them into
/// whatever field has focus and `BurstVerifier` can count what arrived.
///
/// Flow control follows the acks: at most `window` keys are unanswered at any time, and when the window is full the
/// generator sleeps instead of spinning, so the main thread stays free between bursts of work. If the Mac is no longer
/// ready, a send does not take, or no ack arrives for `stallSeconds`, the run stops where it is and nothing is resent
/// (a key without an ack may or may not have been typed). Only counts and line numbers are logged, never the text.
@MainActor
final class BurstGenerator {
    enum Outcome: Equatable {
        case finished(sent: Int)
        case stopped(sent: Int, reason: Reason)
        case cancelled(sent: Int)
    }

    enum Reason: String {
        case notReady
        case sendRefused
        case stalled
    }

    static let defaultTotal = 10_000
    /// Unanswered keys allowed at once.
    static let window = 16
    /// Lines handed over per tick before yielding to the run loop.
    static let linesPerTick = 8
    static let tickMilliseconds = 4
    static let stallSeconds: Double = 10

    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "burst")

    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    /// - Parameters:
    ///   - isReady: whether the Mac can take typed keys right now.
    ///   - pending: keys sent and not yet answered.
    ///   - send: routes line `n` through the normal input path (text `#n`, then the return key); `false` when it did not leave the phone.
    ///   - onProgress: the number of lines handed over so far, called about every 100 lines.
    ///   - onFinish: called once, on the main actor.
    func start(
        total: Int = BurstGenerator.defaultTotal,
        isReady: @escaping @MainActor () -> Bool,
        pending: @escaping @MainActor () -> Int,
        send: @escaping @MainActor (Int) -> Bool,
        onProgress: @escaping @MainActor (Int) -> Void,
        onFinish: @escaping @MainActor (Outcome) -> Void
    ) {
        guard task == nil else { return }
        Self.log.info("burst start total=\(total, privacy: .public)")
        task = Task { @MainActor [weak self] in
            var sent = 0
            var lastProgressAt = Date()
            var outcome = Outcome.finished(sent: 0)
            run: while sent < total {
                if Task.isCancelled { outcome = .cancelled(sent: sent); break run }
                guard isReady() else { outcome = .stopped(sent: sent, reason: .notReady); break run }
                var handed = 0
                while sent < total, handed < Self.linesPerTick, pending() < Self.window {
                    guard send(sent + 1) else {
                        outcome = .stopped(sent: sent, reason: .sendRefused)
                        break run
                    }
                    sent += 1
                    handed += 1
                    lastProgressAt = Date()
                    if sent % 100 == 0 { onProgress(sent) }
                }
                if handed == 0, Date().timeIntervalSince(lastProgressAt) > Self.stallSeconds {
                    outcome = .stopped(sent: sent, reason: .stalled)
                    break run
                }
                // An ack frees window space; check again shortly. Nothing blocks the main thread.
                try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
            }
            if case .finished = outcome { outcome = .finished(sent: sent) }
            Self.log.info("burst end sent=\(sent, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
            self?.task = nil
            onFinish(outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }
}
#endif
