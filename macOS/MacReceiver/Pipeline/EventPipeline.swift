import Foundation
import OSLog
import RemoteKeyboardCore

/// Turns each verified keyboard event into at most one injection and exactly one ack.
///
/// Events arrive here only after `ReceiverSecurity` authenticated the connection and opened the sealed payload; the
/// pipeline never sees a plaintext message from the radio.
///
/// A repeated event (same `eventId`) is acked with its original code and never typed again; an event whose `seq`
/// is not above the highest one processed in its session is acked `outOfOrder` and not typed. What was processed is
/// remembered across link losses.
///
/// Strictly one event at a time, in arrival order: events are queued into a stream and a single consumer finishes
/// one (including its ASCII switch, settle and restore) before it reads the next. Fails closed: the focus is read
/// fresh before the guard and once more right before posting. Logs carry kind, length, result and timing only.
@MainActor
final class EventPipeline {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "pipeline")

    private let snapshot: @MainActor () async -> FocusSnapshot?
    private let switcher: InputSourceSwitcher
    private let injector: TextInjector
    private let sendAck: @MainActor (Ack) -> Void
    private let noteValidEvent: @MainActor () -> Void
    private let onPing: @MainActor (_ shownAtMs: Int64, _ connectedAtMs: Int64) -> Void
    private let onInputSourceRestore: @MainActor (_ restoredOK: Bool) -> Void

    private enum Item: Sendable {
        case event(KeyboardEvent)
        /// Authenticated and decrypted, but the inner event could not be parsed.
        case malformed
    }

    /// An item tagged with the link generation it arrived in.
    private struct Queued: Sendable {
        let generation: UInt64
        let item: Item
    }

    private let continuation: AsyncStream<Queued>.Continuation
    private var consumer: Task<Void, Never>?
    /// Bumped whenever the link goes away; anything queued under an older generation is dropped unprocessed.
    private var generation: UInt64 = 0
    /// Deliberately not reset by `discardQueued()`: a resend after a reconnect must still be recognised.
    private var deduplicator = EventDeduplicator()

    /// - Parameters:
    ///   - snapshot: a forced, fresh focus read (not a cached value).
    ///   - noteValidEvent: called for every validly decoded event, whether or not it is injected.
    ///   - onPing: receives a reconnect probe's timestamps. A ping never reaches the focus read or the injector.
    ///   - onInputSourceRestore: called after every injection that switched input source; `false` means the original
    ///     source could not be selected again (the text was still typed and acked `posted`).
    init(
        snapshot: @escaping @MainActor () async -> FocusSnapshot?,
        switcher: InputSourceSwitcher,
        injector: TextInjector,
        sendAck: @escaping @MainActor (Ack) -> Void,
        noteValidEvent: @escaping @MainActor () -> Void,
        onPing: @escaping @MainActor (_ shownAtMs: Int64, _ connectedAtMs: Int64) -> Void = { _, _ in },
        onInputSourceRestore: @escaping @MainActor (_ restoredOK: Bool) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.switcher = switcher
        self.injector = injector
        self.sendAck = sendAck
        self.noteValidEvent = noteValidEvent
        self.onPing = onPing
        self.onInputSourceRestore = onInputSourceRestore
        let (stream, continuation) = AsyncStream<Queued>.makeStream()
        self.continuation = continuation
        consumer = Task { @MainActor [weak self] in
            for await item in stream {
                guard let self else { return }
                guard item.generation == self.generation else {
                    Self.log.info("event dropped reason=link-lost")
                    continue
                }
                switch item.item {
                case .event(let event): await self.process(event)
                case .malformed: self.processMalformed()
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumer?.cancel()
    }

    /// Queues one verified event. Order of calls is the order of processing.
    func submit(_ event: KeyboardEvent) { continuation.yield(Queued(generation: generation, item: .event(event))) }

    /// Queues the answer for an authenticated payload that could not be parsed; it is acked `malformed` in order.
    func submitMalformed() { continuation.yield(Queued(generation: generation, item: .malformed)) }

    /// Drops every item that is queued but not yet being processed. Called when receiving stops or the link
    /// is lost: keys typed for a connection that no longer exists are not injected later. The event already in
    /// flight finishes under its own focus checks.
    func discardQueued() { generation &+= 1 }

    // MARK: Decision mapping (pure)

    /// The refusal ack for a guard decision; `nil` when the guard allows.
    nonisolated static func ackCode(for decision: InjectionDecision) -> AckCode? {
        switch decision {
        case .allow: nil
        case .notAuthorized: .notAuthorized
        case .noFocus: .noFocus
        case .staleFocus: .staleFocus
        }
    }

    /// The ack after `withASCII` returned. `lateDecision` is the focus re-check made right before posting, and
    /// `injected` says whether every posting step succeeded.
    nonisolated static func ackCode(result: SwitchResult, lateDecision: InjectionDecision, injected: Bool) -> AckCode {
        switch result {
        case .switchFailed: return .switchFailed
        case .compositionActive: return .compositionActive
        case .refused: return ackCode(for: lateDecision) ?? .staleFocus
        case .injected, .injectedRestoreFailed:
            if let refusal = ackCode(for: lateDecision) { return refusal }
            return injected ? .posted : .injectFailed
        }
    }

    // MARK: Processing

    /// An authenticated payload that did not parse: not an event, not receive activity, answered `malformed`.
    func processMalformed() {
        Self.log.info("event rejected ack=malformed")
        sendAck(Ack(eventId: Ack.unknownEventId, result: .malformed))
    }

    /// Handles one event to completion. Internal so tests can drive it without the stream.
    func process(_ event: KeyboardEvent) async {
        let started = ContinuousClock.now
        noteValidEvent()
        let code = await handle(event)
        sendAck(Ack(eventId: event.eventId, result: code))
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let (name, length) = Self.describe(event.kind)
        Self.log.info("event kind=\(name, privacy: .public) length=\(length, privacy: .public) ack=\(code.rawValue, privacy: .public) ms=\(ms, privacy: .public)")
    }

    private func handle(_ event: KeyboardEvent) async -> AckCode {
        switch event.kind {
        case .ping(let shownAtMs, let connectedAtMs):
            // A probe: recorded and answered, never injected. It skips the deduplicator (no check, nothing
            // recorded) and the epoch rule below, so a ping without a focus epoch is not refused.
            onPing(shownAtMs, connectedAtMs)
            return .pong
        case .probe:
            // The keyboard's liveness probe: answered and nothing else. Not a reconnect sample (no `onPing`, so nothing
            // reaches reconnect.csv), not recorded for deduplication and never injected.
            return .pong
        case .pointerOpen, .pointerClose:
            // The touchpad switch is answered by the coordinator before an event gets here. One that does arrive was not
            // routed there, and nothing may be switched on by the typing pipeline.
            return .notAuthorized
        default:
            break
        }
        switch deduplicator.check(event) {
        case .duplicate(let original): return original
        case .outOfOrder: return .outOfOrder
        case .fresh: break
        }
        let code = await decide(event)
        deduplicator.record(event, result: code)
        return code
    }

    /// The result for an event that is new and in order.
    private func decide(_ event: KeyboardEvent) async -> AckCode {
        if case .text(let text) = event.kind, text.isEmpty { return .malformed }
        // An event typed before any status arrived has no epoch to compare, so it cannot be tied to a field.
        guard event.focusEpoch != nil else { return .staleFocus }
        // Fresh read immediately before the guard.
        let decision = FocusGuard.authorize(eventEpoch: event.focusEpoch, current: await snapshot())
        if let refusal = Self.ackCode(for: decision) { return refusal }

        var lateDecision = InjectionDecision.allow
        var injected = false
        let result = await switcher.withASCII(isAuthorized: {
            // Re-run after the gate wait and before Escape: the focus may have moved while this call queued.
            lateDecision = FocusGuard.authorize(eventEpoch: event.focusEpoch, current: await snapshot())
            return lateDecision == .allow
        }) {
            // The switch and composition cancel take real time; confirm the focus once more before posting.
            lateDecision = FocusGuard.authorize(eventEpoch: event.focusEpoch, current: await snapshot())
            guard lateDecision == .allow else { return }
            injected = inject(event.kind)
        }
        switch result {
        case .injected: onInputSourceRestore(true)
        case .injectedRestoreFailed: onInputSourceRestore(false)
        default: break
        }
        return Self.ackCode(result: result, lateDecision: lateDecision, injected: injected)
    }

    private func inject(_ kind: EventKind) -> Bool {
        switch kind {
        case .text(let text): injector.insert(text).complete
        case .backspace: injector.backspace()
        case .returnKey: injector.returnKeyPress()
        case .ping, .probe, .pointerOpen, .pointerClose: false
        }
    }

    private static func describe(_ kind: EventKind) -> (String, Int) {
        switch kind {
        case .text(let text): ("text", text.utf8.count)
        case .backspace: ("backspace", 0)
        case .returnKey: ("return", 0)
        case .ping: ("ping", 0)
        case .probe: ("probe", 0)
        case .pointerOpen: ("pointerOpen", 0)
        case .pointerClose: ("pointerClose", 0)
        }
    }
}
