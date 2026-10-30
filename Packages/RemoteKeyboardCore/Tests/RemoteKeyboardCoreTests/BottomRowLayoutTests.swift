import XCTest
@testable import RemoteKeyboardCore

final class BottomRowLayoutTests: XCTestCase {
    private let gap = KeyboardMetrics.keyGap

    private func placement(_ key: BottomRowKey, in list: [BottomRowPlacement]) -> BottomRowPlacement? {
        list.first { $0.key == key }
    }

    func testChinesePageWithClearAndWithoutGlobe() {
        let width = 396.0
        let list = BottomRowLayout.placements(totalWidth: width, showsGlobe: false, showsClear: true)
        XCTAssertEqual(list.map(\.key), [.chineseEnglish, .symbols, .space, .clear, .returnKey])
        XCTAssertEqual(placement(.chineseEnglish, in: list), BottomRowPlacement(key: .chineseEnglish, x: 0, width: 56))
        XCTAssertEqual(placement(.symbols, in: list), BottomRowPlacement(key: .symbols, x: 62, width: 56))
        XCTAssertEqual(placement(.returnKey, in: list), BottomRowPlacement(key: .returnKey, x: width - 72, width: 72))
        // 重寫 sits between space and return, as wide as 中英 and 符號.
        XCTAssertEqual(placement(.clear, in: list), BottomRowPlacement(key: .clear, x: width - 72 - gap - 56, width: 56))
        // Space fills what is left, with one gap on each side.
        XCTAssertEqual(placement(.space, in: list), BottomRowPlacement(key: .space, x: 124, width: (width - 72 - gap - 56 - gap) - 124))
    }

    func testPagesWithoutClearHaveNoClearKey() {
        let list = BottomRowLayout.placements(totalWidth: 396, showsGlobe: false, showsClear: false)
        XCTAssertEqual(list.map(\.key), [.chineseEnglish, .symbols, .space, .returnKey])
        XCTAssertNil(placement(.clear, in: list))
        // Same geometry the bottom row had before 重寫 moved here: space runs up to return minus one gap.
        XCTAssertEqual(placement(.space, in: list), BottomRowPlacement(key: .space, x: 124, width: 396 - 72 - gap - 124))
    }

    func testGlobeShiftsEverythingRightByItsWidthAndGap() throws {
        let without = BottomRowLayout.placements(totalWidth: 396, showsGlobe: false, showsClear: true)
        let with = BottomRowLayout.placements(totalWidth: 396, showsGlobe: true, showsClear: true)
        XCTAssertEqual(with.map(\.key), [.globe, .chineseEnglish, .symbols, .space, .clear, .returnKey])
        XCTAssertEqual(placement(.globe, in: with), BottomRowPlacement(key: .globe, x: 0, width: 44))
        XCTAssertEqual(placement(.chineseEnglish, in: with)?.x, 50)
        XCTAssertEqual(placement(.symbols, in: with)?.x, 112)
        XCTAssertEqual(placement(.space, in: with)?.x, 174)
        let spaceWith = try XCTUnwrap(placement(.space, in: with))
        let spaceWithout = try XCTUnwrap(placement(.space, in: without))
        XCTAssertEqual(spaceWith.width, spaceWithout.width - 44 - gap, accuracy: 0.0001)
        // The right-hand keys do not move.
        XCTAssertEqual(placement(.clear, in: with), placement(.clear, in: without))
        XCTAssertEqual(placement(.returnKey, in: with), placement(.returnKey, in: without))
    }

    func testSpaceStaysPositiveOnTheNarrowestAndWidestPhones() {
        // The key area is the keyboard width minus 2 x 3 pt: 375 pt and 402 pt phones.
        for keyboardWidth in [375.0, 402.0] {
            let width = keyboardWidth - 2 * KeyboardMetrics.keyAreaSideInset
            for globe in [false, true] {
                for clear in [false, true] {
                    let list = BottomRowLayout.placements(totalWidth: width, showsGlobe: globe, showsClear: clear)
                    let space = placement(.space, in: list)
                    XCTAssertNotNil(space)
                    XCTAssertGreaterThan(space?.width ?? 0, 0, "\(keyboardWidth) globe \(globe) clear \(clear)")
                }
            }
        }
    }

    func testKeysNeverOverlapAndStayInsideTheRow() {
        let width = 369.0
        let list = BottomRowLayout.placements(totalWidth: width, showsGlobe: true, showsClear: true)
        for (left, right) in zip(list, list.dropFirst()) {
            XCTAssertEqual(right.x - (left.x + left.width), gap, accuracy: 0.0001, "\(left.key) to \(right.key)")
        }
        XCTAssertEqual(list.last.map { $0.x + $0.width }, width)
    }

    func testTooNarrowRowKeepsSpaceAtZeroWidth() {
        let list = BottomRowLayout.placements(totalWidth: 200, showsGlobe: true, showsClear: true)
        XCTAssertEqual(placement(.space, in: list)?.width, 0)
    }
}
