//! Counter-AEAD packets for the pointer channel (protocol v4 §8.1, §8.2).

use crate::secret::{PairKey, SecretBytes};
use crate::session::hkdf32;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::ChaCha20Poly1305;
use std::fmt;
use thiserror::Error;

/// First byte of a pointer packet (§8.1).
pub const POINTER_MAGIC: u8 = 0x03;
/// Length of a pointer packet (§8.1).
pub const PACKET_LEN: usize = 41;
/// Length of the pointer plaintext (§8.3).
pub const PLAINTEXT_LEN: usize = 16;

/// Why a packet could not be sealed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ChannelError {
    #[error("plaintext is not 16 bytes")]
    BadLength,
    #[error("counter reached 2^64 - 1")]
    CounterExhausted,
    #[error("sealing failed")]
    SealFailed,
}

/// Why a packet was dropped (§8.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ChannelOpenError {
    #[error("length is not 41")]
    BadLength,
    #[error("first byte is not 0x03")]
    BadMagic,
    #[error("counter already seen, or 0")]
    Replayed,
    #[error("counter more than 64 below the largest accepted")]
    TooOld,
    #[error("tag did not verify")]
    AuthFailed,
}

const HEADER_LEN: usize = 9;
const TAG_LEN: usize = 16;
const NONCE_PREFIX: &[u8; 4] = b"PTR3";

/// `K_ptr` (§8.1): HKDF-SHA256 over the pair key, empty salt, info `"rk-pointer-p2m" ‖ hostNonce ‖ phoneNonce`.
pub fn derive_pointer_key(pair_key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16]) -> SecretBytes<32> {
    SecretBytes::new(hkdf32(pair_key.expose(), &[b"rk-pointer-p2m", host_nonce, phone_nonce]))
}

fn nonce(counter: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[..4].copy_from_slice(NONCE_PREFIX);
    n[4..].copy_from_slice(&counter.to_be_bytes());
    n
}

/// What the replay window says about a counter (§8.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayVerdict {
    Accept,
    Replayed,
    TooOld,
}

/// Largest accepted counter and a bitmap of the 64 below it (§8.2).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplayWindow {
    maximum: u64,
    /// Bit `i` set means counter `maximum - 1 - i` was accepted.
    seen: u64,
}

impl ReplayWindow {
    /// An empty window.
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `counter` may be accepted: not 0, not the maximum, not seen inside the window, not more than 64 below the
    /// maximum. Does not change the window.
    pub fn verdict(&self, counter: u64) -> ReplayVerdict {
        if counter == 0 {
            return ReplayVerdict::Replayed;
        }
        if counter > self.maximum {
            return ReplayVerdict::Accept;
        }
        let distance = self.maximum - counter;
        if distance == 0 {
            ReplayVerdict::Replayed
        } else if distance > 64 {
            ReplayVerdict::TooOld
        } else if self.seen & (1u64 << (distance - 1)) != 0 {
            ReplayVerdict::Replayed
        } else {
            ReplayVerdict::Accept
        }
    }

    /// Records a counter whose packet verified; a counter the window refuses is ignored. Called only after the tag
    /// verified, so a forged packet with a huge counter cannot move the window (§8.2 receiver rule 5).
    pub fn commit(&mut self, counter: u64) {
        if self.verdict(counter) != ReplayVerdict::Accept {
            return;
        }
        if counter > self.maximum {
            let shift = counter - self.maximum;
            self.seen = if shift >= 64 { 0 } else { self.seen << shift };
            // The old maximum is now `shift` below the new one.
            if shift <= 64 {
                self.seen |= 1u64 << (shift - 1);
            }
            self.maximum = counter;
        } else {
            self.seen |= 1u64 << (self.maximum - counter - 1);
        }
    }
}

/// Seals the packets of one connection; the counter is handed out inside `seal` (§8.2 sender rules).
pub struct ChannelSealer {
    key: SecretBytes<32>,
    last_counter: u64,
}

