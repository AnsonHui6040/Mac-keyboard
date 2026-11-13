//! Fixed-size secret byte strings (protocol v4 §5.3 pair key, §7.1 session keys, §8.1 channel key).

use std::fmt;
use subtle::ConstantTimeEq;

/// A secret of `N` bytes. `Debug` never prints the bytes and equality is constant time.
#[derive(Clone)]
pub struct SecretBytes<const N: usize>([u8; N]);

impl<const N: usize> SecretBytes<N> {
    /// Wraps raw secret bytes.
    pub fn new(bytes: [u8; N]) -> Self {
        Self(bytes)
    }

    /// The raw bytes, for key storage and the crypto primitives. Callers must not log them.
    pub fn expose(&self) -> &[u8; N] {
        &self.0
    }
}

impl<const N: usize> fmt::Debug for SecretBytes<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecretBytes([redacted])")
    }
}

impl<const N: usize> PartialEq for SecretBytes<N> {
    fn eq(&self, other: &Self) -> bool {
        self.0.ct_eq(&other.0).into()
    }
}

impl<const N: usize> Eq for SecretBytes<N> {}

/// The 32-byte key two paired devices share (protocol v4 §5.3).
pub type PairKey = SecretBytes<32>;
