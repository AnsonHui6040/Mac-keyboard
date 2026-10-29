import ApplicationServices
import CoreGraphics
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// The mapping is pure and Escape goes through the posting seam; no AX call and no real event is made.
@MainActor
final class CompositionAdapterTests: XCTestCase {
    @MainActor private final class RecordingPoster: EventPosting {
        var batches: [[CGEvent]] = []
        func post(_ events: [CGEvent]) { batches.append(events) }
    }

    func testAttributeNameIsTheWebKitMarkerRangeConstant() {
        XCTAssertEqual(AXCompositionAdapter.markedRangeAttribute, "AXTextInputMarkedTextMarkerRange")
    }

    func testValueMeansComposing() {
        XCTAssertEqual(AXCompositionAdapter.state(error: .success, hasValue: true), .composing)
    }

    func testSupportedButEmptyMeansNotComposing() {
        XCTAssertEqual(AXCompositionAdapter.state(error: .success, hasValue: false), .notComposing)
        XCTAssertEqual(AXCompositionAdapter.state(error: .noValue, hasValue: false), .notComposing)
    }

    func testUnsupportedAndOtherErrorsAreUnknown() {
        let errors: [AXError] = [.attributeUnsupported, .cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented, .failure]
        for error in errors {
            XCTAssertEqual(AXCompositionAdapter.state(error: error, hasValue: false), .unknown, "\(error.rawValue)")
        }
    }

    func testMissingElementReadsAsUnknown() {
        XCTAssertEqual(AXCompositionAdapter(element: { nil }, poster: RecordingPoster()).state(), .unknown)
    }

    func testCancelBuildsAndPostsEscapeThroughTheSeam() {
        XCTAssertEqual(AXCompositionAdapter.escapeKey, 53)
        let poster = RecordingPoster()
        AXCompositionAdapter(element: { nil }, poster: poster).cancel()
        XCTAssertEqual(poster.batches.count, 1)
        XCTAssertEqual(poster.batches[0].map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(poster.batches[0].allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 53 })
        XCTAssertTrue(poster.batches[0].allSatisfy { $0.flags.isEmpty })
    }
}
