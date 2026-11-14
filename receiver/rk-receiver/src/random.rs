//! Where nonces, private scalars and grants come from. The application never reaches for the system itself, so a test can
//! hand it a fixed sequence.

use std::sync::{Arc, Mutex, MutexGuard};

pub trait RandomSource: Send {
    fn fill(&mut self, buf: &mut [u8]);
}

/// The operating system's random source.
#[derive(Debug, Default)]
pub struct OsRandom;

impl RandomSource for OsRandom {
    fn fill(&mut self, buf: &mut [u8]) {
        // The OS source failing is not recoverable and a predictable nonce would be worse than stopping.
        getrandom::fill(buf).expect("operating system random source unavailable");
    }
}

/// A repeatable sequence for tests. Every byte is between 1 and 200, so a 32-byte block is always a valid P-256 scalar.
#[derive(Debug, Default)]
pub struct SequenceRandom {
    counter: u32,
}

impl RandomSource for SequenceRandom {
    fn fill(&mut self, buf: &mut [u8]) {
        self.counter += 1;
        for (i, byte) in buf.iter_mut().enumerate() {
            *byte = u8::try_from((self.counter as usize * 7 + i * 13) % 200 + 1).unwrap_or(1);
        }
    }
}

/// One random source shared by the application and the closures it hands to the core.
#[derive(Clone)]
pub struct SharedRandom {
    inner: Arc<Mutex<Box<dyn RandomSource>>>,
}

impl SharedRandom {
    pub fn new(source: Box<dyn RandomSource>) -> Self {
        Self { inner: Arc::new(Mutex::new(source)) }
    }

    fn lock(&self) -> MutexGuard<'_, Box<dyn RandomSource>> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn bytes<const N: usize>(&self) -> [u8; N] {
        let mut out = [0u8; N];
        self.lock().fill(&mut out);
        out
    }

    pub fn u32(&self) -> u32 {
        u32::from_be_bytes(self.bytes::<4>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_blocks_differ_and_stay_in_range() {
        let r = SharedRandom::new(Box::new(SequenceRandom::default()));
        let a = r.bytes::<32>();
        let b = r.bytes::<32>();
        assert_ne!(a, b);
        assert!(a.iter().chain(b.iter()).all(|x| (1..=200).contains(x)));
    }

    #[test]
    fn os_random_fills_the_buffer() {
        let r = SharedRandom::new(Box::new(OsRandom));
        assert_ne!(r.bytes::<32>(), [0u8; 32]);
    }
}
