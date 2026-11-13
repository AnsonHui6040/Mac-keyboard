//! A Rust phone talks to a Rust host through the real codecs, fragmentation and encryption, without any radio.

use rk_core::dedup::{DedupDecision, EventDeduplicator};
use rk_core::frame::{split_frames, FrameReassembler, Reassembly};
use rk_core::handshake::{HostHandshake, HostOutput, PhoneHandshake, PhoneOutput, PhoneProgress, Route};
use rk_core::identity::{HostIdentity, HostPlatform, PairedPhone, PhoneIdentity, PhonePlatform};
use rk_core::message::{
    decode_control, decode_peripheral, encode_control, encode_peripheral, Ack, AckResult, CodecError, ControlMessage,
    EventKind, KeyboardEvent, PeripheralMessage, ReceiverStatus,
};
use rk_core::pairing::{HostPairing, HostPairingOutput, PhonePairing, PhonePairingOutput};
use rk_core::pointer::{Opcode, PointerAction, PointerPayload, PointerRejection, PointerReceiver};
use rk_core::secret::PairKey;
use uuid::Uuid;

const MTU: usize = 185;

fn host_identity() -> HostIdentity {
    HostIdentity { id: [0x11; 16], name: "書房的 Windows".into(), platform: HostPlatform::Windows }
}

fn phone_identity(n: u8) -> PhoneIdentity {
    PhoneIdentity { id: [n; 16], name: format!("Phone {n}"), platform: PhonePlatform::Android }
}

fn scalar(n: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    s[31] = n;
    s
}

fn nonce16(n: u8) -> [u8; 16] {
    [n; 16]
}

/// Runs the three pairing messages through the wire codecs and returns the stored phone record.
fn pair(host: &HostIdentity, phone: &PhoneIdentity) -> PairedPhone {
    let mut host_side = HostPairing::new(scalar(7), host.clone()).unwrap();
    let mut phone_side = PhonePairing::new(scalar(9), phone.clone()).unwrap();

    let offer = decode_peripheral(&encode_peripheral(&phone_side.offer())).unwrap();
    let HostPairingOutput::Send(accept) = host_side.receive(&offer) else { panic!("pairAccept expected") };
    let accept = decode_control(&encode_control(&accept)).unwrap();
    let PhonePairingOutput::Send(reveal) = phone_side.receive(&accept) else { panic!("pairReveal expected") };
    let reveal = decode_peripheral(&encode_peripheral(&reveal)).unwrap();
    assert_eq!(host_side.receive(&reveal), HostPairingOutput::Completed);

    assert_eq!(host_side.sas(), phone_side.sas(), "both people see the same pairing code");
    assert_eq!(host_side.pair_key(), phone_side.pair_key());
    assert_eq!(phone_side.host(), Some(host));
    PairedPhone { identity: host_side.phone().unwrap().clone(), pair_key: host_side.pair_key().unwrap().clone() }
}

/// A phone message as the host sees it: encoded, fragmented, delivered frame by frame and put back together.
fn over_the_air(message: &PeripheralMessage, message_id: u16) -> Vec<u8> {
    let frames = split_frames(&encode_peripheral(message), message_id, MTU).unwrap();
    let mut reassembler = FrameReassembler::new();
    let mut complete = None;
    for frame in &frames {
        match reassembler.accept(frame) {
            Reassembly::Incomplete => {}
            Reassembly::Complete(bytes) => complete = Some(bytes),
            Reassembly::Rejected(e) => panic!("frame rejected: {e}"),
        }
    }
    complete.expect("all frames delivered")
}

fn to_host(host: &mut HostHandshake, message: &PeripheralMessage, id: u16) -> HostOutput {
    host.receive_bytes(&over_the_air(message, id))
}

fn to_phone(phone: &mut PhoneHandshake, message: &ControlMessage) -> PhoneOutput {
    phone.receive(&decode_control(&encode_control(message)).unwrap())
}

fn event(seq: u64, kind: EventKind) -> KeyboardEvent {
    KeyboardEvent {
        event_id: Uuid::from_u128(0xE000 + seq as u128),
        session_id: Uuid::from_u128(0x5E55_1011),
        seq,
        focus_epoch: Some(1),
        kind,
    }
}

struct Connected {
    host: HostHandshake,
    phone: PhoneHandshake,
}

/// Selected-route handshake up to authentication on both sides.
fn connect(host_id: [u8; 16], phones: Vec<PairedPhone>, phone_key: PairKey) -> Connected {
    connect_with_nonces(host_id, phones, phone_key, nonce16(0xA0), nonce16(0xB0))
}

