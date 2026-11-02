import CryptoKit
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
        store = MacPairingStore(directory: directory, legacyKeychainService: keychainService)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        for account in ["pairKey", "pairKey.v2"] {
            SecItemDelete(keychainQuery(account: account) as CFDictionary)
        }
    }

    private var keyFile: URL { directory.appendingPathComponent("pair-key") }

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

    func testSaveThenLoadReturnsSameKey() throws {
        let key = SymmetricKey(size: .bits256)
        try store.save(key)
        XCTAssertEqual(bytes(store.load()), bytes(key))
    }

    func testSaveTwiceReplaces() throws {
        let second = SymmetricKey(size: .bits256)
        try store.save(SymmetricKey(size: .bits256))
        try store.save(second)
        XCTAssertEqual(bytes(store.load()), bytes(second))
    }

    func testSaveCreatesDirectoryWith0700AndFileWith0600() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.save(SymmetricKey(size: .bits256))
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(keyFile), 0o600)
    }

    func testReplacingKeepsFilePermissionsAt0600() throws {
        try store.save(SymmetricKey(size: .bits256))
        try store.save(SymmetricKey(size: .bits256))
        XCTAssertEqual(try permissions(keyFile), 0o600)
    }

    func testDeleteThenLoadIsNil() throws {
        try store.save(SymmetricKey(size: .bits256))
        store.delete()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
    }

    func testDeleteWithNothingStoredDoesNotThrow() {
        store.delete()
        store.delete()
        XCTAssertNil(store.load())
    }

    func testWrongLengthFileLoadsAsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for length in [0, 31, 33] {
            try Data(repeating: 1, count: length).write(to: keyFile)
            XCTAssertNil(store.load(), "length \(length)")
        }
    }

    func testSymlinkInPlaceOfFileLoadsAsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere")
        try Data(repeating: 9, count: 32).write(to: target)
        try FileManager.default.createSymbolicLink(at: keyFile, withDestinationURL: target)
        XCTAssertNil(store.load())
    }

    func testSaveReplacesSymlinkWithoutWritingThroughIt() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere")
        let original = Data(repeating: 9, count: 32)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: keyFile, withDestinationURL: target)
        let key = SymmetricKey(size: .bits256)
        try store.save(key)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(bytes(store.load()), bytes(key))
    }

    func testNoTemporaryFileLeftBehind() throws {
        try store.save(SymmetricKey(size: .bits256))
        try store.save(SymmetricKey(size: .bits256))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["pair-key"])
    }

    func testSaveThrowsWhenDirectoryCannotBeCreated() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let blocked = MacPairingStore(directory: blocker.appendingPathComponent("sub"),
                                      legacyKeychainService: keychainService)
        XCTAssertThrowsError(try blocked.save(SymmetricKey(size: .bits256))) { error in
            guard case PairKeyStoreError.file = error else { return XCTFail("\(error)") }
        }
    }

    func testSaveAndDeleteRemoveLegacyKeychainItems() throws {
        func addLegacy() {
            for account in ["pairKey", "pairKey.v2"] {
                var item = keychainQuery(account: account)
                item[kSecValueData as String] = Data(repeating: 7, count: 32)
                XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
            }
        }
        func legacyGone() -> Bool {
            ["pairKey", "pairKey.v2"].allSatisfy {
                SecItemCopyMatching(keychainQuery(account: $0) as CFDictionary, nil) == errSecItemNotFound
            }
        }
        addLegacy()
        XCTAssertNil(store.load(), "load must not read the keychain")
        try store.save(SymmetricKey(size: .bits256))
        XCTAssertTrue(legacyGone())
        addLegacy()
        store.delete()
        XCTAssertTrue(legacyGone())
    }
}
