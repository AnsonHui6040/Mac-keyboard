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

/// A librime session. Calls on one session must not run concurrently
/// (the caller guarantees this).
public final class RimeSession: @unchecked Sendable {
    private let api: UnsafeMutablePointer<RimeApi>
    private let id: RimeSessionId

    init(api: UnsafeMutablePointer<RimeApi>, id: RimeSessionId) {
        self.api = api
        self.id = id
    }

    deinit {
        _ = api.pointee.destroy_session?(id)
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
            while api.pointee.candidate_list_next?(&iterator) == RimeBool(1) {
                if let text = iterator.candidate.text {
                    candidates.append(String(cString: text))
                }
            }
            api.pointee.candidate_list_end?(&iterator)
        }
        return RimeState(input: input, candidates: candidates)
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