/// The same with the nonces of this connection chosen by the caller.
fn connect_with_nonces(
    host_id: [u8; 16],
    phones: Vec<PairedPhone>,
    phone_key: PairKey,
    host_nonce: [u8; 16],
    phone_nonce: [u8; 16],
) -> Connected {
    let mut host = HostHandshake::new(host_id, phones, host_nonce, Route::Selected);
    let mut phone = PhoneHandshake::new(Some((host_id, phone_key)), phone_nonce);
    let HostOutput::Send(hello) = host.begin() else { panic!("hello expected") };
    let PhoneOutput::Send(reply) = to_phone(&mut phone, &hello) else { panic!("helloReply expected") };
    let HostOutput::Authenticated { reply: auth, .. } = to_host(&mut host, &reply, 0) else { panic!("authenticated expected") };
    assert_eq!(to_phone(&mut phone, &auth), PhoneOutput::Authenticated);
    Connected { host, phone }
}

#[test]
fn pair_then_handshake_then_event() {
    let host_id = host_identity();
    let phone_id = phone_identity(1);
    let paired = pair(&host_id, &phone_id);
    assert_eq!(paired.identity, phone_id);

    let mut c = connect(host_id.id, vec![paired.clone()], paired.pair_key.clone());
    assert!(c.host.is_authenticated());
    assert!(c.phone.can_send_events());
    assert_eq!(c.phone.progress(), PhoneProgress::Authenticated);

    // The first encrypted status goes host to phone.
    let mut status = ReceiverStatus::new(true, 1);
    status.pointer_grant = Some(0x1234_5678);
    let sealed = c.host.seal_control(&ControlMessage::Status(status.clone()), &[1; 12]).unwrap();
    assert_eq!(to_phone(&mut c.phone, &sealed), PhoneOutput::Deliver(ControlMessage::Status(status)));

    // Text with a slash, a supplementary-plane character and a CJK character goes phone to host and is acknowledged.
    let typed = event(1, EventKind::Text("書房/🙂 path/to".into()));
    let wire = c.phone.seal_event(&typed, &[2; 12]).unwrap();
    let HostOutput::Event(received) = to_host(&mut c.host, &wire, 1) else { panic!("event expected") };
    assert_eq!(received, typed);
    assert!(!format!("{received:?}").contains("書房"), "Debug output must not carry typed text");

    let mut dedup = EventDeduplicator::new();
    assert_eq!(dedup.check(&received), DedupDecision::Fresh);
    dedup.record(&received, AckResult::Posted);
    assert_eq!(dedup.check(&received), DedupDecision::Duplicate(AckResult::Posted));
    let ack = ControlMessage::Ack(Ack { event_id: received.event_id, result: AckResult::Posted });
    let sealed = c.host.seal_control(&ack, &[3; 12]).unwrap();
    assert_eq!(to_phone(&mut c.phone, &sealed), PhoneOutput::Deliver(ack));

    // A second event of the same session is accepted, an older seq is not.
    let next = event(2, EventKind::Backspace);
    let wire = c.phone.seal_event(&next, &[4; 12]).unwrap();
    assert_eq!(to_host(&mut c.host, &wire, 2), HostOutput::Event(next.clone()));
    assert_eq!(dedup.check(&next), DedupDecision::Fresh);
    dedup.record(&next, AckResult::Posted);
    let stale = event(1, EventKind::ReturnKey);
    let stale = KeyboardEvent { event_id: Uuid::from_u128(0xFFFF), ..stale };
    assert_eq!(dedup.check(&stale), DedupDecision::OutOfOrder);
}

#[test]
fn eight_phones_last_one_authenticates() {
    let host_id = host_identity();
    let phones: Vec<PairedPhone> = (1..=8)
        .map(|n| PairedPhone { identity: phone_identity(n), pair_key: PairKey::new([n; 32]) })
        .collect();
    let last = phones[7].clone();
    let mut host = HostHandshake::new(host_id.id, phones.clone(), nonce16(0xA1), Route::Selected);
    let mut phone = PhoneHandshake::new(Some((host_id.id, last.pair_key.clone())), nonce16(0xB1));
    let HostOutput::Send(hello) = host.begin() else { panic!("hello expected") };
    let PhoneOutput::Send(reply) = to_phone(&mut phone, &hello) else { panic!("helloReply expected") };
    let HostOutput::Authenticated { phone_id, .. } = to_host(&mut host, &reply, 0) else { panic!("authenticated expected") };
    assert_eq!(phone_id, last.identity.id, "the eighth key matched, so the eighth phone is the one connected");

    // The first one authenticates just as well, whatever its place in the list.
    let first = phones[0].clone();
    let mut host = HostHandshake::new(host_id.id, phones, nonce16(0xA2), Route::Selected);
    let mut phone = PhoneHandshake::new(Some((host_id.id, first.pair_key.clone())), nonce16(0xB2));
    let HostOutput::Send(hello) = host.begin() else { panic!("hello expected") };
    let PhoneOutput::Send(reply) = to_phone(&mut phone, &hello) else { panic!("helloReply expected") };
    let HostOutput::Authenticated { phone_id, .. } = to_host(&mut host, &reply, 0) else { panic!("authenticated expected") };
    assert_eq!(phone_id, first.identity.id);
}

