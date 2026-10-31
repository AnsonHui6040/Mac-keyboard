public struct HitPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HitRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Decides which key a touch in the empty space between keys belongs to. Pure, so it can be tested without UIKit.
public enum KeyHitResolver {
    /// How far a touch may be from a key and still count: one key row height. Row 2 is inset by half a key, so its
    /// left and right edges are about 20 pt from the first and last key; a smaller reach would leave them dead.
    public static let defaultMaxDistance: Double = KeyboardMetrics.keyRowHeight

    /// Fingers land systematically below the key they aim at (Henze et al., 2011 and 2012). A touch in the empty
    /// space is therefore read this many points higher. 3 pt moves the middle of the 12 pt row gap down to 9 pt below
    /// the upper row, so the gap is shared 9 : 3 in favour of the upper row.
    public static let defaultTouchYOffset: Double = 3

    /// The index of the key closest to `point`. A point inside a key gives that key, with no correction. Otherwise
    /// the key closest to the point moved up by `touchYOffset` decides, but only if it is within `maxDistance` of
    /// the real touch. Equal distances take the earlier key. Nil when the list is empty or no key qualifies.
    public static func nearest(
        to point: HitPoint, in keys: [HitRect], maxDistance: Double, touchYOffset: Double = defaultTouchYOffset
    ) -> Int? {
        if let inside = keys.firstIndex(where: { distance(from: point, to: $0) == 0 }) { return inside }
        let corrected = HitPoint(x: point.x, y: point.y - touchYOffset)
        var best: (index: Int, distance: Double)?
        for (index, key) in keys.enumerated() {
            let d = distance(from: corrected, to: key)
            if let current = best, d >= current.distance { continue }
            best = (index, d)
        }
        guard let best, distance(from: point, to: keys[best.index]) <= maxDistance else { return nil }
        return best.index
    }

    /// The shortest distance from `point` to the rectangle; 0 inside or on its edge.
    private static func distance(from point: HitPoint, to key: HitRect) -> Double {
        let dx = max(key.x - point.x, 0, point.x - (key.x + key.width))
        let dy = max(key.y - point.y, 0, point.y - (key.y + key.height))
        return (dx * dx + dy * dy).squareRoot()
    }
}
