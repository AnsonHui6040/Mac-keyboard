//! The Wi-Fi assist (protocol v4 §8.6) as pure logic: where probes go, when the next one is due, which datagrams are let in.
//!
//! Nothing here touches a socket or a clock. The application keeps one [`Probing`] per connection while the pointer channel
//! is open with a valid `wifi` offer, asks it when a probe is due and what a datagram's source must be, and hands the
//! sealed probe to the runner as a [`WifiCommand`].

use rk_core::channel::{PACKET_LEN, POINTER_MAGIC};
use rk_core::message::WifiOffer;
use std::io;
use std::net::{SocketAddr, SocketAddrV4};

/// §8.6 rule 1 (Provisional, no measurement behind it): one probe per address every 250 ms.
pub const PROBE_INTERVAL_MS: u64 = 250;

/// What the application asks the runner to do on the network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WifiCommand {
    /// Send one datagram with these bytes to each of these addresses.
    Send { to: Vec<SocketAddrV4>, bytes: Vec<u8> },
}

/// The probes of one open pointer channel: the targets from `pointerOpen.wifi` and the time of the next probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Probing {
    targets: Vec<SocketAddrV4>,
    next_ms: u64,
}

impl Probing {
    /// Probing that starts now: the first probe is due at `now_ms`.
    pub fn new(offer: &WifiOffer, now_ms: u64) -> Self {
        Self { targets: offer.addrs.iter().map(|a| SocketAddrV4::new(*a, offer.port)).collect(), next_ms: now_ms }
    }

    pub fn targets(&self) -> &[SocketAddrV4] {
        &self.targets
    }

    pub fn target_count(&self) -> usize {
        self.targets.len()
    }

    /// A probe is due.
    pub fn due(&self, now_ms: u64) -> bool {
        now_ms >= self.next_ms
    }

    /// A probe was sent at `now_ms`. The next one is one interval later, not earlier to make up for a late wake-up.
    pub fn sent(&mut self, now_ms: u64) {
        self.next_ms = now_ms + PROBE_INTERVAL_MS;
    }

    /// The time the next probe is due.
    pub fn next_wake_ms(&self) -> u64 {
        self.next_ms
    }

    /// §8.6 rule 4: only a datagram from an address and port we probe is listened to.
    pub fn is_target(&self, from: SocketAddr) -> bool {
        match from {
            SocketAddr::V4(from) => self.targets.contains(&from),
            SocketAddr::V6(_) => false,
        }
    }
}

/// The word the log uses for the kind of an I/O error: a fixed word, never the text of the error (which can hold an address).
pub fn io_kind_word(kind: io::ErrorKind) -> &'static str {
    match kind {
        io::ErrorKind::PermissionDenied => "permission_denied",
        io::ErrorKind::AddrInUse => "addr_in_use",
        io::ErrorKind::AddrNotAvailable => "addr_not_available",
        io::ErrorKind::ConnectionReset => "connection_reset",
        io::ErrorKind::ConnectionRefused => "connection_refused",
        io::ErrorKind::NetworkUnreachable => "network_unreachable",
        io::ErrorKind::HostUnreachable => "host_unreachable",
        io::ErrorKind::NetworkDown => "network_down",
        io::ErrorKind::WouldBlock => "would_block",
        io::ErrorKind::InvalidInput => "invalid_input",
        io::ErrorKind::TimedOut => "timed_out",
        io::ErrorKind::OutOfMemory => "out_of_memory",
        _ => "other",
    }
}

/// §8.6 rule 4: a datagram worth handing to the pointer checks is exactly 41 bytes and starts with `0x03`.
pub fn is_pointer_datagram(bytes: &[u8]) -> bool {
    bytes.len() == PACKET_LEN && bytes.first() == Some(&POINTER_MAGIC)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_core::message::WifiOffer;
    use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

    fn offer(addrs: &[[u8; 4]], port: u16) -> WifiOffer {
        WifiOffer::new(addrs.iter().map(|a| Ipv4Addr::from(*a)).collect(), port).expect("a valid offer")
    }

    #[test]
    fn targets_are_every_address_of_the_offer_with_its_port() {
        let p = Probing::new(&offer(&[[192, 168, 1, 23], [10, 0, 0, 5]], 50_123), 0);
        assert_eq!(
            p.targets(),
            [SocketAddrV4::new(Ipv4Addr::new(192, 168, 1, 23), 50_123), SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 5), 50_123)]
        );
        assert_eq!(p.target_count(), 2);
    }

    #[test]
    fn the_first_probe_is_due_at_once_and_the_next_one_250_ms_after_each_send() {
        let mut p = Probing::new(&offer(&[[192, 168, 1, 23]], 4000), 1_000);
        assert!(p.due(1_000));
        assert_eq!(p.next_wake_ms(), 1_000);
        p.sent(1_000);
        assert!(!p.due(1_249));
        assert!(p.due(1_250));
        assert_eq!(p.next_wake_ms(), 1_250);
        p.sent(1_251);
        assert_eq!(p.next_wake_ms(), 1_501, "a late wake-up does not make up for the lost time with a burst");
    }

    #[test]
    fn only_a_target_address_and_port_is_a_source_to_listen_to() {
        let p = Probing::new(&offer(&[[192, 168, 1, 23]], 4000), 0);
        let from = |a: [u8; 4], port| SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::from(a), port));
        assert!(p.is_target(from([192, 168, 1, 23], 4000)));
        assert!(!p.is_target(from([192, 168, 1, 23], 4001)), "same host, other port");
        assert!(!p.is_target(from([192, 168, 1, 24], 4000)), "other host, same port");
        assert!(!p.is_target(SocketAddr::new(std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST), 4000)));
    }

    #[test]
    fn a_datagram_is_a_candidate_only_with_41_bytes_and_magic_03() {
        let mut ok = vec![0x03];
        ok.resize(41, 0);
        assert!(is_pointer_datagram(&ok));
        assert!(!is_pointer_datagram(&ok[..40]));
        let mut long = ok.clone();
        long.push(0);
        assert!(!is_pointer_datagram(&long));
        let mut probe = ok.clone();
        probe[0] = 0x05;
        assert!(!is_pointer_datagram(&probe), "a probe is not a pointer packet");
        assert!(!is_pointer_datagram(&[]));
    }
}
