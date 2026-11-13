//! Checks rk-core against `receiver/testdata/swift-vectors-v4.json`, which the Swift implementation generates from the fixed
//! inputs of docs/protocol/v4.md. Nothing here edits that file.

use rk_core::channel::{derive_pointer_key, ChannelOpenError, ChannelSet, PACKET_LEN, POINTER_MAGIC};
use rk_core::frame::{split_frames, FrameReassembler, Reassembly};
use rk_core::identity::{clamp_name, identity_hash, HostIdentity, HostPlatform, PhoneIdentity, PhonePlatform};
use rk_core::message::{
    decode_control, decode_peripheral, encode_control, encode_peripheral, Ack, AckResult, ControlMessage, EventKind,
    KeyboardEvent, PeripheralMessage, ReceiverStatus,
};
use rk_core::pairing::{
    commitment, derive_pair_key, ecdh_x, host_proof, phone_proof, public_key, sas, verify_host_proof, verify_phone_proof,
    HostPairing, HostPairingOutput, PhonePairing, PhonePairingOutput, Role,
};
use rk_core::pointer::{Opcode, PointerPayload};
use rk_core::secret::PairKey;
use rk_core::select_uuid::{select_uuid, PAIRING_ADVERT_UUID};
use rk_core::session::{derive_session_key, OpenedEvent, SessionCrypto, SessionDirection};
use serde_json::Value;
use std::collections::BTreeMap;
use uuid::Uuid;

fn vectors() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../testdata/swift-vectors-v4.json");
    let text = std::fs::read_to_string(path).expect("swift vector file is readable");
    serde_json::from_str(&text).expect("swift vector file is JSON")
}

fn unhex(s: &str) -> Vec<u8> {
    assert_eq!(s.len() % 2, 0, "odd hex length");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex digit")).collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn arr<const N: usize>(bytes: Vec<u8>) -> [u8; N] {
    bytes.try_into().unwrap_or_else(|v: Vec<u8>| panic!("expected {N} bytes, got {}", v.len()))
}

fn text<'a>(v: &'a Value, path: &[&str]) -> &'a str {
    let mut cur = v;
    for key in path {
        cur = &cur[*key];
    }
    cur.as_str().unwrap_or_else(|| panic!("{path:?} is not a string"))
}

fn scalar(n: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    s[31] = n;
    s
}

struct Inputs {
    host: HostIdentity,
    phone: PhoneIdentity,
    host_nonce: [u8; 16],
    phone_nonce: [u8; 16],
}

fn inputs(v: &Value) -> Inputs {
    let i = &v["inputs"];
    Inputs {
        host: HostIdentity {
            id: arr(unhex(text(i, &["hostId"]))),
            name: text(i, &["hostName"]).to_string(),
            platform: HostPlatform::from_wire(text(i, &["hostPlatform"])).expect("host platform"),
        },
        phone: PhoneIdentity {
            id: arr(unhex(text(i, &["phoneId"]))),
            name: text(i, &["phoneName"]).to_string(),
            platform: PhonePlatform::from_wire(text(i, &["phonePlatform"])).expect("phone platform"),
        },
        host_nonce: arr(unhex(text(i, &["hostNonce"]))),
        phone_nonce: arr(unhex(text(i, &["phoneNonce"]))),
    }
}

fn pair_key(v: &Value) -> PairKey {
    PairKey::new(arr(unhex(text(v, &["pairing", "pairKey"]))))
}

enum Msg {
    Control(ControlMessage),
    Peripheral(PeripheralMessage),
}

fn event_ids() -> (Uuid, Uuid) {
    (
        Uuid::parse_str("0F8FAD5B-D9CB-469F-A165-70867728950E").unwrap(),
        Uuid::parse_str("7C9E6679-7425-40DE-944B-E07FC1F90AE7").unwrap(),
    )
}

fn event(seq: u64, focus_epoch: Option<u64>, kind: EventKind) -> KeyboardEvent {
    let (event_id, session_id) = event_ids();
    KeyboardEvent { event_id, session_id, seq, focus_epoch, kind }
}

