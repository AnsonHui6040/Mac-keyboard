import Foundation
import RimeC

public struct RimeState: Equatable, Sendable {
    public var input: String
    public var candidates: [String]
    public init(input: String, candidates: [String]) {
        self.input = input
        self.candidates = candidates
    }
}

private struct DestroyHandle: @unchecked Sendable {
    let api: UnsafeMutablePointer<RimeApi>
    let id: RimeSessionId
}

/// A librime session. Calls on one session must not run concurrently
/// (the caller guarantees this).
public final class RimeSession: @unchecked Sendable {
    private let api: UnsafeMutablePointer<RimeApi>
    private let id: RimeSessionId

    /// `state.candidates` reads at most this many candidates, so a long pinyin code cannot stall the keyboard.
    public var candidateLimit = 200

    init(api: UnsafeMutablePointer<RimeApi>, id: RimeSessionId) {
        self.api = api
        self.id = id
    }

    /// Test hook: called with `Thread.isMainThread` each time a session is destroyed.
    nonisolated(unsafe) static var onDestroy: (@Sendable (Bool) -> Void)?

    /// Every librime call must happen on the main thread. The last reference may be
    /// released on any thread (for example inside a Task result), so destruction is
    /// handed to the main thread; the API pointer is process-lifetime and stays valid.
    deinit {
        let handle = DestroyHandle(api: api, id: id)
        let destroy: @Sendable () -> Void = {
            _ = handle.api.pointee.destroy_session?(handle.id)
            RimeSession.onDestroy?(Thread.isMainThread)
        }
        if Thread.isMainThread {
            destroy()
        } else {
            DispatchQueue.main.async(execute: destroy)
        }
    }

    public func processKey(_ keycode: Int32) -> Bool {
        api.pointee.process_key?(id, keycode, 0) == RimeBool(1)
    }

    public var state: RimeState {
        var input = ""
        if let raw = api.pointee.get_input?(id) {
            input = String(cString: raw)
        }
        var candidates: [String] = []
        var iterator = RimeCandidateListIterator()
        if api.pointee.candidate_list_begin?(id, &iterator) == RimeBool(1) {
            while candidates.count < candidateLimit, api.pointee.candidate_list_next?(&iterator) == RimeBool(1) {
                if let text = iterator.candidate.text {
                    candidates.append(String(cString: text))
                }
            }
            api.pointee.candidate_list_end?(&iterator)
        }
        return RimeState(input: input, candidates: candidates)
    }

    /// The composition text librime shows, with the scheme's `preedit_format` applied; empty when nothing is composed.
    public var preedit: String {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context?(id, &context) == RimeBool(1) else { return "" }
        defer { _ = api.pointee.free_context?(&context) }
        guard let raw = context.composition.preedit else { return "" }
        return String(cString: raw)
    }

    /// The part of the composition librime has already converted (selected), as text; empty when nothing is selected.
    /// Reads the preedit bytes before `sel_start` (a UTF-8 byte offset), so it never includes the raw code left over.
    /// This holds only while the schema's segmentor makes the abc segment cover the code from the start to the end (no
    /// punct or fallback segment, no initials/finals); everything before `sel_start` is then selected text. Re-verify
    /// this whenever a schema changes.
    public var selectedText: String {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context?(id, &context) == RimeBool(1) else { return "" }
        defer { _ = api.pointee.free_context?(&context) }
        guard let raw = context.composition.preedit else { return "" }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self),
                                        count: strlen(raw))
        let end = max(0, min(Int(context.composition.sel_start), bytes.count))
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    public func takeCommit() -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit?(id, &commit) == RimeBool(1) else { return nil }
        defer { _ = api.pointee.free_commit?(&commit) }
        guard let text = commit.text else { return nil }
        return String(cString: text)
    }

    public func selectCandidate(_ index: Int) -> Bool {
        api.pointee.select_candidate?(id, index) == RimeBool(1)
    }

    public func clear() {
        api.pointee.clear_composition?(id)
    }

    public func isHealthy(probeKey: Character) -> Bool {
        clear()
        defer { clear() }
        guard let ascii = probeKey.asciiValue else { return false }
        _ = processKey(Int32(ascii))
        return !state.candidates.isEmpty
    }
}
