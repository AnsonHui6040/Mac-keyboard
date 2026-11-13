//! The challenge-response between a paired phone and a host (protocol v4 §6).

use crate::channel::ChannelSet;
use crate::identity::{PairedPhone, PhonePlatform, ID_LEN, MAX_PHONES};
use crate::message::{decode_peripheral, CodecError, ControlMessage, KeyboardEvent, PeripheralMessage};
use crate::pairing::{
    host_proof, parse_public, phone_proof, verify_host_proof, verify_phone_proof, COMMITMENT_LEN, NONCE_LEN, PUBLIC_KEY_LEN,
};
use crate::secret::PairKey;
use crate::session::{OpenedEvent, SessionCrypto, SessionDirection, SessionError, SessionPin};
use std::fmt;
use thiserror::Error;

/// Why a seal call was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum HandshakeError {
    #[error("not authenticated")]
    NotAuthenticated,
    #[error("only ack, status and bye may be sealed")]
    InvalidControlMessage,
    #[error("sealing failed")]
    SealFailed,
}

impl From<SessionError> for HandshakeError {
    fn from(_: SessionError) -> Self {
        Self::SealFailed
    }
}

/// How the connection was found (§1.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// Through the host's selected UUID: only the handshake runs.
    Selected,
    /// Through the pairing UUID: only pairing runs.
    Pairing,
}

/// What the host's handshake asks the adapter to do (§6.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostOutput {
    None,
    /// Write this to `control`.
    Send(ControlMessage),
    /// The phone proof matched the key of `phone_id`: write `reply` (`auth`).
    Authenticated { reply: ControlMessage, phone_id: [u8; 16] },
    /// Pairing step 1, to be handed to `HostPairing` if the pairing window is open.
    PairOffer { commitment: Vec<u8> },
    /// Pairing step 3, to be handed to `HostPairing`.
    PairReveal { public_key: Vec<u8>, phone_id: Vec<u8>, phone_name: String, phone_platform: PhonePlatform },
    /// A verified, decrypted event.
    Event(KeyboardEvent),
    /// Authenticated and decrypted, but the inner message is unreadable: answer `malformed` (§7.2).
    MalformedPayload,
    /// Write `authFailed`, disconnect, hold the device off (§6.2). Reported once.
    AuthFailed,
    /// The keyboard types to another host: disconnect without `authFailed`, back off 10 s (§6.4). Reported once.
    NotSelected,
    /// The 5-second handshake timer ran out: disconnect without `authFailed`, back off (§6.2). Reported once.
    TimedOut,
    /// A plaintext message of another protocol version: show the update note, disconnect, hold off (§10). Reported once.
    UnsupportedVersion(i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HostState {
    Idle,
    AwaitingReply,
    Authenticated,
    Failed,
}

/// What an authenticated connection keeps: the key, the nonces and the two session directions.
struct HostSession {
    pair_key: PairKey,
    phone_nonce: [u8; NONCE_LEN],
    p2m: SessionCrypto,
    m2p: SessionCrypto,
}

/// The host's side of one connection. One instance per connection, built with a fresh nonce; a new connection needs a
/// new one (a recorded `helloReply` must never become valid again).
pub struct HostHandshake {
    host_id: [u8; ID_LEN],
    phones: Vec<PairedPhone>,
    host_nonce: [u8; NONCE_LEN],
    route: Route,
    state: HostState,
    /// `pairOffer` was accepted on a pairing-route connection: the 5-second timer no longer applies (§6.2).
    pairing_started: bool,
    session: Option<HostSession>,
    pin: SessionPin,
    channel_set_taken: bool,
}

impl fmt::Debug for HostHandshake {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HostHandshake([redacted])")
    }
}

impl HostHandshake {
    /// `phones` in storage order; only the first eight are used, which bounds the HMACs one reply can cost (§6.2). Empty
    /// when nothing is paired, in which case a connection on the `Selected` route fails from `begin()` before anything is
    /// written. `host_nonce` is fresh for this connection.
    pub fn new(host_id: [u8; 16], phones: Vec<PairedPhone>, host_nonce: [u8; 16], route: Route) -> Self {
        Self {
            host_id,
            phones: phones.into_iter().take(MAX_PHONES).collect(),
            host_nonce,
            route,
            state: HostState::Idle,
            pairing_started: false,
            session: None,
            pin: SessionPin::new(),
            channel_set_taken: false,
        }
    }

    /// Starts the challenge once the link is ready (§6.2). On the `Pairing` route nothing is written: the phone speaks
    /// first with `pairOffer`.
    pub fn begin(&mut self) -> HostOutput {
        if self.state != HostState::Idle {
            return HostOutput::None;
        }
        if self.route == Route::Pairing {
            return HostOutput::None;
        }
        // No key to check a reply against: a connection through the selected UUID with nobody paired is a failure.
        if self.phones.is_empty() {
            return self.fail();
        }
        self.state = HostState::AwaitingReply;
        HostOutput::Send(ControlMessage::Hello { host_id: self.host_id.to_vec(), host_nonce: self.host_nonce.to_vec() })
    }

    /// Reads one reassembled message and handles it (§6.2, §10). Bytes that are not a message fail the connection; a
    /// plaintext message of another version is reported on its own and does not.
    pub fn receive_bytes(&mut self, bytes: &[u8]) -> HostOutput {
        if self.state == HostState::Failed {
            return HostOutput::None;
        }
        match decode_peripheral(bytes) {
            Ok(message) => self.receive(&message),
            Err(CodecError::Malformed) => self.fail(),
            Err(CodecError::UnsupportedVersion(version)) => {
                self.end();
                HostOutput::UnsupportedVersion(version)
            }
        }
    }