/// Builds each of the 18 messages from its structure, using only the fixed inputs and the vector's own byte strings.
fn rebuild(v: &Value) -> BTreeMap<String, Msg> {
    let inp = inputs(v);
    let host_public = unhex(text(v, &["pairing", "hostPublic"]));
    let phone_public = unhex(text(v, &["pairing", "phonePublic"]));
    let (event_id, _) = event_ids();
    let mut m = BTreeMap::new();
    let mut put = |name: &str, msg: Msg| {
        m.insert(name.to_string(), msg);
    };
    put(
        "pairAccept",
        Msg::Control(ControlMessage::PairAccept {
            public_key: host_public,
            host_id: inp.host.id.to_vec(),
            host_name: inp.host.name.clone(),
            platform: inp.host.platform,
        }),
    );
    put("hello", Msg::Control(ControlMessage::Hello { host_id: inp.host.id.to_vec(), host_nonce: inp.host_nonce.to_vec() }));
    put("auth", Msg::Control(ControlMessage::Auth { proof: unhex(text(v, &["handshake", "hostProof"])) }));
    put("authFailed", Msg::Control(ControlMessage::AuthFailed));
    put("ack", Msg::Control(ControlMessage::Ack(Ack { event_id, result: AckResult::Posted })));
    let mut status = ReceiverStatus::new(true, 12);
    status.app_name = Some("備忘錄".to_string());
    status.pointer_grant = Some(305_419_896);
    put("status", Msg::Control(ControlMessage::Status(status)));
    let mut untrusted = ReceiverStatus::new(false, 1);
    untrusted.trusted = false;
    put("statusUntrusted", Msg::Control(ControlMessage::Status(untrusted)));
    put("bye", Msg::Control(ControlMessage::Bye));
    put("sealedControl", Msg::Control(ControlMessage::Sealed(unhex(text(v, &["session", "hostToPhone", "sealedHex"])))));
    put("pairOffer", Msg::Peripheral(PeripheralMessage::PairOffer { commitment: unhex(text(v, &["pairing", "commitment"])) }));
    put(
        "pairReveal",
        Msg::Peripheral(PeripheralMessage::PairReveal {
            public_key: phone_public,
            phone_id: inp.phone.id.to_vec(),
            phone_name: inp.phone.name.clone(),
            phone_platform: inp.phone.platform,
        }),
    );
    put(
        "helloReply",
        Msg::Peripheral(PeripheralMessage::HelloReply {
            phone_nonce: inp.phone_nonce.to_vec(),
            proof: unhex(text(v, &["handshake", "phoneProof"])),
        }),
    );
    put("notSelected", Msg::Peripheral(PeripheralMessage::NotSelected));
    put("sealedEvent", Msg::Peripheral(PeripheralMessage::Sealed(unhex(text(v, &["session", "phoneToHost", "sealedHex"])))));
    put("eventText", Msg::Peripheral(PeripheralMessage::Event(event(1, Some(7), EventKind::Text("A".into())))));
    put("eventBackspace", Msg::Peripheral(PeripheralMessage::Event(event(2, Some(7), EventKind::Backspace))));
    put(
        "eventPing",
        Msg::Peripheral(PeripheralMessage::Event(event(3, None, EventKind::Ping { shown_at_ms: 120, connected_at_ms: 480 }))),
    );
    put(
        "eventPointerOpen",
        Msg::Peripheral(PeripheralMessage::Event(event(4, None, EventKind::PointerOpen { grant: 305_419_896 }))),
    );
    m
}

fn encode(msg: &Msg) -> Vec<u8> {
    match msg {
        Msg::Control(c) => encode_control(c),
        Msg::Peripheral(p) => encode_peripheral(p),
    }
}

