//! Key agreement, the pairing code, proofs and the two pairing reducers (protocol v4 §5, §6.1).

use crate::identity::{identity_hash, is_valid_name, HostIdentity, PhoneIdentity, PhonePlatform};
use crate::message::{ControlMessage, PeripheralMessage};
use crate::secret::{PairKey, SecretBytes};
use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use p256::elliptic_curve::sec1::ToSec1Point;
use p256::{PublicKey, SecretKey};
use sha2::{Digest, Sha256};
use std::fmt;
use subtle::ConstantTimeEq;
use thiserror::Error;

/// Length of a nonce in bytes (§6.1).
pub const NONCE_LEN: usize = 16;
/// Length of a proof in bytes (§6.1).
pub const PROOF_LEN: usize = 32;
/// Length of a public key on the wire (§5.1).
pub const PUBLIC_KEY_LEN: usize = 65;
/// Length of a commitment in bytes (§5.2).
pub const COMMITMENT_LEN: usize = 32;

/// Why a key or identity was refused (§5.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PairingError {
    #[error("not a valid 65-byte P-256 point, or not allowed here")]
    InvalidPublicKey,
    #[error("private scalar is zero or not below the group order")]
    InvalidScalar,
    #[error("identity refused")]
    InvalidIdentity,
}

/// Which end of the pairing a reducer is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Host,
    Phone,
}

fn secret_key(scalar: &[u8; 32]) -> Result<SecretKey, PairingError> {
    SecretKey::from_slice(scalar).map_err(|_| PairingError::InvalidScalar)
}

fn encode_public(key: &PublicKey) -> [u8; PUBLIC_KEY_LEN] {
    let point = key.to_sec1_point(false);
    let mut out = [0u8; PUBLIC_KEY_LEN];
    out.copy_from_slice(point.as_bytes());
    out
}

/// A 65-byte X9.63 uncompressed point on the curve; compressed forms, other lengths and off-curve points are refused.
pub(crate) fn parse_public(bytes: &[u8]) -> Result<PublicKey, PairingError> {
    if bytes.len() != PUBLIC_KEY_LEN || bytes[0] != 0x04 {
        return Err(PairingError::InvalidPublicKey);
    }
    PublicKey::from_sec1_bytes(bytes).map_err(|_| PairingError::InvalidPublicKey)
}

/// The X9.63 uncompressed public key for a private scalar (§5.1).
pub fn public_key(scalar: &[u8; 32]) -> Result<[u8; PUBLIC_KEY_LEN], PairingError> {
    Ok(encode_public(&secret_key(scalar)?.public_key()))
}

/// The X coordinate of the ECDH shared point (§5.3 `Z`). The peer key must be a valid point and not our own.
pub fn ecdh_x(scalar: &[u8; 32], peer_public: &[u8]) -> Result<SecretBytes<32>, PairingError> {
    let secret = secret_key(scalar)?;
    let peer = parse_public(peer_public)?;
    if peer == secret.public_key() {
        return Err(PairingError::InvalidPublicKey);
    }
    let shared = p256::ecdh::diffie_hellman(secret.to_nonzero_scalar(), peer.as_affine());
    let mut z = [0u8; 32];
    z.copy_from_slice(shared.raw_secret_bytes().as_slice());
    Ok(SecretBytes::new(z))
}

/// `SHA-256("rk-commit" ‖ phonePublic)` (§5.2 step 1).
pub fn commitment(phone_public: &[u8]) -> [u8; COMMITMENT_LEN] {
    let mut hasher = Sha256::new();
    hasher.update(b"rk-commit");
    hasher.update(phone_public);
    hasher.finalize().into()
}

/// Constant-time check of a revealed key against a commitment (§5.2 step 3).
pub fn verify_commitment(commitment_bytes: &[u8], phone_public: &[u8]) -> bool {
    if commitment_bytes.len() != COMMITMENT_LEN {
        return false;
    }
    commitment(phone_public).ct_eq(commitment_bytes).into()
}

