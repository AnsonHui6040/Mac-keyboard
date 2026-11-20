import Foundation

/// One `BPMFBase.txt` line: character, bopomofo, pinyin (with tone digit), Daqian keys, category.
public struct BaseRow: Equatable, Sendable {
    public var line: Int
    public var character: String
    public var zhuyin: String
    public var pinyin: String
    public var keys: String
    public var category: String
}

public struct McBopomofoData: Sendable {
    public var base: [BaseRow]
    public var mappings: [[String]]  // word, syllable, syllable, ...
    public var occurrences: [String: Double]
    public var exclusions: [(key: String, value: String)]
    public var heterophony: [[String: Set<String>]]  // three tables: character -> readings

    private static func lines(_ text: String) -> [(number: Int, text: Substring)] {
        var result: [(Int, Substring)] = []
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.append((offset + 1, line))
        }
        return result
    }

    private static func columns(_ line: Substring) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    public static func parse(base: String, mappings: String, occurrences: String, exclusions: String,
                             heterophony: [String]) -> McBopomofoData {
        var baseRows: [BaseRow] = []
        for (number, line) in lines(base) {
            let c = columns(line)
            guard c.count >= 5 else { continue }
            baseRows.append(BaseRow(line: number, character: c[0], zhuyin: c[1], pinyin: c[2], keys: c[3], category: c[4]))
        }
        let mappingRows = lines(mappings).map { columns($0.text) }.filter { $0.count >= 2 }
        var occ: [String: Double] = [:]
        for (_, line) in lines(occurrences) {
            let c = columns(line)
            if c.count >= 2, let count = Double(c[1]), occ[c[0]] == nil { occ[c[0]] = count }
        }
        var exclusionRows: [(key: String, value: String)] = []
        for (_, line) in lines(exclusions) {
            let c = columns(line)
            if c.count >= 2 { exclusionRows.append((c[0], c[1])) }
        }
        let tables = (0..<3).map { index -> [String: Set<String>] in
            var table: [String: Set<String>] = [:]
            guard index < heterophony.count else { return table }
            for (_, line) in lines(heterophony[index]) {
                let c = columns(line)
                if c.count >= 2 { table[c[0], default: []].insert(c[1]) }
            }
            return table
        }
        return McBopomofoData(base: baseRows, mappings: mappingRows, occurrences: occ,
                              exclusions: exclusionRows, heterophony: tables)
    }

    public static func load(directory: URL) throws -> McBopomofoData {
        func read(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        return parse(base: try read("BPMFBase.txt"), mappings: try read("BPMFMappings.txt"),
                     occurrences: try read("phrase.occ"), exclusions: try read("exclusion.txt"),
                     heterophony: [try read("heterophony1.list"), try read("heterophony2.list"),
                                   try read("heterophony3.list")])
    }

    /// Corrected occurrence a(k): the raw count minus the raw count of every excluding phrase v (rule 3).
    func correctedOccurrence(_ key: String) -> Double {
        guard var value = occurrences[key] else { return 0.5 }
        for (k, v) in exclusions where k == key && v.contains(key) {
            if let other = occurrences[v] { value -= other }
        }
        return value < 1 ? 0.5 : value
    }

    /// Single-character weight with the three heterophony tables (rule 5).
    func characterWeight(_ character: String, reading: String) -> Int {
        let score = correctedOccurrence(character)
        func rounded(_ divisor: Double) -> Int { Int((score / divisor).rounded()) }
        let h = heterophony
        guard let first = h[0][character], !first.contains(reading) else { return max(1, rounded(1)) }
        guard let second = h[1][character] else { return 6 }
        if second.contains(reading) { return max(6, rounded(4.93)) }
        guard let third = h[2][character] else { return 6 }
        if third.contains(reading) { return max(6, rounded(24.3)) }
        return 6
    }

    func phraseWeight(_ word: String) -> Int {
        let score = correctedOccurrence(word) * pow(2.7, Double(word.count - 1))
        return max(1, Int(score.rounded()))
    }
}
