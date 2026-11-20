import Foundation
import os
import RemoteKeyboardCore
import RimeEngine

/// Provides the Quick (速成) input method: librime when it starts and passes its health check, otherwise the Swift
/// engine. The load runs once; callers that arrive while it runs wait for the same result. Every librime call runs on
/// the main actor. Nothing typed is ever logged: only the start time and whether it worked.
@MainActor
final class QuickEngineLoader {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "rime")
    private static let schema = "quick5"

    private let loader: OnceLoader<(any ChineseInputMethod)?>
    private var pendingDrop: Task<Void, Never>?

    init(bundle: Bundle) {
        loader = OnceLoader { await MainActor.run { Self.load(bundle: bundle) } }
    }

    /// The Quick engine, or nil when neither engine could load.
    func method() async -> (any ChineseInputMethod)? {
        await pendingDrop?.value
        return await loader.value()
    }

    /// The keyboard went away: forget the engine so its librime session is released (the runtime stays).
    func drop() {
        let previous = pendingDrop
        let loader = self.loader
        pendingDrop = Task {
            await previous?.value
            await loader.reset()
        }
    }

    // MARK: Loading

    private static func load(bundle: Bundle) -> (any ChineseInputMethod)? {
        #if DEBUG
        let override = MeasureLaunchConfig.read().quickEngine
        #else
        let override: String? = nil
        #endif
        var session: RimeSession?
        if override != "swift" {
            session = startRime(bundle: bundle)
        }
        switch QuickEngineChoice.decide(override: override, rimeStarted: session != nil) {
        case .rime:
            if let session { return RimeInputMethod(session: session) }
            return swiftQuick(bundle: bundle)
        case .swift:
            return swiftQuick(bundle: bundle)
        }
    }

    private static func startRime(bundle: Bundle) -> RimeSession? {
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
            let made = try runtime.makeSession(schema: schema)
            if made.isHealthy(probeKey: "a") {
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