/// `pairKey` for one pairing attempt (§5.3). `role` says which slot `my_scalar` fills; the peer's key goes in the other.
/// The names and platforms are used as they came in the messages.
pub fn derive_pair_key(
    my_scalar: &[u8; 32],
    role: Role,
    peer_public: &[u8],
    host: &HostIdentity,
    phone: &PhoneIdentity,
) -> Result<PairKey, PairingError> {
    let z = ecdh_x(my_scalar, peer_public)?;
    if !is_valid_name(&host.name) || !is_valid_name(&phone.name) {
        return Err(PairingError::InvalidIdentity);
    }
    let mine = public_key(my_scalar)?;
    let (host_public, phone_public): (&[u8], &[u8]) = match role {
        Role::Host => (&mine, peer_public),
        Role::Phone => (peer_public, &mine),
    };
    let mut info = Vec::with_capacity(226);
    info.extend_from_slice(host_public);
    info.extend_from_slice(phone_public);
    info.extend_from_slice(&host.id);
    info.extend_from_slice(&identity_hash(&host.name, host.platform.as_str()));
    info.extend_from_slice(&phone.id);
    info.extend_from_slice(&identity_hash(&phone.name, phone.platform.as_str()));
    debug_assert_eq!(info.len(), 226);
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"rk-pair-v2"), z.expose()).expand(&info, &mut key).map_err(|_| PairingError::InvalidPublicKey)?;
    Ok(PairKey::new(key))
}

/// The six-digit pairing code (§5.4): the first four bytes of `HKDF(pairKey, info "rk-sas")` as a big-endian `u32`,
/// modulo 1 000 000, left-padded with zeros.
pub fn sas(pair_key: &PairKey) -> String {
    let mut t = [0u8; 4];
    // 4 bytes is a valid HKDF output length.
    Hkdf::<Sha256>::new(None, pair_key.expose()).expand(b"rk-sas", &mut t).expect("4 bytes is a valid HKDF output length");
    format!("{:06}", u32::from_be_bytes(t) % 1_000_000)
}

fn proof(label: &[u8], key: &PairKey, host_nonce: &[u8], phone_nonce: &[u8]) -> Hmac<Sha256> {
    // RFC 2104: a key shorter than the 64-byte block is padded with zeros, which is what lets this skip the fallible
    // `new_from_slice`.
    let mut block = [0u8; 64];
    block[..32].copy_from_slice(key.expose());
    let mut mac = <Hmac<Sha256> as KeyInit>::new((&block).into());
    mac.update(label);
    mac.update(host_nonce);
    mac.update(phone_nonce);
    mac
}

fn compute(label: &[u8], key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16]) -> [u8; PROOF_LEN] {
    proof(label, key, host_nonce, phone_nonce).finalize().into_bytes().into()
}

fn verify(label: &[u8], received: &[u8], key: &PairKey, host_nonce: &[u8], phone_nonce: &[u8]) -> bool {
    if host_nonce.len() != NONCE_LEN || phone_nonce.len() != NONCE_LEN || received.len() != PROOF_LEN {
        return false;
    }
    proof(label, key, host_nonce, phone_nonce).verify_slice(received).is_ok()
}

/// `HMAC-SHA256(pairKey, "phone" ‖ hostNonce ‖ phoneNonce)` (§6.1).
pub fn phone_proof(key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16]) -> [u8; PROOF_LEN] {
    compute(b"phone", key, host_nonce, phone_nonce)
}

/// `HMAC-SHA256(pairKey, "host" ‖ hostNonce ‖ phoneNonce)` (§6.1).
pub fn host_proof(key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16]) -> [u8; PROOF_LEN] {
    compute(b"host", key, host_nonce, phone_nonce)
}

/// Constant-time check; a nonce or proof of the wrong length is a mismatch without any comparison (§6.1).
pub fn verify_phone_proof(received: &[u8], key: &PairKey, host_nonce: &[u8], phone_nonce: &[u8]) -> bool {
    verify(b"phone", received, key, host_nonce, phone_nonce)
}

/// Constant-time check; a nonce or proof of the wrong length is a mismatch without any comparison (§6.1).
pub fn verify_host_proof(received: &[u8], key: &PairKey, host_nonce: &[u8], phone_nonce: &[u8]) -> bool {
    verify(b"host", received, key, host_nonce, phone_nonce)
}

