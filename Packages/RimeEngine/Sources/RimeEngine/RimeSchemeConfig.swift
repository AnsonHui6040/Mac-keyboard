import RemoteKeyboardCore

/// How `RimeInputMethod` treats one librime scheme: which keys it takes, how long the code may get and how the
/// code is shown while composing.
public struct RimeSchemeConfig: Sendable, Equatable {
    public enum Composing: Sendable, Equatable {
        /// Show the input code as Cangjie radicals.
        case cangjieRadicals
        /// Show librime's preedit, already formatted by the scheme's `preedit_format`.
        case preedit
        /// Show librime's preedit, replacing the parts that are still key characters (syllable not finished) with
        /// the key's face. Converted characters and Bopomofo stay as they are.
        case preeditWithKeyLabels([Character: String])
    }

    public var schema: String
    public var keys: Set<Character>
    public var maxCodeLength: Int
    public var composing: Composing
    public var probeKey: Character

    public init(schema: String, keys: Set<Character>, maxCodeLength: Int, composing: Composing, probeKey: Character) {
        self.schema = schema
        self.keys = keys
        self.maxCodeLength = maxCodeLength
        self.composing = composing
        self.probeKey = probeKey
    }

    private static let letters = Set("abcdefghijklmnopqrstuvwxyz")

    // Daqian layout. A copy of ImeDataTools' `BopomofoKeys` (that package is macOS only, so RimeEngine cannot use it).
    private static let zhuyinKeys = "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347"
    private static let zhuyinSymbols = "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙"

    public static let quick5 = RimeSchemeConfig(
        schema: "quick5", keys: letters, maxCodeLength: 2, composing: .cangjieRadicals, probeKey: "a")
    public static let cangjie5 = RimeSchemeConfig(
        schema: "cangjie5", keys: letters, maxCodeLength: 5, composing: .cangjieRadicals, probeKey: "a")
    public static let zhuyin = RimeSchemeConfig(
        schema: "zhuyin", keys: Set(zhuyinKeys), maxCodeLength: 60,
        composing: .preeditWithKeyLabels(
            Dictionary(uniqueKeysWithValues: zip(zhuyinKeys, zhuyinSymbols.map { String($0) }))),
        probeKey: "j")
    public static let pinyin = RimeSchemeConfig(
        schema: "pinyin", keys: letters, maxCodeLength: 60, composing: .preedit, probeKey: "a")
    public static let jyutping = RimeSchemeConfig(
        schema: "jyutping", keys: letters, maxCodeLength: 60, composing: .preedit, probeKey: "m")

    /// The scheme for a keyed method; nil for handwriting.
    public static func forMethod(_ id: ChineseInputMethodID) -> RimeSchemeConfig? {
        switch id {
        case .handwriting: return nil
        case .quick: return .quick5
        case .cangjie: return .cangjie5
        case .zhuyin: return .zhuyin
        case .jyutping: return .jyutping
        case .pinyin: return .pinyin
        }
    }
}