    /// Handles one decoded phone message (§6.2). Before authentication only `helloReply` (`Selected`) or `pairOffer`
    /// and `pairReveal` (`Pairing`) are acceptable, afterwards only `sealed`; a plaintext `event` is a violation at every
    /// point. `notSelected` is the one message that ends the connection without a failure.
    pub fn receive(&mut self, message: &PeripheralMessage) -> HostOutput {
        if self.state == HostState::Failed {
            return HostOutput::None;
        }
        match message {
            PeripheralMessage::Event(_) => self.fail(),
            PeripheralMessage::PairOffer { commitment } => {
                if self.route != Route::Pairing || self.state == HostState::Authenticated || commitment.len() != COMMITMENT_LEN {
                    return self.fail();
                }
                self.pairing_started = true;
                HostOutput::PairOffer { commitment: commitment.clone() }
            }
            PeripheralMessage::PairReveal { public_key, phone_id, phone_name, phone_platform } => {
                if self.route != Route::Pairing
                    || self.state == HostState::Authenticated
                    || public_key.len() != PUBLIC_KEY_LEN
                    || parse_public(public_key).is_err()
                {
                    return self.fail();
                }
                HostOutput::PairReveal {
                    public_key: public_key.clone(),
                    phone_id: phone_id.clone(),
                    phone_name: phone_name.clone(),
                    phone_platform: *phone_platform,
                }
            }
            PeripheralMessage::NotSelected => {
                if self.route != Route::Selected || self.state == HostState::Authenticated {
                    return self.fail();
                }
                self.end();
                HostOutput::NotSelected
            }
            PeripheralMessage::HelloReply { phone_nonce, proof } => {
                if self.route != Route::Selected || self.state != HostState::AwaitingReply {
                    return self.fail();
                }
                self.verify_reply(phone_nonce, proof)
            }
            PeripheralMessage::Sealed(payload) => self.receive_sealed(payload),
        }
    }

    /// The host does not know who answers. Every stored key is checked, constant time each and without stopping at the
    /// first hit, so the time taken does not tell where in the list the phone was; the first match is the phone (§6.2).
    fn verify_reply(&mut self, phone_nonce: &[u8], proof: &[u8]) -> HostOutput {
        let mut matched: Option<usize> = None;
        for (index, entry) in self.phones.iter().enumerate() {
            let ok = verify_phone_proof(proof, &entry.pair_key, &self.host_nonce, phone_nonce);
            if ok && matched.is_none() {
                matched = Some(index);
            }
        }
        let (Some(index), Ok(phone_nonce)) = (matched, <[u8; NONCE_LEN]>::try_from(phone_nonce)) else {
            return self.fail();
        };
        let entry = &self.phones[index];
        let pair_key = entry.pair_key.clone();
        let phone_id = entry.identity.id;
        let reply = ControlMessage::Auth { proof: host_proof(&pair_key, &self.host_nonce, &phone_nonce).to_vec() };
        self.session = Some(HostSession {
            p2m: SessionCrypto::new(&pair_key, &self.host_nonce, &phone_nonce, SessionDirection::PhoneToHost),
            m2p: SessionCrypto::new(&pair_key, &self.host_nonce, &phone_nonce, SessionDirection::HostToPhone),
            pair_key,
            phone_nonce,
        });
        self.state = HostState::Authenticated;
        HostOutput::Authenticated { reply, phone_id }
    }

    fn receive_sealed(&mut self, payload: &[u8]) -> HostOutput {
        let Some(session) = self.session.as_ref().filter(|_| self.state == HostState::Authenticated) else {
            return self.fail();
        };
        match session.p2m.open_event(payload) {
            Ok(OpenedEvent::Event(event)) => {
                // The first sessionId of the connection is pinned; another one is a violation (§7.4).
                if self.pin.accept(event.session_id) {
                    HostOutput::Event(event)
                } else {
                    self.fail()
                }
            }
            Ok(OpenedEvent::Malformed) => HostOutput::MalformedPayload,
            Ok(OpenedEvent::NotAnEvent) | Err(_) => self.fail(),
        }
    }

    /// The 5-second timer ran out (§6.2): only disconnect, no `authFailed`. Does not apply once authenticated, nor once a
    /// pairing attempt has begun (its limit is the pairing window).
    pub fn on_timeout(&mut self) -> HostOutput {
        if matches!(self.state, HostState::Failed | HostState::Authenticated) || self.pairing_started {
            return HostOutput::None;
        }
        self.end();
        HostOutput::TimedOut
    }

    /// True once the phone's proof verified.
    pub fn is_authenticated(&self) -> bool {
        self.state == HostState::Authenticated
    }

    /// The counter channel of this connection, once, after authentication. Keep it for the life of the connection:
    /// asking again would give a second set whose counters start at 1 under the same key.
    pub fn take_channel_set(&mut self) -> Option<ChannelSet> {
        if self.state != HostState::Authenticated || self.channel_set_taken {
            return None;
        }
        let session = self.session.as_ref()?;
        self.channel_set_taken = true;
        Some(ChannelSet::new(&session.pair_key, &self.host_nonce, &session.phone_nonce))
    }

    /// Wraps an `ack`, `status` or `bye` for the wire (§7.2). After authentication the host writes nothing else on
    /// `control` except `authFailed`. `nonce` is 12 fresh random bytes.
    pub fn seal_control(&self, message: &ControlMessage, nonce: &[u8; 12]) -> Result<ControlMessage, HandshakeError> {
        let session = self.session.as_ref().filter(|_| self.state == HostState::Authenticated).ok_or(HandshakeError::NotAuthenticated)?;
        session.m2p.seal_control(message, nonce).map_err(|e| match e {
            SessionError::InvalidInner => HandshakeError::InvalidControlMessage,
            _ => HandshakeError::SealFailed,
        })
    }

    /// The connection is over without a failure to report again: no state is kept that could be used.
    fn end(&mut self) {
        self.state = HostState::Failed;
        self.session = None;
    }

    fn fail(&mut self) -> HostOutput {
        self.end();
        HostOutput::AuthFailed
    }
}

/// What the phone's handshake asks the adapter to do (§6.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PhoneOutput {
    None,
    /// Notify this message to the host.
    Send(PeripheralMessage),
    /// The host proved itself; events may now be sent.
    Authenticated,
    /// An `ack`, `status` or `bye` the app may act on.
    Deliver(ControlMessage),
    /// The handshake failed; this connection never carries an event.
    Failed,
}

