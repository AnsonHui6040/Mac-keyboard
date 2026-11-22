import RemoteKeyboardCore
import XCTest
@testable import RimeEngine

/// Colloquial words boosted in the pinyin and zhuyin dictionaries (ime/sources/colloquial-boost.txt), on the real schemes.
final class RimeColloquialBoostTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func output(_ schema: String, _ config: RimeSchemeConfig, _ id: ChineseInputMethodID, _ keys: String) throws -> IMEOutput {
        var method = RimeInputMethod(session: try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: schema),
                                     config: config, id: id)
        var out = IMEOutput()
        for key in keys { out = method.handle(.key(String(key))) }
        return out
    }

    private func pinyin(_ keys: String) throws -> IMEOutput { try output("pinyin", .pinyin, .pinyin, keys) }
    private func zhuyin(_ keys: String) throws -> IMEOutput { try output("zhuyin", .zhuyin, .zhuyin, keys) }

    func testPinyinInitialsPutTheColloquialWordFirst() throws {
        XCTAssertEqual(try pinyin("nh").candidates.first, "你好")
        XCTAssertEqual(try pinyin("xx").candidates.first, "謝謝")
        XCTAssertEqual(try pinyin("bkq").candidates.first, "不客氣")
    }

    /// ㄋ is key s and ㄏ is key c, so 你好 is "sc".
    func testZhuyinInitialsPutTheColloquialWordFirst() throws {
        XCTAssertEqual(try zhuyin("sc").candidates.first, "你好")
        // 謝謝 = ㄒㄧㄝˋ ㄒㄧㄝˋ, initial key "vv"
        XCTAssertEqual(try zhuyin("vv").candidates.first, "謝謝")
    }

    private func boostWords() throws -> [String] {
        let text = try String(contentsOf: Self.repoRoot.appending(path: "ime/sources/colloquial-boost.txt"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    /// (text, code) rows of a generated dictionary.
    private func rows(_ name: String) throws -> [(String, String)] {
        let text = try String(contentsOf: Self.repoRoot.appending(path: "ime/rime/\(name).dict.yaml"), encoding: .utf8)
        guard let body = text.range(of: "\n...\n") else { return [] }
        return text[body.upperBound...].split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            return c.count >= 2 ? (String(c[0]), String(c[1])) : nil
        }
    }

    /// Records the first candidate of every list word typed with its full code. With RK_FULLCODE_OUT set, the lines
    /// are written there (used to compare before and after a dictionary regeneration). Every list word must be typable.
    func testFullCodesOfEveryListWordAreTypable() throws {
        let words = Set(try boostWords())
        var lines: [String] = []
        for (schema, config, id, name, joiner) in [("pinyin", RimeSchemeConfig.pinyin, ChineseInputMethodID.pinyin, "pinyin", ""),
                                                   ("zhuyin", .zhuyin, .zhuyin, "zhuyin", "")] {
            for (text, code) in try rows(name) where words.contains(text) {
                let keys = code.split(separator: " ").joined(separator: joiner)
                let out = try output(schema, config, id, keys)
                XCTAssertFalse(out.candidates.isEmpty, "\(schema) \(keys) (\(text)) has no candidates")
                lines.append("\(schema)\t\(text)\t\(keys)\t\(out.candidates.first ?? "")")
            }
        }
        XCTAssertGreaterThanOrEqual(lines.count, words.count)
        if let path = ProcessInfo.processInfo.environment["RK_FULLCODE_OUT"] {
            try (lines.sorted().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