#[test]
fn encodes_every_message_byte_for_byte() {
    let v = vectors();
    let built = rebuild(&v);
    let listed = v["messages"].as_array().expect("messages");
    assert_eq!(listed.len(), 18, "the vector file lists 18 messages");
    let mut with_escaped_slash = 0;
    for entry in listed {
        let name = text(entry, &["name"]);
        let expected_json = text(entry, &["json"]);
        let msg = built.get(name).unwrap_or_else(|| panic!("no rebuilt message named {name}"));
        let bytes = encode(msg);
        assert_eq!(bytes, expected_json.as_bytes(), "{name}: bytes differ from the Swift JSON");
        assert_eq!(hex(&bytes), text(entry, &["utf8Hex"]), "{name}: utf8Hex differs");
        let out = String::from_utf8(bytes).expect("UTF-8");
        assert!(!out.replace("\\/", "").contains('/'), "{name}: a slash is not escaped");
        if expected_json.contains("\\/") {
            assert!(out.contains("\\/"), "{name}: Swift escapes a slash and Rust must too");
            with_escaped_slash += 1;
        }
    }
    assert!(with_escaped_slash >= 4, "the vectors must exercise \\/ (found {with_escaped_slash} messages)");
}

#[test]
fn decodes_every_message() {
    let v = vectors();
    for entry in v["messages"].as_array().expect("messages") {
        let name = text(entry, &["name"]);
        let json = text(entry, &["json"]);
        let section = text(entry, &["section"]);
        let reencoded = if section == "3.2" {
            encode_control(&decode_control(json.as_bytes()).unwrap_or_else(|e| panic!("{name}: {e}")))
        } else {
            encode_peripheral(&decode_peripheral(json.as_bytes()).unwrap_or_else(|e| panic!("{name}: {e}")))
        };
        assert_eq!(reencoded, json.as_bytes(), "{name}: decode then encode changed the bytes");
    }
}

#[test]
fn derives_pair_key_and_sas() {
    let v = vectors();
    let inp = inputs(&v);
    let p = &v["pairing"];

    let host_public = public_key(&scalar(1)).expect("host key");
    let phone_public = public_key(&scalar(2)).expect("phone key");
    assert_eq!(hex(&host_public), text(p, &["hostPublic"]));
    assert_eq!(hex(&phone_public), text(p, &["phonePublic"]));
    assert_eq!(hex(&commitment(&phone_public)), text(p, &["commitment"]));
    assert_eq!(hex(ecdh_x(&scalar(1), &phone_public).unwrap().expose()), text(p, &["z"]));
    assert_eq!(hex(ecdh_x(&scalar(2), &host_public).unwrap().expose()), text(p, &["z"]));
    assert_eq!(hex(&identity_hash(&inp.host.name, "mac")), text(p, &["hostIdentityHash"]));
    assert_eq!(hex(&identity_hash(&inp.phone.name, "ios")), text(p, &["phoneIdentityHash"]));

    let from_host = derive_pair_key(&scalar(1), Role::Host, &phone_public, &inp.host, &inp.phone).unwrap();
    let from_phone = derive_pair_key(&scalar(2), Role::Phone, &host_public, &inp.host, &inp.phone).unwrap();
    assert_eq!(hex(from_host.expose()), text(p, &["pairKey"]));
    assert_eq!(from_host, from_phone);
    assert_eq!(sas(&from_host), text(p, &["sas"]));

    // The same through the two reducers, message by message, against the vector's bytes.
    let built = rebuild(&v);
    let mut host = HostPairing::new(scalar(1), inp.host.clone()).unwrap();
    let mut phone = PhonePairing::new(scalar(2), inp.phone.clone()).unwrap();
    let offer = phone.offer();
    assert_eq!(encode(&Msg::Peripheral(offer.clone())), encode(&built["pairOffer"]));
    let HostPairingOutput::Send(accept) = host.receive(&offer) else { panic!("host should answer pairOffer") };
    assert_eq!(encode(&Msg::Control(accept.clone())), encode(&built["pairAccept"]));
    let PhonePairingOutput::Send(reveal) = phone.receive(&accept) else { panic!("phone should reveal") };
    assert_eq!(encode(&Msg::Peripheral(reveal.clone())), encode(&built["pairReveal"]));
    assert_eq!(host.receive(&reveal), HostPairingOutput::Completed);
    assert_eq!(hex(host.pair_key().unwrap().expose()), text(p, &["pairKey"]));
    assert_eq!(hex(phone.pair_key().unwrap().expose()), text(p, &["pairKey"]));
    assert_eq!(host.sas(), Some("947102"));
    assert_eq!(phone.sas(), Some("947102"));
    assert_eq!(host.phone(), Some(&inp.phone));
    assert_eq!(phone.host(), Some(&inp.host));
}