#[test]
fn unknown_phone_fails() {
    let host_id = host_identity();
    let known = vec![PairedPhone { identity: phone_identity(1), pair_key: PairKey::new([1; 32]) }];
    let mut host = HostHandshake::new(host_id.id, known, nonce16(0xA3), Route::Selected);
    // A phone that holds a key the host never stored.
    let mut stranger = PhoneHandshake::new(Some((host_id.id, PairKey::new([0x55; 32]))), nonce16(0xB3));
    let HostOutput::Send(hello) = host.begin() else { panic!("hello expected") };
    let PhoneOutput::Send(reply) = to_phone(&mut stranger, &hello) else { panic!("helloReply expected") };
    assert_eq!(to_host(&mut host, &reply, 0), HostOutput::AuthFailed);
    assert!(!host.is_authenticated());
    assert_eq!(to_host(&mut host, &reply, 1), HostOutput::None, "failure is reported once and then the connection is dead");

    // A host that is paired with nobody fails the connection before writing anything.
    let mut empty = HostHandshake::new(host_id.id, vec![], nonce16(0xA4), Route::Selected);
    assert_eq!(empty.begin(), HostOutput::AuthFailed);
}

#[test]
fn hello_for_other_host_replies_not_selected() {
    let mine = host_identity();
    let other = [0x99; 16];
    let paired = pair(&mine, &phone_identity(1));
    // The phone types to host `mine`; a host with another id writes hello.
    let mut other_host = HostHandshake::new(other, vec![paired.clone()], nonce16(0xA5), Route::Selected);
    let mut phone = PhoneHandshake::new(Some((mine.id, paired.pair_key.clone())), nonce16(0xB5));
    let HostOutput::Send(hello) = other_host.begin() else { panic!("hello expected") };
    let PhoneOutput::Send(reply) = to_phone(&mut phone, &hello) else { panic!("notSelected expected") };
    assert_eq!(reply, PeripheralMessage::NotSelected);
    assert_eq!(phone.progress(), PhoneProgress::InProgress, "no state is kept and nothing failed");
    assert_eq!(to_host(&mut other_host, &reply, 0), HostOutput::NotSelected);
    assert_eq!(to_host(&mut other_host, &reply, 1), HostOutput::None);

    // A phone with no current host answers the same way.
    let mut nothing = PhoneHandshake::new(None, nonce16(0xB6));
    let hello = ControlMessage::Hello { host_id: other.to_vec(), host_nonce: nonce16(0xA6).to_vec() };
    assert_eq!(to_phone(&mut nothing, &hello), PhoneOutput::Send(PeripheralMessage::NotSelected));

    // The right host can still handshake afterwards with the same phone object.
    let mut right_host = HostHandshake::new(mine.id, vec![paired], nonce16(0xA7), Route::Selected);
    let HostOutput::Send(hello) = right_host.begin() else { panic!("hello expected") };
    assert!(matches!(to_phone(&mut phone, &hello), PhoneOutput::Send(PeripheralMessage::HelloReply { .. })));
}

