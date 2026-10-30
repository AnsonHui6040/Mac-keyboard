import Foundation
import RemoteKeyboardCore
import os
#if canImport(MLKitDigitalInkRecognition)
@preconcurrency import MLKitCommon
@preconcurrency import MLKitDigitalInkRecognition
#endif

// The second of the two files that import Google ML Kit (the other is the extension's MLKitRecognizer). It downloads
// the `zh-Hani-TW` handwriting model in the host app, where the download works, and hands it to the keyboard through
// the App Group (see `HandwritingModelStore`). In the iOS Simulator ML Kit is not linked: the downloader then reports
// that downloading is only possible on a device. Logs carry counts, sizes and error codes only.

/// Downloads, copies and deletes the handwriting model; the settings page shows its state.
@MainActor
final class HandwritingModelDownloader: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        /// 0...1, or nil while the size is not known yet.
        case downloading(fraction: Double?)
        case copying
        /// Downloaded and copied for the keyboard; the size is that of the copy in the App Group.
        case ready(bytes: Int64)
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded

    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "handwriting")

    private var task: Task<Void, Never>?

    #if canImport(MLKitDigitalInkRecognition)
    /// A download with no progress for this long is given up.
    private static let stallSeconds = 60.0
    private static let pollInterval = Duration.milliseconds(300)
    /// The latest `mlkitModelDownloadDidFail` error, read by the polling loop.
    private var failure: NSError?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    #endif

    init() {
        refresh()
        #if canImport(MLKitDigitalInkRecognition)
        observeFailures()
        #endif
    }

    deinit {
        task?.cancel()
        #if canImport(MLKitDigitalInkRecognition)
        observers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .copying: true
        case .notDownloaded, .ready, .failed: false
        }
    }

    // MARK: State

    func refresh() {
        guard !isBusy else { return }
        if let bytes = HandwritingModelStore.groupCopySize() {
            state = .ready(bytes: bytes)
        } else if case .failed = state {
            // Keep the failure on screen until the next try.
        } else {
            state = .notDownloaded
        }
    }

    // MARK: Actions

    #if canImport(MLKitDigitalInkRecognition)

    func start() {
        guard !isBusy else { return }
        failure = nil
        state = .downloading(fraction: nil)
        task = Task { [weak self] in await self?.run() }
    }

    /// Deletes the model in the app and the copy for the keyboard. The keyboard's own copy goes away only when the
    /// keyboard is removed from the phone.
    func delete() {
        guard !isBusy else { return }
        task?.cancel()
        HandwritingModelStore.removeGroupCopy()
        guard let model = Self.model() else {
            state = .notDownloaded
            return
        }
        ModelManager.modelManager().deleteDownloadedModel(model) { [weak self] error in
            let code = error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
            Task { @MainActor in
                if let code {
                    Self.logger.error("model delete failed error=\(code, privacy: .public)")
                    self?.state = .failed("無法刪除模型")
                } else {
                    self?.state = .notDownloaded
                }
            }
        }
    }

    private func run() async {
        guard let model = Self.model() else {
            state = .failed("找不到手寫模型")
            return
        }
        let manager = ModelManager.modelManager()
        if !manager.isModelDownloaded(model) {
            // Background downloading needs a shared container in an app extension and stays off here as well.
            let conditions = ModelDownloadConditions(allowsCellularAccess: true, allowsBackgroundDownloading: false)
            let progress = manager.download(model, conditions: conditions)
            Self.logger.info("model download started")
            let started = Date()
            var lastCompleted = progress.completedUnitCount
            var lastChange = Date()
            while !manager.isModelDownloaded(model) {
                if Task.isCancelled {
                    progress.cancel()
                    return
                }
                if let failure {
                    state = .failed(Self.reason(for: failure))
                    return
                }
                if progress.completedUnitCount != lastCompleted {
                    lastCompleted = progress.completedUnitCount
                    lastChange = Date()
                } else if Date().timeIntervalSince(lastChange) > Self.stallSeconds {
                    progress.cancel()
                    Self.logger.error("model download stalled")
                    state = .failed("下載沒有進度，請確認網路後再試")
                    return
                }
                state = .downloading(fraction: progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                try? await Task.sleep(for: Self.pollInterval)
            }
            Self.logger.info("model download finished seconds=\(Date().timeIntervalSince(started), privacy: .public)")
        }
        state = .copying
        let copied = await Task.detached(priority: .userInitiated) { () -> Result<Int64, HandwritingModelStore.StoreError> in
            do {
                return .success(try HandwritingModelStore.exportToGroup().bytes)
            } catch let error as HandwritingModelStore.StoreError {
                return .failure(error)
            } catch {
                return .failure(.failed("複製失敗"))
            }
        }.value
        switch copied {
        case .success(let bytes): state = .ready(bytes: bytes)
        case .failure(let error): state = .failed(error.description)
        }
    }

    private static func model() -> DigitalInkRecognitionModel? {
        guard let identifier = try? DigitalInkRecognitionModelIdentifier.from(languageTag: HandwritingModelStore.languageTag) else {
            return nil
        }
        return DigitalInkRecognitionModel(modelIdentifier: identifier)
    }

    private func observeFailures() {
        let token = NotificationCenter.default.addObserver(
            forName: .mlkitModelDownloadDidFail, object: nil, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[ModelDownloadUserInfoKey.error.rawValue] as? NSError
            MainActor.assumeIsolated {
                self?.failure = error ?? NSError(domain: "HandwritingModel", code: -1)
                if let error {
                    Self.logger.error("model download failed error=\(error.domain, privacy: .public) \(error.code, privacy: .public)")
                }
            }
        }
        observers = [token]
    }

    /// A reason in Taiwan Chinese for the common failures; anything else shows the error domain and code.
    private static func reason(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return "沒有網路連線"
            case NSURLErrorTimedOut: return "連線逾時"
            default: break
            }
        }
        return "下載失敗（\(error.domain) \(error.code)）"
    }

    #else

    func start() { state = .failed("模擬器無法下載手寫模型，請在實體 iPhone 上操作") }

    func delete() {
        HandwritingModelStore.removeGroupCopy()
        state = .notDownloaded
    }

    #endif
}
