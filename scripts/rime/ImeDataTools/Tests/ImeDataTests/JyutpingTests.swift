import XCTest
@testable import ImeData

final class JyutpingTests: XCTestCase {
    func testJyutpingEntries() {
        let lists = WordsHKLists.parse(
            charList: "Source,x\n我,ngo5\n嘅,ge2,ge3\nA,ei1\n係,hai6,V\n",
            wordList: "Source,x\n唔該,m4 goi1\nBB床*,bi4 bi1 cong4\n我哋,ngo5 dei6\n一二三,jat1 ji6\n多謝*,do1 ze6\n",
            charCount: "Source,x\n我,500\n嘅,900\n",
            wordCount: "Source,x\n唔該,40\n")
        let unihan = UnihanCantonese.parse("# c\nU+5605\tkCantonese\tge3\nU+5497\tkCantonese\tzo2\nU+4E00\tkCantonese\tjat1\nU+4E00\tkMandarin\tyī\n")
        let output = JyutpingDict.entries(lists, unihan: unihan, allowedCharacters: ["咗", "嘅"])
        XCTAssertEqual(output.entries.map { "\($0.code)|\($0.text)|\($0.weight!)" },
                       ["ge|嘅|900", "hai|係|1", "m goi|唔該|108", "ngo|我|500", "ngo dei|我哋|3", "zo|咗|1"])
        XCTAssertEqual(output.dropped, 1)  // 一二三: two syllables for three characters
    }
    func testUnihanSkipsCompatibilityIdeographs() {
        let unihan = UnihanCantonese.parse("U+6D34\tkCantonese\tping4\nU+2F907\tkCantonese\tbaan6\n")
        XCTAssertEqual(unihan, ["洴": ["ping4"]])
    }
}
