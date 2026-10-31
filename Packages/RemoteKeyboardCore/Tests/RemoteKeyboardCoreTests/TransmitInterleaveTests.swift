#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

/// The exit rule that decides, when both a long text's 0x02 frames and a packet (0x03 or a measurement probe) wait,
/// which one goes next (spec §8.2 rule 4).
final class TransmitInterleaveTests: XCTestCase {
    /// Hands over `count` items while both sides always have something waiting.
    private func sequence(_ mode: TransmitInterleave.Mode, count: Int, hasFrame: Bool = true, hasPacket: Bool = true) -> [TransmitInterleave.Source] {
        var interleave = TransmitInterleave(mode: mode)
        var result: [TransmitInterleave.Source] = []
        for _ in 0..<count {
            guard let source = interleave.choose(hasFrame: hasFrame, hasPacket: hasPacket) else { break }
            interleave.handed(source)
            result.append(source)
        }
        return result
    }

    func testKeyboardModeGivesFramesFirstAndOnePacketAfterFour() {
        XCTAssertEqual(TransmitInterleave.ratio, 4)
        let result = sequence(.keyboard, count: 10)
        XCTAssertEqual(result, [.frame, .frame, .frame, .frame, .packet, .frame, .frame, .frame, .frame, .packet])
    }

    func testTrackpadModeGivesPacketsFirstAndOneFrameAfterFour() {
        let result = sequence(.trackpad, count: 10)
        XCTAssertEqual(result, [.packet, .packet, .packet, .packet, .frame, .packet, .packet, .packet, .packet, .frame])
    }

    func testTrackpadModeFramesStillAdvanceOneInFiveWhilePacketsAlwaysWait() {
        let result = sequence(.trackpad, count: 1_000)
        XCTAssertEqual(result.filter { $0 == .frame }.count, 200, "a long text is never starved while the touchpad sends")
    }

    func testTrackpadModeSendsFramesAtFullSpeedWhenNoPacketWaits() {
        let result = sequence(.trackpad, count: 50, hasPacket: false)
        XCTAssertEqual(result, Array(repeating: .frame, count: 50))
    }

    func testKeyboardModeSendsPacketsAtFullSpeedWhenNoFrameWaits() {
        let result = sequence(.keyboard, count: 50, hasFrame: false)
        XCTAssertEqual(result, Array(repeating: .packet, count: 50))
    }

    func testNothingWaitingChoosesNothing() {
        let interleave = TransmitInterleave(mode: .trackpad)
        XCTAssertNil(interleave.choose(hasFrame: false, hasPacket: false))
    }

    func testAChoiceThatWasNotHandedChangesNothing() {
        let interleave = TransmitInterleave(mode: .keyboard)
        // The radio refused: no `handed`, so the same item is chosen again.
        XCTAssertEqual(interleave.choose(hasFrame: true, hasPacket: true), .frame)
        XCTAssertEqual(interleave.choose(hasFrame: true, hasPacket: true), .frame)
    }

    func testTheCountRestartsWhenTheOtherSideWasHandedOrTheModeChanges() {
        var interleave = TransmitInterleave(mode: .keyboard)
        for _ in 0..<3 { interleave.handed(.frame) }
        interleave.mode = .trackpad
        XCTAssertEqual(interleave.choose(hasFrame: true, hasPacket: true), .packet, "a new mode starts a new count")
        for _ in 0..<4 { interleave.handed(.packet) }
        XCTAssertEqual(interleave.choose(hasFrame: true, hasPacket: true), .frame)
        interleave.handed(.frame)
        XCTAssertEqual(interleave.choose(hasFrame: true, hasPacket: true), .packet)
    }

    func testHandingTheFavouredSideWhileTheOtherIsEmptyDoesNotUseUpTheOthersTurn() {
        var interleave = TransmitInterleave(mode: .keyboard)
        for _ in 0..<10 { interleave.handed(.frame, otherWaiting: false) }
        // A packet appears: it waits for at most four more frames, as in the original rule.
        var frames = 0
        while interleave.choose(hasFrame: true, hasPacket: true) == .frame {
            interleave.handed(.frame)
            frames += 1
        }
        XCTAssertEqual(frames, 4)
    }
}
#endif
