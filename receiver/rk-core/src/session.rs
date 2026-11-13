//! Session encryption of the messages after authentication (protocol v4 §7).

use crate::message::{decode_control, decode_peripheral, encode_control, encode_peripheral, ControlMessage, KeyboardEvent, PeripheralMessage};
use crate::secret::{PairKey, SecretBytes};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use sha2::Sha256;
use std::fmt;
use thiserror::Error;
use uuid::Uuid;

/// Length of the AEAD nonce in bytes (§7.2).
pub const AEAD_NONCE_LEN: usize = 12;
/// Length of the Poly1305 tag in bytes (§7.2).
pub const TAG_LEN: usize = 16;

/// Which way a session key protects (§7.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionDirection {
    PhoneToHost,
    HostToPhone,
}

/// Why a session operation failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SessionError {
    #[error("wrong key, tampered or too short")]
    OpenFailed,
    #[error("sealing failed")]
    SealFailed,
    #[error("the inner message is not allowed in this direction")]
    InvalidInner,
    #[error("this key protects the other direction")]
    WrongDirection,
}

/// `K_p2m` or `K_m2p` (§7.1): HKDF-SHA256 over the pair key, empty salt, info `label ‖ hostNonce ‖ phoneNonce`.
pub fn derive_session_key(
    pair_key: &PairKey,
    host_nonce: &[u8; 16],
    phone_nonce: &[u8; 16],
    direction: SessionDirection,
) -> SecretBytes<32> {
    let label: &[u8] = match direction {
        SessionDirection::PhoneToHost => b"rk-session-p2m",
        SessionDirection::HostToPhone => b"rk-session-m2p",
    };
    SecretBytes::new(hkdf32(pair_key.expose(), &[label, host_nonce, phone_nonce]))
}

/// HKDF-SHA256 with an empty salt (the same as 32 zero bytes) and `info` given in parts.
pub(crate) fn hkdf32(ikm: &[u8], info_parts: &[&[u8]]) -> [u8; 32] {
    let info: Vec<u8> = info_parts.concat();
    let mut out = [0u8; 32];
    // 32 bytes is far below the 255 * 32 limit, so expand cannot fail.
    Hkdf::<Sha256>::new(None, ikm).expand(&info, &mut out).expect("32 bytes is a valid HKDF output length");
    out
}

/// What a decrypted phone-to-host payload turned out to be (§7.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenedEvent {
    Event(KeyboardEvent),
    /// Decrypted, but not a readable message (includes an inner `protocolVersion` other than 4).
    Malformed,
    /// Decrypted and readable, but not an `event`.
    NotAnEvent,
}

/// One direction of one session.
pub struct SessionCrypto {
    key: SecretBytes<32>,
    direction: SessionDirection,
}

impl fmt::Debug for SessionCrypto {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SessionCrypto([redacted])")
    }
}

impl SessionCrypto {
    /// Derives the key of one direction (§7.1).
    pub fn new(pair_key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16], direction: SessionDirection) -> Self {
        Self { key: derive_session_key(pair_key, host_nonce, phone_nonce, direction), direction }
    }

    /// `nonce ‖ ciphertext ‖ tag` with the given nonce (§7.2). The caller supplies fresh random bytes; a nonce must
    /// never repeat under one key.
    pub fn seal(&self, plain: &[u8], nonce: &[u8; AEAD_NONCE_LEN]) -> Result<Vec<u8>, SessionError> {
        let cipher = ChaCha20Poly1305::new(self.key.expose().into());
        let sealed = cipher.encrypt(nonce.into(), Payload { msg: plain, aad: &[] }).map_err(|_| SessionError::SealFailed)?;
        let mut out = Vec::with_capacity(AEAD_NONCE_LEN + sealed.len());
        out.extend_from_slice(nonce);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    /// Opens a sealed output; shorter than 28 bytes or a bad tag is `OpenFailed` (§7.2).
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, SessionError> {
        if sealed.len() < AEAD_NONCE_LEN + TAG_LEN {
            return Err(SessionError::OpenFailed);
        }
        let (nonce, rest) = sealed.split_at(AEAD_NONCE_LEN);
        let nonce: &[u8; AEAD_NONCE_LEN] = nonce.try_into().map_err(|_| SessionError::OpenFailed)?;
        let cipher = ChaCha20Poly1305::new(self.key.expose().into());
        cipher.decrypt(nonce.into(), Payload { msg: rest, aad: &[] }).map_err(|_| SessionError::OpenFailed)
    }

    fn require(&self, direction: SessionDirection) -> Result<(), SessionError> {
        if self.direction == direction {
            Ok(())
        } else {
            Err(SessionError::WrongDirection)
        }
    }

    /// Seals one event as a phone-to-host `sealed` message (§7.2).
    pub fn seal_event(&self, event: &KeyboardEvent, nonce: &[u8; AEAD_NONCE_LEN]) -> Result<PeripheralMessage, SessionError> {
        self.require(SessionDirection::PhoneToHost)?;
        let plain = encode_peripheral(&PeripheralMessage::Event(event.clone()));
        Ok(PeripheralMessage::Sealed(self.seal(&plain, nonce)?))
    }

    /// Opens a phone-to-host `sealed` payload (§7.2). `Err` means it did not open; the other two outcomes decrypted.
    pub fn open_event(&self, payload: &[u8]) -> Result<OpenedEvent, SessionError> {
        self.require(SessionDirection::PhoneToHost)?;
        let plain = self.open(payload)?;
        Ok(match decode_peripheral(&plain) {
            Ok(PeripheralMessage::Event(event)) => OpenedEvent::Event(event),
            Ok(_) => OpenedEvent::NotAnEvent,
            Err(_) => OpenedEvent::Malformed,
        })
    }

    /// Seals an `ack`, `status` or `bye` as a host-to-phone `sealed` message; anything else is `InvalidInner` (§7.2).
    pub fn seal_control(&self, inner: &ControlMessage, nonce: &[u8; AEAD_NONCE_LEN]) -> Result<ControlMessage, SessionError> {
        self.require(SessionDirection::HostToPhone)?;
        if !is_allowed_control_inner(inner) {
            return Err(SessionError::InvalidInner);
        }
        Ok(ControlMessage::Sealed(self.seal(&encode_control(inner), nonce)?))
    }

    /// Opens a host-to-phone `sealed` payload; the inner message must be `ack`, `status` or `bye` (§7.2). An inner that
    /// cannot be read is `OpenFailed` here: the phone treats every error as a failed handshake.
    pub fn open_control(&self, payload: &[u8]) -> Result<ControlMessage, SessionError> {
        self.require(SessionDirection::HostToPhone)?;
        let inner = decode_control(&self.open(payload)?).map_err(|_| SessionError::OpenFailed)?;
        if is_allowed_control_inner(&inner) {
            Ok(inner)
        } else {
            Err(SessionError::InvalidInner)
        }
    }
}

