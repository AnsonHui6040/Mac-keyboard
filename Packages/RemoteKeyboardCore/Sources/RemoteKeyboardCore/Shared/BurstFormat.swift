import Foundation

/// What a burst run left in the target document, as numbers only (never the text).
public struct BurstReport: Equatable, Sendable {
    /// Line numbers in `1...expected` that never appeared, ascending.
    public let missing: [Int]
    /// Line numbers that appeared more than once, ascending, each listed once.
    public let duplicated: [Int]
    /// Line numbers whose first appearance came after a larger number, ascending.
    public let outOfOrder: [Int]

    public init(missing: [Int], duplicated: [Int], outOfOrder: [Int]) {
        self.missing = missing
        self.duplicated = duplicated
        self.outOfOrder = outOfOrder
    }

    public var isClean: Bool { missing.isEmpty && duplicated.isEmpty && outOfOrder.isEmpty }
}

/// The T15 burst: `n` lines of `#n`, numbered from 1, typed into a document and checked afterwards.
public enum BurstFormat {
    /// One line of the burst, newline included.
    public static func line(_ n: Int) -> String { "#\(n)\n" }

    /// Reads `text` line by line. A line counts only when it is exactly `#` and ASCII digits (a trailing `\r` is
    /// tolerated); anything else, and numbers outside `1...count`, is ignored.
    public static func verify(_ text: String, expected count: Int) -> BurstReport {
        var seen: [Int: Int] = [:]
        var outOfOrder: [Int] = []
        var highest = 0
        // Split on bytes: "\r\n" is one Character in Swift, so a Character split would miss CRLF line ends.
        for raw in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let n = number(in: raw), n >= 1, n <= count else { continue }
            seen[n, default: 0] += 1
            guard seen[n] == 1 else { continue }
            if n < highest { outOfOrder.append(n) } else { highest = n }
        }
        let missing = count >= 1 ? (1...count).filter { seen[$0] == nil } : []
        let duplicated = seen.filter { $0.value > 1 }.keys.sorted()
        return BurstReport(missing: missing, duplicated: duplicated, outOfOrder: outOfOrder.sorted())
    }

    private static func number(in line: Substring.UTF8View) -> Int? {
        var body = line
        if body.last == 0x0D { body = body.dropLast() }
        guard body.first == 0x23 else { return nil }
        let digits = body.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}
