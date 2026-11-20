import Foundation
import os
import RemoteKeyboardCore
import RimeEngine

/// Provides the engine of a keyed Chinese method (Quick, Cangjie, Zhuyin, Jyutping, Pinyin). Quick uses librime when
/// it starts and passes its health check, otherwise the Swift engine (C1); the other methods have no fallback and give
/// nil. The engine is kept per method: asking for another method releases the loaded session first, so a scheme changed
/// in the app takes effect even when the extension's process outlives the keyboard. Every librime call runs on the
/// main actor. Nothing typed is ever logged: only the start time and whether it worked.
@MainActor
final class ChineseEngineLoader {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "rime")

    private struct Loaded {
        let id: ChineseInputMethodID
        let method: (any ChineseInputMethod)?
    }

    private let bundle: Bundle
    private var loaded: Loaded?

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// The engine for `id` (loaded once per method, a failure included), or nil when it could not load.
    func method(for id: ChineseInputMethodID) async -> (any ChineseInputMethod)? {
        if let loaded, loaded.id == id { return loaded.method }
        // A different method: the old session goes first.
        loaded = nil
        let made = Self.load(id, bundle: bundle)
        loaded = Loaded(id: id, method: made)
        return made
    }

    /// The keyboard went away: forget the engine so its librime session is released (the runtime stays).
    func drop() {
        loaded = nil
    }

    // MARK: Loading

    private static func load(_ id: ChineseInputMethodID, bundle: Bundle) -> (any ChineseInputMethod)? {
        guard let config = RimeSchemeConfig.forMethod(id) else { return nil }
        guard id == .quick else {
            guard let session = startRime(config: config, bundle: bundle) else { return nil }
            return RimeInputMethod(session: session, config: config, id: id)
        }
        #if DEBUG
        let override = MeasureLaunchConfig.read().quickEngine
        #else
        let override: String? = nil
        #endif
        var session: RimeSession?
        if override != "swift" {
            session = startRime(config: config, bundle: bundle)
        }
        switch QuickEngineChoice.decide(override: override, rimeStarted: session != nil) {
        case .rime:
            if let session { return RimeInputMethod(session: session, config: config, id: id) }
            return swiftQuick(bundle: bundle)
        case .swift:
            return swiftQuick(bundle: bundle)
        }
    }

    private static func startRime(config: RimeSchemeConfig, bundle: Bundle) -> RimeSession? {
        #if DEBUG
        let began = DispatchTime.now().uptimeNanoseconds
        #endif
        let session: RimeSession?
        do {
            guard let shared = bundle.resourceURL?.appendingPathComponent("rime/shared", isDirectory: true) else {
                throw RimeError.initializeFailed
            }
            let user = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("rime/user", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let runtime = try RimeRuntime.start(
                RimePaths(sharedData: shared, prebuilt: shared.appendingPathComponent("build", isDirectory: true), userData: user))
            let made = try runtime.makeSession(schema: config.schema)
            if made.isHealthy(probeKey: config.probeKey) {
                session = made
            } else {
                log.error("rime health check failed")
                session = nil
            }
        } catch {
            // Event kind and error case only; the cases carry no typed text.
            log.error("rime start failed: \(String(describing: error), privacy: .public)")
            session = nil
        }
        #if DEBUG
        let ms = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        log.info("rime start \(session != nil ? "ok" : "failed", privacy: .public) in \(ms, privacy: .public) ms")
        #endif
        return session
    }

    private static func swiftQuick(bundle: Bundle) -> (any ChineseInputMethod)? {
        guard
            let url = bundle.url(forResource: "quick-table", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            let dictionary = try? QuickDictionary(tableText: text)
        else { return nil }
        return QuickInputMethod(dictionary: dictionary)
    }
}
