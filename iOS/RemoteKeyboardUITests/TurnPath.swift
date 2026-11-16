import CoreGraphics

/// Pure path generator for the unpredictable-turn strokes (testTurnStrokes). Test target only.
enum TurnPath {
    /// Deterministic PRNG: the same seed always gives the same path, so Bluetooth and Wi-Fi runs can be compared.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Up, down, left, right as screen steps (y grows downwards).
    static let directions: [CGVector] = [CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0)]

    /// End points of `segments` consecutive segments, each exactly `segmentLength` long along one axis, starting at `start`.
    /// A random direction that would leave `box` is replaced by its opposite (a direction may repeat). Every end point is inside `box`.
    static func make(seed: UInt64, segments: Int, segmentLength: CGFloat, box: CGRect, start: CGPoint) -> [CGPoint] {
        var rng = SplitMix64(seed: seed)
        var current = start
        var ends: [CGPoint] = []
        for _ in 0..<segments {
            let pick = Int(rng.next() % 4)
            // 0 up, 1 down, 2 left, 3 right: the opposite of 0 is 1 and of 2 is 3.
            let order = [pick, pick ^ 1, (pick ^ 2), (pick ^ 2) ^ 1]
            var moved = false
            for index in order {
                let d = directions[index]
                let next = CGPoint(x: current.x + d.dx * segmentLength, y: current.y + d.dy * segmentLength)
                if box.contains(next) {
                    current = next
                    moved = true
                    break
                }
            }
            precondition(moved, "the box is too small for a \(segmentLength) pt segment")
            ends.append(current)
        }
        return ends
    }

    /// The finger path as 60 Hz samples: touch-down at `start` (offset 0), then every `step` seconds a point on the way to the next
    /// segment end, the last sample of a segment being the end point exactly. Offsets are seconds from touch-down.
    static func samples(start: CGPoint, ends: [CGPoint], segmentDuration: Double, step: Double = 1.0 / 60.0) -> (points: [CGPoint], offsets: [Double]) {
        var points = [start]
        var offsets = [0.0]
        var from = start
        let pieces = max(1, Int((segmentDuration / step).rounded()))
        for (index, to) in ends.enumerated() {
            for piece in 1...pieces {
                let t = Double(piece) / Double(pieces)
                points.append(piece == pieces ? to : CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                offsets.append(Double(index) * segmentDuration + segmentDuration * t)
            }
            from = to
        }
        return (points, offsets)
    }
}
