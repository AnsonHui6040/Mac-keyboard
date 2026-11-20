import Foundation

public struct LayoutKeyFrame: Equatable, Sendable {
    public var x: Double
    public var width: Double

    public init(x: Double, width: Double) {
        self.x = x
        self.width = width
    }
}

/// Places the keys of a layout. The widest row (sum of key widths; on a tie the one with more keys) fixes the unit
/// width so it fills the line; every row is then centred.
public enum KeyboardLayoutGeometry {
    private static func units(_ row: [LayoutKey]) -> Double { row.reduce(0) { $0 + ($1.width ?? 1) } }

    public static func frames(_ layout: KeyboardLayout, width: Double, gap: Double) -> [[LayoutKeyFrame]] {
        guard let base = layout.rows.max(by: { a, b in
            let (ua, ub) = (units(a), units(b))
            return ua != ub ? ua < ub : a.count < b.count
        }) else { return [] }
        let unit = (width - Double(base.count - 1) * gap) / units(base)
        return layout.rows.map { row in
            let total = units(row) * unit + Double(row.count - 1) * gap
            var x = (width - total) / 2
            return row.map { key in
                let keyWidth = (key.width ?? 1) * unit
                defer { x += keyWidth + gap }
                return LayoutKeyFrame(x: x, width: keyWidth)
            }
        }
    }

    public static func height(rows: Int) -> Double {
        guard rows > 0 else { return 0 }
        return Double(rows) * KeyboardMetrics.keyRowHeight + Double(rows - 1) * KeyboardMetrics.rowGap
    }
}
