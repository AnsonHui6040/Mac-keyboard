/// The keys of the bottom row, left to right.
public enum BottomRowKey: Equatable, Sendable {
    case globe
    case chineseEnglish
    case symbols
    case space
    /// 重寫, only on the Chinese (handwriting) page.
    case clear
    case returnKey
}

/// Where one bottom-row key sits, in the row's own coordinates.
public struct BottomRowPlacement: Equatable, Sendable {
    public let key: BottomRowKey
    public let x: Double
    public let width: Double

    public init(key: BottomRowKey, x: Double, width: Double) {
        self.key = key
        self.x = x
        self.width = width
    }
}

/// Bottom row geometry. Pure, so the widths can be tested without UIKit. Fixed keys keep their width; space takes
/// what is left, and never goes below zero.
public enum BottomRowLayout {
    public static let globeWidth: Double = 44
    /// 中英, 符號 and 重寫.
    public static let wideKeyWidth: Double = 56
    public static let returnWidth: Double = 72

    /// Keys left to right (D19): globe (when iOS asks for it), 符號, 中英, space, 重寫 (Chinese page only), return.
    public static func placements(
        totalWidth: Double, showsGlobe: Bool, showsClear: Bool, gap: Double = KeyboardMetrics.keyGap
    ) -> [BottomRowPlacement] {
        var result: [BottomRowPlacement] = []
        var x = 0.0
        func place(_ key: BottomRowKey, width: Double) {
            result.append(BottomRowPlacement(key: key, x: x, width: width))
            x += width + gap
        }
        if showsGlobe { place(.globe, width: globeWidth) }
        place(.symbols, width: wideKeyWidth)
        place(.chineseEnglish, width: wideKeyWidth)
        // Space ends one gap before the first key on its right.
        let rightWidth = returnWidth + (showsClear ? gap + wideKeyWidth : 0)
        let spaceWidth = max(0, totalWidth - x - rightWidth - gap)
        place(.space, width: spaceWidth)
        if showsClear { place(.clear, width: wideKeyWidth) }
        result.append(BottomRowPlacement(key: .returnKey, x: totalWidth - returnWidth, width: returnWidth))
        return result
    }
}