/// Where the phone's handshake stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhoneProgress {
    InProgress,
    Authenticated,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PhoneState {
    AwaitingHello,
    AwaitingAuth,
    Authenticated,
    Failed,
}

/// The phone's side of one connection. One instance per connection, built with a fresh nonce.
pub struct PhoneHandshake {
    selected: Option<([u8; ID_LEN], PairKey)>,
    phone_nonce: [u8; NONCE_LEN],
    state: PhoneState,
    host_nonce: [u8; NONCE_LEN],
    p2m: Option<SessionCrypto>,
    m2p: Option<SessionCrypto>,
    channel_set_taken: bool,
}

impl fmt::Debug for PhoneHandshake {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PhoneHandshake([redacted])")
    }
}

impl PhoneHandshake {
    /// `selected` is the current host's id and pair key; `None` when the phone has no current host, in which case every
    /// well-formed `hello` is answered with `notSelected`. `phone_nonce` is fresh for this connection.
    pub fn new(selected: Option<([u8; 16], PairKey)>, phone_nonce: [u8; 16]) -> Self {
        Self {
            selected,
            phone_nonce,
            state: PhoneState::AwaitingHello,
            host_nonce: [0; NONCE_LEN],
            p2m: None,
            m2p: None,
            channel_set_taken: false,
        }
    }

    /// True only after the host's `auth` verified. Until then the phone sends no event.
    pub fn can_send_events(&self) -> bool {
        self.state == PhoneState::Authenticated
    }

    /// Where the handshake stands, for deciding whether a connected link is worth keeping.
    pub fn progress(&self) -> PhoneProgress {
        match self.state {
            PhoneState::AwaitingHello | PhoneState::AwaitingAuth => PhoneProgress::InProgress,
            PhoneState::Authenticated => PhoneProgress::Authenticated,
            PhoneState::Failed => PhoneProgress::Failed,
        }
    }

    /// Handles one host message from the bound central (§6.3). Which central wrote it is `CentralBinding`'s business.
    pub fn receive(&mut self, message: &ControlMessage) -> PhoneOutput {
        if self.state == PhoneState::Failed {
            return PhoneOutput::None;
        }
        match message {
            ControlMessage::Hello { host_id, host_nonce } => {
                // Row 1: a malformed hello fails this connection.
                let (Ok(host_id), Ok(host_nonce)) = (<[u8; ID_LEN]>::try_from(host_id.as_slice()), <[u8; NONCE_LEN]>::try_from(host_nonce.as_slice())) else {
                    return self.fail();
                };
                // Row 2: meant for another host, or there is no current host. Plain `notSelected`, no state kept, the
                // same answer whether or not this phone was ever paired with `host_id`.
                let Some((_, pair_key)) = self.selected.as_ref().filter(|(current, _)| *current == host_id) else {
                    return PhoneOutput::Send(PeripheralMessage::NotSelected);
                };
                // Row 4: a second hello for this host, before or after `auth`, is a protocol violation.
                if self.state != PhoneState::AwaitingHello {
                    return self.fail();
                }
                // Row 3.
                let proof = phone_proof(pair_key, &host_nonce, &self.phone_nonce);
                self.host_nonce = host_nonce;
                self.state = PhoneState::AwaitingAuth;
                PhoneOutput::Send(PeripheralMessage::HelloReply { phone_nonce: self.phone_nonce.to_vec(), proof: proof.to_vec() })
            }
            ControlMessage::Auth { proof } => {
                let verified = match (&self.state, &self.selected) {
                    (PhoneState::AwaitingAuth, Some((_, key))) => verify_host_proof(proof, key, &self.host_nonce, &self.phone_nonce),
                    _ => false,
                };
                if !verified {
                    return self.fail();
                }
                let Some((_, key)) = self.selected.as_ref() else {
                    return self.fail();
                };
                self.p2m = Some(SessionCrypto::new(key, &self.host_nonce, &self.phone_nonce, SessionDirection::PhoneToHost));
                self.m2p = Some(SessionCrypto::new(key, &self.host_nonce, &self.phone_nonce, SessionDirection::HostToPhone));
                self.state = PhoneState::Authenticated;
                PhoneOutput::Authenticated
            }
            ControlMessage::AuthFailed => self.fail(),
            ControlMessage::Ack(_) | ControlMessage::Status(_) | ControlMessage::Bye => {
                // After authentication the host only sends these sealed, so a plain one is a violation; before it they are dropped.
                if self.state == PhoneState::Authenticated {
                    self.fail()
                } else {
                    PhoneOutput::None
                }
            }
            ControlMessage::Sealed(payload) => {
                let inner = match (&self.state, &self.m2p) {
                    (PhoneState::Authenticated, Some(m2p)) => m2p.open_control(payload).ok(),
                    _ => None,
                };
                match inner {
                    Some(inner) => PhoneOutput::Deliver(inner),
                    None => self.fail(),
                }
            }
            // Pairing is handled outside the handshake.
            ControlMessage::PairAccept { .. } => PhoneOutput::None,
        }
    }

    /// The counter channel of this connection, once, after the host's proof verified. `None` before that, after a failure
    /// and on every later call.
    pub fn take_channel_set(&mut self) -> Option<ChannelSet> {
        if self.state != PhoneState::Authenticated || self.channel_set_taken {
            return None;
        }
        let (_, key) = self.selected.as_ref()?;
        self.channel_set_taken = true;
        Some(ChannelSet::new(key, &self.host_nonce, &self.phone_nonce))
    }

    /// Wraps one event for the wire (§7.2). Refused until authenticated. `nonce` is 12 fresh random bytes.
    pub fn seal_event(&self, event: &KeyboardEvent, nonce: &[u8; 12]) -> Result<PeripheralMessage, HandshakeError> {
        let p2m = self.p2m.as_ref().filter(|_| self.state == PhoneState::Authenticated).ok_or(HandshakeError::NotAuthenticated)?;
        p2m.seal_event(event, nonce).map_err(HandshakeError::from)
    }

