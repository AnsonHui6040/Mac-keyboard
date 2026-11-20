import Foundation
import RimeC

public struct RimePaths: Sendable, Equatable {
    public var sharedData: URL
    public var prebuilt: URL
    public var userData: URL
    public init(sharedData: URL, prebuilt: URL, userData: URL) {
        self.sharedData = sharedData
        self.prebuilt = prebuilt
        self.userData = userData
    }
}

public enum RimeError: Error, Equatable {
    case alreadyStartedWithOtherPaths
    case initializeFailed
    case schemaUnavailable(String)
    case sessionFailed
}

public enum RimeKeyCode {
    public static let space: Int32 = 0x20
    public static let backSpace: Int32 = 0xff08
    public static let returnKey: Int32 = 0xff0d
}

/// One librime runtime per process. Start is idempotent for identical paths.
public final class RimeRuntime: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (paths: RimePaths, runtime: RimeRuntime)?

    let api: UnsafeMutablePointer<RimeApi>
    // Keeps the C strings handed to librime alive for the process lifetime.
    private let cStrings: [UnsafeMutablePointer<CChar>]

    private init(api: UnsafeMutablePointer<RimeApi>, cStrings: [UnsafeMutablePointer<CChar>]) {
        self.api = api
        self.cStrings = cStrings
    }

    public static func start(_ paths: RimePaths) throws -> RimeRuntime {
        lock.lock()
        defer { lock.unlock() }
        if let current {
            guard current.paths == paths else { throw RimeError.alreadyStartedWithOtherPaths }
            return current.runtime
        }
        guard let api = rime_get_api() else { throw RimeError.initializeFailed }
        let strings = [
            strdup(paths.sharedData.path),
            strdup(paths.userData.path),
            strdup(paths.prebuilt.path),
            strdup("rime.remotekeyboard"),
            strdup("")
        ].compactMap { $0 }
        guard strings.count == 5 else {
            strings.forEach { free($0) }
            throw RimeError.initializeFailed
        }
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = UnsafePointer(strings[0])
        traits.user_data_dir = UnsafePointer(strings[1])
        traits.prebuilt_data_dir = UnsafePointer(strings[2])
        traits.app_name = UnsafePointer(strings[3])
        traits.log_dir = UnsafePointer(strings[4])
        traits.min_log_level = 3
        api.pointee.setup?(&traits)
        api.pointee.initialize?(&traits)
        let runtime = RimeRuntime(api: api, cStrings: strings)
        current = (paths, runtime)
        return runtime
    }

    public func makeSession(schema: String) throws -> RimeSession {
        guard let create = api.pointee.create_session else { throw RimeError.sessionFailed }
        let id = create()
        guard id != 0 else { throw RimeError.sessionFailed }
        // select_schema reports success even for unknown ids, so check the schema config exists.
        var config = RimeConfig()
        var exists = false
        if api.pointee.schema_open?(schema, &config) == RimeBool(1) {
            var buffer = [CChar](repeating: 0, count: 256)
            if api.pointee.config_get_string?(&config, "schema/schema_id", &buffer, buffer.count) == RimeBool(1) {
                exists = String(cString: buffer) == schema
            }
            _ = api.pointee.config_close?(&config)
        }
        guard exists, api.pointee.select_schema?(id, schema) == RimeBool(1) else {
            _ = api.pointee.destroy_session?(id)
            throw RimeError.schemaUnavailable(schema)
        }
        return RimeSession(api: api, id: id)
    }
}

typealias RimeBool = Int32
