import CoreGraphics
import Foundation
import RemoteKeyboardCore
import os
#if canImport(MLKitDigitalInkRecognition)
@preconcurrency import MLKitCommon
@preconcurrency import MLKitDigitalInkRecognition
#endif

// One of the two files that import Google ML Kit (the other is the host app's HandwritingModelDownloader). ML Kit has
// no arm64 iOS Simulator slice, so the Podfile links it for devices only; without it (`canImport` false) this file
// compiles to a stub that reports the model as present and recognises nothing.
//
// Nothing here logs ink, candidates or text; only counts, durations and error codes.

enum MLKitHandwriting {
    #if canImport(MLKitDigitalInkRecognition)
    static let isLinked = true
    #else
    static let isLinked = false
    #endif

    /// Whether this process (the extension) already has the model in its own ML Kit directory.
    static func isModelDownloaded() -> Bool {
        #if canImport(MLKitDigitalInkRecognition)
        guard let identifier = try? DigitalInkRecognitionModelIdentifier.from(languageTag: HandwritingModelStore.languageTag) else {
            return false
        }
        return ModelManager.modelManager().isModelDownloaded(DigitalInkRecognitionModel(modelIdentifier: identifier))
        #else
        return true
        #endif
    }
}

#if canImport(MLKitDigitalInkRecognition)

/// Lets exactly one of the recognizer's callback and the deadline resume the continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

actor MLKitRecognizer: HandwritingRecognizing {
    /// More than the 9 candidates the input method keeps, because non-Han results are dropped afterwards.
    private static let maxResults = 12
    /// A call that has not answered by then throws, so a hung ML Kit call never blocks the actor for good.
    private static let deadlineSeconds = 3.0
    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "handwriting")

    private let recognizer: DigitalInkRecognizer

    /// nil when ML Kit does not know the language tag.
    init?() {
        guard let identifier = try? DigitalInkRecognitionModelIdentifier.from(languageTag: HandwritingModelStore.languageTag) else {
            return nil
        }
        let options = DigitalInkRecognizerOptions(model: DigitalInkRecognitionModel(modelIdentifier: identifier))
        options.maxResultCount = Int32(Self.maxResults)
        recognizer = DigitalInkRecognizer.digitalInkRecognizer(options: options)
    }

    func recognize(strokes: [[InkPoint]], in size: CGSize, preContext: String) async throws -> [String] {
        guard let origin = strokes.first(where: { !$0.isEmpty })?.first?.t else { return [] }
        // ML Kit wants milliseconds; only the differences matter, so they are taken from the first point.
        let inkStrokes = strokes.filter { !$0.isEmpty }.map { stroke in
            Stroke(points: stroke.map { point in
                StrokePoint(x: Float(point.x), y: Float(point.y), t: Int(max(0, (point.t - origin) * 1000).rounded()))
            })
        }
        let ink = Ink(strokes: inkStrokes)
        let context = DigitalInkRecognitionContext(
            preContext: String(preContext.suffix(20)),
            writingArea: WritingArea(width: Float(size.width), height: Float(size.height)))
        let started = ContinuousClock.now
        let outcome: Result<[String], NSError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            recognizer.recognize(ink: ink, context: context) { @Sendable result, error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(returning: .failure(error as NSError))
                } else {
                    continuation.resume(returning: .success(result?.candidates.map(\.text) ?? []))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.deadlineSeconds) {
                guard once.claim() else { return }
                continuation.resume(returning: .failure(NSError(domain: "HandwritingRecognizer", code: -2)))
            }
        }
        let elapsed = started.duration(to: .now)
        switch outcome {
        case .success(let texts):
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            Self.logger.debug("recognize strokes=\(inkStrokes.count, privacy: .public) candidates=\(texts.count, privacy: .public) ms=\(milliseconds, privacy: .public)")
            return texts
        case .failure(let error):
            Self.logger.error("recognize failed domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
            // No model in this process any more (not loaded, or damaged): the keyboard re-imports it.
            if !MLKitHandwriting.isModelDownloaded() { throw HandwritingRecognitionError.modelUnavailable }
            throw error
        }
    }
}

#else

/// Simulator stand-in: no ML Kit, so nothing is ever recognised.
actor MLKitRecognizer: HandwritingRecognizing {
    init?() {}

    func recognize(strokes: [[InkPoint]], in size: CGSize, preContext: String) async throws -> [String] { [] }
}

#endif