/// What the phone's pairing reducer asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PhonePairingOutput {
    None,
    /// Notify this message to the host.
    Send(PeripheralMessage),
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PhoneState {
    AwaitingAccept,
    Revealed,
    Failed,
}

/// The phone side of one pairing attempt (§5.2). Failure is sticky; the key and code are dropped when it happens.
pub struct PhonePairing {
    scalar: [u8; 32],
    public: [u8; PUBLIC_KEY_LEN],
    phone: PhoneIdentity,
    state: PhoneState,
    pair_key: Option<PairKey>,
    sas: Option<String>,
    host: Option<HostIdentity>,
}

impl fmt::Debug for PhonePairing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PhonePairing([redacted])")
    }
}

impl PhonePairing {
    /// A fresh attempt. `private_scalar` must be new for this attempt and never reused: the commitment only binds the
    /// phone to a key it has not shown yet, and a reused key would let a man in the middle search for a matching code.
    /// `phone` has a 16-byte id and a name already clamped to 32 bytes.
    pub fn new(private_scalar: [u8; 32], phone: PhoneIdentity) -> Result<Self, PairingError> {
        let public = public_key(&private_scalar)?;
        if !is_valid_name(&phone.name) {
            return Err(PairingError::InvalidIdentity);
        }
        Ok(Self { scalar: private_scalar, public, phone, state: PhoneState::AwaitingAccept, pair_key: None, sas: None, host: None })
    }

    /// Step 1: the commitment to this side's public key.
    pub fn offer(&self) -> PeripheralMessage {
        PeripheralMessage::PairOffer { commitment: commitment(&self.public).to_vec() }
    }

    /// Feeds one control message; only `pairAccept` matters, every other message is ignored (§5.2).
    pub fn receive(&mut self, message: &ControlMessage) -> PhonePairingOutput {
        if self.state == PhoneState::Failed {
            return PhonePairingOutput::None;
        }
        let ControlMessage::PairAccept { public_key, host_id, host_name, platform } = message else {
            return PhonePairingOutput::None;
        };
        let accepted = (self.state == PhoneState::AwaitingAccept)
            .then(|| HostIdentity::from_wire(host_id, host_name, *platform).ok())
            .flatten()
            .and_then(|host| {
                let key = derive_pair_key(&self.scalar, Role::Phone, public_key, &host, &self.phone).ok()?;
                Some((host, key))
            });
        let Some((host, key)) = accepted else {
            self.fail();
            return PhonePairingOutput::Failed;
        };
        self.sas = Some(sas(&key));
        self.pair_key = Some(key);
        self.host = Some(host);
        self.state = PhoneState::Revealed;
        self.scalar = [0; 32];
        PhonePairingOutput::Send(PeripheralMessage::PairReveal {
            public_key: self.public.to_vec(),
            phone_id: self.phone.id.to_vec(),
            phone_name: self.phone.name.clone(),
            phone_platform: self.phone.platform,
        })
    }

    fn fail(&mut self) {
        self.state = PhoneState::Failed;
        self.scalar = [0; 32];
        self.pair_key = None;
        self.sas = None;
        self.host = None;
    }

    /// The key, once the reveal went out.
    pub fn pair_key(&self) -> Option<&PairKey> {
        self.pair_key.as_ref()
    }

    /// The pairing code, once the reveal went out.
    pub fn sas(&self) -> Option<&str> {
        self.sas.as_deref()
    }

    /// The host that answered, as it described itself.
    pub fn host(&self) -> Option<&HostIdentity> {
        self.host.as_ref()
    }
}

/// What the host's pairing reducer asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostPairingOutput {
    /// Write this to `control`.
    Send(ControlMessage),
    /// The reveal matched; `pair_key`, `sas` and `phone` are available.
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HostState {
    Idle,
    Accepted,
    Completed,
    Failed,
}

/// The host side of one pairing attempt (§5.2). Failure is sticky; the key and code are dropped when it happens.
pub struct HostPairing {
    scalar: [u8; 32],
    public: [u8; PUBLIC_KEY_LEN],
    host: HostIdentity,
    state: HostState,
    commitment: Vec<u8>,
    pair_key: Option<PairKey>,
    sas: Option<String>,
    phone: Option<PhoneIdentity>,
}

