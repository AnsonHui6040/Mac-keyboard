//! The reverse test vectors: what Rust seals and splits, for the Swift tests to open and compare.
//!
//! `cd receiver && cargo test -p rk-core write_rust_vectors -- --ignored` regenerates `receiver/testdata/rust-vectors-v4.json`;
//! `rust_vectors_file_is_current` fails when the committed file differs from what this code produces. The output is
//! deterministic: every key, nonce, AEAD nonce and message is fixed here.

use crate::channel::ChannelSet;
use crate::frame::split_frames;
use crate::json::Json;
use crate::message::{
    encode_control, encode_peripheral, Ack, AckResult, ControlMessage, EventKind, KeyboardEvent, PeripheralMessage, ReceiverStatus,
};
use crate::pointer::{Opcode, PointerPayload, ScrollPhase};
use crate::secret::PairKey;
use crate::session::{derive_session_key, SessionCrypto, SessionDirection};
use uuid::Uuid;

const FILE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../testdata/rust-vectors-v4.json");

// The pair key of docs/protocol/v4.md §5.5 and the nonces of its "記號" section.
const PAIR_KEY: &str = "412eab3b375653317cd096f9c47c74fb2db0edf32aa0897f1ef6a50009b12b20";
const HOST_NONCE: &str = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf";
const PHONE_NONCE: &str = "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf";