fn is_allowed_control_inner(m: &ControlMessage) -> bool {
    matches!(m, ControlMessage::Ack(_) | ControlMessage::Status(_) | ControlMessage::Bye)
}

/// Ties one authenticated connection to a single `sessionId` (§7.4): the first one seen is pinned and any other on the
/// same connection is a violation. One pin per connection.
#[derive(Debug, Default)]
pub struct SessionPin {
    pinned: Option<Uuid>,
}

impl SessionPin {
    /// A pin that has seen nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// `true` when `session_id` is the pinned one or becomes it.
    pub fn accept(&mut self, session_id: Uuid) -> bool {
        match self.pinned {
            None => {
                self.pinned = Some(session_id);
                true
            }
            Some(pinned) => pinned == session_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{Ack, AckResult, EventKind, ReceiverStatus};

    const HOST_NONCE: [u8; 16] = [0xA0; 16];
    const PHONE_NONCE: [u8; 16] = [0xB0; 16];

    fn key() -> PairKey {
        PairKey::new([0x42; 32])
    }

    fn pair() -> (SessionCrypto, SessionCrypto) {
        (
            SessionCrypto::new(&key(), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost),
            SessionCrypto::new(&key(), &HOST_NONCE, &PHONE_NONCE, SessionDirection::HostToPhone),
        )
    }

    fn event(kind: EventKind) -> KeyboardEvent {
        KeyboardEvent { event_id: Uuid::from_u128(1), session_id: Uuid::from_u128(2), seq: 1, focus_epoch: None, kind }
    }

    #[test]
    fn the_two_directions_and_two_connections_have_different_keys() {
        let p2m = derive_session_key(&key(), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        let m2p = derive_session_key(&key(), &HOST_NONCE, &PHONE_NONCE, SessionDirection::HostToPhone);
        let other_host = derive_session_key(&key(), &[0xA1; 16], &PHONE_NONCE, SessionDirection::PhoneToHost);
        let other_phone = derive_session_key(&key(), &HOST_NONCE, &[0xB1; 16], SessionDirection::PhoneToHost);
        let other_pair = derive_session_key(&PairKey::new([0x43; 32]), &HOST_NONCE, &PHONE_NONCE, SessionDirection::PhoneToHost);
        assert_ne!(p2m, m2p);
        assert_ne!(p2m, other_host);
        assert_ne!(p2m, other_phone);
        assert_ne!(p2m, other_pair);
    }

    #[test]
    fn sealed_output_is_nonce_then_ciphertext_then_tag() {
        let (p2m, _) = pair();
        let sealed = p2m.seal(b"hello", &[9; 12]).unwrap();
        assert_eq!(sealed.len(), 12 + 5 + 16);
        assert_eq!(sealed[..12], [9; 12]);
        assert_eq!(p2m.open(&sealed).unwrap(), b"hello");
        let empty = p2m.seal(b"", &[9; 12]).unwrap();
        assert_eq!(empty.len(), 28);
        assert_eq!(p2m.open(&empty).unwrap(), b"");
    }

    #[test]
    fn a_flipped_bit_anywhere_does_not_open() {
        let (p2m, _) = pair();
        let sealed = p2m.seal(b"some plaintext", &[3; 12]).unwrap();
        for i in 0..sealed.len() {
            let mut bad = sealed.clone();
            bad[i] ^= 0x01;
            assert_eq!(p2m.open(&bad), Err(SessionError::OpenFailed), "byte {i}");
        }
    }

    #[test]
    fn output_shorter_than_28_bytes_does_not_open() {
        let (p2m, _) = pair();
        for len in [0, 1, 12, 27] {
            assert_eq!(p2m.open(&vec![0u8; len]), Err(SessionError::OpenFailed), "len {len}");
        }
    }

    #[test]
    fn the_other_direction_and_another_connection_cannot_open() {
        let (p2m, m2p) = pair();
        let sealed = p2m.seal(b"x", &[1; 12]).unwrap();
        assert!(m2p.open(&sealed).is_err());
        let other = SessionCrypto::new(&key(), &HOST_NONCE, &[0xB1; 16], SessionDirection::PhoneToHost);
        assert!(other.open(&sealed).is_err());
    }

    #[test]
    fn a_phone_to_host_inner_must_be_an_event() {
        let (p2m, _) = pair();
        let ok = p2m.seal_event(&event(EventKind::Text("a".into())), &[1; 12]).unwrap();
        let PeripheralMessage::Sealed(payload) = ok else { panic!("sealed expected") };
        assert!(matches!(p2m.open_event(&payload), Ok(OpenedEvent::Event(_))));

        let not_event = p2m.seal(&encode_peripheral(&PeripheralMessage::NotSelected), &[2; 12]).unwrap();
        assert_eq!(p2m.open_event(&not_event), Ok(OpenedEvent::NotAnEvent));
        let not_event = p2m.seal(&encode_peripheral(&PeripheralMessage::PairOffer { commitment: vec![0; 32] }), &[2; 12]).unwrap();
        assert_eq!(p2m.open_event(&not_event), Ok(OpenedEvent::NotAnEvent));
    }

    #[test]
    fn an_unreadable_inner_is_malformed_not_a_failed_open() {
        let (p2m, _) = pair();
        for junk in [&b"not json"[..], b"{}", br#"{"protocolVersion":3,"type":"notSelected"}"#, br#"{"protocolVersion":4,"type":"event"}"#] {
            let sealed = p2m.seal(junk, &[4; 12]).unwrap();
            assert_eq!(p2m.open_event(&sealed), Ok(OpenedEvent::Malformed), "{}", String::from_utf8_lossy(junk));
        }
    }

    #[test]
    fn a_host_to_phone_inner_must_be_ack_status_or_bye() {
        let (_, m2p) = pair();
        for inner in [
            ControlMessage::Ack(Ack { event_id: Uuid::nil(), result: AckResult::Pong }),
            ControlMessage::Status(ReceiverStatus::new(true, 1)),
            ControlMessage::Bye,
        ] {
            let ControlMessage::Sealed(payload) = m2p.seal_control(&inner, &[5; 12]).unwrap() else { panic!("sealed expected") };
            assert_eq!(m2p.open_control(&payload), Ok(inner));
        }
        for inner in [
            ControlMessage::AuthFailed,
            ControlMessage::Hello { host_id: vec![0; 16], host_nonce: vec![0; 16] },
            ControlMessage::Auth { proof: vec![0; 32] },
            ControlMessage::Sealed(vec![1]),
        ] {
            assert_eq!(m2p.seal_control(&inner, &[5; 12]), Err(SessionError::InvalidInner));
            // A sender that ignores the rule still cannot get its message through the receiver.
            let payload = m2p.seal(&encode_control(&inner), &[5; 12]).unwrap();
            assert_eq!(m2p.open_control(&payload), Err(SessionError::InvalidInner));
        }
        let junk = m2p.seal(b"{}", &[5; 12]).unwrap();
        assert_eq!(m2p.open_control(&junk), Err(SessionError::OpenFailed));
    }

    #[test]
    fn a_key_only_serves_its_own_direction() {
        let (p2m, m2p) = pair();
        assert_eq!(p2m.seal_control(&ControlMessage::Bye, &[0; 12]), Err(SessionError::WrongDirection));
        assert_eq!(m2p.seal_event(&event(EventKind::Probe), &[0; 12]), Err(SessionError::WrongDirection));
        assert_eq!(p2m.open_control(&[0; 40]), Err(SessionError::WrongDirection));
        assert_eq!(m2p.open_event(&[0; 40]), Err(SessionError::WrongDirection));
    }

    #[test]
    fn the_first_session_id_is_pinned_and_a_second_is_refused() {
        let mut pin = SessionPin::new();
        let a = Uuid::from_u128(1);
        let b = Uuid::from_u128(2);
        assert!(pin.accept(a));
        assert!(pin.accept(a));
        assert!(!pin.accept(b));
        assert!(pin.accept(a), "refusing another id does not unpin the first");
    }

    #[test]
    fn debug_output_hides_the_key() {
        let (p2m, _) = pair();
        assert_eq!(format!("{p2m:?}"), "SessionCrypto([redacted])");
        assert_eq!(format!("{:?}", key()), "SecretBytes([redacted])");
    }
}