impl fmt::Debug for HostPairing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HostPairing([redacted])")
    }
}

impl HostPairing {
    /// A fresh attempt. `private_scalar` must be new for this attempt and never reused: the host's key is on the wire
    /// before the phone's is revealed. `host` has a 16-byte id and a name already clamped to 32 bytes.
    pub fn new(private_scalar: [u8; 32], host: HostIdentity) -> Result<Self, PairingError> {
        let public = public_key(&private_scalar)?;
        if !is_valid_name(&host.name) {
            return Err(PairingError::InvalidIdentity);
        }
        Ok(Self {
            scalar: private_scalar,
            public,
            host,
            state: HostState::Idle,
            commitment: Vec::new(),
            pair_key: None,
            sas: None,
            phone: None,
        })
    }

    /// Feeds one phone message; anything but `pairOffer` then `pairReveal` fails the attempt.
    pub fn receive(&mut self, message: &PeripheralMessage) -> HostPairingOutput {
        match message {
            PeripheralMessage::PairOffer { commitment } => self.receive_offer(commitment),
            PeripheralMessage::PairReveal { public_key, phone_id, phone_name, phone_platform } => {
                self.receive_reveal(public_key, phone_id, phone_name, *phone_platform)
            }
            _ => self.fail(),
        }
    }

    /// Step 1 (§5.2): the commitment must be 32 bytes and only one is accepted per connection.
    pub fn receive_offer(&mut self, commitment_bytes: &[u8]) -> HostPairingOutput {
        if self.state != HostState::Idle || commitment_bytes.len() != COMMITMENT_LEN {
            return self.fail();
        }
        self.commitment = commitment_bytes.to_vec();
        self.state = HostState::Accepted;
        HostPairingOutput::Send(ControlMessage::PairAccept {
            public_key: self.public.to_vec(),
            host_id: self.host.id.to_vec(),
            host_name: self.host.name.clone(),
            platform: self.host.platform,
        })
    }

    /// Step 3 (§5.2): only after `pairAccept` went out; the key must match the commitment, be a valid point other than
    /// our own, and the identity must be well formed.
    pub fn receive_reveal(
        &mut self,
        public_key: &[u8],
        phone_id: &[u8],
        phone_name: &str,
        phone_platform: PhonePlatform,
    ) -> HostPairingOutput {
        if self.state != HostState::Accepted || !verify_commitment(&self.commitment, public_key) {
            return self.fail();
        }
        let Ok(phone) = PhoneIdentity::from_wire(phone_id, phone_name, phone_platform) else {
            return self.fail();
        };
        let Ok(key) = derive_pair_key(&self.scalar, Role::Host, public_key, &self.host, &phone) else {
            return self.fail();
        };
        self.sas = Some(sas(&key));
        self.pair_key = Some(key);
        self.phone = Some(phone);
        self.state = HostState::Completed;
        self.scalar = [0; 32];
        HostPairingOutput::Completed
    }

    fn fail(&mut self) -> HostPairingOutput {
        self.state = HostState::Failed;
        self.scalar = [0; 32];
        self.commitment.clear();
        self.pair_key = None;
        self.sas = None;
        self.phone = None;
        HostPairingOutput::Failed
    }

    /// The key, once completed.
    pub fn pair_key(&self) -> Option<&PairKey> {
        self.pair_key.as_ref()
    }

    /// The pairing code, once completed.
    pub fn sas(&self) -> Option<&str> {
        self.sas.as_deref()
    }

