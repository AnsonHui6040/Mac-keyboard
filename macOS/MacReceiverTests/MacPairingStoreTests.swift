import CryptoKit
import RemoteKeyboardCore
import Security
import XCTest
@testable import MacReceiver

final class MacPairingStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var keychainService = ""
    private var store: MacPairingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("RemoteKeyboardReceiver")
        keychainService = "com.ansonhui.remotekeyboard.pairing.test.\(UUID().uuidString)"
        store = makeStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        for account in ["pairKey", "pairKey.v2"] {
            SecItemDelete(keychainQuery(account: account) as CFDictionary)
        }
    }

    private func makeStore(directory: URL? = nil, hostName: @escaping () -> String? = { "書房的 Mac" }) -> MacPairingStore {
        MacPairingStore(
            directory: directory ?? self.directory, legacyKeychainService: keychainService, defaultHostName: hostName)
    }

    private var phonesDirectory: URL { directory.appendingPathComponent("phones") }
    private var hostFile: URL { directory.appendingPathComponent("host.json") }
    private var legacyFile: URL { directory.appendingPathComponent("pair-key") }

    private func keyFile(_ phone: PhoneIdentity) -> URL {
        phonesDirectory.appendingPathComponent(phone.id.map { String(format: "%02x", $0) }.joined() + ".key")
    }

    private func infoFile(_ phone: PhoneIdentity) -> URL {
        phonesDirectory.appendingPathComponent(phone.id.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    private func phone(_ n: UInt8, key: SymmetricKey = SymmetricKey(size: .bits256)) -> PairedPhone {
        PairedPhone(identity: TestIdentity.phone(n), pairKey: key)
    }

    // MARK: Host identity

    func testHostIdentityIsStableAcrossLoads() throws {
        let first = store.loadHost()
        XCTAssertEqual(first.id.count, 16)
        XCTAssertEqual(first.name, "書房的 Mac")
        XCTAssertEqual(first.platform, .mac)
        XCTAssertEqual(store.loadHost(), first, "the same object answers again")
        XCTAssertEqual(makeStore(hostName: { "別的名字" }).loadHost(), first, "and so does a new launch: read back from host.json")
    }

    func testHostNameIsClampedAndEmptyNameFallsBackToADefault() {
        let long = String(repeating: "電", count: 30)
        let other = root.appendingPathComponent("other")
        let host = makeStore(directory: other, hostName: { long }).loadHost()
        XCTAssertEqual(host.name, String(repeating: "電", count: 10), "10 characters of 3 bytes fill 30 of 32 bytes")
        XCTAssertTrue(host.isValid)
        let empty = makeStore(directory: root.appendingPathComponent("empty"), hostName: { "" }).loadHost()
        XCTAssertEqual(empty.name, "Mac")
        let missing = makeStore(directory: root.appendingPathComponent("missing"), hostName: { nil }).loadHost()
        XCTAssertEqual(missing.name, "Mac")
    }

    func testUnreadableHostFileIsReplacedByANewIdentity() throws {
        let first = store.loadHost()
        try Data("not json".utf8).write(to: hostFile)
        let again = makeStore().loadHost()
        XCTAssertNotEqual(again.id, first.id, "a damaged host.json is a new host")
        XCTAssertTrue(again.isValid)
        XCTAssertEqual(makeStore().loadHost(), again, "and the new one is stored")
    }

    func testMissingHostFileMakesANewIdentityAndKeepsThePhones() throws {
        try store.save(phone(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostFile.path))
        let host = makeStore().loadHost()
        XCTAssertTrue(host.isValid)
        XCTAssertEqual(makeStore().loadPhones().count, 1, "a missing file is a first run, not damage")
        XCTAssertEqual(makeStore().loadHost(), host)
    }

    func testDamagedHostFileMakesANewIdentityAndClearsThePhones() throws {
        let first = store.loadHost()
        try store.save(phone(1))
        try store.save(phone(2))
        try Data("not json".utf8).write(to: hostFile)
        let fresh = makeStore()
        let again = fresh.loadHost()
        XCTAssertNotEqual(again.id, first.id)
        XCTAssertEqual(fresh.loadPhones(), [], "phones paired with the old identity can never connect again")
        XCTAssertEqual(makeStore().loadPhones(), [])
        XCTAssertEqual(makeStore().loadHost(), again)
    }

    func testSymlinkHostFileMakesANewIdentityAndClearsThePhones() throws {
        let first = store.loadHost()
        try store.save(phone(1))
        let target = root.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: hostFile, to: target)
        try FileManager.default.createSymbolicLink(at: hostFile, withDestinationURL: target)
        let fresh = makeStore()
        XCTAssertNotEqual(fresh.loadHost().id, first.id)
        XCTAssertEqual(fresh.loadPhones(), [])
    }

    func testIntactHostFileLeavesThePhonesAlone() throws {
        let host = store.loadHost()
        try store.save(phone(1))
        let fresh = makeStore()
        XCTAssertEqual(fresh.loadHost(), host)
        XCTAssertEqual(fresh.loadPhones().count, 1)
    }

    // MARK: Phones

    func testSecondPhoneDoesNotReplaceFirst() throws {
        let first = phone(1), second = phone(2)
        try store.save(first)
        try store.save(second)
        let loaded = store.loadPhones()
        XCTAssertEqual(loaded.map(\.identity), [first.identity, second.identity], "kept in the order they were added")
        XCTAssertEqual(bytes(loaded[0].pairKey), bytes(first.pairKey))
        XCTAssertEqual(bytes(loaded[1].pairKey), bytes(second.pairKey))
    }

    func testAddedDatesAreReadBackAndSurviveAnOverwrite() throws {
        let before = Date()
        try store.save(phone(1))
        let first = try XCTUnwrap(store.loadAddedDates()[TestIdentity.phone(1).id])
        XCTAssertLessThan(abs(first.timeIntervalSince(before)), 5)
        try store.save(phone(1))
        XCTAssertEqual(store.loadAddedDates()[TestIdentity.phone(1).id], first, "an overwrite keeps the original date")
        XCTAssertNil(store.loadAddedDates()[TestIdentity.phone(2).id])
    }

    func testSamePhoneIdOverwrites() throws {
        let first = phone(1), other = phone(2)
        try store.save(first)
        try store.save(other)
        let renamed = PairedPhone(
            identity: PhoneIdentity(id: first.identity.id, name: "新名字", platform: .android), pairKey: SymmetricKey(size: .bits256))
        try store.save(renamed)
        let loaded = store.loadPhones()
        XCTAssertEqual(loaded.count, 2, "no third entry")
        XCTAssertEqual(loaded.first?.identity, renamed.identity, "the record is replaced and keeps its place")
        XCTAssertEqual(bytes(loaded.first?.pairKey), bytes(renamed.pairKey))
        XCTAssertNotEqual(bytes(loaded.first?.pairKey), bytes(first.pairKey))
    }

    func testNinthPhoneIsRefused() throws {
        for n in 1...8 { try store.save(phone(UInt8(n))) }
        XCTAssertThrowsError(try store.save(phone(9))) { XCTAssertEqual($0 as? PairingStoreError, .full) }
        XCTAssertEqual(store.loadPhones().count, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile(TestIdentity.phone(9)).path), "nothing of the ninth was written")
        // A phone that is already there can still be paired again when eight are stored.
        XCTAssertNoThrow(try store.save(phone(3)))
        XCTAssertEqual(store.loadPhones().count, 8)
    }

    func testFilesAre0600() throws {
        let p = phone(1)
        try store.save(p)
        _ = store.loadHost()
        XCTAssertEqual(try permissions(keyFile(p.identity)), 0o600)
        XCTAssertEqual(try permissions(infoFile(p.identity)), 0o600)
        XCTAssertEqual(try permissions(hostFile), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(phonesDirectory), 0o700)
        try store.save(p)
        XCTAssertEqual(try permissions(keyFile(p.identity)), 0o600, "replacing keeps the mode")
        XCTAssertEqual(try permissions(infoFile(p.identity)), 0o600)
    }

    func testLegacyKeyFileIsRemoved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 32).write(to: legacyFile)
        let host = store.loadHost()
        store.removeLegacyKey()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(store.loadPhones().isEmpty, "the panel is back to unpaired")
        XCTAssertEqual(store.loadHost(), host, "removing the old key leaves the host alone")
        store.removeLegacyKey()
    }

    func testLegacyKeychainItemsAreRemovedToo() throws {
        for account in ["pairKey", "pairKey.v2"] {
            var item = keychainQuery(account: account)
            item[kSecValueData as String] = Data(repeating: 7, count: 32)
            XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        }
        store.removeLegacyKey()
        for account in ["pairKey", "pairKey.v2"] {
            XCTAssertEqual(SecItemCopyMatching(keychainQuery(account: account) as CFDictionary, nil), errSecItemNotFound)
        }
    }

    func testDeleteRemovesBothFilesAndOnlyThatPhone() throws {
        let first = phone(1), second = phone(2)
        try store.save(first)
        try store.save(second)
        store.delete(phoneId: first.identity.id)
        XCTAssertEqual(store.loadPhones().map(\.identity), [second.identity])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile(first.identity).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: infoFile(first.identity).path))
        store.delete(phoneId: first.identity.id)
        store.delete(phoneId: Data(repeating: 1, count: 16))
        XCTAssertEqual(store.loadPhones().count, 1, "deleting what is not there is not an error")
    }

    func testAPhoneWithAWrongLengthKeyFileIsSkipped() throws {
        let p = phone(1)
        try store.save(p)
        for length in [0, 31, 33] {
            try Data(repeating: 1, count: length).write(to: keyFile(p.identity))
            XCTAssertTrue(store.loadPhones().isEmpty, "length \(length)")
        }
    }

    func testSymlinkInPlaceOfAKeyFileIsSkipped() throws {
        let p = phone(1)
        try store.save(p)
        let target = root.appendingPathComponent("elsewhere")
        try Data(repeating: 9, count: 32).write(to: target)
        try FileManager.default.removeItem(at: keyFile(p.identity))
        try FileManager.default.createSymbolicLink(at: keyFile(p.identity), withDestinationURL: target)
        XCTAssertTrue(store.loadPhones().isEmpty)
    }

    func testSaveReplacesASymlinkWithoutWritingThroughIt() throws {
        let p = phone(1)
        try store.save(p)
        let target = root.appendingPathComponent("elsewhere")
        let original = Data(repeating: 9, count: 32)
        try original.write(to: target)
        try FileManager.default.removeItem(at: keyFile(p.identity))
        try FileManager.default.createSymbolicLink(at: keyFile(p.identity), withDestinationURL: target)
        let again = PairedPhone(identity: p.identity, pairKey: SymmetricKey(size: .bits256))
        try store.save(again)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(bytes(store.loadPhones().first?.pairKey), bytes(again.pairKey))
    }

    func testAPhoneRecordWhoseIdDoesNotMatchItsFileNameIsSkipped() throws {
        let p = phone(1)
        try store.save(p)
        let other = TestIdentity.phone(2)
        let forged = try JSONEncoder().encode(other)
        try forged.write(to: infoFile(p.identity))
        XCTAssertTrue(store.loadPhones().isEmpty)
    }

    func testNoTemporaryFileLeftBehind() throws {
        let p = phone(1)
        try store.save(p)
        try store.save(p)
        _ = store.loadHost()
        let names = try FileManager.default.contentsOfDirectory(atPath: phonesDirectory.path).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix(".") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["host.json", "phones"])
    }

    func testSaveThrowsWhenDirectoryCannotBeCreated() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let blocked = makeStore(directory: blocker.appendingPathComponent("sub"))
        XCTAssertThrowsError(try blocked.save(phone(1))) { error in
            guard case PairingStoreError.file = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(blocked.loadPhones().isEmpty)
    }
}
