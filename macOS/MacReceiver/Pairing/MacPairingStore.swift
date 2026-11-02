import CryptoKit
import Darwin
import Foundation
import Security

/// Where the Mac keeps the one pair key it holds.
protocol PairKeyStoring: AnyObject {
    func load() -> SymmetricKey?
    func save(_ key: SymmetricKey) throws
    /// Removing a key that is not there is not an error.
    func delete()
}

enum PairKeyStoreError: Error, Equatable {
    /// A file system step failed; the text names the step and the errno, never the key.
    case file(String)
}

/// The pair key in a file: `<Application Support>/RemoteKeyboardReceiver/pair-key`, 32 raw bytes, readable only by
/// the macOS user (directory 0700, file 0600). The app is not sandboxed, so that is `~/Library/Application Support`.
/// The key is never logged.
///
/// Why a file and not the Keychain: the release build is ad-hoc signed, so every build has a new code signature, and
/// the Keychain ties an item to the signature of its creator (access list and partition list). A newer build could
/// neither delete nor silently read the item, and macOS asked for the login-keychain password. The accepted cost:
/// other apps of the same macOS user can read the file.
///
/// Older builds kept the key in Keychain items (service `com.ansonhui.remotekeyboard.pairing`, accounts `pairKey`
/// and `pairKey.v2`). Those are never read, because reading can raise a password dialog; `save` and `delete` only
/// try to remove them.
final class MacPairingStore: PairKeyStoring {
    static let legacyService = "com.ansonhui.remotekeyboard.pairing"
    private static let legacyAccounts = ["pairKey", "pairKey.v2"]
    private static let fileName = "pair-key"
    private static let keyLength = 32

    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteKeyboardReceiver", isDirectory: true)
    }

    private let directory: URL
    private let legacyKeychainService: String

    /// Tests pass a temporary directory and their own Keychain service so they never touch the real key.
    init(directory: URL = MacPairingStore.defaultDirectory,
         legacyKeychainService: String = MacPairingStore.legacyService) {
        self.directory = directory
        self.legacyKeychainService = legacyKeychainService
    }

    private var keyFile: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> SymmetricKey? {
        // O_NOFOLLOW makes a symlink in place of the file fail instead of being read.
        let fd = open(keyFile.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == Self.keyLength else { return nil }
        var buffer = [UInt8](repeating: 0, count: Self.keyLength)
        guard read(fd, &buffer, Self.keyLength) == Self.keyLength else { return nil }
        return SymmetricKey(data: buffer)
    }

    func save(_ key: SymmetricKey) throws {
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { try fail("mkdir") }
        // mkdir applies the umask and an existing directory keeps its own mode.
        guard chmod(directory.path, 0o700) == 0 else { try fail("chmod directory") }

        // The temporary file is created 0600 in the target's directory, so the rename is atomic and the key is
        // never readable by others, even briefly. O_EXCL | O_NOFOLLOW refuse a pre-planted path.
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { try fail("create temporary file") }
        var committed = false
        defer {
            close(fd)
            if !committed { unlink(temporary.path) }
        }
        let bytes = key.withUnsafeBytes { Array($0) }
        guard fchmod(fd, 0o600) == 0 else { try fail("chmod file") }
        guard write(fd, bytes, bytes.count) == bytes.count else { try fail("write") }
        guard fsync(fd) == 0 else { try fail("fsync") }
        guard rename(temporary.path, keyFile.path) == 0 else { try fail("rename") }
        committed = true
        removeLegacyKeychainItems()
    }

    func delete() {
        unlink(keyFile.path)
        removeLegacyKeychainItems()
    }

    private func fail(_ step: String) throws -> Never {
        throw PairKeyStoreError.file("\(step): errno \(errno)")
    }

    /// Best effort and `SecItemDelete` only: an item made by another build may refuse deletion, and reading or
    /// updating one can raise a password dialog.
    private func removeLegacyKeychainItems() {
        for account in Self.legacyAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: account
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }
}
