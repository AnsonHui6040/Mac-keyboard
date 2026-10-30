#!/usr/bin/env swift
// Builds the Quick (速成) table from libcangjie's data/table.txt (Public Domain; see quick-table-LICENSE.txt).
//
// Usage: swift scripts/make-quick-table.swift <table.txt> <output quick-table.txt>
//
// table.txt has 15 space-separated columns per data line (README.table.md numbers them one lower, because the file
// carries a second character column):
//   1 character, 2 simplified form, 3 is Chinese, 4 in Big5, 5 in HKSCS (unused), 6-11 other flags,
//   12 Cangjie 3 codes, 13 Cangjie 5 codes (comma separated or NA), 14 short code, 15 ordering (higher = more common;
//   Big5 characters follow the Big5 order reversed, everything else is 0).
// Kept: Chinese characters in Big5 (characters that are only in HKSCS are left out). Quick code = first + last letter of a Cangjie 5 code (Cangjie 3 when the
// Cangjie 5 column is NA); a one-letter code stays as it is. One row per (code, character); under one code the higher
// ordering comes first, ties keep the file order. Output: `code<TAB>character` per line.
// Keep `quickCode` in line with QuickDictionary.quickCode(fromCangjie:).
import Foundation

func quickCode(_ cangjie: Substring) -> String? {
    guard !cangjie.isEmpty, cangjie.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return nil }
    guard cangjie.count > 1, let first = cangjie.first, let last = cangjie.last else { return String(cangjie) }
    return String([first, last])
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-quick-table.swift <table.txt> <output>\n".utf8))
    exit(2)
}
let text = try String(contentsOfFile: arguments[1], encoding: .utf8)

struct Row { let code: String; let character: String; let order: Int; let index: Int }
var rows: [Row] = []
var seen = Set<String>()
var index = 0
for line in text.split(separator: "\n") where !line.hasPrefix("#") {
    let columns = line.split(separator: " ", omittingEmptySubsequences: true)
    guard columns.count == 15 else {
        FileHandle.standardError.write(Data("unexpected column count \(columns.count): \(line)\n".utf8))
        exit(1)
    }
    guard columns[2] == "1", columns[3] == "1" else { continue }
    let cangjie = columns[12] != "NA" ? columns[12] : columns[11]
    let order = Int(columns[14]) ?? 0
    for code in cangjie.split(separator: ",") {
        guard let quick = quickCode(code) else { continue }
        let key = quick + "\t" + columns[0]
        if seen.insert(key).inserted {
            rows.append(Row(code: quick, character: String(columns[0]), order: order, index: index))
            index += 1
        }
    }
}
rows.sort { a, b in
    if a.code != b.code { return a.code < b.code }
    if a.order != b.order { return a.order > b.order }
    return a.index < b.index
}
let output = rows.map { "\($0.code)\t\($0.character)" }.joined(separator: "\n") + "\n"
try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
print("rows: \(rows.count)")