    /// The phone that paired, once completed.
    pub fn phone(&self) -> Option<&PhoneIdentity> {
        self.phone.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::HostPlatform;

    fn scalar(n: u8) -> [u8; 32] {
        let mut s = [0u8; 32];
        s[31] = n;
        s
    }

    fn host() -> HostIdentity {
        HostIdentity { id: [1; 16], name: "書房的 Mac".into(), platform: HostPlatform::Mac }
    }

    fn phone() -> PhoneIdentity {
        PhoneIdentity { id: [2; 16], name: "Anson 的 iPhone".into(), platform: PhonePlatform::Ios }
    }

    fn pairs() -> (HostPairing, PhonePairing) {
        (HostPairing::new(scalar(1), host()).unwrap(), PhonePairing::new(scalar(2), phone()).unwrap())
    }

    /// Runs the offer and accept steps; returns the pairAccept message and the phone's reveal.
    fn through_reveal(h: &mut HostPairing, p: &mut PhonePairing) -> (ControlMessage, PeripheralMessage) {
        let HostPairingOutput::Send(accept) = h.receive(&p.offer()) else { panic!("accept expected") };
        let PhonePairingOutput::Send(reveal) = p.receive(&accept) else { panic!("reveal expected") };
        (accept, reveal)
    }

    #[test]
    fn the_protocol_example_gives_the_documented_key_and_code() {
        // §5.5: the example identities of the protocol's "記號" section.
        let host = HostIdentity { id: core::array::from_fn(|i| i as u8), ..host() };
        let phone = PhoneIdentity { id: core::array::from_fn(|i| 0x10 + i as u8), ..phone() };
        let mut h = HostPairing::new(scalar(1), host).unwrap();
        let mut p = PhonePairing::new(scalar(2), phone).unwrap();
        let (_, reveal) = through_reveal(&mut h, &mut p);
        assert_eq!(h.receive(&reveal), HostPairingOutput::Completed);
        let hex: String = h.pair_key().unwrap().expose().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "412eab3b375653317cd096f9c47c74fb2db0edf32aa0897f1ef6a50009b12b20");
        assert_eq!(h.sas(), Some("947102"));
        assert_eq!(p.sas(), Some("947102"));
    }

    #[test]
    fn both_sides_agree_and_a_different_identity_changes_the_key() {
        let host_pub = public_key(&scalar(1)).unwrap();
        let phone_pub = public_key(&scalar(2)).unwrap();
        let a = derive_pair_key(&scalar(1), Role::Host, &phone_pub, &host(), &phone()).unwrap();
        let b = derive_pair_key(&scalar(2), Role::Phone, &host_pub, &host(), &phone()).unwrap();
        assert_eq!(a, b);
        let renamed = HostIdentity { name: "書房的 Mac2".into(), ..host() };
        assert_ne!(a, derive_pair_key(&scalar(2), Role::Phone, &host_pub, &renamed, &phone()).unwrap());
        let other_platform = HostIdentity { platform: HostPlatform::Linux, ..host() };
        assert_ne!(a, derive_pair_key(&scalar(2), Role::Phone, &host_pub, &other_platform, &phone()).unwrap());
        let other_id = HostIdentity { id: [9; 16], ..host() };
        assert_ne!(a, derive_pair_key(&scalar(2), Role::Phone, &host_pub, &other_id, &phone()).unwrap());
        let other_phone = PhoneIdentity { id: [9; 16], ..phone() };
        assert_ne!(a, derive_pair_key(&scalar(2), Role::Phone, &host_pub, &host(), &other_phone).unwrap());
        // A man in the middle with his own key gets a different key on each side.
        let mitm_pub = public_key(&scalar(3)).unwrap();
        assert_ne!(a, derive_pair_key(&scalar(2), Role::Phone, &mitm_pub, &host(), &phone()).unwrap());
    }

    #[test]
    fn the_code_is_always_six_digits() {
        let mut leading_zero = 0;
        for i in 0..=255u8 {
            let code = sas(&PairKey::new([i; 32]));
            assert_eq!(code.len(), 6, "{code}");
            assert!(code.bytes().all(|b| b.is_ascii_digit()));
            if code.starts_with('0') {
                leading_zero += 1;
            }
        }
        assert!(leading_zero > 0, "padding is exercised");
    }

    #[test]
    fn scalars_must_be_nonzero_and_below_the_group_order() {
        assert_eq!(public_key(&[0; 32]), Err(PairingError::InvalidScalar));
        assert_eq!(public_key(&[0xFF; 32]), Err(PairingError::InvalidScalar));
        assert!(public_key(&scalar(1)).is_ok());
        assert!(HostPairing::new([0; 32], host()).is_err());
        assert!(PhonePairing::new([0; 32], phone()).is_err());
    }

