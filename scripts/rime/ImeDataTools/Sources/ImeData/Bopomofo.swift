import Foundation

/// Standard (Daqian) keyboard layout: `keys[i]` types `symbols[i]`. Tones: ˊ 6, ˇ 3, ˋ 4, ˙ 7 (first tone has no key).
public enum BopomofoKeys {
    public static let keys = "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347"
    public static let symbols = "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙"

    private static let table: [Character: Character] = Dictionary(
        uniqueKeysWithValues: zip(symbols, keys))

    /// Keys for one syllable; nil when any character is not a bopomofo symbol or tone mark.
    public static func keys(for syllable: String) -> String? {
        var out = ""
        for symbol in syllable {
            guard let key = table[symbol] else { return nil }
            out.append(key)
        }
        return out.isEmpty ? nil : out
    }
}
