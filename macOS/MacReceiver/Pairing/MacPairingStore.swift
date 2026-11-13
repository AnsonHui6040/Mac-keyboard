import CryptoKit
import Darwin
import Foundation
import OSLog
import RemoteKeyboardCore
import Security

/// Where the Mac keeps its own identity and the phones it is paired with.
protocol PairingStoring: AnyObject {
    /// This Mac's identity. The first call on a Mac that has none makes one (random id, the platform name 「Mac」 as display
    /// name) and stores it; later calls, and later launches, return the same identity. An existing host.json keeps its name.
    func loadHost() -> HostIdentity
    /// Gives this Mac another display name and returns the new identity. The name is trimmed, cut to 32 UTF-8 bytes, and an
    /// empty one becomes 「Mac」; id and platform stay, and so do the phones. A phone shows the new name only after it is
    /// paired again (the handshake uses the id and the key, not the name).
    @discardableResult func renameHost(_ name: String) throws -> HostIdentity
    /// Every phone that is stored in full (identity and key), oldest first, at most eight.
    func loadPhones() -> [PairedPhone]
    /// When each stored phone was added, by phone id. A phone without a date is left out.
    func loadAddedDates() -> [Data: Date]
    /// Stores a phone. One with the same id is replaced and keeps its place; a ninth phone throws `.full`.
    func save(_ phone: PairedPhone) throws
    /// Removing a phone that is not there is not an error.
    func delete(phoneId: Data)
    /// Removes the pair key of protocol v3, which cannot be used any more (docs/protocol/v4.md §10).
    func removeLegacyKey()
}

extension PairingStoring {
    func loadAddedDates() -> [Data: Date] { [:] }
}

enum PairingStoreError: Error, Equatable {
    /// A file system step failed; the text names the step and the errno, never a key.
    case file(String)
    /// Eight phones are stored and this one is not among them.
    case full
}

