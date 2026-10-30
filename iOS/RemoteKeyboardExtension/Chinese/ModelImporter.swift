import Foundation
import RemoteKeyboardCore

/// Brings the keyboard's own ML Kit model in line with the host app's copy in the App Group. One actor for the whole
/// process, so two keyboard controllers never copy at the same time: a second request awaits the one in flight. The
/// copy runs in a task this actor owns; cancelling the requester cancels it (the copy then stops and removes its
/// staging directory). No ML Kit import here; the model check goes through `MLKitHandwriting`.
actor ModelImporter {
    static let shared = ModelImporter()

    enum Outcome: Equatable, Sendable {
        case ready
        case missing
        /// The import was cancelled; nothing was changed.
        case cancelled
    }

    private struct Result: Sendable {
        var outcome: Outcome
        /// The group stamp an import failed for; no import is tried again until the group stamp changes.
        var failedStamp: String?
    }

    private var inFlight: Task<Result, Never>?
    private var failedStamp: String?

    /// Decides (`ModelImportPolicy`) and, when needed, imports. `onImportStart` is called when a copy really begins.
    func prepare(onImportStart: @escaping @Sendable () -> Void) async -> Outcome {
        if let inFlight { return await inFlight.value.outcome }
        let failed = failedStamp
        let task = Task.detached(priority: .userInitiated) {
            Self.work(failedStamp: failed, onImportStart: onImportStart)
        }
        inFlight = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight = nil
        if let stamp = result.failedStamp { failedStamp = stamp }
        return result.outcome
    }

    /// The recognizer found the model unusable: remove the keyboard's copy so the next appearance imports again.
    func discardLocalCopy() {
        failedStamp = nil
        HandwritingModelStore.removeLocalCopy()
    }

    private static func work(failedStamp: String?, onImportStart: @Sendable () -> Void) -> Result {
        let groupState = HandwritingModelStore.groupCopyState()
        var group: String?
        if case .complete(let stamp) = groupState { group = stamp }
        let action = ModelImportPolicy.decide(
            modelPresent: MLKitHandwriting.isModelDownloaded(), group: groupState,
            localStamp: HandwritingModelStore.localStamp(), failedStamp: failedStamp)
        switch action {
        case .useLocal:
            return Result(outcome: .ready)
        case .missing:
            return Result(outcome: .missing)
        case .dropLocal:
            HandwritingModelStore.removeLocalCopy()
            return Result(outcome: .missing)
        case .importFromGroup:
            onImportStart()
            do {
                _ = try HandwritingModelStore.importFromGroup()
            } catch HandwritingModelStore.StoreError.cancelled {
                return Result(outcome: .cancelled)
            } catch {
                return Result(outcome: .missing, failedStamp: group)
            }
            // ML Kit may still not accept the copy: back off until the host app writes a new one.
            return MLKitHandwriting.isModelDownloaded()
                ? Result(outcome: .ready) : Result(outcome: .missing, failedStamp: group)
        }
    }
}