    #[test]
    fn peer_keys_must_be_65_byte_uncompressed_points_on_the_curve() {
        let good = public_key(&scalar(2)).unwrap();
        assert!(ecdh_x(&scalar(1), &good).is_ok());
        assert_eq!(ecdh_x(&scalar(1), &good[..64]), Err(PairingError::InvalidPublicKey));
        assert_eq!(ecdh_x(&scalar(1), &[good.as_slice(), &[0]].concat()), Err(PairingError::InvalidPublicKey));
        assert_eq!(ecdh_x(&scalar(1), &[]), Err(PairingError::InvalidPublicKey));
        let mut off_curve = good;
        off_curve[64] ^= 1;
        assert_eq!(ecdh_x(&scalar(1), &off_curve), Err(PairingError::InvalidPublicKey));
        let mut bad_prefix = good;
        bad_prefix[0] = 0x05;
        assert_eq!(ecdh_x(&scalar(1), &bad_prefix), Err(PairingError::InvalidPublicKey));
        let mut zeros = [0u8; 65];
        zeros[0] = 4;
        assert_eq!(ecdh_x(&scalar(1), &zeros), Err(PairingError::InvalidPublicKey));
        // A compressed encoding of a valid point is not the wire form.
        let mut compressed = vec![if good[64] & 1 == 0 { 2 } else { 3 }];
        compressed.extend_from_slice(&good[1..33]);
        assert_eq!(ecdh_x(&scalar(1), &compressed), Err(PairingError::InvalidPublicKey));
        // Our own key is refused as the peer's.
        let own = public_key(&scalar(1)).unwrap();
        assert_eq!(ecdh_x(&scalar(1), &own), Err(PairingError::InvalidPublicKey));
    }

    #[test]
    fn commitments_bind_one_key_and_compare_in_constant_time_form() {
        let a = public_key(&scalar(2)).unwrap();
        let b = public_key(&scalar(3)).unwrap();
        let c = commitment(&a);
        assert!(verify_commitment(&c, &a));
        assert!(!verify_commitment(&c, &b));
        assert!(!verify_commitment(&c[..31], &a));
        assert!(!verify_commitment(&[c.as_slice(), &[0]].concat(), &a));
        assert!(!verify_commitment(&[], &a));
    }

    #[test]
    fn proofs_depend_on_key_nonces_and_label() {
        let k = PairKey::new([7; 32]);
        let (hn, pn) = ([1; 16], [2; 16]);
        let p = phone_proof(&k, &hn, &pn);
        assert!(verify_phone_proof(&p, &k, &hn, &pn));
        assert!(!verify_phone_proof(&p, &PairKey::new([8; 32]), &hn, &pn));
        assert!(!verify_phone_proof(&p, &k, &[3; 16], &pn));
        assert!(!verify_phone_proof(&p, &k, &hn, &[3; 16]));
        assert!(!verify_phone_proof(&host_proof(&k, &hn, &pn), &k, &hn, &pn));
        assert!(!verify_phone_proof(&p[..31], &k, &hn, &pn));
        assert!(!verify_phone_proof(&[p.as_slice(), &[0]].concat(), &k, &hn, &pn));
        assert!(!verify_phone_proof(&[], &k, &hn, &pn));
        assert!(!verify_phone_proof(&p, &k, &hn[..15], &pn));
        assert!(!verify_phone_proof(&p, &k, &[hn.as_slice(), &[0]].concat(), &pn));
    }

    #[test]
    fn a_proof_or_commitment_that_differs_in_one_byte_is_refused_wherever_that_byte_is() {
        let k = PairKey::new([7; 32]);
        let (hn, pn) = ([1; 16], [2; 16]);
        let phone = phone_proof(&k, &hn, &pn);
        let host = host_proof(&k, &hn, &pn);
        for index in [0usize, 15, 30, 31] {
            let mut bad = phone;
            bad[index] ^= 1;
            assert!(!verify_phone_proof(&bad, &k, &hn, &pn), "phone proof, byte {index}");
            let mut bad = host;
            bad[index] ^= 1;
            assert!(!verify_host_proof(&bad, &k, &hn, &pn), "host proof, byte {index}");
        }
        let public = public_key(&scalar(2)).unwrap();
        let good = commitment(&public);
        assert!(verify_commitment(&good, &public));
        for index in [0usize, 15, 30, 31] {
            let mut bad = good;
            bad[index] ^= 1;
            assert!(!verify_commitment(&bad, &public), "commitment, byte {index}");
        }
    }