/// The Mac's identity and pair keys in files under `<Application Support>/RemoteKeyboardReceiver/`, readable only by the macOS
/// user (directories 0700, files 0600). The app is not sandboxed, so that is `~/Library/Application Support`.
///
///     host.json                       this Mac: id, display name, platform
///     phones/<phone id, hex>.key      the pair key, 32 raw bytes
///     phones/<phone id, hex>.json     the phone: id, name, platform, and when it was added (for the order)
///
/// A phone counts only when both of its files are there and agree. Keys are never logged.
///
/// Why files and not the Keychain: the release build is ad-hoc signed, so every build has a new code signature, and the Keychain
/// ties an item to the signature of its creator (access list and partition list). A newer build could neither delete nor silently
/// read the item, and macOS asked for the login-keychain password. The accepted cost: other apps of the same macOS user can read
/// the files.
///
/// Older builds kept the key in Keychain items (service `com.ansonhui.remotekeyboard.pairing`, accounts `pairKey` and
/// `pairKey.v2`), and v3 kept it in the file `pair-key`. None of these is read; `removeLegacyKey` only tries to remove them.
final class MacPairingStore: PairingStoring {
    static let legacyService = "com.ansonhui.remotekeyboard.pairing"
    private static let legacyAccounts = ["pairKey", "pairKey.v2"]
    private static let legacyFileName = "pair-key"
    private static let hostFileName = "host.json"
    private static let phonesDirectoryName = "phones"
    private static let keyLength = 32
    /// A record file is a few hundred bytes; anything larger is not one of ours.
    private static let maxRecordBytes = 4096
    static let fallbackHostName = "Mac"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "pairing-store")

    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteKeyboardReceiver", isDirectory: true)
    }

    private struct PhoneRecord: Codable {
        let id: Data
        let name: String
        let platform: PhonePlatform
        /// Milliseconds since 1970, to keep the order in which phones were added. Records without one sort first.
        let added: Double?
    }

    private let directory: URL
    private let legacyKeychainService: String
    private var cachedHost: HostIdentity?

    /// Tests pass a temporary directory and their own Keychain service, so they never touch the real files.
    init(
        directory: URL = MacPairingStore.defaultDirectory,
        legacyKeychainService: String = MacPairingStore.legacyService
    ) {
        self.directory = directory
        self.legacyKeychainService = legacyKeychainService
    }

    private var hostFile: URL { directory.appendingPathComponent(Self.hostFileName) }
    private var phonesDirectory: URL { directory.appendingPathComponent(Self.phonesDirectoryName, isDirectory: true) }

    private func name(_ id: Data) -> String { id.map { String(format: "%02x", $0) }.joined() }
    private func keyFile(_ id: Data) -> URL { phonesDirectory.appendingPathComponent(name(id) + ".key") }
    private func recordFile(_ id: Data) -> URL { phonesDirectory.appendingPathComponent(name(id) + ".json") }

    // MARK: Host

    func loadHost() -> HostIdentity {
        if let cachedHost { return cachedHost }
        if let data = readRegularFile(hostFile, maxBytes: Self.maxRecordBytes),
           let host = try? JSONDecoder().decode(HostIdentity.self, from: data), host.isValid {
            cachedHost = host
            return host
        }
        // No file at all is a first run. A file that is there but cannot be used (damaged, a symlink, too large, unreadable)
        // is replaced only together with the phones: they were paired with the identity it held and can never connect to a new
        // one, so they are removed and the panel starts from "not paired" instead of listing phones that cannot connect.
        var info = stat()
        if lstat(hostFile.path, &info) == 0 || errno != ENOENT {
            Self.log.error("host identity file unusable, new identity and no paired phones")
            clearPhones()
        }
        var id = [UInt8](repeating: 0, count: IdentityName.idLength)
        if SecRandomCopyBytes(kSecRandomDefault, id.count, &id) != errSecSuccess {
            id = (0..<id.count).map { _ in UInt8.random(in: 0...255) }
        }
        let host = HostIdentity(id: Data(id), name: Self.fallbackHostName, platform: .mac)
        cachedHost = host
        if let data = try? JSONEncoder().encode(host) { try? writeAtomically(data, to: hostFile, directory: directory) }
        return host
    }

    /// Removes every stored phone. Only plain `.key` and `.json` files of a real directory; a symlink in place of the directory
    /// is left alone.
    private func clearPhones() {
        var info = stat()
        guard lstat(phonesDirectory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: phonesDirectory.path) else { return }
        for file in names where file.hasSuffix(".key") || file.hasSuffix(".json") {
            unlink(phonesDirectory.appendingPathComponent(file).path)
        }
    }

    @discardableResult
    func renameHost(_ name: String) throws -> HostIdentity {
        let current = loadHost()
        let clamped = IdentityName.clamp(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let renamed = HostIdentity(
            id: current.id, name: clamped.isEmpty ? Self.fallbackHostName : clamped, platform: current.platform)
        guard let data = try? JSONEncoder().encode(renamed) else { throw PairingStoreError.file("encode") }
        try writeAtomically(data, to: hostFile, directory: directory)
        cachedHost = renamed
        return renamed
    }

    // MARK: Phones

    func loadPhones() -> [PairedPhone] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: phonesDirectory.path) else { return [] }
        var found: [(added: Double, phone: PairedPhone)] = []
        for file in names where file.hasSuffix(".json") {
            let stem = String(file.dropLast(".json".count))
            guard let data = readRegularFile(phonesDirectory.appendingPathComponent(file), maxBytes: Self.maxRecordBytes),
                  let record = try? JSONDecoder().decode(PhoneRecord.self, from: data) else { continue }
            let identity = PhoneIdentity(id: record.id, name: record.name, platform: record.platform)
            // The file name and the record say the same id, or the record was not written by this store.
            guard identity.isValid, name(identity.id) == stem,
                  let key = readRegularFile(keyFile(identity.id), maxBytes: Self.keyLength), key.count == Self.keyLength
            else { continue }
            found.append((record.added ?? 0, PairedPhone(identity: identity, pairKey: SymmetricKey(data: key))))
        }
        found.sort { ($0.added, name($0.phone.identity.id)) < ($1.added, name($1.phone.identity.id)) }
        return PairedList(entries: found.map(\.phone)).entries
    }

    func loadAddedDates() -> [Data: Date] {
        var dates: [Data: Date] = [:]
        for phone in loadPhones() {
            if let added = previousAdded(phone.identity.id), added > 0 {
                dates[phone.identity.id] = Date(timeIntervalSince1970: added / 1000)
            }
        }
        return dates
    }

    func save(_ phone: PairedPhone) throws {
        let existing = loadPhones()
        let replacing = existing.contains { $0.identity.id == phone.identity.id }
        if !replacing, existing.count >= PairedList<PairedPhone>.capacity { throw PairingStoreError.full }

        try makeDirectory(directory)
        try makeDirectory(phonesDirectory)
        let key = phone.pairKey.withUnsafeBytes { Data($0) }
        let added = replacing ? (previousAdded(phone.identity.id) ?? 0) : Date().timeIntervalSince1970 * 1000
        let record = PhoneRecord(id: phone.identity.id, name: phone.identity.name, platform: phone.identity.platform, added: added)
        guard let json = try? JSONEncoder().encode(record) else { throw PairingStoreError.file("encode") }
        try writeAtomically(key, to: keyFile(phone.identity.id), directory: phonesDirectory)
        do {
            try writeAtomically(json, to: recordFile(phone.identity.id), directory: phonesDirectory)
        } catch {
            // A phone is stored in full or not at all; the key of a new phone must not stay behind without its record.
            if !replacing { unlink(keyFile(phone.identity.id).path) }
            throw error
        }
    }

    func delete(phoneId: Data) {
        unlink(keyFile(phoneId).path)
        unlink(recordFile(phoneId).path)
    }

    private func previousAdded(_ id: Data) -> Double? {
        guard let data = readRegularFile(recordFile(id), maxBytes: Self.maxRecordBytes) else { return nil }
        return (try? JSONDecoder().decode(PhoneRecord.self, from: data))?.added
    }

    // MARK: Legacy

    func removeLegacyKey() {
        unlink(directory.appendingPathComponent(Self.legacyFileName).path)
        removeLegacyKeychainItems()
    }

    /// Best effort and `SecItemDelete` only: an item made by another build may refuse deletion, and reading or updating one can
    /// raise a password dialog.
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

    // MARK: Files

    /// The bytes of a regular file of at most `maxBytes`, or nil. O_NOFOLLOW makes a symlink in place of the file fail instead of
    /// being read.
    private func readRegularFile(_ url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maxBytes else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        guard buffer.isEmpty || read(fd, &buffer, buffer.count) == buffer.count else { return nil }
        return Data(buffer)
    }

    private func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { try fail("mkdir") }
        // mkdir applies the umask and an existing directory keeps its own mode.
        guard chmod(url.path, 0o700) == 0 else { try fail("chmod directory") }
    }

    /// The temporary file is created 0600 in the target's directory, so the rename is atomic and the content is never readable by
    /// others, even briefly. O_EXCL | O_NOFOLLOW refuse a pre-planted path.
    private func writeAtomically(_ bytes: Data, to target: URL, directory: URL) throws {
        try makeDirectory(directory)
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { try fail("create temporary file") }
        var committed = false
        defer {
            close(fd)
            if !committed { unlink(temporary.path) }
        }
        let array = [UInt8](bytes)
        guard fchmod(fd, 0o600) == 0 else { try fail("chmod file") }
        guard write(fd, array, array.count) == array.count else { try fail("write") }
        guard fsync(fd) == 0 else { try fail("fsync") }
        guard rename(temporary.path, target.path) == 0 else { try fail("rename") }
        committed = true
    }

    private func fail(_ step: String) throws -> Never {
        throw PairingStoreError.file("\(step): errno \(errno)")
    }
}
