import CoreGraphics
import XCTest
@testable import RemoteKeyboardCore

/// Answers per call from a script and records what it was asked.
private actor FakeRecognizer: HandwritingRecognizing {
    struct Call: Equatable {
        var strokes: [[InkPoint]]
        var preContext: String
    }

    private(set) var calls: [Call] = []
    private var answers: [[String]]
    private let failure: Error?

    init(answers: [[String]] = [], failure: Error? = nil) {
        self.answers = answers
        self.failure = failure
    }

    func recognize(strokes: [[InkPoint]], in size: CGSize, preContext: String) async throws -> [String] {
        calls.append(Call(strokes: strokes, preContext: preContext))
        if let failure { throw failure }
        return answers.isEmpty ? [] : answers.removeFirst()
    }
}

@MainActor
private final class Clock {
    var blocked = false
}

@MainActor
final class HandwritingSessionTests: XCTestCase {
    private let size = CGSize(width: 300, height: 150)

    private func ink(_ count: Int = 1) -> [[InkPoint]] {
        (0..<count).map { index in
            [InkPoint(x: 10, y: Double(index), t: 1), InkPoint(x: 20, y: Double(index), t: 1.1)]
        }
    }

    private func makeSession(
        _ recognizer: FakeRecognizer, clock: Clock = Clock()
    ) -> HandwritingSession {
        let session = HandwritingSession(sleep: { [clock] _ in
            if clock.blocked { try await Task.sleep(for: .seconds(60)) }
        })
        session.setRecognizer(recognizer)
        return session
    }

    func testStrokeEndRecognisesAfterTheDebounceAndShowsCandidates() async {
        let recognizer = FakeRecognizer(answers: [["=", "香", "秤"]])
        let session = makeSession(recognizer)
        var changes = 0
        session.onChange = { changes += 1 }
        session.strokesEnded(ink(), size: size)
        await session.settle()
        XCTAssertEqual(session.candidates, ["香", "秤"])
        XCTAssertEqual(changes, 1)
    }