    fn fail(&mut self) -> PhoneOutput {
        self.state = PhoneState::Failed;
        self.p2m = None;
        self.m2p = None;
        PhoneOutput::Failed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::PhoneIdentity;
    use crate::message::{encode_peripheral, Ack, AckResult, EventKind, ReceiverStatus};
    use crate::pairing::{commitment, public_key};
    use uuid::Uuid;

    const HOST_ID: [u8; 16] = [0x11; 16];
    const HOST_NONCE: [u8; 16] = [0xA0; 16];
    const PHONE_NONCE: [u8; 16] = [0xB0; 16];

    fn key(n: u8) -> PairKey {
        PairKey::new([n; 32])
    }

    fn paired(n: u8) -> PairedPhone {
        PairedPhone { identity: PhoneIdentity { id: [n; 16], name: format!("p{n}"), platform: PhonePlatform::Ios }, pair_key: key(n) }
    }

    fn host(route: Route, phones: Vec<PairedPhone>) -> HostHandshake {
        HostHandshake::new(HOST_ID, phones, HOST_NONCE, route)
    }

    fn phone(n: u8) -> PhoneHandshake {
        PhoneHandshake::new(Some((HOST_ID, key(n))), PHONE_NONCE)
    }

    fn event(session: u128, seq: u64, kind: EventKind) -> KeyboardEvent {
        KeyboardEvent { event_id: Uuid::from_u128(u128::from(seq) + 1000), session_id: Uuid::from_u128(session), seq, focus_epoch: None, kind }
    }

    fn good_reply(n: u8) -> PeripheralMessage {
        PeripheralMessage::HelloReply {
            phone_nonce: PHONE_NONCE.to_vec(),
            proof: phone_proof(&key(n), &HOST_NONCE, &PHONE_NONCE).to_vec(),
        }
    }

    /// A host on the selected route that has written `hello` and is waiting for the reply.
    fn waiting_host(phones: Vec<PairedPhone>) -> HostHandshake {
        let mut h = host(Route::Selected, phones);
        assert!(matches!(h.begin(), HostOutput::Send(ControlMessage::Hello { .. })));
        h
    }

    /// A pair of handshakes that completed.
    fn connected(n: u8) -> (HostHandshake, PhoneHandshake) {
        let mut h = waiting_host(vec![paired(n)]);
        let mut p = phone(n);
        let ControlMessage::Hello { .. } = (match h.begin() {
            HostOutput::None => ControlMessage::Hello { host_id: vec![], host_nonce: vec![] },
            other => panic!("{other:?}"),
        }) else {
            unreachable!()
        };
        let hello = ControlMessage::Hello { host_id: HOST_ID.to_vec(), host_nonce: HOST_NONCE.to_vec() };
        let PhoneOutput::Send(reply) = p.receive(&hello) else { panic!("helloReply expected") };
        let HostOutput::Authenticated { reply: auth, .. } = h.receive(&reply) else { panic!("authenticated expected") };
        assert_eq!(p.receive(&auth), PhoneOutput::Authenticated);
        (h, p)
    }

    fn sealed_event(p: &PhoneHandshake, e: &KeyboardEvent) -> PeripheralMessage {
        p.seal_event(e, &[9; 12]).unwrap()
    }

    // ---- host: §6.2 when the link is ready

    #[test]
    fn selected_route_with_keys_writes_hello() {
        let mut h = host(Route::Selected, vec![paired(1)]);
        assert_eq!(
            h.begin(),
            HostOutput::Send(ControlMessage::Hello { host_id: HOST_ID.to_vec(), host_nonce: HOST_NONCE.to_vec() })
        );
        assert_eq!(h.begin(), HostOutput::None, "begin runs once");
    }

    #[test]
    fn selected_route_without_any_key_fails_before_writing() {
        let mut h = host(Route::Selected, vec![]);
        assert_eq!(h.begin(), HostOutput::AuthFailed);
        assert_eq!(h.begin(), HostOutput::None);
    }

    #[test]
    fn pairing_route_writes_no_hello_even_when_keys_exist() {
        let mut h = host(Route::Pairing, vec![paired(1)]);
        assert_eq!(h.begin(), HostOutput::None);
        let offer = PeripheralMessage::PairOffer { commitment: vec![0; 32] };
        assert_eq!(h.receive(&offer), HostOutput::PairOffer { commitment: vec![0; 32] });
    }

    // ---- host: §6.2 "treated as an authentication failure", one test per row

    #[test]
    fn row_bytes_that_are_not_a_message_fail() {
        for junk in [&b"garbage"[..], b"{}", br#"{"protocolVersion":4,"type":"unknownType"}"#, br#"{"protocolVersion":4}"#, b""] {
            let mut h = waiting_host(vec![paired(1)]);
            assert_eq!(h.receive_bytes(junk), HostOutput::AuthFailed, "{}", String::from_utf8_lossy(junk));
        }
    }

    #[test]
    fn row_plaintext_event_fails_before_and_after_authentication() {
        let plain = PeripheralMessage::Event(event(1, 1, EventKind::Text("x".into())));
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.receive(&plain), HostOutput::AuthFailed);
        let (mut h, _) = connected(1);
        assert_eq!(h.receive(&plain), HostOutput::AuthFailed);
        let mut h = host(Route::Pairing, vec![]);
        assert_eq!(h.receive(&plain), HostOutput::AuthFailed);
    }

    #[test]
    fn row_pair_offer_or_reveal_after_authentication_fails() {
        for message in [
            PeripheralMessage::PairOffer { commitment: vec![0; 32] },
            PeripheralMessage::PairReveal { public_key: public_key(&[1; 32]).unwrap().to_vec(), phone_id: vec![1; 16], phone_name: "p".into(), phone_platform: PhonePlatform::Ios },
        ] {
            let (mut h, _) = connected(1);
            assert_eq!(h.receive(&message), HostOutput::AuthFailed, "{message:?}");
        }
    }

