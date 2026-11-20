// make-ime-dicts --src <build/rime/src> --wordshk <ime/sources/wordshk> --out <folder> [--lock <versions.lock>]
// Writes quick5, cangjie5, zhuyin and pinyin .dict.yaml into <folder>.
import Foundation
import ImeData

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var options: [String: String] = [:]
var args = CommandLine.arguments.dropFirst()
while let key = args.popFirst() {
    guard key.hasPrefix("--"), let value = args.popFirst() else {
        fail("usage: make-ime-dicts --src <dir> --wordshk <dir> --out <dir> [--lock <file>]", code: 2)
    }
    options[key] = value
}
guard let src = options["--src"], let wordshk = options["--wordshk"], let out = options["--out"] else {
    fail("usage: make-ime-dicts --src <dir> --wordshk <dir> --out <dir> [--lock <file>]", code: 2)
}
let lockPath = options["--lock"] ?? "scripts/rime/versions.lock"

do {
    let table = try CangjieTable.parse(String(contentsOfFile: src + "/libcangjie-table.txt", encoding: .utf8))
    let frequency = try WordsHKFrequency.parse(String(contentsOfFile: wordshk + "/charcount.csv", encoding: .utf8))
    print("words.hk frequency rows: \(frequency.count)")
    guard frequency.count >= 6000 else { fail("words.hk frequency table too small: \(frequency.count)") }
    let lock = try String(contentsOfFile: lockPath, encoding: .utf8)
    guard let tableURL = VersionsLock.url(named: "libcangjie-table", in: lock) else {
        fail("libcangjie-table not found in \(lockPath)")
    }
    let sources = [
        "Cangjie table of libcangjie (Public Domain): \(tableURL)",
        "Character frequency: words.hk charcount.csv (public domain; https://words.hk/faiman/analysis/)",
        "Order per code: Big5 characters first (libcangjie order), then HKSCS characters (words.hk frequency)."
    ]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for (name, entries) in [("quick5", CangjieDicts.quick5(table, frequency: frequency)),
                            ("cangjie5", CangjieDicts.cangjie5(table, frequency: frequency))] {
        let text = DictWriter.render(name: name, sort: "original", sources: sources, entries: entries)
        try text.write(toFile: out + "/\(name).dict.yaml", atomically: true, encoding: .utf8)
        print("\(name): \(entries.count) rows")
    }

    let mcbopomofo = try McBopomofoData.load(directory: URL(fileURLWithPath: src + "/mcbopomofo"))
    guard let mcURL = VersionsLock.url(named: "mcbopomofo/BPMFBase.txt", in: lock) else {
        fail("mcbopomofo/BPMFBase.txt not found in \(lockPath)")
    }
    let mcSources = [
        "Data: McBopomofo 3.1.1 Source/Data (MIT): \(mcURL)",
        "The McBopomofo word list derives from libtabe (BSD); weights follow McBopomofo's frequency rules.",
        "License texts: McBopomofo MIT, libtabe BSD; see LICENSE-data.txt."
    ]
    let zhuyin = MandarinDicts.zhuyin(mcbopomofo)
    let pinyin = MandarinDicts.pinyin(mcbopomofo)
    for (name, output) in [("zhuyin", zhuyin), ("pinyin", pinyin)] {
        let text = DictWriter.render(name: name, sort: "by_weight", sources: mcSources, entries: output.entries)
        try text.write(toFile: out + "/\(name).dict.yaml", atomically: true, encoding: .utf8)
    }
    print("zhuyin entries=\(zhuyin.entries.count) dropped=\(zhuyin.dropped) key_mismatches=\(zhuyin.keyMismatches)")
    for m in zhuyin.mismatches { print("  key mismatch line \(m.line): zhuyin=\(m.zhuyin) keys=\(m.given)") }
    print("pinyin entries=\(pinyin.entries.count) dropped=\(pinyin.dropped)")
    let utf8Rows = mcbopomofo.base.filter { $0.category == "utf8" && Han.isAllHan($0.character) }
    print("utf8 category single characters: rows=\(utf8Rows.count) distinct=\(Set(utf8Rows.map(\.character)).count)")
} catch {
    fail("make-ime-dicts failed: \(error)")
}