impl ChannelSealer {
    /// Seals one 16-byte plaintext with the next counter. A packet that is not sent is lost, not re-sealed: the next call
    /// uses the next counter, so a nonce never repeats under the key. Counter 2^64 - 1 is the last one usable.
    pub fn seal(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ChannelError> {
        if plaintext.len() != PLAINTEXT_LEN {
            return Err(ChannelError::BadLength);
        }
        if self.last_counter == u64::MAX {
            return Err(ChannelError::CounterExhausted);
        }
        self.last_counter += 1;
        let counter = self.last_counter;
        let mut packet = Vec::with_capacity(PACKET_LEN);
        packet.push(POINTER_MAGIC);
        packet.extend_from_slice(&counter.to_be_bytes());
        let cipher = ChaCha20Poly1305::new(self.key.expose().into());
        let body = cipher
            .encrypt((&nonce(counter)).into(), Payload { msg: plaintext, aad: &packet[..HEADER_LEN] })
            .map_err(|_| ChannelError::SealFailed)?;
        packet.extend_from_slice(&body);
        Ok(packet)
    }

    /// The counter of the packet sealed last; 0 before the first.
    pub fn last_counter(&self) -> u64 {
        self.last_counter
    }
}

/// Opens the packets of one connection; the window moves only after the tag verified (§8.2 receiver rules).
pub struct ChannelOpener {
    key: SecretBytes<32>,
    window: ReplayWindow,
    last_opened_counter: u64,
}

impl ChannelOpener {
    /// Checks and opens one packet: length 41, magic `0x03`, replay window, then the AEAD.
    pub fn open(&mut self, packet: &[u8]) -> Result<Vec<u8>, ChannelOpenError> {
        if packet.len() != PACKET_LEN {
            return Err(ChannelOpenError::BadLength);
        }
        if packet[0] != POINTER_MAGIC {
            return Err(ChannelOpenError::BadMagic);
        }
        let mut counter_bytes = [0u8; 8];
        counter_bytes.copy_from_slice(&packet[1..HEADER_LEN]);
        let counter = u64::from_be_bytes(counter_bytes);
        match self.window.verdict(counter) {
            ReplayVerdict::Accept => {}
            ReplayVerdict::Replayed => return Err(ChannelOpenError::Replayed),
            ReplayVerdict::TooOld => return Err(ChannelOpenError::TooOld),
        }
        let cipher = ChaCha20Poly1305::new(self.key.expose().into());
        let plain = cipher
            .decrypt((&nonce(counter)).into(), Payload { msg: &packet[HEADER_LEN..], aad: &packet[..HEADER_LEN] })
            .map_err(|_| ChannelOpenError::AuthFailed)?;
        debug_assert_eq!(packet.len() - HEADER_LEN - TAG_LEN, plain.len());
        self.window.commit(counter);
        self.last_opened_counter = counter;
        Ok(plain)
    }

    /// The counter of the packet accepted last; 0 before the first.
    pub fn last_opened_counter(&self) -> u64 {
        self.last_opened_counter
    }
}

/// The counter channel of one authenticated connection, kept until the connection ends (§8.2 sender rule 1). Entering
/// and leaving the touchpad page, or closing and reopening the channel, all use the same sealer, so a counter never
/// starts at 1 twice under one key.
pub struct ChannelSet {
    sealer: ChannelSealer,
    opener: ChannelOpener,
}

impl fmt::Debug for ChannelSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ChannelSet([redacted])")
    }
}

impl ChannelSet {
    /// Derives `K_ptr` and starts both counters at 0 (the first packet carries 1).
    pub fn new(pair_key: &PairKey, host_nonce: &[u8; 16], phone_nonce: &[u8; 16]) -> Self {
        Self::with_starting_counter(pair_key, host_nonce, phone_nonce, 0)
    }

    /// As `new`, but the sealer's next packet carries `starting_counter + 1`. For tests of very large counters.
    pub(crate) fn with_starting_counter(
        pair_key: &PairKey,
        host_nonce: &[u8; 16],
        phone_nonce: &[u8; 16],
        starting_counter: u64,
    ) -> Self {
        let key = derive_pointer_key(pair_key, host_nonce, phone_nonce);
        Self {
            sealer: ChannelSealer { key: key.clone(), last_counter: starting_counter },
            opener: ChannelOpener { key, window: ReplayWindow::new(), last_opened_counter: 0 },
        }
    }

    /// The sending side (phone).
    pub fn sealer(&mut self) -> &mut ChannelSealer {
        &mut self.sealer
    }