    #[test]
    fn row_pair_offer_or_reveal_with_a_bad_length_or_key_fails_even_on_the_pairing_route() {
        let good_key = public_key(&[1; 32]).unwrap();
        let bad_offers = [vec![0; 31], vec![0; 33], vec![]];
        for c in bad_offers {
            let mut h = host(Route::Pairing, vec![]);
            assert_eq!(h.receive(&PeripheralMessage::PairOffer { commitment: c }), HostOutput::AuthFailed);
        }
        let mut off_curve = good_key;
        off_curve[64] ^= 1;
        let bad_keys = [good_key[..64].to_vec(), [good_key.as_slice(), &[0]].concat(), off_curve.to_vec(), vec![0; 65], vec![]];
        for k in bad_keys {
            let mut h = host(Route::Pairing, vec![]);
            let reveal = PeripheralMessage::PairReveal { public_key: k.clone(), phone_id: vec![1; 16], phone_name: "p".into(), phone_platform: PhonePlatform::Ios };
            assert_eq!(h.receive(&reveal), HostOutput::AuthFailed, "key of {} bytes", k.len());
        }
        let mut h = host(Route::Pairing, vec![]);
        let reveal = PeripheralMessage::PairReveal { public_key: good_key.to_vec(), phone_id: vec![1; 16], phone_name: "p".into(), phone_platform: PhonePlatform::Ios };
        assert!(matches!(h.receive(&reveal), HostOutput::PairReveal { .. }));
    }

    #[test]
    fn row_pair_offer_or_reveal_on_a_selected_route_connection_fails() {
        let good_key = public_key(&[1; 32]).unwrap();
        let messages = [
            PeripheralMessage::PairOffer { commitment: commitment(&good_key).to_vec() },
            PeripheralMessage::PairReveal { public_key: good_key.to_vec(), phone_id: vec![1; 16], phone_name: "p".into(), phone_platform: PhonePlatform::Ios },
        ];
        for message in messages {
            let mut h = waiting_host(vec![paired(1)]);
            assert_eq!(h.receive(&message), HostOutput::AuthFailed);
        }
    }

    #[test]
    fn row_hello_reply_or_sealed_on_a_pairing_route_connection_fails() {
        for message in [good_reply(1), PeripheralMessage::Sealed(vec![0; 40])] {
            let mut h = host(Route::Pairing, vec![paired(1)]);
            assert_eq!(h.begin(), HostOutput::None);
            assert_eq!(h.receive(&message), HostOutput::AuthFailed);
        }
    }

    #[test]
    fn row_not_selected_after_authentication_or_on_a_pairing_route_fails() {
        let (mut h, _) = connected(1);
        assert_eq!(h.receive(&PeripheralMessage::NotSelected), HostOutput::AuthFailed);
        let mut h = host(Route::Pairing, vec![]);
        assert_eq!(h.receive(&PeripheralMessage::NotSelected), HostOutput::AuthFailed);
    }

