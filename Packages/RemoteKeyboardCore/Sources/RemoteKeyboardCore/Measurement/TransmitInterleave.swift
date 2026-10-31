#if DEBUG
import Foundation

/// Which of two waiting things the exit hands over next: a frame of a long `0x02` text, or a packet (a `0x03` pointer packet
/// in the product, a measurement probe here). Spec §8.2 rule 4.
///
/// - `.keyboard`: frames first; after every `ratio` frames handed while a packet waited, one packet.
/// - `.trackpad`: packets first; after every `ratio` packets handed while a frame waited, one frame, so a text that was
///   still on its way when the user switched to the touchpad keeps moving and is never starved.
/// - When only one side waits, only that side is sent, at full speed.
///
/// A choice changes nothing until `handed` is called, so a refusal by the radio leaves the rule where it was.
public struct TransmitInterleave: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case keyboard, trackpad }
    public enum Source: Equatable, Sendable { case frame, packet }

    /// Provisional: 4 of the favoured side per 1 of the other.
    public static let ratio = 4

    public var mode: Mode {
        didSet { if mode != oldValue { streak = 0 } }
    }
    /// Favoured items handed since the other side last got its turn, counted only while the other side waited.
    private var streak = 0

    public init(mode: Mode = .keyboard) { self.mode = mode }

    private var favoured: Source { mode == .keyboard ? .frame : .packet }

    public func choose(hasFrame: Bool, hasPacket: Bool) -> Source? {
        switch (hasFrame, hasPacket) {
        case (false, false): nil
        case (true, false): .frame
        case (false, true): .packet
        case (true, true):
            streak >= Self.ratio ? (favoured == .frame ? .packet : .frame) : favoured
        }
    }

    /// - Parameter otherWaiting: whether the other side had something waiting when this one was handed. The count only
    ///   goes up then, so a packet that arrives after a long stretch of frames still waits for at most `ratio` more.
    public mutating func handed(_ source: Source, otherWaiting: Bool = true) {
        if source == favoured {
            if otherWaiting { streak += 1 }
        } else {
            streak = 0
        }
    }
}
#endif
