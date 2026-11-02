import XCTest
@testable import RemoteKeyboardCore

/// `AppGroup.resolvedIdentifier` picks the App Group out of an embedded provisioning profile. SideStore re-signs with
/// `group.com.ansonhui.remotekeyboard.<TEAMID>`; every other input must fall back to the base group.
final class AppGroupResolutionTests: XCTestCase {
    private let base = "group.com.ansonhui.remotekeyboard"

    private func plist(groups: [String]?) -> Data {
        var entitlements: [String: Any] = ["application-identifier": "ABCDE12345.com.ansonhui.remotekeyboard"]
        if let groups { entitlements["com.apple.security.application-groups"] = groups }
        let root: [String: Any] = ["Name": "test", "Entitlements": entitlements]
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// A CMS envelope is binary junk around the XML plist; the junk here includes bytes that are not valid UTF-8.
    private func cms(_ xml: Data) -> Data {
        Data([0x30, 0x82, 0x0A, 0xFF, 0xFE, 0x00, 0x80]) + xml + Data([0x00, 0xFF, 0xC3, 0x28, 0x31, 0x82])
    }

    func testExactBaseIsKept() {
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: plist(groups: [base])), base)
    }

    func testSideStoreSuffixIsReturned() {
        let suffixed = base + ".ABCDE12345"
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: plist(groups: [suffixed])), suffixed)
    }

    func testExactBaseWinsOverSuffixed() {
        let data = plist(groups: [base + ".ABCDE12345", base])
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: data), base)
    }

    func testUnrelatedGroupIsSkippedForSuffixed() {
        let suffixed = base + ".ABCDE12345"
        let data = plist(groups: ["group.other.app", suffixed])
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: data), suffixed)
    }

    func testOnlyUnrelatedGroupReturnsBase() {
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: plist(groups: ["group.other.app"])), base)
    }

    func testWildcardReturnsBase() {
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: plist(groups: ["*"])), base)
    }

    func testNilReturnsBase() {
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: nil), base)
    }

    func testGarbageReturnsBase() {
        let garbage = Data((0..<256).map { UInt8($0 & 0xFF) })
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: garbage), base)
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: Data()), base)
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: Data("<?xml broken </plist>".utf8)), base)
    }

    func testPlistInsideBinaryJunkIsParsed() {
        let suffixed = base + ".ABCDE12345"
        let data = cms(plist(groups: [suffixed]))
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: data), suffixed)
    }

    func testMissingEntitlementsReturnsBase() {
        let root: [String: Any] = ["Name": "test"]
        let data = try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: data), base)
    }

    func testMissingGroupsKeyReturnsBase() {
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: plist(groups: nil)), base)
    }

    func testSimilarPrefixIsNotMatched() {
        let data = plist(groups: [base + "x", base + "x.ABCDE12345"])
        XCTAssertEqual(AppGroup.resolvedIdentifier(provisioningProfile: data), base)
    }

    func testProcessIdentifierWithoutProfileIsBase() {
        // swift test and macOS have no embedded.mobileprovision in the main bundle.
        XCTAssertEqual(AppGroup.identifier, base)
        XCTAssertEqual(AppGroup.keychainAccessGroup, AppGroup.identifier)
    }
}