    #[test]
    fn not_selected_while_waiting_ends_the_connection_without_a_failure_and_only_once() {
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.receive(&PeripheralMessage::NotSelected), HostOutput::NotSelected);
        assert_eq!(h.receive(&good_reply(1)), HostOutput::None);
        assert!(!h.is_authenticated());
    }

    #[test]
    fn row_hello_reply_when_not_waiting_fails() {
        // Before hello was written.
        let mut h = host(Route::Selected, vec![paired(1)]);
        assert_eq!(h.receive(&good_reply(1)), HostOutput::AuthFailed);
        // After authentication.
        let (mut h, _) = connected(1);
        assert_eq!(h.receive(&good_reply(1)), HostOutput::AuthFailed);
    }

    #[test]
    fn row_hello_reply_with_a_proof_that_does_not_verify_fails() {
        let wrong_key = PeripheralMessage::HelloReply {
            phone_nonce: PHONE_NONCE.to_vec(),
            proof: phone_proof(&key(9), &HOST_NONCE, &PHONE_NONCE).to_vec(),
        };
        let host_label = PeripheralMessage::HelloReply {
            phone_nonce: PHONE_NONCE.to_vec(),
            proof: host_proof(&key(1), &HOST_NONCE, &PHONE_NONCE).to_vec(),
        };
        let other_nonce = PeripheralMessage::HelloReply {
            phone_nonce: vec![0xB1; 16],
            proof: phone_proof(&key(1), &HOST_NONCE, &PHONE_NONCE).to_vec(),
        };
        let mut last_byte = phone_proof(&key(1), &HOST_NONCE, &PHONE_NONCE);
        last_byte[31] ^= 1;
        let last_byte = PeripheralMessage::HelloReply { phone_nonce: PHONE_NONCE.to_vec(), proof: last_byte.to_vec() };
        let mut first_byte = phone_proof(&key(1), &HOST_NONCE, &PHONE_NONCE);
        first_byte[0] ^= 1;
        let first_byte = PeripheralMessage::HelloReply { phone_nonce: PHONE_NONCE.to_vec(), proof: first_byte.to_vec() };
        let short_proof = PeripheralMessage::HelloReply { phone_nonce: PHONE_NONCE.to_vec(), proof: vec![0; 31] };
        let short_nonce = PeripheralMessage::HelloReply {
            phone_nonce: PHONE_NONCE[..15].to_vec(),
            proof: phone_proof(&key(1), &HOST_NONCE, &PHONE_NONCE[..15].try_into().map_or(PHONE_NONCE, |_: [u8; 15]| PHONE_NONCE)).to_vec(),
        };
        for bad in [wrong_key, host_label, other_nonce, last_byte, first_byte, short_proof, short_nonce] {
            let mut h = waiting_host(vec![paired(1), paired(2)]);
            assert_eq!(h.receive(&bad), HostOutput::AuthFailed, "{bad:?}");
        }
    }

    #[test]
    fn row_sealed_before_authentication_fails() {
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.receive(&PeripheralMessage::Sealed(vec![0; 40])), HostOutput::AuthFailed);
    }

    #[test]
    fn row_sealed_that_does_not_open_fails() {
        let (mut h, _) = connected(1);
        assert_eq!(h.receive(&PeripheralMessage::Sealed(vec![0; 40])), HostOutput::AuthFailed);
        let (mut h, _) = connected(1);
        assert_eq!(h.receive(&PeripheralMessage::Sealed(vec![0; 5])), HostOutput::AuthFailed);
        // Sealed for another connection (other nonces).
        let (mut h, _) = connected(1);
        let other = SessionCrypto::new(&key(1), &HOST_NONCE, &[0xB1; 16], SessionDirection::PhoneToHost);
        let foreign = other.seal_event(&event(1, 1, EventKind::Backspace), &[1; 12]).unwrap();
        assert_eq!(h.receive(&foreign), HostOutput::AuthFailed);
    }

    #[test]
    fn row_sealed_with_a_valid_inner_that_is_not_an_event_fails() {
        for inner in [PeripheralMessage::NotSelected, PeripheralMessage::PairOffer { commitment: vec![0; 32] }] {
            let (mut h, _) = connected(1);
            let crypto = SessionCrypto::new(&key(1), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
            let sealed = crypto.seal(&encode_peripheral(&inner), &[2; 12]).unwrap();
            assert_eq!(h.receive(&PeripheralMessage::Sealed(sealed)), HostOutput::AuthFailed, "{inner:?}");
        }
    }

    #[test]
    fn row_a_second_session_id_on_one_connection_fails() {
        let (mut h, p) = connected(1);
        assert!(matches!(h.receive(&sealed_event(&p, &event(7, 1, EventKind::Backspace))), HostOutput::Event(_)));
        assert!(matches!(h.receive(&sealed_event(&p, &event(7, 2, EventKind::Probe))), HostOutput::Event(_)), "the same session continues");
        assert_eq!(h.receive(&sealed_event(&p, &event(8, 1, EventKind::Backspace))), HostOutput::AuthFailed);
        assert_eq!(h.receive(&sealed_event(&p, &event(7, 3, EventKind::Backspace))), HostOutput::None, "dead after the failure");
    }

    #[test]
    fn a_sealed_event_after_authentication_is_delivered_and_an_unreadable_inner_is_malformed_not_a_failure() {
        let (mut h, p) = connected(1);
        let e = event(1, 1, EventKind::Text("機密/🙂".into()));
        assert_eq!(h.receive(&sealed_event(&p, &e)), HostOutput::Event(e));
        let crypto = SessionCrypto::new(&key(1), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        for junk in [&b"{}"[..], b"junk", br#"{"protocolVersion":3,"type":"notSelected"}"#] {
            let sealed = crypto.seal(junk, &[3; 12]).unwrap();
            assert_eq!(h.receive(&PeripheralMessage::Sealed(sealed)), HostOutput::MalformedPayload);
        }
        assert!(h.is_authenticated(), "still authenticated afterwards");
        let next = event(1, 2, EventKind::Backspace);
        assert_eq!(h.receive(&sealed_event(&p, &next)), HostOutput::Event(next));
    }

    // ---- host: version mismatch, timeout, results are reported once

    #[test]
    fn a_plaintext_message_of_another_version_is_reported_once_and_is_not_an_auth_failure() {
        let mut h = waiting_host(vec![paired(1)]);
        let v3 = br#"{"commitment":"AA==","protocolVersion":3,"type":"pairOffer"}"#;
        assert_eq!(h.receive_bytes(v3), HostOutput::UnsupportedVersion(3));
        assert_eq!(h.receive_bytes(v3), HostOutput::None);
        assert!(!h.is_authenticated());
        let mut h = host(Route::Pairing, vec![]);
        assert_eq!(h.receive_bytes(br#"{"protocolVersion":99,"type":"x"}"#), HostOutput::UnsupportedVersion(99));
    }

    #[test]
    fn the_handshake_timer_ends_the_connection_without_auth_failed() {
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.on_timeout(), HostOutput::TimedOut);
        assert_eq!(h.on_timeout(), HostOutput::None);
        assert_eq!(h.receive(&good_reply(1)), HostOutput::None, "a late reply is not used");
        // Before `begin` too.
        let mut h = host(Route::Selected, vec![paired(1)]);
        assert_eq!(h.on_timeout(), HostOutput::TimedOut);
    }

    #[test]
    fn the_timer_does_not_apply_once_authenticated() {
        let (mut h, _) = connected(1);
        assert_eq!(h.on_timeout(), HostOutput::None);
        assert!(h.is_authenticated());
    }

    #[test]
    fn on_the_pairing_route_the_timer_runs_until_a_pair_offer_arrives() {
        let mut h = host(Route::Pairing, vec![]);
        assert_eq!(h.on_timeout(), HostOutput::TimedOut);
        let mut h = host(Route::Pairing, vec![]);
        assert!(matches!(h.receive(&PeripheralMessage::PairOffer { commitment: vec![0; 32] }), HostOutput::PairOffer { .. }));
        assert_eq!(h.on_timeout(), HostOutput::None, "the pairing window limits the attempt now");
    }

    #[test]
    fn after_a_failure_nothing_more_is_reported() {
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.receive(&PeripheralMessage::NotSelected.clone()), HostOutput::NotSelected);
        let mut h = waiting_host(vec![paired(1)]);
        assert_eq!(h.receive(&PeripheralMessage::Sealed(vec![0; 40])), HostOutput::AuthFailed);
        assert_eq!(h.receive(&PeripheralMessage::Sealed(vec![0; 40])), HostOutput::None);
        assert_eq!(h.on_timeout(), HostOutput::None);
        assert_eq!(h.receive_bytes(b"junk"), HostOutput::None);
        assert!(h.take_channel_set().is_none());
        assert_eq!(h.seal_control(&ControlMessage::Bye, &[0; 12]), Err(HandshakeError::NotAuthenticated));
    }

    // ---- host: several phones

    #[test]
    fn the_first_matching_key_in_list_order_is_the_phone() {
        // Two entries with the same key: the first one wins.
        let mut twin = paired(2);
        twin.identity.id = [0x77; 16];
        let mut h = waiting_host(vec![paired(1), paired(2), twin]);
        let HostOutput::Authenticated { phone_id, .. } = h.receive(&good_reply(2)) else { panic!("authenticated expected") };
        assert_eq!(phone_id, [2; 16]);
    }

    #[test]
    fn every_one_of_eight_stored_keys_can_authenticate_and_a_ninth_unknown_cannot() {
        let phones: Vec<PairedPhone> = (1..=8).map(paired).collect();
        for n in 1..=8u8 {
            let mut h = waiting_host(phones.clone());
            let HostOutput::Authenticated { phone_id, .. } = h.receive(&good_reply(n)) else { panic!("phone {n} should authenticate") };
            assert_eq!(phone_id, [n; 16]);
        }
        let mut h = waiting_host(phones);
        assert_eq!(h.receive(&good_reply(9)), HostOutput::AuthFailed);
    }

    #[test]
    fn a_ninth_stored_key_is_never_tried() {
        let phones: Vec<PairedPhone> = (1..=9).map(paired).collect();
        let mut h = waiting_host(phones);
        assert_eq!(h.receive(&good_reply(9)), HostOutput::AuthFailed, "at most eight keys are checked (§6.2)");
    }

    #[test]
    fn the_session_keys_come_from_the_matched_phone_only() {
        let mut h = waiting_host(vec![paired(1), paired(2)]);
        assert!(matches!(h.receive(&good_reply(2)), HostOutput::Authenticated { .. }));
        let right = SessionCrypto::new(&key(2), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        let wrong = SessionCrypto::new(&key(1), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        let e = event(1, 1, EventKind::Backspace);
        let with_wrong = wrong.seal_event(&e, &[1; 12]).unwrap();
        assert_eq!(h.receive(&with_wrong), HostOutput::AuthFailed);
        let mut h = waiting_host(vec![paired(1), paired(2)]);
        h.receive(&good_reply(2));
        assert_eq!(h.receive(&right.seal_event(&e, &[1; 12]).unwrap()), HostOutput::Event(e));
    }

    // ---- host: sealing and channels

    #[test]
    fn the_host_seals_only_ack_status_and_bye_and_only_when_authenticated() {
        let h = host(Route::Selected, vec![paired(1)]);
        assert_eq!(h.seal_control(&ControlMessage::Bye, &[0; 12]), Err(HandshakeError::NotAuthenticated));
        let (h, mut p) = connected(1);
        for inner in [
            ControlMessage::Ack(Ack { event_id: Uuid::nil(), result: AckResult::Posted }),
            ControlMessage::Status(ReceiverStatus::new(true, 1)),
            ControlMessage::Bye,
        ] {
            let sealed = h.seal_control(&inner, &[4; 12]).unwrap();
            assert_eq!(p.receive(&sealed), PhoneOutput::Deliver(inner));
        }
        for bad in [ControlMessage::AuthFailed, ControlMessage::Auth { proof: vec![0; 32] }] {
            assert_eq!(h.seal_control(&bad, &[4; 12]), Err(HandshakeError::InvalidControlMessage));
        }
    }

    #[test]
    fn channel_sets_are_handed_out_once_and_work_across_the_two_sides() {
        let (mut h, mut p) = connected(1);
        let mut host_set = h.take_channel_set().unwrap();
        let mut phone_set = p.take_channel_set().unwrap();
        assert!(h.take_channel_set().is_none());
        assert!(p.take_channel_set().is_none());
        let packet = phone_set.sealer().seal(&[5; 16]).unwrap();
        assert_eq!(host_set.opener().open(&packet).unwrap(), [5; 16]);
        let (mut early, _) = (host(Route::Selected, vec![paired(1)]), ());
        assert!(early.take_channel_set().is_none(), "nothing before authentication");
    }

    // ---- phone: §6.3 handshake failures

    fn phone_hello(host_id: &[u8], nonce: &[u8]) -> ControlMessage {
        ControlMessage::Hello { host_id: host_id.to_vec(), host_nonce: nonce.to_vec() }
    }

    #[test]
    fn phone_a_matching_hello_gets_a_reply_with_a_proof_the_host_accepts() {
        let mut p = phone(1);
        let PhoneOutput::Send(PeripheralMessage::HelloReply { phone_nonce, proof }) = p.receive(&phone_hello(&HOST_ID, &HOST_NONCE)) else {
            panic!("helloReply expected")
        };
        assert_eq!(phone_nonce, PHONE_NONCE);
        assert!(verify_phone_proof(&proof, &key(1), &HOST_NONCE, &PHONE_NONCE));
        assert_eq!(p.progress(), PhoneProgress::InProgress);
        assert!(!p.can_send_events());
    }

    #[test]
    fn phone_row_malformed_hello_fails() {
        for hello in [
            phone_hello(&HOST_ID[..15], &HOST_NONCE),
            phone_hello(&[HOST_ID.as_slice(), &[0]].concat(), &HOST_NONCE),
            phone_hello(&HOST_ID, &HOST_NONCE[..15]),
            phone_hello(&HOST_ID, &[HOST_NONCE.as_slice(), &[0]].concat()),
            phone_hello(&[], &[]),
        ] {
            let mut p = phone(1);
            assert_eq!(p.receive(&hello), PhoneOutput::Failed);
            assert_eq!(p.progress(), PhoneProgress::Failed);
        }
    }

    #[test]
    fn phone_a_hello_for_another_host_gets_not_selected_and_keeps_no_state() {
        let mut p = phone(1);
        assert_eq!(p.receive(&phone_hello(&[0x99; 16], &HOST_NONCE)), PhoneOutput::Send(PeripheralMessage::NotSelected));
        assert_eq!(p.progress(), PhoneProgress::InProgress);
        assert!(matches!(p.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::Send(PeripheralMessage::HelloReply { .. })));
        // The same answer for a host the phone was never paired with, and with no current host at all.
        let mut none = PhoneHandshake::new(None, PHONE_NONCE);
        assert_eq!(none.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::Send(PeripheralMessage::NotSelected));
        assert_eq!(none.progress(), PhoneProgress::InProgress);
        // Even in the middle of a handshake or after it, a hello for another host is only answered.
        let (_, mut authed) = connected(1);
        assert_eq!(authed.receive(&phone_hello(&[0x99; 16], &HOST_NONCE)), PhoneOutput::Send(PeripheralMessage::NotSelected));
        assert_eq!(authed.progress(), PhoneProgress::Authenticated);
    }

    #[test]
    fn phone_row_a_second_matching_hello_fails() {
        let mut p = phone(1);
        assert!(matches!(p.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::Send(_)));
        assert_eq!(p.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::Failed);
        let (_, mut authed) = connected(1);
        assert_eq!(authed.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::Failed);
    }

    #[test]
    fn phone_row_auth_when_not_waiting_or_with_a_bad_proof_fails() {
        let good = ControlMessage::Auth { proof: host_proof(&key(1), &HOST_NONCE, &PHONE_NONCE).to_vec() };
        // Not waiting: no hello yet.
        let mut p = phone(1);
        assert_eq!(p.receive(&good), PhoneOutput::Failed);
        // Bad proofs while waiting.
        for bad in [
            host_proof(&key(2), &HOST_NONCE, &PHONE_NONCE).to_vec(),
            phone_proof(&key(1), &HOST_NONCE, &PHONE_NONCE).to_vec(),
            vec![0; 31],
            vec![],
        ] {
            let mut p = phone(1);
            p.receive(&phone_hello(&HOST_ID, &HOST_NONCE));
            assert_eq!(p.receive(&ControlMessage::Auth { proof: bad }), PhoneOutput::Failed);
        }
        // Auth twice.
        let mut p = phone(1);
        p.receive(&phone_hello(&HOST_ID, &HOST_NONCE));
        assert_eq!(p.receive(&good), PhoneOutput::Authenticated);
        assert_eq!(p.receive(&good), PhoneOutput::Failed);
    }

    #[test]
    fn phone_rejects_a_host_proof_that_differs_in_one_byte() {
        for index in [0usize, 31] {
            let mut proof = host_proof(&key(1), &HOST_NONCE, &PHONE_NONCE);
            proof[index] ^= 1;
            let mut p = phone(1);
            p.receive(&phone_hello(&HOST_ID, &HOST_NONCE));
            assert_eq!(p.receive(&ControlMessage::Auth { proof: proof.to_vec() }), PhoneOutput::Failed, "byte {index}");
        }
    }

    #[test]
    fn phone_row_auth_failed_fails() {
        let mut p = phone(1);
        assert_eq!(p.receive(&ControlMessage::AuthFailed), PhoneOutput::Failed);
        let (_, mut authed) = connected(1);
        assert_eq!(authed.receive(&ControlMessage::AuthFailed), PhoneOutput::Failed);
    }

    #[test]
    fn phone_row_plain_ack_status_or_bye_fails_after_authentication_and_is_dropped_before() {
        let plain = [
            ControlMessage::Ack(Ack { event_id: Uuid::nil(), result: AckResult::Posted }),
            ControlMessage::Status(ReceiverStatus::new(true, 1)),
            ControlMessage::Bye,
        ];
        for m in &plain {
            let mut p = phone(1);
            assert_eq!(p.receive(m), PhoneOutput::None);
            assert_eq!(p.progress(), PhoneProgress::InProgress, "dropped, not failed");
            let (_, mut authed) = connected(1);
            assert_eq!(authed.receive(m), PhoneOutput::Failed);
        }
    }

    #[test]
    fn phone_row_sealed_before_authentication_or_unopenable_or_with_a_wrong_inner_fails() {
        let mut p = phone(1);
        assert_eq!(p.receive(&ControlMessage::Sealed(vec![0; 40])), PhoneOutput::Failed);
        let (_, mut authed) = connected(1);
        assert_eq!(authed.receive(&ControlMessage::Sealed(vec![0; 40])), PhoneOutput::Failed);
        // An inner that is a valid message but not ack, status or bye.
        let (_, mut authed) = connected(1);
        let crypto = SessionCrypto::new(&key(1), &HOST_NONCE, &PHONE_NONCE, SessionDirection::HostToPhone);
        let payload = crypto.seal(&crate::message::encode_control(&ControlMessage::AuthFailed), &[1; 12]).unwrap();
        assert_eq!(authed.receive(&ControlMessage::Sealed(payload)), PhoneOutput::Failed);
        // Sealed in the wrong direction does not open.
        let (_, mut authed) = connected(1);
        let wrong_way = SessionCrypto::new(&key(1), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        let payload = wrong_way.seal(&crate::message::encode_control(&ControlMessage::Bye), &[1; 12]).unwrap();
        assert_eq!(authed.receive(&ControlMessage::Sealed(payload)), PhoneOutput::Failed);
    }

    #[test]
    fn phone_pair_accept_is_ignored() {
        let mut p = phone(1);
        let accept = ControlMessage::PairAccept { public_key: vec![0; 65], host_id: vec![0; 16], host_name: "x".into(), platform: crate::identity::HostPlatform::Mac };
        assert_eq!(p.receive(&accept), PhoneOutput::None);
        assert_eq!(p.progress(), PhoneProgress::InProgress);
    }

    #[test]
    fn phone_after_a_failure_sends_nothing_and_hands_out_nothing() {
        let (_, mut p) = connected(1);
        assert_eq!(p.receive(&ControlMessage::AuthFailed), PhoneOutput::Failed);
        assert_eq!(p.receive(&phone_hello(&HOST_ID, &HOST_NONCE)), PhoneOutput::None);
        assert!(!p.can_send_events());
        assert_eq!(p.seal_event(&event(1, 1, EventKind::Backspace), &[0; 12]), Err(HandshakeError::NotAuthenticated));
        assert!(p.take_channel_set().is_none());
    }

    #[test]
    fn phone_cannot_seal_an_event_before_authentication() {
        let p = phone(1);
        assert_eq!(p.seal_event(&event(1, 1, EventKind::Backspace), &[0; 12]), Err(HandshakeError::NotAuthenticated));
    }

    #[test]
    fn debug_output_hides_the_state() {
        let (h, p) = connected(1);
        assert_eq!(format!("{h:?}"), "HostHandshake([redacted])");
        assert_eq!(format!("{p:?}"), "PhoneHandshake([redacted])");
    }
}
