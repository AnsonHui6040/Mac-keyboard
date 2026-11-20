/// Runs a load once; callers that arrive during the load wait for the same result. `reset()` makes the next
/// `value()` load again.
public actor OnceLoader<Value: Sendable> {
    private let load: @Sendable () async -> Value
    private var task: Task<Value, Never>?

    public init(_ load: @escaping @Sendable () async -> Value) {
        self.load = load
    }

    public func value() async -> Value {
        if let task { return await task.value }
        let load = self.load
        let created = Task { await load() }
        task = created
        return await created.value
    }

    public func reset() {
        task = nil
    }
}
