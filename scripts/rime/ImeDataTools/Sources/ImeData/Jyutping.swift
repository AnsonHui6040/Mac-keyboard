import Foundation

/// words.hk lists. Every row is `text,reading[,reading…]` (the count files hold `text,count`); the first row of each
/// file is a `Source,<url>` header and is skipped.
public struct WordsHKLists: Sendable {
    public var characters: [(text: String, readings: [String])]
    public var words: [(text: String, readings: [String])]
    public var characterCount: [String: Int]
    public var wordCount: [String: Int]

    public static func parse(charList: String, wordList: String, charCount: String, wordCount: String) -> WordsHKLists {
        func readings(_ csv: String) -> [(text: String, readings: [String])] {
            CSV.rows(csv).dropFirst().compactMap { row in
                guard let text = row.first, row.count >= 2 else { return nil }
                return (text, Array(row.dropFirst()))
            }
        }
        return WordsHKLists(characters: readings(charList), words: readings(wordList),
                            characterCount: WordsHKFrequency.parse(charCount),
                            wordCount: WordsHKFrequency.parse(wordCount))
    }
}

/// Unihan `kCantonese` readings: `U+XXXX<TAB>kCantonese<TAB>reading reading`.
public enum UnihanCantonese {
    public static func parse(_ readingsText: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in readingsText.split(separator: "\n") where line.hasPrefix("U+") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[1] == "kCantonese",
                  let value = UInt32(fields[0].dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { continue }
            // Compatibility ideographs normalise to another character in Swift String comparison; their readings
            // would leak onto that character, so they are skipped.
            if (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value) { continue }
            let readings = fields[2].split(separator: " ").map(String.init)
            result[String(Character(scalar)), default: []].append(contentsOf: readings)
        }
        return result
    }
}

public struct JyutpingOutput: Equatable {
    public var entries: [DictEntry]
    public var dropped: Int
}

public enum JyutpingDict {
    /// Words get weight = max(1, round(count × 2.7^(length − 1))): the longer match outranks its single characters.
    static let lengthFactor = 2.7

    public static func entries(_ lists: WordsHKLists, unihan: [String: [String]],
                               allowedCharacters: Set<String>) -> JyutpingOutput {
        var items: [DictEntry] = []
        var dropped = 0
        var listed = Set<String>()
        for row in lists.characters where Han.isAllHan(row.text) {
            listed.insert(row.text)
            for reading in row.readings {
                guard let code = strippedSyllable(reading) else { continue }
                items.append(DictEntry(text: row.text, code: code, weight: lists.characterCount[row.text] ?? 1))
            }
        }
        for character in allowedCharacters where !listed.contains(character) {
            for reading in unihan[character] ?? [] {
                guard let code = strippedSyllable(reading) else { continue }
                items.append(DictEntry(text: character, code: code, weight: 1))
            }
        }
        for row in lists.words where Han.isAllHan(row.text) && !row.text.hasSuffix("*") && row.text.unicodeScalars.count >= 2 {
            let length = row.text.unicodeScalars.count
            let count = lists.wordCount[row.text] ?? 1
            let weight = max(1, Int((Double(count) * pow(lengthFactor, Double(length - 1))).rounded()))
            for reading in row.readings {
                let syllables = reading.split(separator: " ", omittingEmptySubsequences: false)
                let codes = syllables.compactMap { strippedSyllable(String($0)) }
                guard syllables.count == length, codes.count == length else { dropped += 1; continue }
                items.append(DictEntry(text: row.text, code: codes.joined(separator: " "), weight: weight))
            }
        }
        return JyutpingOutput(entries: MandarinDicts.finish(items), dropped: dropped)
    }

    /// `^[a-z]+[1-6]$` -> the syllable without its tone digit.
    private static func strippedSyllable(_ reading: String) -> String? {
        let bytes = Array(reading.utf8)
        guard bytes.count >= 2, let tone = bytes.last, tone >= 49 && tone <= 54,
              bytes.dropLast().allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return nil }
        return String(decoding: bytes.dropLast(), as: UTF8.self)
    }
}
