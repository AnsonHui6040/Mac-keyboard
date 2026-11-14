//! What a link backend tells the diagnostic log: typed, so that no free text can get into it.

use crate::DeviceKey;
use sha2::{Digest, Sha256};

/// Why a connection did not work or ended (the `kind=` field of the diagnostic log).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailKind {
    /// WinRT reported the device unreachable during service discovery.
    Unreachable,
    /// BlueZ's L2CAP socket answered `ENOSYS`.
    Enosys,
    /// The controller dropped the link: `le-connection-abort-by-local`.
    AbortByLocal,
    /// An ATT error response.
    AttError,
    Timeout,
    NotSelected,
    AuthFailed,
    UnsupportedVersion,
    PeerBye,
    LinkLost,
}

impl FailKind {
    /// The word written to the log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unreachable => "unreachable",
            Self::Enosys => "enosys",
            Self::AbortByLocal => "abort_by_local",
            Self::AttError => "att_error",
            Self::Timeout => "timeout",
            Self::NotSelected => "not_selected",
            Self::AuthFailed => "auth_failed",
            Self::UnsupportedVersion => "unsupported_version",
            Self::PeerBye => "peer_bye",
            Self::LinkLost => "link_lost",
        }
    }
}

/// An 8-character hex hash of a device address. Only [`DeviceKey::short`] makes one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShortId(String);

impl ShortId {
    pub(crate) fn of(key: DeviceKey) -> Self {
        let digest = Sha256::digest(key.0.to_le_bytes());
        Self(digest[..4].iter().map(|b| format!("{b:02x}")).collect())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A value a log line can carry. There is deliberately no free-text variant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    U(u64),
    B(bool),
    /// A fixed word chosen by the program, never user data.
    S(&'static str),
    /// A hashed device address.
    Id(ShortId),
}

/// One diagnostic event of a link backend, tied to a connection serial.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diag {
    pub conn: u64,
    pub ev: &'static str,
    /// Milliseconds since the advertisement of this connection was first seen.
    pub since_adv_ms: Option<u64>,
    /// Only written when the log level is `debug`.
    pub debug: bool,
    pub fields: Vec<(&'static str, Value)>,
}

impl Diag {
    pub fn new(conn: u64, ev: &'static str) -> Self {
        Self { conn, ev, since_adv_ms: None, debug: false, fields: Vec::new() }
    }

    pub fn at(mut self, since_adv_ms: u64) -> Self {
        self.since_adv_ms = Some(since_adv_ms);
        self
    }

    pub fn debug(mut self) -> Self {
        self.debug = true;
        self
    }

    pub fn with(mut self, key: &'static str, value: Value) -> Self {
        self.fields.push((key, value));
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_id_is_eight_hex_characters_and_hides_the_address() {
        let id = DeviceKey(0xAABB_CCDD_EEFF).short();
        assert_eq!(id.as_str().len(), 8);
        assert!(id.as_str().bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(!id.as_str().contains("aabbccddeeff"));
        assert_ne!(DeviceKey(1).short(), DeviceKey(2).short());
    }

    #[test]
    fn every_fail_kind_has_its_own_word() {
        let all = [
            FailKind::Unreachable,
            FailKind::Enosys,
            FailKind::AbortByLocal,
            FailKind::AttError,
            FailKind::Timeout,
            FailKind::NotSelected,
            FailKind::AuthFailed,
            FailKind::UnsupportedVersion,
            FailKind::PeerBye,
            FailKind::LinkLost,
        ];
        let mut words: Vec<_> = all.iter().map(|k| k.as_str()).collect();
        words.sort_unstable();
        words.dedup();
        assert_eq!(words.len(), all.len());
    }
}
