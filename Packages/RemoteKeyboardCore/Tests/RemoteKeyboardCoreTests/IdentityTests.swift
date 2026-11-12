import XCTest
@testable import RemoteKeyboardCore

final class IdentityTests: XCTestCase {
    private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    func testNameClampKeepsWholeCharacters() {
        // 11 × 測 is 33 bytes; the longest prefix within 32 bytes is 10 characters (30 bytes).
        let tall = String(repeating: "測", count: 11)
        XCTAssertEqual(tall.utf8.count, 33)
        let clamped = IdentityName.clamp(tall)
        XCTAssertEqual(clamped, String(repeating: "測", count: 10))
        XCTAssertEqual(clamped.utf8.count, 30)

        // "a" followed by eight family emoji is 145 bytes. The cut falls on a scalar boundary inside the second family:
        // U+1F468, U+200D, U+1F469 stay (30 bytes), the next U+200D would make 33.
        let long = "a" + String(repeating: family, count: 8)
        XCTAssertEqual(long.utf8.count, 145)
        let cut = IdentityName.clamp(long)
        XCTAssertEqual(cut.utf8.count, 30)
        XCTAssertEqual(
            cut.unicodeScalars.map(\.value),
            [0x61, 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x1F468, 0x200D, 0x1F469])
        // The result is valid UTF-8 and survives a trip through bytes.
        XCTAssertEqual(String(decoding: Data(cut.utf8), as: UTF8.self).unicodeScalars.map(\.value), cut.unicodeScalars.map(\.value))
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8))
    }

    func testNameClampLeavesShortNamesAlone() {
        for name in ["", "書房的 Mac", String(repeating: "a", count: 32), String(repeating: "測", count: 10) + "ab"] {
            XCTAssertEqual(IdentityName.clamp(name), name)
        }
        XCTAssertEqual(IdentityName.clamp(String(repeating: "a", count: 33)), String(repeating: "a", count: 32))
        // A three-byte scalar that would straddle the limit is dropped whole.
        XCTAssertEqual(IdentityName.clamp(String(repeating: "a", count: 31) + "測"), String(repeating: "a", count: 31))
        // A four-byte scalar likewise.
        XCTAssertEqual(IdentityName.clamp(String(repeating: "a", count: 29) + "\u{1F468}"), String(repeating: "a", count: 29))
    }

    func testNameValidityRejectsEmptyAndOverlong() {
        XCTAssertFalse(IdentityName.isValid(""))
        XCTAssertFalse(IdentityName.isValid(String(repeating: "a", count: 33)))
        XCTAssertTrue(IdentityName.isValid(String(repeating: "a", count: 32)))
        XCTAssertTrue(IdentityName.isValid("a"))
        XCTAssertFalse(IdentityName.isValid(String(repeating: "測", count: 11)))
        XCTAssertTrue(IdentityName.isValid(String(repeating: "測", count: 10)))
        XCTAssertEqual(IdentityName.maxBytes, 32)
    }

    func testIdentityIdLengthIsChecked() {
        XCTAssertTrue(HostIdentity(id: Data(repeating: 1, count: 16), name: "H", platform: .mac).isValid)
        XCTAssertFalse(HostIdentity(id: Data(repeating: 1, count: 15), name: "H", platform: .mac).isValid)
        XCTAssertFalse(HostIdentity(id: Data(repeating: 1, count: 16), name: "", platform: .mac).isValid)
        XCTAssertFalse(PhoneIdentity(id: Data(repeating: 1, count: 17), name: "P", platform: .ios).isValid)
        XCTAssertFalse(PhoneIdentity(id: Data(repeating: 1, count: 16), name: String(repeating: "a", count: 33), platform: .android).isValid)
        XCTAssertTrue(PhoneIdentity(id: Data(repeating: 1, count: 16), name: "P", platform: .android).isValid)
    }

    func testPlatformStringsAreTheWireStrings() {
        XCTAssertEqual([HostPlatform.mac, .windows, .linux].map(\.rawValue), ["mac", "windows", "linux"])
        XCTAssertEqual([PhonePlatform.ios, .android].map(\.rawValue), ["ios", "android"])
    }

    func testLocalStorageRoundTrip() throws {
        let host = Fixture.hostIdentity
        XCTAssertEqual(try JSONDecoder().decode(HostIdentity.self, from: JSONEncoder().encode(host)), host)
        let phone = Fixture.phoneIdentity
        XCTAssertEqual(try JSONDecoder().decode(PhoneIdentity.self, from: JSONEncoder().encode(phone)), phone)
    }
}
