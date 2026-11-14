//! Time as the application sees it: a wall clock for log stamps and a monotonic clock for everything that waits.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub trait Clock: Send + Sync {
    /// Milliseconds since 1970-01-01T00:00:00Z.
    fn wall_unix_ms(&self) -> u64;
    /// Milliseconds since the program started; never goes back.
    fn mono_ms(&self) -> u64;
}

/// The real clocks.
#[derive(Debug)]
pub struct SystemClock {
    start: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self { start: Instant::now() }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn wall_unix_ms(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    }

    fn mono_ms(&self) -> u64 {
        u64::try_from(self.start.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

/// A clock a test moves by hand. Both clocks advance together.
#[derive(Debug)]
pub struct FakeClock {
    wall: AtomicU64,
    mono: AtomicU64,
}

impl FakeClock {
    /// Starts at the given wall time and at monotonic zero.
    pub fn new(wall_unix_ms: u64) -> Self {
        Self { wall: AtomicU64::new(wall_unix_ms), mono: AtomicU64::new(0) }
    }

    pub fn advance(&self, ms: u64) {
        self.wall.fetch_add(ms, Ordering::SeqCst);
        self.mono.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn wall_unix_ms(&self) -> u64 {
        self.wall.load(Ordering::SeqCst)
    }

    fn mono_ms(&self) -> u64 {
        self.mono.load(Ordering::SeqCst)
    }
}