fn unhex<const N: usize>(s: &str) -> [u8; N] {
    let bytes: Vec<u8> = (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex digit")).collect();
    bytes.try_into().expect("hex length")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A fixed AEAD nonce for one vector: 12 bytes counting up from `start`.
fn aead_nonce(start: u8) -> [u8; 12] {
    core::array::from_fn(|i| start.wrapping_add(i as u8))
}

fn str_json(s: &str) -> Json {
    Json::string(s)
}

/// Pretty-prints with sorted keys, two-space indentation and a space after each colon.
fn pretty(value: &Json, depth: usize, out: &mut String) {
    let pad = |n: usize| "  ".repeat(n);
    match value {
        Json::Object(map) if map.is_empty() => out.push_str("{}"),
        Json::Object(map) => {
            out.push_str("{\n");
            for (i, (key, v)) in map.iter().enumerate() {
                out.push_str(&pad(depth + 1));
                out.push_str(&String::from_utf8(Json::string(key).to_bytes()).expect("UTF-8"));
                out.push_str(": ");
                pretty(v, depth + 1, out);
                out.push_str(if i + 1 < map.len() { ",\n" } else { "\n" });
            }
            out.push_str(&pad(depth));
            out.push('}');
        }
        Json::Array(items) if items.is_empty() => out.push_str("[]"),
        Json::Array(items) => {
            out.push_str("[\n");
            for (i, v) in items.iter().enumerate() {
                out.push_str(&pad(depth + 1));
                pretty(v, depth + 1, out);
                out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&pad(depth));
            out.push(']');
        }
        other => out.push_str(&String::from_utf8(other.to_bytes()).expect("UTF-8")),
    }
}

fn event(seq: u64, focus_epoch: Option<u64>, kind: EventKind) -> KeyboardEvent {
    KeyboardEvent {
        event_id: Uuid::parse_str("0F8FAD5B-D9CB-469F-A165-70867728950E").expect("uuid"),
        session_id: Uuid::parse_str("7C9E6679-7425-40DE-944B-E07FC1F90AE7").expect("uuid"),
        seq,
        focus_epoch,
        kind,
    }
}

struct Sealed {
    name: &'static str,
    nonce: [u8; 12],
    plaintext: Vec<u8>,
    sealed: Vec<u8>,
    message_json: Vec<u8>,
}

impl Sealed {
    fn to_json(&self) -> Json {
        Json::object([
            ("aeadNonce", str_json(&hex(&self.nonce))),
            ("messageJson", str_json(std::str::from_utf8(&self.message_json).expect("UTF-8"))),
            ("name", str_json(self.name)),
            ("plaintext", str_json(std::str::from_utf8(&self.plaintext).expect("UTF-8"))),
            ("plaintextHex", str_json(&hex(&self.plaintext))),
            ("sealedHex", str_json(&hex(&self.sealed))),
        ])
    }
}

fn seal_event(name: &'static str, crypto: &SessionCrypto, nonce: [u8; 12], e: &KeyboardEvent) -> Sealed {
    let plaintext = encode_peripheral(&PeripheralMessage::Event(e.clone()));
    let PeripheralMessage::Sealed(sealed) = crypto.seal_event(e, &nonce).expect("seal event") else { unreachable!("seal_event gives sealed") };
    let message_json = encode_peripheral(&PeripheralMessage::Sealed(sealed.clone()));
    Sealed { name, nonce, plaintext, sealed, message_json }
}

fn seal_control(name: &'static str, crypto: &SessionCrypto, nonce: [u8; 12], inner: &ControlMessage) -> Sealed {
    let plaintext = encode_control(inner);
    let ControlMessage::Sealed(sealed) = crypto.seal_control(inner, &nonce).expect("seal control") else { unreachable!("seal_control gives sealed") };
    let message_json = encode_control(&ControlMessage::Sealed(sealed.clone()));
    Sealed { name, nonce, plaintext, sealed, message_json }
}

fn generate() -> String {
    let pair_key = PairKey::new(unhex(PAIR_KEY));
    let host_nonce: [u8; 16] = unhex(HOST_NONCE);
    let phone_nonce: [u8; 16] = unhex(PHONE_NONCE);
    let p2m = SessionCrypto::new(&pair_key, &host_nonce, &phone_nonce, SessionDirection::PhoneToHost);
    let m2p = SessionCrypto::new(&pair_key, &host_nonce, &phone_nonce, SessionDirection::HostToPhone);

    // ---- phone to host: events sealed by Rust.
    let long_text: String = "書房的 Mac 🙂 path/to/file 𠮷野家 \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ".repeat(12);
    let phone_to_host = [
        seal_event("textWithSlashAndMultibyte", &p2m, aead_nonce(0x20), &event(1, Some(7), EventKind::Text("書房/🙂 a/b".into()))),
        seal_event("textWithEscapes", &p2m, aead_nonce(0x30), &event(2, Some(7), EventKind::Text("tab\there \"quoted\" back\\slash \u{1} \u{8}\u{c}\r\u{7f}\u{2028}\u{2029}".into()))),
        seal_event("backspace", &p2m, aead_nonce(0x40), &event(3, Some(7), EventKind::Backspace)),
        seal_event("ping", &p2m, aead_nonce(0x50), &event(4, None, EventKind::Ping { shown_at_ms: 120, connected_at_ms: 480 })),
        seal_event("pointerOpen", &p2m, aead_nonce(0x60), &event(5, None, EventKind::PointerOpen { grant: u32::MAX })),
        seal_event("longText", &p2m, aead_nonce(0x70), &event(u64::MAX, Some(u64::MAX), EventKind::Text(long_text))),
    ];
    assert!(
        phone_to_host.iter().any(|s| String::from_utf8_lossy(&s.message_json).contains("\\/")),
        "at least one sealed message carries a base64 slash"
    );

    // ---- host to phone: ack and status sealed by Rust.
    let ack = ControlMessage::Ack(Ack {
        event_id: Uuid::parse_str("0F8FAD5B-D9CB-469F-A165-70867728950E").expect("uuid"),
        result: AckResult::Posted,
    });
    let mut status = ReceiverStatus::new(true, 1);
    status.pointer_grant = Some(0x1234_5678);
    let mut linux_status = ReceiverStatus::new(false, 1);
    linux_status.trusted = false;
    let host_to_phone = [
        seal_control("ack", &m2p, aead_nonce(0x80), &ack),
        seal_control("ackOutOfOrder", &m2p, aead_nonce(0x90), &ControlMessage::Ack(Ack { event_id: Uuid::nil(), result: AckResult::OutOfOrder })),
        seal_control("status", &m2p, aead_nonce(0xA0), &ControlMessage::Status(status)),
        seal_control("statusUntrusted", &m2p, aead_nonce(0xB0), &ControlMessage::Status(linux_status)),
        seal_control("bye", &m2p, aead_nonce(0xC0), &ControlMessage::Bye),
    ];

    // ---- pointer packets: counter 1 and a large counter.
    let pointer_cases: [(&str, u64, PointerPayload); 2] = [
        (
            "scrollBegan",
            1,
            PointerPayload { arg: ScrollPhase::Began as u8, ..PointerPayload::new(Opcode::Scroll, 0x20, -48, 160, 166, 7) },
        ),
        ("heartbeatLeftDown", (1 << 40) + 5, PointerPayload::new(Opcode::Heartbeat, 0x11, 0, 0, 0, 65_535)),
    ];
    let pointer: Vec<Json> = pointer_cases
        .iter()
        .map(|(name, counter, payload)| {
            let mut channels = ChannelSet::with_starting_counter(&pair_key, &host_nonce, &phone_nonce, counter - 1);
            let plain = payload.encode();
            let packet = channels.sealer().seal(&plain).expect("seal pointer packet");
            let mut nonce = b"PTR3".to_vec();
            nonce.extend_from_slice(&counter.to_be_bytes());
            Json::object([
                ("aeadNonce", str_json(&hex(&nonce))),
                ("associatedDataHex", str_json(&hex(&packet[..9]))),
                ("counter", Json::uint(*counter)),
                ("name", str_json(name)),
                ("packetHex", str_json(&hex(&packet))),
                ("plaintextHex", str_json(&hex(&plain))),
            ])
        })
        .collect();

    // ---- segmentation of one long message at two notification sizes.
    let long_message = encode_peripheral(&phone_to_host.last().map(|s| PeripheralMessage::Sealed(s.sealed.clone())).expect("long message"));
    let segmentation: Vec<Json> = [(185usize, 0x0102u16), (23, 0xFFFE)]
        .iter()
        .map(|(max_frame, message_id)| {
            let frames = split_frames(&long_message, *message_id, *max_frame).expect("split");
            Json::object([
                ("frames", Json::Array(frames.iter().map(|f| str_json(&hex(f))).collect())),
                ("maxFrameBytes", Json::uint(*max_frame as u64)),
                ("messageHex", str_json(&hex(&long_message))),
                ("messageId", Json::uint(u64::from(*message_id))),
                ("messageLength", Json::uint(long_message.len() as u64)),
            ])
        })
        .collect();

    let doc = Json::object([
        (
            "about",
            str_json(
                "Generated by rk-core (receiver/rk-core/src/rust_vectors.rs) from the fixed inputs of docs/protocol/v4.md. Do not edit; \
                 rerun: cd receiver && cargo test -p rk-core write_rust_vectors -- --ignored",
            ),
        ),
        (
            "inputs",
            Json::object([
                ("hostNonce", str_json(HOST_NONCE)),
                ("keyHostToPhone", str_json(&hex(derive_session_key(&pair_key, &host_nonce, &phone_nonce, SessionDirection::HostToPhone).expose()))),
                ("keyPhoneToHost", str_json(&hex(derive_session_key(&pair_key, &host_nonce, &phone_nonce, SessionDirection::PhoneToHost).expose()))),
                ("pairKey", str_json(PAIR_KEY)),
                ("phoneNonce", str_json(PHONE_NONCE)),
            ]),
        ),
        ("pointer", Json::Array(pointer)),
        ("protocolVersion", Json::int(4)),
        ("segmentation", Json::Array(segmentation)),
        (
            "session",
            Json::object([
                ("hostToPhone", Json::Array(host_to_phone.iter().map(Sealed::to_json).collect())),
                ("phoneToHost", Json::Array(phone_to_host.iter().map(Sealed::to_json).collect())),
            ]),
        ),
    ]);
    let mut out = String::new();
    pretty(&doc, 0, &mut out);
    out.push('\n');
    out
}

#[test]
#[ignore = "writes receiver/testdata/rust-vectors-v4.json; run with --ignored"]
fn write_rust_vectors() {
    let text = generate();
    assert_eq!(text, generate(), "the output must be deterministic");
    std::fs::write(FILE, text).expect("write rust-vectors-v4.json");
}

/// A checkout with `core.autocrlf` (Windows) turns the file into CRLF; the content is the same.
fn same_content(committed: &str, generated: &str) -> bool {
    committed.replace("\r\n", "\n") == generated
}

#[test]
fn rust_vectors_file_is_current() {
    let committed = std::fs::read_to_string(FILE).expect("receiver/testdata/rust-vectors-v4.json exists; run write_rust_vectors");
    assert!(
        same_content(&committed, &generate()),
        "rust-vectors-v4.json is out of date; rerun: cd receiver && cargo test -p rk-core write_rust_vectors -- --ignored"
    );
}

#[test]
fn a_crlf_checkout_of_the_file_still_counts_as_current_but_a_real_difference_does_not() {
    let generated = generate();
    assert!(same_content(&generated.replace('\n', "\r\n"), &generated), "CRLF line endings only");
    let mut changed = generated.clone();
    changed = changed.replacen("\"protocolVersion\": 4", "\"protocolVersion\": 5", 1);
    assert_ne!(changed, generated);
    assert!(!same_content(&changed, &generated));
    assert!(!same_content(&changed.replace('\n', "\r\n"), &generated));
    // A byte changed in a sealed vector, with CRLF endings: still different.
    let tampered = generated.replacen("\"sealedHex\": \"", "\"sealedHex\": \"00", 1).replace('\n', "\r\n");
    assert!(!same_content(&tampered, &generated));
}

#[test]
fn generated_vectors_are_deterministic_end_with_a_newline_and_have_the_documented_shape() {
    let text = generate();
    assert_eq!(text, generate());
    assert!(text.ends_with("}\n") && !text.ends_with("\n\n"));
    let doc = Json::parse(text.as_bytes()).expect("the file is JSON");
    assert_eq!(doc.get("protocolVersion").and_then(Json::as_u64), Some(4));
    for key in ["about", "inputs", "session", "pointer", "segmentation"] {
        assert!(doc.get(key).is_some(), "{key}");
    }
    let session = doc.get("session").expect("session");
    let p2m = session.get("phoneToHost").and_then(|v| if let Json::Array(a) = v { Some(a) } else { None }).expect("phoneToHost");
    assert!(p2m.len() >= 4);
    let m2p = session.get("hostToPhone").and_then(|v| if let Json::Array(a) = v { Some(a) } else { None }).expect("hostToPhone");
    assert!(m2p.len() >= 2);
}

#[test]
fn every_vector_opens_again_with_the_documented_keys() {
    let text = generate();
    let doc = Json::parse(text.as_bytes()).expect("JSON");
    let pair_key = PairKey::new(unhex(PAIR_KEY));
    let host_nonce: [u8; 16] = unhex(HOST_NONCE);
    let phone_nonce: [u8; 16] = unhex(PHONE_NONCE);
    let p2m = SessionCrypto::new(&pair_key, &host_nonce, &phone_nonce, SessionDirection::PhoneToHost);
    let m2p = SessionCrypto::new(&pair_key, &host_nonce, &phone_nonce, SessionDirection::HostToPhone);
    let list = |v: &Json, key: &str| -> Vec<Json> {
        match v.get(key) {
            Some(Json::Array(a)) => a.clone(),
            _ => panic!("{key} is an array"),
        }
    };
    let field = |v: &Json, key: &str| v.get(key).and_then(Json::as_str).expect("string field").to_string();
    let bytes = |s: &str| -> Vec<u8> { (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect() };
    for case in list(doc.get("session").expect("session"), "phoneToHost") {
        assert_eq!(p2m.open(&bytes(&field(&case, "sealedHex"))).expect("opens"), field(&case, "plaintext").as_bytes());
    }
    for case in list(doc.get("session").expect("session"), "hostToPhone") {
        assert_eq!(m2p.open(&bytes(&field(&case, "sealedHex"))).expect("opens"), field(&case, "plaintext").as_bytes());
    }
    for case in match doc.get("pointer") {
        Some(Json::Array(a)) => a.clone(),
        _ => panic!("pointer is an array"),
    } {
        let mut channels = ChannelSet::new(&pair_key, &host_nonce, &phone_nonce);
        let plain = channels.opener().open(&bytes(&field(&case, "packetHex"))).expect("pointer packet opens");
        assert_eq!(hex(&plain), field(&case, "plaintextHex"));
        assert_eq!(hex(&plain).len(), 32);
    }
}
