import CoreGraphics
import Foundation

/// The Mac cursor's speed curve (trackpad spec §10, provisional): `g(v) = g0 + (gmax − g0) · v² / (v² + v0²)`, with `v`
/// the finger's speed in points per second.
public enum PointerAcceleration {
    public static let baseGain = 1.25
    public static let maxGain = 3.5
    public static let kneeSpeed = 550.0
    public static let minDtSeconds = 0.005
    public static let maxDtSeconds = 0.150

    public static func gain(speed v: Double) -> Double {
        let v2 = v * v
        return baseGain + (maxGain - baseGain) * v2 / (v2 + kneeSpeed * kneeSpeed)
    }

    /// `dt` of a packet (tenths of a millisecond) as seconds, clamped to 5 to 150 ms so a first packet or one after a long
    /// stall does not read as an extreme speed.
    public static func seconds(fromTenthsOfMs tenths: UInt16) -> Double {
        min(max(Double(tenths) * 0.0001, minDtSeconds), maxDtSeconds)
    }

    /// The cursor movement in Mac points for a packet's displacement.
    public static func scaled(dxSixteenths: Int16, dySixteenths: Int16, dtTenthsOfMs: UInt16) -> (dx: Double, dy: Double) {
        let dx = Double(dxSixteenths) / 16, dy = Double(dySixteenths) / 16
        let speed = hypot(dx, dy) / seconds(fromTenthsOfMs: dtTenthsOfMs)
        let gain = gain(speed: speed)
        return (dx * gain, dy * gain)
    }
}

/// Keeps the cursor on a screen. The screens are given as the rectangles of the global (Quartz) space.
public enum PointerScreenClamp {
    /// The nearest point of the union of `rects`. A point exactly on the far edge of a rectangle is outside it, so the
    /// nearest valid point there is one point inside. With no rectangle the point is returned as it is.
    public static func clamp(_ point: CGPoint, to rects: [CGRect]) -> CGPoint {
        if rects.contains(where: { $0.contains(point) }) { return point }
        var best: CGPoint?
        var bestDistance = Double.infinity
        for rect in rects where rect.width >= 1 && rect.height >= 1 {
            let candidate = CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
            let distance = hypot(Double(candidate.x - point.x), Double(candidate.y - point.y))
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best ?? point
    }
}
