import Foundation

/// Raises the weight of a hand-written list of colloquial words so each one ranks first for its initial-only
/// abbreviation (first character of every syllable code), above every word that is not on the list.
public enum ColloquialBoost {
    public struct MissingWords: Error, CustomStringConvertible {
        public var words: [String]
        public var description: String { "colloquial boost words not found in the dictionary: " + words.joined(separator: " ") }
    }

    public struct InvalidList: Error, CustomStringConvertible {
        public var singleCharacters: [String]
        public var duplicates: [String]
        public var description: String {
            "colloquial boost list problems; single characters: " + singleCharacters.joined(separator: " ")
                + "; duplicates: " + duplicates.joined(separator: " ")
        }
    }

    /// How a code is turned into the key a user can type as an abbreviation.
    public enum Style {
        /// Every letter can start an abbreviation: first letter of each syllable.
        case pinyin
        /// The schema only abbreviates initials. A syllable that starts with another key (a medial or a final)
        /// has to be typed in full, so it is keyed by the whole syllable without its tone key.
        case zhuyin
    }

    static let zhuyinInitialKeys = Set("1qaz2wsxedcrfv5tgbyhn")
    static let zhuyinToneKeys = Set("6347")

    public struct Result: Equatable {
        public var entries: [DictEntry]
        public var boosted: Int
    }

    /// One word per line; blank lines and lines starting with `#` are ignored.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func groupKey(_ code: String, style: Style) -> String {
        let syllables = code.split(separator: " ")
        let parts: [String] = syllables.map { syllable in
            guard let first = syllable.first else { return "" }
            switch style {
            case .pinyin: return String(first)
            case .zhuyin:
                if zhuyinInitialKeys.contains(first) { return String(first) }
                var full = syllable
                if let last = full.last, zhuyinToneKeys.contains(last) { full = full.dropLast() }
                return "<\(full)>"
            }
        }
        return "\(syllables.count)|" + parts.joined()
    }

    public static func apply(to entries: [DictEntry], list: [String], style: Style = .pinyin) throws -> Result {
        let listed = Set(list)
        var seen = Set<String>()
        let duplicates = list.filter { !seen.insert($0).inserted }
        let singles = list.filter { $0.count < 2 }
        if !duplicates.isEmpty || !singles.isEmpty { throw InvalidList(singleCharacters: singles, duplicates: duplicates) }
        let present = Set(entries.map(\.text))
        let missing = list.filter { !present.contains($0) }
        if !missing.isEmpty { throw MissingWords(words: missing) }

        var ceiling: [String: Int] = [:]  // highest weight among words that are not on the list
        for entry in entries where !listed.contains(entry.text) {
            let key = groupKey(entry.code, style: style)
            ceiling[key] = max(ceiling[key] ?? 0, entry.weight ?? 0)
        }
        var indexes: [String: [Int]] = [:]
        for (offset, entry) in entries.enumerated() where listed.contains(entry.text) { indexes[entry.text, default: []].append(offset) }

        var result = entries
        var boosted = 0
        // Later list words first, so an earlier word always ends above a later one that shares its key.
        for word in list.reversed() {
            for offset in indexes[word] ?? [] {
                let key = groupKey(result[offset].code, style: style)
                let old = result[offset].weight ?? 0
                let new = max(old, (ceiling[key] ?? 0) + 1)
                ceiling[key] = new
                if new != old { result[offset].weight = new; boosted += 1 }
            }
        }
        return Result(entries: MandarinDicts.finish(result), boosted: boosted)
    }
}
