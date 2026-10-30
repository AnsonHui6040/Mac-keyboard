import Foundation

public enum QuickDictionaryError: Error, Equatable, Sendable {
    /// A table line is not `code<TAB>character` with a one or two letter lowercase code. `line` counts from 1.
    case malformedLine(Int)
}

/// The Quick (速成) table: input code (one or two letters) to characters, most common first. The table text has one
/// `code<TAB>character` per line; characters under one code keep the order of the file.
public struct QuickDictionary: Sendable {
    private let table: [String: [String]]

    public init(tableText: String) throws {
        var table: [String: [String]] = [:]
        var number = 0
        for line in tableText.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty, Self.isValidCode(fields[0]) else {
                throw QuickDictionaryError.malformedLine(number)
            }
            table[String(fields[0]), default: []].append(String(fields[1]))
        }
        self.table = table
    }

    /// The characters for a code, best first; empty for an unknown code.
    public func candidates(for code: String) -> [String] {
        table[code] ?? []
    }

    /// The Quick code of a Cangjie code: its first letter plus its last letter (a one-letter code stays as it is).
    /// Nil when the text is not a lowercase Cangjie code. `scripts/make-quick-table.swift` applies the same rule.
    public static func quickCode(fromCangjie code: String) -> String? {
        guard !code.isEmpty, code.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return nil }
        guard code.count > 1, let first = code.first, let last = code.last else { return code }
        return String([first, last])
    }

    private static func isValidCode(_ text: Substring) -> Bool {
        (1...2).contains(text.utf8.count) && text.utf8.allSatisfy { $0 >= 97 && $0 <= 122 }
    }
}
