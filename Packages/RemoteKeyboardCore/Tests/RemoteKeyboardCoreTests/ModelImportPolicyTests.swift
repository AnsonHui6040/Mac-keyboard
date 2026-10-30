import XCTest
@testable import RemoteKeyboardCore

final class ModelImportPolicyTests: XCTestCase {
    private func decide(
        present: Bool, group: ModelImportPolicy.GroupCopy, local: String?, failed: String? = nil
    ) -> ModelImportPolicy.Action {
        ModelImportPolicy.decide(modelPresent: present, group: group, localStamp: local, failedStamp: failed)
    }

    func testMatchingStampsUseTheLocalModel() {
        XCTAssertEqual(decide(present: true, group: .complete(stamp: "a"), local: "a"), .useLocal)
    }

    func testMissingModelWithGroupCopyImports() {
        XCTAssertEqual(decide(present: false, group: .complete(stamp: "a"), local: nil), .importFromGroup)
    }

    func testChangedGroupStampImportsAgain() {
        XCTAssertEqual(decide(present: true, group: .complete(stamp: "b"), local: "a"), .importFromGroup)
        XCTAssertEqual(decide(present: true, group: .complete(stamp: "b"), local: nil), .importFromGroup)
    }

    func testFailedStampBacksOffUntilTheStampChanges() {
        XCTAssertEqual(decide(present: false, group: .complete(stamp: "a"), local: nil, failed: "a"), .missing)
        XCTAssertEqual(decide(present: true, group: .complete(stamp: "a"), local: "old", failed: "a"), .useLocal)
        XCTAssertEqual(decide(present: false, group: .complete(stamp: "b"), local: nil, failed: "a"), .importFromGroup)
    }

    func testNoGroupFolderAndNoModelIsMissing() {
        XCTAssertEqual(decide(present: false, group: .absent, local: nil), .missing)
    }

    func testOnlyATrulyAbsentGroupFolderDropsTheModelThatCameFromIt() {
        XCTAssertEqual(decide(present: true, group: .absent, local: "a"), .dropLocal)
    }

    func testModelNotImportedFromTheGroupIsKeptWithoutGroupFolder() {
        XCTAssertEqual(decide(present: true, group: .absent, local: nil), .useLocal)
    }

    func testUnavailableOrUnfinishedGroupNeverDropsTheLocalModel() {
        for group in [ModelImportPolicy.GroupCopy.unavailable, .exporting] {
            XCTAssertEqual(decide(present: true, group: group, local: "a"), .useLocal, "\(group)")
            XCTAssertEqual(decide(present: true, group: group, local: nil), .useLocal, "\(group)")
            XCTAssertEqual(decide(present: false, group: group, local: nil), .missing, "\(group)")
            XCTAssertEqual(decide(present: false, group: group, local: "a"), .missing, "\(group)")
        }
    }
}