#[test]
fn version_3_message_is_unsupported_version() {
    let v3_offer = br#"{"commitment":"qmn6tkRDxcEgxyJGaYUqyjpBwuFUXfRocPOuhb6QpGc=","protocolVersion":3,"type":"pairOffer"}"#;
    assert_eq!(decode_peripheral(v3_offer), Err(CodecError::UnsupportedVersion(3)));
    // The version is read before anything else, so a v3 message with a shape v4 does not know is still a version problem.
    assert_eq!(decode_peripheral(br#"{"protocolVersion":3,"type":"somethingNew"}"#), Err(CodecError::UnsupportedVersion(3)));
    assert_eq!(decode_peripheral(br#"{"protocolVersion":3}"#), Err(CodecError::UnsupportedVersion(3)));
    assert_eq!(decode_peripheral(br#"{"protocolVersion":4}"#), Err(CodecError::Malformed));

    let host_id = host_identity();
    let paired = pair(&host_id, &phone_identity(1));
    let mut host = HostHandshake::new(host_id.id, vec![paired], nonce16(0xA8), Route::Selected);
    assert!(matches!(host.begin(), HostOutput::Send(_)));
    assert_eq!(host.receive_bytes(br#"{"phoneNonce":"sLGys7S1tre4ubq7vL2+vw==","proof":"gSjeDFQ5PKWiJFofBUa6nHIfEWptkf3UzlwjqVieT9A=","protocolVersion":3,"type":"helloReply"}"#), HostOutput::UnsupportedVersion(3));
    assert_eq!(host.receive_bytes(b"{}"), HostOutput::None, "reported once");
}

#[test]
fn tampered_frame_fails_auth() {
    let host_id = host_identity();
    let paired = pair(&host_id, &phone_identity(1));

    // A flipped byte inside the ciphertext: the frames are fine, the AEAD tag is not.
    let mut c = connect(host_id.id, vec![paired.clone()], paired.pair_key.clone());
    let sealed = c.phone.seal_event(&event(1, EventKind::Text("機密".into())), &[5; 12]).unwrap();
    let PeripheralMessage::Sealed(mut payload) = sealed else { panic!("sealed expected") };
    let middle = payload.len() / 2;
    payload[middle] ^= 0x01;
    assert_eq!(to_host(&mut c.host, &PeripheralMessage::Sealed(payload), 1), HostOutput::AuthFailed);

    // A flipped byte inside a frame of the JSON text: whatever it breaks, the connection fails.
    let mut c = connect(host_id.id, vec![paired.clone()], paired.pair_key.clone());
    let sealed = c.phone.seal_event(&event(1, EventKind::Text("機密".into())), &[6; 12]).unwrap();
    let mut frames = split_frames(&encode_peripheral(&sealed), 9, 40).unwrap();
    assert!(frames.len() > 2);
    frames[1][10] ^= 0x04;
    let mut reassembler = FrameReassembler::new();
    let mut whole = None;
    for f in &frames {
        if let Reassembly::Complete(bytes) = reassembler.accept(f) {
            whole = Some(bytes);
        }
    }
    assert_eq!(c.host.receive_bytes(&whole.unwrap()), HostOutput::AuthFailed);

    // A sealed message that was not sealed for this connection: another connection's key.
    let mut c = connect(host_id.id, vec![paired.clone()], paired.pair_key.clone());
    let other = connect_with_nonces(host_id.id, vec![paired.clone()], paired.pair_key, nonce16(0xA9), nonce16(0xB9));
    let foreign = other.phone.seal_event(&event(1, EventKind::Backspace), &[7; 12]).unwrap();
    assert_eq!(to_host(&mut c.host, &foreign, 1), HostOutput::AuthFailed);
}

#[test]
fn replayed_pointer_packet_is_dropped() {
    let host_id = host_identity();
    let paired = pair(&host_id, &phone_identity(1));
    let mut c = connect(host_id.id, vec![paired.clone()], paired.pair_key.clone());

    let mut phone_channels = c.phone.take_channel_set().expect("phone channels");
    assert!(c.phone.take_channel_set().is_none(), "handed out once");
    let host_channels = c.host.take_channel_set().expect("host channels");
    assert!(c.host.take_channel_set().is_none());

    let mut pointer = PointerReceiver::new(true, Box::new(|| 0xABCD));
    pointer.attach(host_channels);
    assert_eq!(pointer.grant(), Some(0xABCD));

    // The phone opens the channel with the grant it read from the status.
    assert_eq!(pointer.handle_open(0xABCD).ack, Some(AckResult::Posted));
    assert!(pointer.is_open());

    let packet = phone_channels
        .sealer()
        .seal(&PointerPayload::new(Opcode::Move, 0, 32, -16, 80, 1).encode())
        .unwrap();
    let t0 = 1_000_000;
    let first = pointer.handle_packet(&packet, t0);
    assert_eq!(first.rejection, None);
    assert!(pointer.needs_frames(), "the movement is queued for playout");
    let played = pointer.frame_tick(t0 + 50_000);
    let moved: f64 = played.actions.iter().map(|a| if let PointerAction::Move { dx, .. } = a { *dx } else { 0.0 }).sum();
    assert!(moved > 0.0, "the first packet moves the cursor right");

    // The same bytes again are a replay: dropped, nothing moves, nothing is queued.
    let replay = pointer.handle_packet(&packet, t0 + 60_000);
    assert_eq!(replay.rejection, Some(PointerRejection::Channel(rk_core::channel::ChannelOpenError::Replayed)));
    assert!(replay.actions.is_empty());
    assert!(!pointer.needs_frames());

    // A fresh packet with the next counter still works afterwards.
    let packet = phone_channels
        .sealer()
        .seal(&PointerPayload::new(Opcode::Move, 0, 16, 0, 80, 1).encode())
        .unwrap();
    assert_eq!(pointer.handle_packet(&packet, t0 + 70_000).rejection, None);
}