    func testSpaceWhileRecognitionIsPendingRecognisesTheCurrentInkFirst() async {
        let clock = Clock()
        let recognizer = FakeRecognizer(answers: [["十", "千"], ["香", "秤"]])
        let session = makeSession(recognizer, clock: clock)
        session.strokesEnded(ink(1), size: size)
        await session.settle()
        XCTAssertEqual(session.candidates, ["十", "千"])

        clock.blocked = true  // the debounce for the second stroke has not fired yet
        session.strokesEnded(ink(2), size: size)
        let output = await session.handle(.space)
        XCTAssertEqual(output.commit, "香", "older candidates must not be committed")
        let calls = await recognizer.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.strokes.count, 2)
        XCTAssertEqual(session.candidates, [])
    }

    func testSpaceAfterASingleStrokeCharacterIsNotDropped() async {
        let clock = Clock()
        clock.blocked = true
        let recognizer = FakeRecognizer(answers: [["一", "二"]])
        let session = makeSession(recognizer, clock: clock)
        session.strokesEnded(ink(1), size: size)
        let output = await session.handle(.space)
        XCTAssertEqual(output.commit, "一")
        XCTAssertNil(output.passThrough)
    }

    func testReturnWhilePendingRecognisesThenClearsWithoutNewline() async {
        let clock = Clock()
        clock.blocked = true
        let recognizer = FakeRecognizer(answers: [["香"]])
        let session = makeSession(recognizer, clock: clock)
        session.strokesEnded(ink(), size: size)
        let output = await session.handle(.returnKey)
        XCTAssertNil(output.commit)
        XCTAssertNil(output.passThrough)
        XCTAssertEqual(session.candidates, [])
    }

    func testCandidateTapIsImmediateAndDoesNotRecogniseAgain() async {
        let recognizer = FakeRecognizer(answers: [["香", "秤"]])
        let session = makeSession(recognizer)
        session.strokesEnded(ink(), size: size)
        await session.settle()
        let output = await session.handle(.selectCandidate(1))
        XCTAssertEqual(output.commit, "秤")
        let calls = await recognizer.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testBackspaceWhilePendingClearsInkWithoutRecognising() async {
        let clock = Clock()
        clock.blocked = true
        let recognizer = FakeRecognizer(answers: [["香"]])
        let session = makeSession(recognizer, clock: clock)
        var cleared = 0
        session.onClearInk = { cleared += 1 }
        session.strokesEnded(ink(), size: size)
        XCTAssertTrue(session.consumesBackspace)
        let output = await session.handle(.backspace)
        XCTAssertNil(output.passThrough)
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(session.consumesBackspace)
        let calls = await recognizer.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testNewStrokeDropsALateResultForOlderInk() async {
        let recognizer = FakeRecognizer(answers: [["十"]])
        let session = makeSession(recognizer)
        session.strokesEnded(ink(1), size: size)
        session.strokeBegan()
        await session.settle()
        XCTAssertEqual(session.candidates, [])
    }

    func testSpaceWithoutInkPassesThrough() async {
        let session = makeSession(FakeRecognizer())
        let output = await session.handle(.space)
        XCTAssertEqual(output.passThrough, .space)
    }

    func testPreContextCarriesTheCommittedCharacters() async {
        let recognizer = FakeRecognizer(answers: [["一"], ["二"], ["三"], ["四"]])
        let session = makeSession(recognizer)
        for _ in 0..<3 {
            session.strokesEnded(ink(), size: size)
            await session.settle()
            _ = await session.handle(.space)
        }
        session.strokesEnded(ink(), size: size)
        await session.settle()
        let calls = await recognizer.calls
        XCTAssertEqual(calls.map(\.preContext), ["", "一", "一二", "一二三"])
    }

    func testPreContextIsCappedAtTwentyAndClearedByResetHistory() async {
        let long = String(repeating: "香", count: 19) + "港" + "你" + "好"  // 22 characters
        let recognizer = FakeRecognizer(answers: [[long], ["一"], ["二"]])
        let session = makeSession(recognizer)
        session.strokesEnded(ink(), size: size)
        await session.settle()
        _ = await session.handle(.selectCandidate(0))
        session.strokesEnded(ink(), size: size)
        await session.settle()
        var calls = await recognizer.calls
        XCTAssertEqual(calls.last?.preContext, String(long.suffix(20)))
        XCTAssertEqual(calls.last?.preContext.count, 20)

        session.resetHistory()
        session.strokesEnded(ink(), size: size)
        await session.settle()
        calls = await recognizer.calls
        XCTAssertEqual(calls.last?.preContext, "")
    }

    func testRecognizerErrorIsReportedAndLeavesNoCandidates() async {
        struct Boom: Error {}
        let recognizer = FakeRecognizer(failure: Boom())
        let session = makeSession(recognizer)
        var reported = 0
        session.onRecognizerError = { _ in reported += 1 }
        session.strokesEnded(ink(), size: size)
        await session.settle()
        XCTAssertEqual(reported, 1)
        XCTAssertEqual(session.candidates, [])
        let output = await session.handle(.backspace)
        XCTAssertNil(output.passThrough, "the ink is still there, so delete clears it first")
    }

    func testInkWrittenBeforeTheRecognizerArrivesIsRecognisedWhenItDoes() async {
        let recognizer = FakeRecognizer(answers: [["香"]])
        let session = HandwritingSession(sleep: { _ in })
        session.strokesEnded(ink(), size: size)
        session.setRecognizer(recognizer)
        await session.settle()
        XCTAssertEqual(session.candidates, ["香"])
    }

    func testDeactivateDropsEverything() async {
        let recognizer = FakeRecognizer(answers: [["香"]])
        let session = makeSession(recognizer)
        session.strokesEnded(ink(), size: size)
        await session.settle()
        session.deactivate()
        XCTAssertEqual(session.candidates, [])
        XCTAssertFalse(session.hasRecognizer)
    }
}
