import Foundation

public struct KeyMismatch: Equatable, Sendable {
    public var line: Int
    public var zhuyin: String
    public var given: String
}

public struct MandarinOutput: Equatable {
    public var entries: [DictEntry]
    public var dropped: Int
    public var keyMismatches: Int
    public var mismatches: [KeyMismatch] = []
}

public enum MandarinDicts {
    public static func zhuyin(_ data: McBopomofoData) -> MandarinOutput {
        var items: [DictEntry] = []
        var dropped = 0
        var mismatches: [KeyMismatch] = []
        for row in data.base where Han.isAllHan(row.character) {
            guard let code = BopomofoKeys.keys(for: row.zhuyin) else { dropped += 1; continue }
            if code != row.keys { mismatches.append(KeyMismatch(line: row.line, zhuyin: row.zhuyin, given: row.keys)) }
            items.append(DictEntry(text: row.character, code: code,
                                   weight: data.characterWeight(row.character, reading: row.zhuyin)))
        }
        for mapping in data.mappings {
            let word = mapping[0]
            guard Han.isAllHan(word), data.occurrences[word] != nil else { continue }
            let syllables = Array(mapping.dropFirst())
            let codes = syllables.compactMap(BopomofoKeys.keys(for:))
            guard syllables.count == word.count, codes.count == syllables.count else { dropped += 1; continue }
            items.append(DictEntry(text: word, code: codes.joined(separator: " "), weight: data.phraseWeight(word)))
        }
        return MandarinOutput(entries: finish(items), dropped: dropped, keyMismatches: mismatches.count,
                              mismatches: mismatches)
    }

    public static func pinyin(_ data: McBopomofoData) -> MandarinOutput {
        var bySyllable: [String: String] = [:]
        for row in data.base where bySyllable[row.zhuyin] == nil { bySyllable[row.zhuyin] = stripTone(row.pinyin) }
        var items: [DictEntry] = []
        var dropped = 0
        for row in data.base where Han.isAllHan(row.character) {
            items.append(DictEntry(text: row.character, code: stripTone(row.pinyin),
                                   weight: data.characterWeight(row.character, reading: row.zhuyin)))
        }
        for mapping in data.mappings {
            let word = mapping[0]
            guard Han.isAllHan(word), data.occurrences[word] != nil else { continue }
            let syllables = Array(mapping.dropFirst())
            let codes = syllables.compactMap { bySyllable[$0] }
            guard syllables.count == word.count, codes.count == syllables.count else { dropped += 1; continue }
            items.append(DictEntry(text: word, code: codes.joined(separator: " "), weight: data.phraseWeight(word)))
        }
        return MandarinOutput(entries: finish(items), dropped: dropped, keyMismatches: 0)
    }

    private static func stripTone(_ pinyin: String) -> String {
        String(pinyin.reversed().drop(while: { $0.isNumber }).reversed())
    }

    /// One entry per (text, code) with the largest weight; sorted by code, weight descending, text.
    private static func finish(_ items: [DictEntry]) -> [DictEntry] {
        var best: [String: DictEntry] = [:]
        for item in items {
            let key = item.code + "\t" + item.text
            if let old = best[key], (old.weight ?? 0) >= (item.weight ?? 0) { continue }
            best[key] = item
        }
        return best.values.sorted { a, b in
            if a.code != b.code { return a.code.utf8.lexicographicallyPrecedes(b.code.utf8) }
            if a.weight != b.weight { return (a.weight ?? 0) > (b.weight ?? 0) }
            return a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
        }
    }
}