    #[test]
    fn host_rejects_a_second_offer() {
        let (mut h, p) = pairs();
        assert!(matches!(h.receive(&p.offer()), HostPairingOutput::Send(_)));
        assert_eq!(h.receive(&p.offer()), HostPairingOutput::Failed);
    }

    #[test]
    fn host_rejects_offers_that_are_not_32_bytes() {
        for len in [0, 31, 33, 65] {
            let (mut h, _) = pairs();
            assert_eq!(h.receive_offer(&vec![0; len]), HostPairingOutput::Failed, "{len}");
        }
    }

    #[test]
    fn host_rejects_a_reveal_before_the_offer() {
        let (mut h, mut p) = pairs();
        let (_, reveal) = {
            let (mut h2, _) = pairs();
            through_reveal(&mut h2, &mut p)
        };
        assert_eq!(h.receive(&reveal), HostPairingOutput::Failed);
    }

    #[test]
    fn host_rejects_a_reveal_that_does_not_match_the_commitment() {
        let (mut h, mut p) = pairs();
        let (_, reveal) = through_reveal(&mut h, &mut p);
        let PeripheralMessage::PairReveal { phone_id, phone_name, phone_platform, .. } = reveal else { panic!("reveal expected") };
        let other = public_key(&scalar(5)).unwrap().to_vec();
        let swapped = PeripheralMessage::PairReveal { public_key: other, phone_id, phone_name, phone_platform };
        assert_eq!(h.receive(&swapped), HostPairingOutput::Failed);
        assert!(h.pair_key().is_none() && h.sas().is_none() && h.phone().is_none());
    }

    #[test]
    fn host_rejects_a_revealed_key_that_is_not_a_point_or_is_its_own() {
        for bad in [vec![4u8; 65], vec![0u8; 65], vec![4u8; 64], public_key(&scalar(1)).unwrap().to_vec()] {
            let (mut h, _) = pairs();
            h.receive_offer(&commitment(&bad));
            assert_eq!(h.receive_reveal(&bad, &[2; 16], "p", PhonePlatform::Ios), HostPairingOutput::Failed);
        }
    }

    #[test]
    fn host_rejects_a_bad_phone_identity_without_repairing_it() {
        let phone_pub = public_key(&scalar(2)).unwrap();
        let cases: [(&[u8], &str); 4] = [(&[2; 15], "p"), (&[2; 17], "p"), (&[2; 16], ""), (&[2; 16], &"a".repeat(33))];
        for (id, name) in cases {
            let (mut h, _) = pairs();
            h.receive_offer(&commitment(&phone_pub));
            assert_eq!(h.receive_reveal(&phone_pub, id, name, PhonePlatform::Android), HostPairingOutput::Failed, "{} {}", id.len(), name.len());
        }
        // A 32-byte name is fine.
        let (mut h, _) = pairs();
        h.receive_offer(&commitment(&phone_pub));
        assert_eq!(h.receive_reveal(&phone_pub, &[2; 16], &"a".repeat(32), PhonePlatform::Android), HostPairingOutput::Completed);
    }

    #[test]
    fn host_rejects_other_messages_and_stays_failed() {
        for other in [
            PeripheralMessage::NotSelected,
            PeripheralMessage::HelloReply { phone_nonce: vec![0; 16], proof: vec![0; 32] },
            PeripheralMessage::Sealed(vec![0; 40]),
        ] {
            let (mut h, p) = pairs();
            assert_eq!(h.receive(&other), HostPairingOutput::Failed);
            assert_eq!(h.receive(&p.offer()), HostPairingOutput::Failed, "no later message is accepted");
        }
    }

