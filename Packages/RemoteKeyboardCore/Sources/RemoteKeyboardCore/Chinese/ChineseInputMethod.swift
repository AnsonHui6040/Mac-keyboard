import CoreGraphics
import Foundation

/// The Chinese input methods the keyboard knows. The host App saves the user's choice under `AppGroup.Key.chineseMethod`.
public enum ChineseInputMethodID: String, Codable, CaseIterable, Sendable {
    case handwriting
    case quick

    /// Decodes the persisted raw value; anything missing or unknown is nil (the resolver then picks a default).
    public static func stored(rawValue: String?) -> ChineseInputMethodID? {
        rawValue.flatMap(ChineseInputMethodID.init(rawValue:))
    }
}

/// What the keyboard feeds an input method. Key and ink events are separate cases so a new method (Cangjie, Zhuyin,
/// Jyutping) only needs its own implementation and a `ChineseInputMethodID` case.
public enum IMEInput: Equatable, Sendable {
    /// A letter key of a code-based method.
    case key(String)
    case shift
    case backspace
    case space
    case returnKey
    /// The user chose the candidate at this index.
    case selectCandidate(Int)
    /// A handwriting engine finished recognising the current ink; best candidate first.
    case recognized([String])
    /// Throw away the composition (ink, input code, candidates).
    case clear
}

/// What the input method answers. `commit` goes to the `InputRouter` as typed text (Local writes it into the field,
/// Remote follows instant or draft). `passThrough` means the method did not handle the key: treat it as a normal key.
public struct IMEOutput: Equatable, Sendable {
    public var commit: String?
    /// The input code being composed, empty for handwriting.
    public var composing: String
    public var candidates: [String]
    public var passThrough: KeyAction?
    /// Quick: a one-shot Shift is waiting for the next letter (the Shift key is drawn from this).
    public var shift: Bool

    public init(
        commit: String? = nil, composing: String = "", candidates: [String] = [], passThrough: KeyAction? = nil,
        shift: Bool = false
    ) {
        self.commit = commit
        self.composing = composing
        self.candidates = candidates
        self.passThrough = passThrough
        self.shift = shift
    }
}

public protocol ChineseInputMethod: Sendable {
    var id: ChineseInputMethodID { get }
    mutating func handle(_ input: IMEInput) -> IMEOutput
    mutating func reset()
}

/// One sampled touch point: position in the writing area's own coordinates and the touch time in seconds
/// (`UITouch.timestamp`, so only differences matter).
public struct InkPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var t: TimeInterval

    public init(x: Double, y: Double, t: TimeInterval) {
        self.x = x
        self.y = y
        self.t = t
    }
}

/// Turns ink into candidate text. The keyboard's engine (Google ML Kit Digital Ink) implements it; tests use a fake.
/// `size` is the writing area; `preContext` is the text committed just before (at most 20 characters, memory only,
/// never logged), which helps the engine tell similar shapes apart.
public protocol HandwritingRecognizing: Sendable {
    func recognize(strokes: [[InkPoint]], in size: CGSize, preContext: String) async throws -> [String]
}

public enum HandwritingRecognitionError: Error, Equatable, Sendable {
    /// The engine could not run because its model is not loaded or is damaged.
    case modelUnavailable
}

/// Which strings count as Chinese characters. The general ML Kit model also returns symbols and digits (it answered
/// "=" for 二 and "+" for 十), so candidates are filtered with this.
public enum HanCharacters {
    private static let ranges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
        0x4E00...0x9FFF,  // CJK Unified Ideographs
        0xF900...0xFAFF,  // CJK Compatibility Ideographs
        0x20000...0x323AF,  // Extensions B to H
        0x2F800...0x2FA1F  // CJK Compatibility Ideographs Supplement
    ]

    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
    }

    /// True when the string is not empty and every scalar is a Han character.
    public static func isAllHan(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isHan)
    }

    /// Keeps the Han-only strings, in order, without repeats.
    public static func filter(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        return candidates.filter { isAllHan($0) && seen.insert($0).inserted }
    }
}