#[test]
fn verifies_both_proofs() {
    let v = vectors();
    let inp = inputs(&v);
    let key = pair_key(&v);
    let phone = phone_proof(&key, &inp.host_nonce, &inp.phone_nonce);
    let host = host_proof(&key, &inp.host_nonce, &inp.phone_nonce);
    assert_eq!(hex(&phone), text(&v, &["handshake", "phoneProof"]));
    assert_eq!(hex(&host), text(&v, &["handshake", "hostProof"]));
    assert!(verify_phone_proof(&phone, &key, &inp.host_nonce, &inp.phone_nonce));
    assert!(verify_host_proof(&host, &key, &inp.host_nonce, &inp.phone_nonce));
    // The labels keep the two proofs apart.
    assert!(!verify_phone_proof(&host, &key, &inp.host_nonce, &inp.phone_nonce));
    assert!(!verify_host_proof(&phone, &key, &inp.host_nonce, &inp.phone_nonce));
    // A proof or nonce of the wrong length is a mismatch.
    assert!(!verify_phone_proof(&phone[..31], &key, &inp.host_nonce, &inp.phone_nonce));
    assert!(!verify_phone_proof(&phone, &key, &inp.host_nonce[..15], &inp.phone_nonce));
    assert!(!verify_phone_proof(&phone, &key, &inp.host_nonce, &[inp.phone_nonce.as_slice(), &[0]].concat()));
}

#[test]
fn opens_swift_session_ciphertext_both_directions() {
    let v = vectors();
    let inp = inputs(&v);
    let key = pair_key(&v);
    let s = &v["session"];

    let k_p2m = derive_session_key(&key, &inp.host_nonce, &inp.phone_nonce, SessionDirection::PhoneToHost);
    let k_m2p = derive_session_key(&key, &inp.host_nonce, &inp.phone_nonce, SessionDirection::HostToPhone);
    assert_eq!(hex(k_p2m.expose()), text(s, &["keyPhoneToHost"]));
    assert_eq!(hex(k_m2p.expose()), text(s, &["keyHostToPhone"]));

    let p2m = SessionCrypto::new(&key, &inp.host_nonce, &inp.phone_nonce, SessionDirection::PhoneToHost);
    let m2p = SessionCrypto::new(&key, &inp.host_nonce, &inp.phone_nonce, SessionDirection::HostToPhone);

    for (crypto, which) in [(&p2m, "phoneToHost"), (&m2p, "hostToPhone")] {
        let case = &s[which];
        let sealed = unhex(text(case, &["sealedHex"]));
        let plain = unhex(text(case, &["plaintextHex"]));
        assert_eq!(plain, text(case, &["plaintext"]).as_bytes());
        assert_eq!(crypto.open(&sealed).unwrap_or_else(|e| panic!("{which}: {e}")), plain, "{which}: plaintext");
        let nonce: [u8; 12] = arr(unhex(text(case, &["aeadNonce"])));
        assert_eq!(crypto.seal(&plain, &nonce).unwrap(), sealed, "{which}: sealing with the vector nonce reproduces Swift");
    }
    // The wrong direction cannot open it.
    assert!(m2p.open(&unhex(text(&s["phoneToHost"], &["sealedHex"]))).is_err());
    assert!(p2m.open(&unhex(text(&s["hostToPhone"], &["sealedHex"]))).is_err());

    // Through the wire messages: the sealed payload of the vector JSON opens to the typed event and ack.
    let built = rebuild(&v);
    let Msg::Peripheral(PeripheralMessage::Sealed(payload)) = &built["sealedEvent"] else { panic!("sealedEvent") };
    let Msg::Peripheral(PeripheralMessage::Event(expected)) = &built["eventText"] else { panic!("eventText") };
    assert_eq!(p2m.open_event(payload).unwrap(), OpenedEvent::Event(expected.clone()));
    let Msg::Control(ControlMessage::Sealed(payload)) = &built["sealedControl"] else { panic!("sealedControl") };
    let Msg::Control(expected) = &built["ack"] else { panic!("ack") };
    assert_eq!(&m2p.open_control(payload).unwrap(), expected);
}

