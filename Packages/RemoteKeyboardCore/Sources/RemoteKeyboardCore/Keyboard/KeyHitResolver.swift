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

    /// The index of the key closest to `point`. A point inside a key gives that key; otherwise the shortest distance
    /// from the point to a key rectangle decides. Equal distances take the earlier key. Nil when the list is empty
    /// or even the closest key is farther than `maxDistance`.
    public static func nearest(to point: HitPoint, in keys: [HitRect], maxDistance: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, key) in keys.enumerated() {
            let dx = max(key.x - point.x, 0, point.x - (key.x + key.width))
            let dy = max(key.y - point.y, 0, point.y - (key.y + key.height))
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance == 0 { return index }
            if let current = best, distance >= current.distance { continue }
            best = (index, distance)
        }
        guard let best, best.distance <= maxDistance else { return nil }
        return best.index
    }
}
