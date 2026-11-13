import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// Cross-implementation check, Rust to Swift: everything `rk-core` produced in `receiver/testdata/rust-vectors-v4.json`
/// (session ciphertexts, pointer packets, segmentation) must be accepted by the Swift code, byte for byte. The other
/// direction is `ProtocolVectorTests`. The file is only read here, never written. Every value in it is public fake data
/// derived from the fixed inputs of docs/protocol/v4.md.
final class RustVectorTests: XCTestCase {
    private static let vectorsPath = "receiver/testdata/rust-vectors-v4.json"

    private static var repoRoot: URL {
        // …/Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/RustVectorTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private enum VectorError: Error, CustomStringConvertible {
        case missing(String)
        case badHex(String)
        var description: String {
            switch self {
            case .missing(let what): "rust-vectors-v4.json: missing or malformed \(what)"
            case .badHex(let text): "rust-vectors-v4.json: not hex: \(text.prefix(16))"
            }
        }
    }

    // MARK: Reading the file

    private func loadRoot() throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent(Self.vectorsPath)
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VectorError.missing("root object") }
        return root
    }

    private func object(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = parent[key] as? [String: Any] else { throw VectorError.missing(key) }
        return value
    }

    private func objects(_ parent: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let value = parent[key] as? [[String: Any]] else { throw VectorError.missing(key) }
        return value
    }

    private func string(_ parent: [String: Any], _ key: String) throws -> String {
        guard let value = parent[key] as? String else { throw VectorError.missing(key) }
        return value
    }

    private func bytes(_ parent: [String: Any], _ key: String) throws -> Data { try unhex(try string(parent, key)) }

    private func unhex(_ text: String) throws -> Data {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { throw VectorError.badHex(text) }
        func nibble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            default: throw VectorError.badHex(text)
            }
        }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            out.append(try nibble(chars[index]) << 4 | nibble(chars[index + 1]))
            index += 2
        }
        return out
    }

    private func flippingLastBit(_ data: Data) -> Data {
        var copy = data
        copy[copy.count - 1] ^= 0x01
        return copy
    }

    // MARK: Shape

    func testRustVectorsFileHasExpectedShape() throws {
        let root = try loadRoot()
        XCTAssertEqual(root["protocolVersion"] as? Int, 4)
        XCTAssertFalse(try string(root, "about").isEmpty)
        let inputs = try object(root, "inputs")
        for key in ["pairKey", "hostNonce", "phoneNonce", "keyHostToPhone", "keyPhoneToHost"] {
            XCTAssertFalse(try string(inputs, key).isEmpty, key)
        }
        let session = try object(root, "session")
        XCTAssertFalse(try objects(session, "hostToPhone").isEmpty)
        XCTAssertFalse(try objects(session, "phoneToHost").isEmpty)
        XCTAssertFalse(try objects(root, "pointer").isEmpty)
        let segmentation = try objects(root, "segmentation")
        XCTAssertFalse(segmentation.isEmpty)
        for item in segmentation { XCTAssertFalse((item["frames"] as? [String] ?? []).isEmpty) }
    }

    // MARK: Fixed expectations

    private static let eventId = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
    private static let sessionId = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

    private static func event(_ seq: UInt64, _ epoch: UInt64?, _ kind: EventKind) -> KeyboardEvent {
        KeyboardEvent(protocolVersion: 4, eventId: eventId, sessionId: sessionId, seq: seq, focusEpoch: epoch, kind: kind)
    }

    /// 書房的 Mac 🙂 path/to/file 𠮷野家 👨‍👩‍👧 , twelve times: multibyte characters, a surrogate pair, a ZWJ sequence and `/`.
    private static let longText = String(
        repeating: "書房的 Mac \u{1F642} path/to/file \u{20BB7}野家 \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", count: 12)

    /// What the Swift decoder must read out of each host-bound inner message, by the vector's `name`.
    private static let expectedEvents: [String: KeyboardEvent] = [
        "textWithSlashAndMultibyte": event(1, 7, .text("書房/\u{1F642} a/b")),
        "textWithEscapes": event(2, 7, .text("tab\there \"quoted\" back\\slash \u{01} \u{08}\u{0C}\r\u{7F}\u{2028}\u{2029}")),
        "backspace": event(3, 7, .backspace),
        "ping": event(4, nil, .ping(shownAtMs: 120, connectedAtMs: 480)),
        "pointerOpen": event(5, nil, .pointerOpen(grant: 4_294_967_295)),
        "longText": event(UInt64.max, UInt64.max, .text(longText)),
    ]

    /// What the Swift decoder must read out of each phone-bound inner message, by the vector's `name`.
    private static let expectedControl: [String: ControlMessage] = [
        "ack": .ack(Ack(eventId: eventId, result: .posted)),
        "ackOutOfOrder": .ack(Ack(eventId: Ack.unknownEventId, result: .outOfOrder)),
        "status": .status(ReceiverStatus(ready: true, appName: nil, focusEpoch: 1, pointerGrant: 305_419_896)),
        "statusUntrusted": .status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, trusted: false)),
        "bye": .bye,
    ]

    private static let expectedPointer: [String: PointerPayload] = [
        "scrollBegan": PointerPayload(
            opcode: .scroll, buttons: 0x20, dx: -48, dy: 160, dt: 166, actionId: 0, arg: PointerPayload.ScrollPhase.began.rawValue,
            status: 0, buttonSeq: 7),
        "heartbeatLeftDown": PointerPayload(opcode: .heartbeat, buttons: 0x11, dx: 0, dy: 0, dt: 0, actionId: 0, arg: 0, status: 0, buttonSeq: 0xFFFF),
    ]

    /// docs/protocol/v4.md §8.1: the pointer key of the fixed inputs.
    private static let documentedPointerKey = "4c23e2029084d213e4609bc0e0cc5ae79414f8ac9fa2a1ac5e65339e12b20730"

    // MARK: The main test

    func testSwiftOpensRustVectors() throws {
        let root = try loadRoot()
        let inputs = try object(root, "inputs")
        let pairKey = SymmetricKey(data: try bytes(inputs, "pairKey"))
        let hostNonce = try bytes(inputs, "hostNonce")
        let phoneNonce = try bytes(inputs, "phoneNonce")

        // Session keys: Swift derives the same ones (the nearest interface is the internal `keyDataForTesting`).
        let p2m = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let m2p = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        XCTAssertEqual(p2m.keyDataForTesting, try bytes(inputs, "keyPhoneToHost"))
        XCTAssertEqual(m2p.keyDataForTesting, try bytes(inputs, "keyHostToPhone"))
        let channels = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(channels.keyDataForTesting(.pointer), try unhex(Self.documentedPointerKey))

        let session = try object(root, "session")
        try checkPhoneToHost(try objects(session, "phoneToHost"), p2m: p2m, m2p: m2p)
        try checkHostToPhone(try objects(session, "hostToPhone"), m2p: m2p, p2m: p2m)
        try checkPointer(try objects(root, "pointer"), pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        try checkSegmentation(try objects(root, "segmentation"))
    }

    // MARK: Phone to host (`PeripheralMessage.sealed`, inner `event`)

    private func checkPhoneToHost(_ items: [[String: Any]], p2m: SessionCrypto, m2p: SessionCrypto) throws {
        for item in items {
            let name = try string(item, "name")
            let sealed = try bytes(item, "sealedHex")
            let plain = try bytes(item, "plaintextHex")
            let nonce = try bytes(item, "aeadNonce")

            // The plaintext field is the same bytes as plaintextHex, and Swift opens the ciphertext to exactly them.
            XCTAssertEqual(Data(try string(item, "plaintext").utf8), plain, "\(name): plaintext vs plaintextHex")
            XCTAssertEqual(try p2m.open(sealed), plain, "\(name): open")
            XCTAssertEqual(sealed.prefix(12), nonce, "\(name): envelope starts with the AEAD nonce")
            // Swift sealing the same plaintext under the same nonce yields the identical envelope.
            XCTAssertEqual(try p2m.seal(plain, nonce: try ChaChaPoly.Nonce(data: nonce)), sealed, "\(name): Swift seal")
            // Other direction or a flipped bit never opens (§7.1, §7.2).
            XCTAssertThrowsError(try m2p.open(sealed), "\(name): wrong direction")
            XCTAssertThrowsError(try p2m.open(flippingLastBit(sealed)), "\(name): tampered")

            // The outer message `{"payload":…,"protocolVersion":4,"type":"sealed"}`.
            let outerJson = Data(try string(item, "messageJson").utf8)
            guard case .sealed(let payload) = try PeripheralCodec.decode(outerJson) else {
                XCTFail("\(name): outer message is not sealed")
                continue
            }
            XCTAssertEqual(payload, sealed, "\(name): outer payload")
            XCTAssertEqual(try PeripheralCodec.encode(.sealed(payload)), outerJson, "\(name): outer message re-encodes identically")

            // The inner event.
            guard let expected = Self.expectedEvents[name] else {
                XCTFail("\(name): no expectation for this vector; add it to expectedEvents")
                continue
            }
            let inner = try PeripheralCodec.decode(try p2m.open(payload))
            XCTAssertEqual(inner, .event(expected), "\(name): inner event")
            XCTAssertEqual(try PeripheralCodec.encode(inner), plain, "\(name): inner event re-encodes identically")
            if case .event(let event) = inner, case .text(let text) = event.kind, case .text(let wanted) = expected.kind {
                XCTAssertEqual(Array(text.utf8), Array(wanted.utf8), "\(name): text bytes")
            }
        }
    }

    // MARK: Host to phone (`ControlMessage.sealed`, inner `ack`, `status`, `bye`)

    private func checkHostToPhone(_ items: [[String: Any]], m2p: SessionCrypto, p2m: SessionCrypto) throws {
        for item in items {
            let name = try string(item, "name")
            let sealed = try bytes(item, "sealedHex")
            let plain = try bytes(item, "plaintextHex")
            let nonce = try bytes(item, "aeadNonce")

            XCTAssertEqual(Data(try string(item, "plaintext").utf8), plain, "\(name): plaintext vs plaintextHex")
            XCTAssertEqual(try m2p.open(sealed), plain, "\(name): open")
            XCTAssertEqual(sealed.prefix(12), nonce, "\(name): envelope starts with the AEAD nonce")
            XCTAssertEqual(try m2p.seal(plain, nonce: try ChaChaPoly.Nonce(data: nonce)), sealed, "\(name): Swift seal")
            XCTAssertThrowsError(try p2m.open(sealed), "\(name): wrong direction")
            XCTAssertThrowsError(try m2p.open(flippingLastBit(sealed)), "\(name): tampered")

            // The outer message `{"sealed":{"_0":…}}`.
            let outerJson = Data(try string(item, "messageJson").utf8)
            guard case .sealed(let payload) = try ControlCodec.decode(outerJson) else {
                XCTFail("\(name): outer message is not sealed")
                continue
            }
            XCTAssertEqual(payload, sealed, "\(name): outer payload")
            XCTAssertEqual(try ControlCodec.encode(.sealed(payload)), outerJson, "\(name): outer message re-encodes identically")

            guard let expected = Self.expectedControl[name] else {
                XCTFail("\(name): no expectation for this vector; add it to expectedControl")
                continue
            }
            let inner = try ControlCodec.decode(try m2p.open(payload))
            XCTAssertEqual(inner, expected, "\(name): inner message")
            XCTAssertEqual(try ControlCodec.encode(inner), plain, "\(name): inner message re-encodes identically")
        }
    }

    // MARK: Pointer packets

    private func checkPointer(_ items: [[String: Any]], pairKey: SymmetricKey, hostNonce: Data, phoneNonce: Data) throws {
        // One receiving channel for all items in file order, as on a connection: counter 1, then 2^40 + 5.
        let channels = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        var largest: UInt64 = 0
        for item in items {
            let name = try string(item, "name")
            let packet = try bytes(item, "packetHex")
            let plain = try bytes(item, "plaintextHex")
            guard let counter = (item["counter"] as? NSNumber)?.uint64Value else {
                XCTFail("\(name): counter missing")
                continue
            }
            XCTAssertEqual(packet.count, 41, "\(name): length")
            XCTAssertEqual(packet[0], 0x03, "\(name): magic")
            XCTAssertEqual(packet.prefix(9), try bytes(item, "associatedDataHex"), "\(name): associated data")
            XCTAssertEqual(
                packet[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, counter, "\(name): counter in the envelope")
            XCTAssertEqual(
                Data("PTR3".utf8) + Data((0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * UInt64(7 - $0))) }),
                try bytes(item, "aeadNonce"), "\(name): nonce")

            // Shared channel, file order: the replay window accepts each counter (it grows).
            XCTAssertGreaterThan(counter, largest, "\(name): vectors must be in increasing counter order for the shared channel")
            let opener = channels.opener(.pointer)
            let opened = try opener.open(packet).get()
            XCTAssertEqual(opened, plain, "\(name): open")
            XCTAssertEqual(opener.lastOpenedCounter, counter, "\(name): lastOpenedCounter")
            largest = counter
            // The same packet again is a replay now.
            XCTAssertEqual(opener.open(packet), .failure(.replayed), "\(name): replay")

            // A fresh channel also opens it on its own: a counter far above 0 needs no earlier packet.
            let fresh = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
            XCTAssertEqual(try fresh.opener(.pointer).open(packet).get(), plain, "\(name): open on a fresh channel")
            // A flipped bit fails authentication and does not move the window.
            let forged = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce).opener(.pointer)
            XCTAssertEqual(forged.open(flippingLastBit(packet)), .failure(.authFailed), "\(name): tampered")
            XCTAssertEqual(forged.lastOpenedCounter, 0, "\(name): a failed packet leaves the window alone")
            XCTAssertEqual(try forged.open(packet).get(), plain, "\(name): the genuine packet still opens after the forged one")

            // Swift sealing the same plaintext with the next counter after `counter - 1` yields the identical packet.
            let sealerSet = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, startingCounter: counter - 1)
            XCTAssertEqual(try sealerSet.sealer(.pointer).seal(plain), packet, "\(name): Swift seal")

            // The payload decodes to the documented fields.
            guard let decoded = PointerPayload.decode(opened) else {
                XCTFail("\(name): PointerPayload.decode returned nil")
                continue
            }
            XCTAssertEqual(decoded.encode(), plain, "\(name): payload re-encodes identically")
            guard let wanted = Self.expectedPointer[name] else {
                XCTFail("\(name): no expectation for this vector; add it to expectedPointer")
                continue
            }
            XCTAssertEqual(decoded, wanted, "\(name): payload fields")
        }
        XCTAssertTrue(items.contains { ((($0["counter"] as? NSNumber)?.uint64Value) ?? 0) > UInt64(1) << 40 }, "a counter above 2^40 is covered")
    }

    // MARK: Segmentation

    private func checkSegmentation(_ items: [[String: Any]]) throws {
        for item in items {
            guard let messageId = (item["messageId"] as? NSNumber)?.intValue, (0...0xFFFF).contains(messageId),
                  let maxFrameBytes = (item["maxFrameBytes"] as? NSNumber)?.intValue,
                  let length = (item["messageLength"] as? NSNumber)?.intValue,
                  let frameHexes = item["frames"] as? [String]
            else {
                XCTFail("segmentation item is malformed")
                continue
            }
            let label = "id \(messageId) F \(maxFrameBytes)"
            let message = try bytes(item, "messageHex")
            let frames = try frameHexes.map(unhex)
            XCTAssertEqual(message.count, length, "\(label): messageLength")

            // Swift splits the message into the same frames.
            let split = try FrameCodec.split(message, messageId: UInt16(messageId), maxFrameBytes: maxFrameBytes)
            XCTAssertEqual(split, frames, "\(label): split")
            XCTAssertEqual(split.count, frames.count, "\(label): frame count")

            // Swift reassembles the Rust frames into the same message: nothing before the last frame, then the message.
            var reassembler = FrameReassembler()
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame[0], 0x02, "\(label): frame \(index) version")
                XCTAssertEqual(frame.count <= maxFrameBytes, true, "\(label): frame \(index) fits")
                let result = reassembler.accept(frame)
                if index < frames.count - 1 {
                    XCTAssertEqual(result, .incomplete, "\(label): frame \(index)")
                } else {
                    XCTAssertEqual(result, .complete(message), "\(label): last frame completes the message")
                }
            }
            // A message cut short is never delivered: leave out the last frame of a fresh reassembler.
            var partial = FrameReassembler()
            for frame in frames.dropLast() { XCTAssertEqual(partial.accept(frame), .incomplete, "\(label): partial") }
        }
    }
}