#[test]
fn opens_swift_pointer_packet() {
    let v = vectors();
    let inp = inputs(&v);
    let key = pair_key(&v);
    let p = &v["pointer"];
    assert_eq!(hex(derive_pointer_key(&key, &inp.host_nonce, &inp.phone_nonce).expose()), text(p, &["key"]));

    let packet = unhex(text(p, &["packetHex"]));
    let plain = unhex(text(p, &["plaintextHex"]));
    assert_eq!(packet.len(), PACKET_LEN);
    assert_eq!(packet[0], POINTER_MAGIC);
    assert_eq!(hex(&packet[..9]), text(p, &["associatedDataHex"]));
    assert_eq!(p["counter"].as_u64(), Some(1));

    let mut host = ChannelSet::new(&key, &inp.host_nonce, &inp.phone_nonce);
    assert_eq!(host.opener().open(&packet).expect("Swift packet opens"), plain);
    assert_eq!(host.opener().last_opened_counter(), 1);
    assert_eq!(host.opener().open(&packet), Err(ChannelOpenError::Replayed), "the same packet twice");

    // The first packet Rust seals under the same key and counter 1 is byte for byte the Swift packet.
    let mut phone = ChannelSet::new(&key, &inp.host_nonce, &inp.phone_nonce);
    assert_eq!(phone.sealer().seal(&plain).unwrap(), packet);

    let payload = PointerPayload::decode(&plain).expect("readable");
    assert_eq!(payload, PointerPayload::new(Opcode::Move, 0x10, 24, -8, 83, 0));
}

#[test]
fn splits_and_reassembles_frames() {
    let v = vectors();
    let s = &v["segmentation"];
    let message = unhex(text(s, &["messageHex"]));
    assert_eq!(message.len() as u64, s["messageLength"].as_u64().unwrap());
    let max_frame = s["maxFrameBytes"].as_u64().unwrap() as usize;
    let id = s["messageId"].as_u64().unwrap() as u16;
    let expected: Vec<Vec<u8>> = s["frames"].as_array().unwrap().iter().map(|f| unhex(f.as_str().unwrap())).collect();

    let frames = split_frames(&message, id, max_frame).unwrap();
    assert_eq!(frames, expected);
    assert_eq!(frames.iter().map(|f| f.len() - 5).collect::<Vec<_>>(), [180, 180, 180, 60]);

    let mut r = FrameReassembler::new();
    for (i, f) in expected.iter().enumerate() {
        let got = r.accept(f);
        if i + 1 < expected.len() {
            assert_eq!(got, Reassembly::Incomplete);
        } else {
            assert_eq!(got, Reassembly::Complete(message.clone()));
        }
    }
}

#[test]
fn select_uuid_matches() {
    let v = vectors();
    let a = &v["advertising"];
    for entry in a["selectUUIDs"].as_array().unwrap() {
        let host_id: [u8; 16] = arr(unhex(text(entry, &["hostId"])));
        let got = select_uuid(&host_id);
        assert_eq!(got.hyphenated().to_string().to_uppercase(), text(entry, &["uuid"]));
        let bytes = got.as_bytes();
        assert_eq!(bytes[6] >> 4, 4, "version nibble");
        assert_eq!(bytes[8] >> 6, 0b10, "variant bits");
    }
    assert_eq!(PAIRING_ADVERT_UUID.hyphenated().to_string().to_uppercase(), text(a, &["pairingAdvertUUID"]));
}

#[test]
fn clamp_name_matches() {
    let v = vectors();
    for entry in v["names"].as_array().unwrap() {
        let input = text(entry, &["input"]);
        assert_eq!(input.len() as u64, entry["inputUtf8Length"].as_u64().unwrap());
        let clamped = clamp_name(input);
        assert_eq!(clamped, text(entry, &["clamped"]));
        assert_eq!(hex(clamped.as_bytes()), text(entry, &["clampedUtf8Hex"]));
        assert_eq!(clamped.len() as u64, entry["clampedUtf8Length"].as_u64().unwrap());
        let scalars: Vec<String> = clamped.chars().map(|c| format!("U+{:04X}", c as u32)).collect();
        let listed: Vec<&str> = entry["clampedScalars"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
        assert_eq!(scalars, listed);
    }
}