    #[test]
    fn host_failure_drops_keys_and_code() {
        let (mut h, mut p) = pairs();
        let (_, reveal) = through_reveal(&mut h, &mut p);
        assert_eq!(h.receive(&reveal), HostPairingOutput::Completed);
        assert!(h.pair_key().is_some());
        // Any further message ends the attempt and takes the result with it (§5.2).
        assert_eq!(h.receive(&reveal), HostPairingOutput::Failed);
        assert!(h.pair_key().is_none() && h.sas().is_none() && h.phone().is_none());
    }

    #[test]
    fn phone_ignores_everything_but_pair_accept() {
        let (_, mut p) = pairs();
        for other in [
            ControlMessage::Hello { host_id: vec![0; 16], host_nonce: vec![0; 16] },
            ControlMessage::Auth { proof: vec![0; 32] },
            ControlMessage::AuthFailed,
            ControlMessage::Bye,
            ControlMessage::Sealed(vec![1]),
        ] {
            assert_eq!(p.receive(&other), PhonePairingOutput::None);
        }
        // Ignored messages did not fail the attempt.
        let (mut h, _) = pairs();
        let HostPairingOutput::Send(accept) = h.receive(&p.offer()) else { panic!("accept expected") };
        assert!(matches!(p.receive(&accept), PhonePairingOutput::Send(_)));
    }

    fn accept_with(
        key: Vec<u8>,
        id: Vec<u8>,
        name: &str,
        platform: HostPlatform,
    ) -> ControlMessage {
        ControlMessage::PairAccept { public_key: key, host_id: id, host_name: name.into(), platform }
    }

    #[test]
    fn phone_rejects_a_bad_host_identity_or_key() {
        let host_pub = public_key(&scalar(1)).unwrap().to_vec();
        let own_pub = public_key(&scalar(2)).unwrap().to_vec();
        let cases = [
            accept_with(host_pub.clone(), vec![1; 15], "h", HostPlatform::Mac),
            accept_with(host_pub.clone(), vec![1; 17], "h", HostPlatform::Mac),
            accept_with(host_pub.clone(), vec![1; 16], "", HostPlatform::Mac),
            accept_with(host_pub.clone(), vec![1; 16], &"a".repeat(33), HostPlatform::Linux),
            accept_with(host_pub[..64].to_vec(), vec![1; 16], "h", HostPlatform::Mac),
            accept_with(vec![4; 65], vec![1; 16], "h", HostPlatform::Mac),
            accept_with(own_pub, vec![1; 16], "h", HostPlatform::Mac),
        ];
        for (i, bad) in cases.iter().enumerate() {
            let (_, mut p) = pairs();
            assert_eq!(p.receive(bad), PhonePairingOutput::Failed, "case {i}");
            assert!(p.pair_key().is_none() && p.sas().is_none() && p.host().is_none());
            assert_eq!(p.receive(&accept_with(host_pub.clone(), vec![1; 16], "h", HostPlatform::Mac)), PhonePairingOutput::None, "failure is sticky");
        }
    }

    #[test]
    fn phone_fails_on_a_second_accept() {
        let (mut h, mut p) = pairs();
        let (accept, _) = through_reveal(&mut h, &mut p);
        assert_eq!(p.receive(&accept), PhonePairingOutput::Failed);
        assert!(p.pair_key().is_none());
    }

    #[test]
    fn a_renamed_host_in_the_accept_gives_different_codes_on_the_two_sides() {
        let (mut h, mut p) = pairs();
        let HostPairingOutput::Send(ControlMessage::PairAccept { public_key, host_id, platform, .. }) = h.receive(&p.offer()) else {
            panic!("accept expected")
        };
        let forged = ControlMessage::PairAccept { public_key, host_id, host_name: "Evil".into(), platform };
        let PhonePairingOutput::Send(reveal) = p.receive(&forged) else { panic!("reveal expected") };
        assert_eq!(h.receive(&reveal), HostPairingOutput::Completed);
        assert_ne!(h.pair_key(), p.pair_key());
        assert_ne!(h.sas(), p.sas(), "the two people would see different codes");
    }

    #[test]
    fn debug_output_hides_everything() {
        let (h, p) = pairs();
        assert_eq!(format!("{h:?}"), "HostPairing([redacted])");
        assert_eq!(format!("{p:?}"), "PhonePairing([redacted])");
    }
}
