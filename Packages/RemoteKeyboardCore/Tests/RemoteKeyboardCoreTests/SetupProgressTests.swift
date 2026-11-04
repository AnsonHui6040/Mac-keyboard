import XCTest
@testable import RemoteKeyboardCore

final class SetupProgressTests: XCTestCase {
    func testStepsAreInOrder() {
        let progress = SetupProgress(bluetoothAllowed: false, isPaired: false, keyboardReady: false)
        XCTAssertEqual(progress.steps.map(\.step), [.bluetooth, .pairing, .keyboard])
    }

    func testNothingDoneIsNotComplete() {
        let progress = SetupProgress(bluetoothAllowed: false, isPaired: false, keyboardReady: false)
        XCTAssertEqual(progress.steps.map(\.isDone), [false, false, false])
        XCTAssertFalse(progress.isComplete)
    }

    func testEachFlagMapsToItsOwnStep() {
        XCTAssertEqual(
            SetupProgress(bluetoothAllowed: true, isPaired: false, keyboardReady: false).steps.map(\.isDone),
            [true, false, false])
        XCTAssertEqual(
            SetupProgress(bluetoothAllowed: false, isPaired: true, keyboardReady: false).steps.map(\.isDone),
            [false, true, false])
        XCTAssertEqual(
            SetupProgress(bluetoothAllowed: false, isPaired: false, keyboardReady: true).steps.map(\.isDone),
            [false, false, true])
    }

    func testTwoOfThreeIsNotComplete() {
        XCTAssertFalse(SetupProgress(bluetoothAllowed: true, isPaired: true, keyboardReady: false).isComplete)
        XCTAssertFalse(SetupProgress(bluetoothAllowed: true, isPaired: false, keyboardReady: true).isComplete)
    }

    func testAllDoneIsComplete() {
        let progress = SetupProgress(bluetoothAllowed: true, isPaired: true, keyboardReady: true)
        XCTAssertTrue(progress.steps.allSatisfy(\.isDone))
        XCTAssertTrue(progress.isComplete)
    }

    // MARK: Last link result

    private func progress(paired: Bool = true, last: LastLinkResult?) -> SetupProgress {
        SetupProgress(bluetoothAllowed: true, isPaired: paired, keyboardReady: true, lastLink: last)
    }

    func testNoLastLinkIsNoProblem() {
        XCTAssertNil(progress(last: nil).connectionProblem)
        XCTAssertTrue(progress(last: nil).isComplete)
    }

    func testConnectedIsNoProblem() {
        XCTAssertNil(progress(last: .connected).connectionProblem)
        XCTAssertTrue(progress(last: .connected).isComplete)
    }

    func testAuthFailedIsAProblemAndNotComplete() {
        XCTAssertEqual(progress(last: .authFailed).connectionProblem, .authFailed)
        XCTAssertFalse(progress(last: .authFailed).isComplete)
    }

    func testUnreachableIsAProblemAndNotComplete() {
        XCTAssertEqual(progress(last: .unreachable).connectionProblem, .unreachable)
        XCTAssertFalse(progress(last: .unreachable).isComplete)
    }

    func testUnpairedHidesTheProblem() {
        XCTAssertNil(progress(paired: false, last: .authFailed).connectionProblem)
        XCTAssertNil(progress(paired: false, last: .unreachable).connectionProblem)
    }

    func testProblemDoesNotChangeTheThreeSteps() {
        XCTAssertEqual(progress(last: .unreachable).steps, progress(last: nil).steps)
    }

    func testClearingTheResultClearsTheProblem() {
        // Re-pairing and 解除配對 both store nil.
        XCTAssertNil(progress(last: nil).connectionProblem)
        XCTAssertTrue(progress(last: nil).isComplete)
    }
}
