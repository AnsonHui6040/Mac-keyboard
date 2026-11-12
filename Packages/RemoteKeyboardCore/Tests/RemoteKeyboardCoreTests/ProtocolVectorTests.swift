import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// Writes the conformance vectors the Rust core (`rk-core`) must reproduce byte for byte, and checks that the file in the
/// repository is the one this code produces. The inputs are the fixed values of docs/protocol/v4.md "記號".
///
///     RK_WRITE_VECTORS=1 swift test --package-path Packages/RemoteKeyboardCore --filter ProtocolVectorTests
///
/// rewrites `receiver/testdata/swift-vectors-v4.json`. Nothing here is a real key or a real identity.
final class ProtocolVectorTests: XCTestCase {
    private static let vectorsPath = "receiver/testdata/swift-vectors-v4.json"

    private static var repoRoot: URL {
        // …/Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/ProtocolVectorTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func testVectorsFileIsCurrent() throws {
        let generated = try Self.makeVectors()
        let url = Self.repoRoot.appendingPathComponent(Self.vectorsPath)
        if ProcessInfo.processInfo.environment["RK_WRITE_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: url)
            return
        }
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(
            String(decoding: onDisk, as: UTF8.self), String(decoding: generated, as: UTF8.self),
            "receiver/testdata/swift-vectors-v4.json is stale; rerun with RK_WRITE_VECTORS=1")
        XCTAssertEqual(onDisk, generated)
    }

    func testGenerationIsDeterministic() throws {
        XCTAssertEqual(try Self.makeVectors(), try Self.makeVectors())
    }

    // MARK: Generation

    private static func hex(_ data: some Sequence<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { hex($0) } }

