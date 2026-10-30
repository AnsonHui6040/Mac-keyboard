import XCTest
@testable import RemoteKeyboardCore

final class ModelImportPolicyTests: XCTestCase {
    private func decide(
        present: Bool, group: String?, local: String?, failed: String? = nil
    ) -> ModelImportPolicy.Action {
        ModelImportPolicy.decide(modelPresent: present, groupStamp: group, localStamp: local, failedStamp: failed)
    }

    func testMatchingStampsUseTheLocalModel() {
        XCTAssertEqual(decide(present: true, group: "a", local: "a"), .useLocal)
    }

    func testMissingModelWithGroupCopyImports() {
        XCTAssertEqual(decide(present: false, group: "a", local: nil), .importFromGroup)
    }

    func testChangedGroupStampImportsAgain() {
        XCTAssertEqual(decide(present: true, group: "b", local: "a"), .importFromGroup)
        XCTAssertEqual(decide(present: true, group: "b", local: nil), .importFromGroup)
    }

    func testFailedStampBacksOffUntilTheStampChanges() {
        XCTAssertEqual(decide(present: false, group: "a", local: nil, failed: "a"), .missing)
        XCTAssertEqual(decide(present: true, group: "a", local: "old", failed: "a"), .useLocal)
        XCTAssertEqual(decide(present: false, group: "b", local: nil, failed: "a"), .importFromGroup)
    }

    func testNoGroupCopyAndNoModelIsMissing() {
        XCTAssertEqual(decide(present: false, group: nil, local: nil), .missing)
    }

    func testGroupCopyDeletedDropsTheModelThatCameFromIt() {
        XCTAssertEqual(decide(present: true, group: nil, local: "a"), .dropLocal)
    }

    func testModelNotImportedFromTheGroupIsKeptWithoutGroupCopy() {
        XCTAssertEqual(decide(present: true, group: nil, local: nil), .useLocal)
    }
}