    /// The receiving side (host).
    pub fn opener(&mut self) -> &mut ChannelOpener {
        &mut self.opener
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_NONCE: [u8; 16] = [0xA0; 16];
    const PHONE_NONCE: [u8; 16] = [0xB0; 16];

    fn set() -> ChannelSet {
        ChannelSet::new(&PairKey::new([0x42; 32]), &HOST_NONCE, &PHONE_NONCE)
    }

    fn plain(n: u8) -> [u8; 16] {
        [n; 16]
    }

    #[test]
    fn a_packet_is_41_bytes_with_magic_and_big_endian_counter() {
        let mut s = set();
        let p = s.sealer().seal(&plain(1)).unwrap();
        assert_eq!(p.len(), PACKET_LEN);
        assert_eq!(p[0], 0x03);
        assert_eq!(p[1..9], 1u64.to_be_bytes());
        let p = s.sealer().seal(&plain(1)).unwrap();
        assert_eq!(p[1..9], 2u64.to_be_bytes());
        assert_eq!(s.sealer().last_counter(), 2);
    }

    #[test]
    fn only_16_byte_plaintexts_are_sealed() {
        let mut s = set();
        assert_eq!(s.sealer().seal(&[0; 15]), Err(ChannelError::BadLength));
        assert_eq!(s.sealer().seal(&[0; 17]), Err(ChannelError::BadLength));
        assert_eq!(s.sealer().last_counter(), 0, "a refused plaintext does not use a counter");
    }

    #[test]
    fn a_sealed_packet_opens_once() {
        let mut phone = set();
        let mut host = set();
        let p = phone.sealer().seal(&plain(7)).unwrap();
        assert_eq!(host.opener().open(&p).unwrap(), plain(7));
        assert_eq!(host.opener().last_opened_counter(), 1);
        assert_eq!(host.opener().open(&p), Err(ChannelOpenError::Replayed));
    }

    #[test]
    fn wrong_length_and_wrong_magic_are_refused_before_anything_else() {
        let mut phone = set();
        let mut host = set();
        let p = phone.sealer().seal(&plain(7)).unwrap();
        assert_eq!(host.opener().open(&p[..40]), Err(ChannelOpenError::BadLength));
        assert_eq!(host.opener().open(&[p.clone(), vec![0]].concat()), Err(ChannelOpenError::BadLength));
        assert_eq!(host.opener().open(&[]), Err(ChannelOpenError::BadLength));
        let mut bad = p.clone();
        bad[0] = 0x7E;
        assert_eq!(host.opener().open(&bad), Err(ChannelOpenError::BadMagic));
        bad[0] = 0x02;
        assert_eq!(host.opener().open(&bad), Err(ChannelOpenError::BadMagic));
        assert!(host.opener().open(&p).is_ok(), "the good packet is still fine afterwards");
    }

    #[test]
    fn counter_zero_is_refused() {
        let mut host = set();
        let mut p = vec![0x03];
        p.extend_from_slice(&0u64.to_be_bytes());
        p.extend_from_slice(&[0; 32]);
        assert_eq!(host.opener().open(&p), Err(ChannelOpenError::Replayed));
    }

    #[test]
    fn a_flipped_bit_anywhere_fails_the_tag_and_does_not_move_the_window() {
        let mut phone = set();
        let mut host = set();
        let p = phone.sealer().seal(&plain(7)).unwrap();
        for i in 1..PACKET_LEN {
            let mut bad = p.clone();
            bad[i] ^= 0x80;
            assert_eq!(host.opener().open(&bad), Err(ChannelOpenError::AuthFailed), "byte {i}");
        }
        // The forged packets did not consume counter 1.
        assert_eq!(host.opener().open(&p).unwrap(), plain(7));
    }

    #[test]
    fn a_forged_huge_counter_cannot_push_the_window_forward() {
        let mut phone = set();
        let mut host = set();
        let first = phone.sealer().seal(&plain(1)).unwrap();
        let mut forged = first.clone();
        forged[1..9].copy_from_slice(&(1u64 << 40).to_be_bytes());
        assert_eq!(host.opener().open(&forged), Err(ChannelOpenError::AuthFailed));
        assert_eq!(host.opener().open(&first).unwrap(), plain(1), "the genuine packet still opens");
    }

    #[test]
    fn another_connection_key_does_not_open() {
        let mut phone = ChannelSet::new(&PairKey::new([0x42; 32]), &HOST_NONCE, &[0xB1; 16]);
        let mut host = set();
        let p = phone.sealer().seal(&plain(1)).unwrap();
        assert_eq!(host.opener().open(&p), Err(ChannelOpenError::AuthFailed));
    }

    #[test]
    fn packets_inside_the_window_open_in_any_order_once_each() {
        let mut phone = set();
        let mut host = set();
        let packets: Vec<Vec<u8>> = (0..10).map(|i| phone.sealer().seal(&plain(i)).unwrap()).collect();
        for i in [9usize, 7, 8, 0, 5] {
            assert_eq!(host.opener().open(&packets[i]).unwrap(), plain(i as u8), "packet {i}");
        }
        for i in [9usize, 7, 8, 0, 5] {
            assert_eq!(host.opener().open(&packets[i]), Err(ChannelOpenError::Replayed), "packet {i} again");
        }
        assert_eq!(host.opener().open(&packets[6]).unwrap(), plain(6));
    }

    #[test]
    fn a_packet_more_than_64_below_the_maximum_is_too_old() {
        let mut phone = set();
        let mut host = set();
        let packets: Vec<Vec<u8>> = (0..70).map(|_| phone.sealer().seal(&plain(0)).unwrap()).collect();
        host.opener().open(&packets[69]).unwrap(); // counter 70
        assert_eq!(host.opener().open(&packets[4]), Err(ChannelOpenError::TooOld), "counter 5 is 65 below");
        assert!(host.opener().open(&packets[5]).is_ok(), "counter 6 is exactly 64 below");
    }

    #[test]
    fn the_window_edge_is_exactly_64() {
        let mut w = ReplayWindow::new();
        w.commit(100);
        assert_eq!(w.verdict(36), ReplayVerdict::Accept, "distance 64");
        assert_eq!(w.verdict(35), ReplayVerdict::TooOld, "distance 65");
        assert_eq!(w.verdict(100), ReplayVerdict::Replayed);
        assert_eq!(w.verdict(101), ReplayVerdict::Accept);
        assert_eq!(w.verdict(0), ReplayVerdict::Replayed);
    }

    #[test]
    fn committing_a_big_jump_forgets_the_old_bitmap_but_keeps_the_old_maximum_once_in_range() {
        let mut w = ReplayWindow::new();
        w.commit(5);
        w.commit(5 + 64);
        assert_eq!(w.verdict(5), ReplayVerdict::Replayed, "distance 64: still remembered");
        w.commit(5 + 64 + 1);
        assert_eq!(w.verdict(5), ReplayVerdict::TooOld, "distance 65");
        w.commit(1_000_000);
        assert_eq!(w.verdict(999_999), ReplayVerdict::Accept);
        assert_eq!(w.verdict(70), ReplayVerdict::TooOld);
        // A jump of exactly 64 and of more than 64 do not overflow the shift.
        let mut w = ReplayWindow::new();
        w.commit(1);
        w.commit(65);
        w.commit(65 + 64);
        w.commit(65 + 64 + 200);
    }

    #[test]
    fn check_does_not_change_the_window() {
        let mut w = ReplayWindow::new();
        w.commit(10);
        let before = w.clone();
        assert_eq!(w.verdict(11), ReplayVerdict::Accept);
        assert_eq!(w, before);
        w.commit(0);
        w.commit(10);
        w.commit(1);
        w.commit(1);
        assert_eq!(w.verdict(1), ReplayVerdict::Replayed);
    }

    #[test]
    fn counter_two_to_the_64_minus_one_is_the_last_usable() {
        let key = PairKey::new([0x42; 32]);
        let mut phone = ChannelSet::with_starting_counter(&key, &HOST_NONCE, &PHONE_NONCE, u64::MAX - 2);
        let mut host = set();
        let a = phone.sealer().seal(&plain(1)).unwrap(); // MAX - 1
        let b = phone.sealer().seal(&plain(2)).unwrap(); // MAX
        assert_eq!(b[1..9], u64::MAX.to_be_bytes());
        assert_eq!(phone.sealer().seal(&plain(3)), Err(ChannelError::CounterExhausted));
        assert_eq!(phone.sealer().seal(&plain(3)), Err(ChannelError::CounterExhausted), "stays finished");
        assert_eq!(host.opener().open(&b).unwrap(), plain(2));
        assert_eq!(host.opener().open(&a).unwrap(), plain(1), "MAX - 1 is still inside the window");
        assert_eq!(host.opener().last_opened_counter(), u64::MAX - 1);
    }

    #[test]
    fn a_dropped_packet_leaves_a_gap_and_the_next_one_uses_a_new_counter() {
        let mut phone = set();
        let mut host = set();
        let lost = phone.sealer().seal(&plain(1)).unwrap();
        let next = phone.sealer().seal(&plain(1)).unwrap();
        assert_ne!(lost, next);
        assert_eq!(next[1..9], 2u64.to_be_bytes());
        assert!(host.opener().open(&next).is_ok());
    }

    #[test]
    fn debug_output_hides_the_keys() {
        assert_eq!(format!("{:?}", set()), "ChannelSet([redacted])");
    }
}