    private static func json(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private static func identityDigest(name: String, platform: String) -> Data {
        Data(SHA256.hash(data: Data(name.utf8) + [0] + Data(platform.utf8)))
    }

    private static func scalars(_ string: String) -> [String] {
        string.unicodeScalars.map { "U+" + String(format: "%04X", $0.value) }
    }

    static func makeVectors() throws -> Data {
        let hostKey = scalarKey(1)
        let phoneKey = scalarKey(2)
        let hostPublic = Pairing.publicKeyData(hostKey)
        let phonePublic = Pairing.publicKeyData(phoneKey)
        let hostId = Data((0..<16).map { UInt8($0) })
        let phoneId = Data((16..<32).map { UInt8($0) })
        let host = HostIdentity(id: hostId, name: "書房的 Mac", platform: .mac)
        let phone = PhoneIdentity(id: phoneId, name: "Anson 的 iPhone", platform: .ios)
        let hostNonce = Data((0..<16).map { UInt8(0xA0 + $0) })
        let phoneNonce = Data((0..<16).map { UInt8(0xB0 + $0) })

        // Pairing, run through the real reducers.
        var phonePairing = PhonePairing(privateKey: phoneKey, phone: phone)
        var hostPairing = MacPairing(privateKey: hostKey, host: host)
        let offer = phonePairing.offer
        guard case .send(let accept) = hostPairing.receive(offer), case .send(let reveal) = phonePairing.receive(accept),
              hostPairing.receive(reveal) == .completed, let pairKey = hostPairing.pairKey, let sas = hostPairing.sas,
              hostPairing.sas == phonePairing.sas, let phoneSideKey = phonePairing.pairKey, hex(pairKey) == hex(phoneSideKey)
        else { throw VectorError.pairingFailed }
        guard case .pairOffer(let commitment) = offer else { throw VectorError.pairingFailed }
        let z = try hostKey.sharedSecretFromKeyAgreement(with: phoneKey.publicKey).withUnsafeBytes { Data($0) }

        // The eighteen JSON examples of docs/protocol/v4.md §3.2 to §3.4.
        let eventId = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
        let sessionId = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!
        func event(_ seq: UInt64, _ epoch: UInt64?, _ kind: EventKind) -> KeyboardEvent {
            KeyboardEvent(protocolVersion: 4, eventId: eventId, sessionId: sessionId, seq: seq, focusEpoch: epoch, kind: kind)
        }
        let textEvent = PeripheralMessage.event(event(1, 7, .text("A")))
        let ack = ControlMessage.ack(Ack(eventId: eventId, result: .posted))
        let proofPhone = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        let proofHost = Pairing.hostProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)

        let p2m = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let m2p = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        let textPlain = try PeripheralCodec.encode(textEvent)
        let ackPlain = try ControlCodec.encode(ack)
        let nonceP2M = Data((0..<12).map { UInt8($0) })
        let nonceM2P = Data((0..<12).map { UInt8(0x10 + $0) })
        let sealedP2M = try p2m.seal(textPlain, nonce: ChaChaPoly.Nonce(data: nonceP2M))
        let sealedM2P = try m2p.seal(ackPlain, nonce: ChaChaPoly.Nonce(data: nonceM2P))

        struct Example { let section: String; let name: String; let bytes: Data }
        let examples: [Example] = [
            Example(section: "3.2", name: "pairAccept", bytes: try ControlCodec.encode(.pairAccept(publicKey: hostPublic, host: host))),
            Example(section: "3.2", name: "hello", bytes: try ControlCodec.encode(.hello(hostId: hostId, hostNonce: hostNonce))),
            Example(section: "3.2", name: "auth", bytes: try ControlCodec.encode(.auth(proof: proofHost))),
            Example(section: "3.2", name: "authFailed", bytes: try ControlCodec.encode(.authFailed)),
            Example(section: "3.2", name: "ack", bytes: ackPlain),
            Example(
                section: "3.2", name: "status",
                bytes: try ControlCodec.encode(.status(ReceiverStatus(ready: true, appName: "備忘錄", focusEpoch: 12, pointerGrant: 305_419_896)))),
            Example(
                section: "3.2", name: "statusUntrusted",
                bytes: try ControlCodec.encode(.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, trusted: false)))),
            Example(section: "3.2", name: "bye", bytes: try ControlCodec.encode(.bye)),
            Example(section: "3.2", name: "sealedControl", bytes: try ControlCodec.encode(.sealed(sealedM2P))),
            Example(section: "3.3", name: "pairOffer", bytes: try PeripheralCodec.encode(offer)),
            Example(section: "3.3", name: "pairReveal", bytes: try PeripheralCodec.encode(reveal)),
            Example(
                section: "3.3", name: "helloReply",
                bytes: try PeripheralCodec.encode(.helloReply(phoneNonce: phoneNonce, proof: proofPhone))),
            Example(section: "3.3", name: "notSelected", bytes: try PeripheralCodec.encode(.notSelected)),
            Example(section: "3.3", name: "sealedEvent", bytes: try PeripheralCodec.encode(.sealed(sealedP2M))),
            Example(section: "3.4", name: "eventText", bytes: textPlain),
            Example(section: "3.4", name: "eventBackspace", bytes: try PeripheralCodec.encode(.event(event(2, 7, .backspace)))),
            Example(
                section: "3.4", name: "eventPing",
                bytes: try PeripheralCodec.encode(.event(event(3, nil, .ping(shownAtMs: 120, connectedAtMs: 480))))),
            Example(
                section: "3.4", name: "eventPointerOpen",
                bytes: try PeripheralCodec.encode(.event(event(4, nil, .pointerOpen(grant: 305_419_896))))),
        ]
        let messages: [[String: Any]] = examples.map {
            ["section": $0.section, "name": $0.name, "json": json($0.bytes), "utf8Hex": hex($0.bytes)]
        }

        // Name clamping (docs/protocol/v4.md §4).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let nameCases = ["書房的 Mac", String(repeating: "測", count: 11), "a" + String(repeating: family, count: 8)]
        let names: [[String: Any]] = nameCases.map { input in
            let clamped = IdentityName.clamp(input)
            return [
                "input": input, "inputUtf8Length": input.utf8.count, "inputScalars": scalars(input),
                "clamped": clamped, "clampedUtf8Length": clamped.utf8.count, "clampedScalars": scalars(clamped),
                "clampedUtf8Hex": hex(clamped.utf8),
            ]
        }

        // Selected UUIDs.
        let selectIds = [hostId, phoneId, Data(repeating: 0x00, count: 16), Data(repeating: 0xFF, count: 16)]
        let selects: [[String: Any]] = selectIds.map { ["hostId": hex($0), "uuid": SelectUUID.make(hostId: $0).uuidString] }

        // Pointer packet.
        let channels = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        let pointerPlain = PointerPayload(opcode: .move, buttons: 0x10, dx: 24, dy: -8, dt: 83, buttonSeq: 0).encode()
        let pointerPacket = try channels.sealer(.pointer).seal(pointerPlain)
        let pointerNonce = Data("PTR3".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 1])

        // Segmentation of a 600-byte message into frames of 185 bytes.
        let big = Data((0..<600).map { UInt8(truncatingIfNeeded: $0) })
        let frames = try FrameCodec.split(big, messageId: 0x0102, maxFrameBytes: 185)

        let root: [String: Any] = [
            "about": "Generated by ProtocolVectorTests from the fixed inputs of docs/protocol/v4.md. Do not edit; rerun with RK_WRITE_VECTORS=1.",
            "protocolVersion": 4,
            "inputs": [
                "hostPrivateScalar": 1, "phonePrivateScalar": 2,
                "hostId": hex(hostId), "hostName": host.name, "hostPlatform": host.platform.rawValue,
                "phoneId": hex(phoneId), "phoneName": phone.name, "phonePlatform": phone.platform.rawValue,
                "hostNonce": hex(hostNonce), "phoneNonce": hex(phoneNonce),
            ] as [String: Any],
            "advertising": [
                "pairingAdvertUUID": GATTServiceSpec.Link.pairingAdvertUUID,
                "selectUUIDs": selects,
            ] as [String: Any],
            "names": names,
            "pairing": [
                "hostPublic": hex(hostPublic), "phonePublic": hex(phonePublic), "commitment": hex(commitment),
                "z": hex(z),
                "hostIdentityHash": hex(identityDigest(name: host.name, platform: host.platform.rawValue)),
                "phoneIdentityHash": hex(identityDigest(name: phone.name, platform: phone.platform.rawValue)),
                "pairKey": hex(pairKey), "sas": sas,
            ] as [String: Any],
            "handshake": [
                "phoneProof": hex(proofPhone), "hostProof": hex(proofHost),
            ] as [String: Any],
            "session": [
                "keyPhoneToHost": hex(p2m.keyDataForTesting), "keyHostToPhone": hex(m2p.keyDataForTesting),
                "phoneToHost": [
                    "aeadNonce": hex(nonceP2M), "plaintext": json(textPlain), "plaintextHex": hex(textPlain),
                    "sealedHex": hex(sealedP2M),
                ] as [String: Any],
                "hostToPhone": [
                    "aeadNonce": hex(nonceM2P), "plaintext": json(ackPlain), "plaintextHex": hex(ackPlain),
                    "sealedHex": hex(sealedM2P),
                ] as [String: Any],
            ] as [String: Any],
            "pointer": [
                "key": channels.keyDataForTesting(.pointer).withUnsafeBytes { hex($0) } ,
                "counter": 1,
                "plaintextHex": hex(pointerPlain), "aeadNonce": hex(pointerNonce),
                "associatedDataHex": hex(pointerPacket.prefix(9)), "packetHex": hex(pointerPacket),
            ] as [String: Any],
            "segmentation": [
                "messageLength": big.count, "maxFrameBytes": 185, "messageId": 0x0102,
                "messageHex": hex(big),
                "frames": frames.map { hex($0) },
            ] as [String: Any],
            "messages": messages,
        ]
        var data = try JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private enum VectorError: Error { case pairingFailed }
}
