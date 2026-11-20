import Foundation

public struct CangjieRow: Equatable, Sendable {
    public var character: String
    public var isBig5: Bool
    public var codes: [String]
    public var order: Int

    public init(character: String, isBig5: Bool, codes: [String], order: Int) {
        self.character = character
        self.isBig5 = isBig5
        self.codes = codes
        self.order = order
    }
}

/// libcangjie `data/table.txt`: 15 space separated columns
/// (char simp zh big5 hkscs zhuyin kanji hira kata punct symbol cj3 cj5 short order).
public enum CangjieTable {
    public static func parse(_ text: String) throws -> [CangjieRow] {
        var rows: [CangjieRow] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count == 15 else { throw ImeDataError.badLine(offset + 1) }
            guard columns[2] == "1", columns[3] == "1" || columns[4] == "1" else { continue }
            let cangjie = columns[12] != "NA" ? columns[12] : columns[11]
            let codes = cangjie.split(separator: ",").filter { $0.utf8.allSatisfy { $0 >= 97 && $0 <= 122 } }
            rows.append(CangjieRow(character: String(columns[0]), isBig5: columns[3] == "1",
                                   codes: codes.map(String.init), order: Int(columns[14]) ?? 0))
        }
        return rows
    }
}

public enum CangjieDicts {
    public static func cangjie5(_ rows: [CangjieRow], frequency: [String: Int]) -> [DictEntry] {
        build(rows, frequency: frequency, mapCode: { $0 })
    }

    /// Quick code = first and last letter of the Cangjie code (a one-letter code stays as it is).
    public static func quick5(_ rows: [CangjieRow], frequency: [String: Int]) -> [DictEntry] {
        build(rows, frequency: frequency, mapCode: { code in
            guard code.count > 1, let first = code.first, let last = code.last else { return code }
            return String([first, last])
        })
    }

    private struct Item {
        var code: String
        var text: String
        var isBig5: Bool
        var rank: Int  // libcangjie order for Big5, words.hk count for HKSCS; higher first
        var index: Int
    }

    /// U7: per code, Big5 characters first (higher libcangjie order first), then HKSCS characters (higher words.hk
    /// count first); ties keep file order. One entry per (code, character), the first occurrence.
    private static func build(_ rows: [CangjieRow], frequency: [String: Int], mapCode: (String) -> String) -> [DictEntry] {
        var items: [Item] = []
        // String equality is canonical: U+FA0C/U+FA0D collapse into U+5140/U+55C0 and are dropped (2 rows),
        // matching the old Swift Quick table; keying by scalars would insert them mid-Big5 and break Quick parity.
        var seen = Set<String>()
        for row in rows {
            for cangjie in row.codes {
                let code = mapCode(cangjie)
                guard seen.insert(code + "\t" + row.character).inserted else { continue }
                items.append(Item(code: code, text: row.character, isBig5: row.isBig5,
                                  rank: row.isBig5 ? row.order : (frequency[row.character] ?? 0), index: items.count))
            }
        }
        items.sort { a, b in
            if a.code != b.code { return a.code.utf8.lexicographicallyPrecedes(b.code.utf8) }
            if a.isBig5 != b.isBig5 { return a.isBig5 }
            if a.rank != b.rank { return a.rank > b.rank }
            return a.index < b.index
        }
        return items.map { DictEntry(text: $0.text, code: $0.code, weight: nil) }
    }
}
