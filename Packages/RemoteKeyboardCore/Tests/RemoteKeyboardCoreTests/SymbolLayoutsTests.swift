import XCTest
@testable import RemoteKeyboardCore

final class SymbolLayoutsTests: XCTestCase {
    func testEnglishLayerOneMatchesApple() {
        let layers = SymbolLayouts.layers(for: .english)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0][0], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(layers[0][1], ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
        XCTAssertEqual(layers[0][2], [".", ",", "?", "!", "'"])
        XCTAssertEqual(layers[1][0], ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
        XCTAssertEqual(layers[1][1], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"])
        XCTAssertEqual(layers[1][2], [".", ",", "?", "!", "'"])
    }

    func testChineseLayerOneIsFullWidth() {
        let layers = SymbolLayouts.layers(for: .chinese)
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[0][0], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(layers[0][1], ["「", "」", "『", "』", "（", "）", "：", "；", "、", "～"])
        XCTAssertEqual(layers[0][2], ["，", "。", "？", "！", "…"])
        for row in layers[0][1...] {
            for key in row {
                let value = key.unicodeScalars.first!.value
                let cjkPunctuation = (0x3000...0x303F).contains(value)
                let fullWidth = (0xFF00...0xFFEF).contains(value)
                XCTAssertTrue(cjkPunctuation || fullWidth || value == 0x2026, "\(key) is not full width")
            }
        }
    }

    func testChineseLayersTwoAndThreeEqualEnglish() {
        let english = SymbolLayouts.layers(for: .english)
        let chinese = SymbolLayouts.layers(for: .chinese)
        XCTAssertEqual(chinese[1], english[0])
        XCTAssertEqual(chinese[2], english[1])
    }

    func testEveryKeyIsSingleGrapheme() {
        for origin in [SymbolOrigin.english, .chinese] {
            for layer in SymbolLayouts.layers(for: origin) {
                for row in layer {
                    for key in row { XCTAssertEqual(key.count, 1, "\(key)") }
                }
            }
        }
    }

    func testNoDuplicateKeyWithinLayer() {
        for origin in [SymbolOrigin.english, .chinese] {
            for layer in SymbolLayouts.layers(for: origin) {
                let keys = layer.flatMap { $0 }
                XCTAssertEqual(Set(keys).count, keys.count)
            }
        }
    }

    func testRowShapeAndLayerKeyTitles() {
        for origin in [SymbolOrigin.english, .chinese] {
            for layer in SymbolLayouts.layers(for: origin) {
                XCTAssertEqual(layer.map(\.count), [10, 10, 5])
            }
            XCTAssertEqual(SymbolLayouts.layerKeyTitles(for: origin).count, SymbolLayouts.layers(for: origin).count)
        }
        XCTAssertEqual(SymbolLayouts.layerKeyTitles(for: .english), ["#+=", "123"])
        XCTAssertEqual(SymbolLayouts.layerKeyTitles(for: .chinese), ["半形", "#+=", "全形"])
    }
}
