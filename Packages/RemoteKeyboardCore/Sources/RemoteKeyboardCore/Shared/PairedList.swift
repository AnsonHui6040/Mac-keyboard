import CryptoKit
import Foundation

/// What `PairedList` needs to know about an entry: the id it is stored under.
public protocol PairedEntry {
    var entryId: Data { get }
}

public enum AddResult: Equatable, Sendable {
    /// A new entry.
    case added
    /// An entry with the same id was overwritten (docs/protocol/v4.md §4: pairing again with the same id replaces the record).
    case replaced
    /// Eight entries are stored and this id is not one of them; nothing changed. The user has to remove one first.
    case full
}

/// Up to eight paired peers, in the order they were added, one entry per id. A phone keeps up to eight hosts, a host up to
/// eight phones.
public struct PairedList<Entry: PairedEntry>: Sendable where Entry: Sendable {
    public static var capacity: Int { 8 }

    public private(set) var entries: [Entry]

    /// - Parameter entries: loaded from storage. Later entries with an id already seen overwrite the earlier one, and
    ///   anything beyond `capacity` is dropped.
    public init(entries: [Entry] = []) {
        self.entries = []
        for entry in entries { _ = add(entry) }
    }

    @discardableResult
    public mutating func add(_ entry: Entry) -> AddResult {
        if let index = entries.firstIndex(where: { $0.entryId == entry.entryId }) {
            entries[index] = entry
            return .replaced
        }
        guard entries.count < Self.capacity else { return .full }
        entries.append(entry)
        return .added
    }

    /// `true` when an entry was removed.
    @discardableResult
    public mutating func remove(id: Data) -> Bool {
        guard let index = entries.firstIndex(where: { $0.entryId == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    public func entry(id: Data) -> Entry? { entries.first { $0.entryId == id } }
}

extension PairedList: Equatable where Entry: Equatable {}
extension PairedList: Codable where Entry: Codable {}

/// A host an iPhone has paired with. The pair key is kept apart (the keychain) and is not part of this record.
public struct PairedHost: Codable, Equatable, Sendable, PairedEntry {
    public let identity: HostIdentity
    public init(identity: HostIdentity) { self.identity = identity }
    public var entryId: Data { identity.id }
}

/// A phone a receiver has paired with, with the key that pairing derived. Not `Codable`: the key lives in secure storage.
public struct PairedPhone: Equatable, Sendable, PairedEntry {
    public let identity: PhoneIdentity
    public let pairKey: SymmetricKey
    public init(identity: PhoneIdentity, pairKey: SymmetricKey) {
        self.identity = identity
        self.pairKey = pairKey
    }
    public var entryId: Data { identity.id }
}

/// The hosts an iPhone knows and the one its keyboard types to now. `selectedId` is `nil` exactly when there is no host.
/// The first host added becomes the current one; later ones are chosen with `select` (a finished pairing the user
/// confirmed) or `cycle` (the key on the keyboard).
public struct HostSelection: Codable, Equatable, Sendable {
    public private(set) var hosts: [HostIdentity]
    public private(set) var selectedId: Data?

    public init() {
        hosts = []
        selectedId = nil
    }

    public var selected: HostIdentity? { hosts.first { $0.id == selectedId } }

    @discardableResult
    public mutating func add(_ host: HostIdentity) -> AddResult {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
            return .replaced
        }
        guard hosts.count < PairedList<PairedHost>.capacity else { return .full }
        hosts.append(host)
        if selectedId == nil { selectedId = host.id }
        return .added
    }

    /// Removing the current host makes the next one in the list current (the first, when it was the last); with no host
    /// left nothing is selected.
    public mutating func remove(id: Data) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts.remove(at: index)
        guard selectedId == id else { return }
        selectedId = hosts.isEmpty ? nil : hosts[index % hosts.count].id
    }

    /// `false` for an id that is not in the list.
    @discardableResult
    public mutating func select(id: Data) -> Bool {
        guard hosts.contains(where: { $0.id == id }) else { return false }
        selectedId = id
        return true
    }

    /// Moves to the next host, wrapping around, and returns it. `nil` (nothing changes) with fewer than two hosts.
    public mutating func cycle() -> HostIdentity? {
        guard hosts.count > 1, let index = hosts.firstIndex(where: { $0.id == selectedId }) else { return nil }
        let next = hosts[(index + 1) % hosts.count]
        selectedId = next.id
        return next
    }
}
