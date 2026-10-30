/// Runs actions one after another on the main actor. The keyboard routes every key through it while an input-method
/// key is still waiting (a space that waits for a recognition), so no later key overtakes a pending commit.
/// `reset()` drops everything not yet started and marks the running action stale.
@MainActor
public final class OrderedActionQueue {
    /// Handed to a running action so it can tell whether the queue was reset while it was suspended.
    public struct Run {
        fileprivate let queue: OrderedActionQueue
        fileprivate let epoch: Int
        @MainActor public var isCurrent: Bool { queue.epoch == epoch }
    }

    public private(set) var pendingCount = 0
    private var tail: Task<Void, Never>?
    private var epoch = 0

    public init() {}

    /// True while any action is queued or running.
    public var isBusy: Bool { pendingCount > 0 }

    public func enqueue(_ work: @escaping @MainActor (Run) async -> Void) {
        pendingCount += 1
        let previous = tail
        let run = Run(queue: self, epoch: epoch)
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, run.isCurrent else { return }
            await work(run)
            if run.isCurrent { self.pendingCount -= 1 }
        }
    }

    /// Drops the actions that have not started and marks the running one stale.
    public func reset() {
        epoch &+= 1
        tail?.cancel()
        tail = nil
        pendingCount = 0
    }

    /// Waits until everything queued so far has run.
    public func drain() async {
        await tail?.value
    }
}
