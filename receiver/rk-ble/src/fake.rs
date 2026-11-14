//! A backend stand-in for tests: it keeps the state a real backend keeps (connected or not, scanning or not, holds,
//! writes) and turns commands into the events a real one would answer with.

use crate::{DeviceKey, DisconnectReason, Diag, LinkCommand, LinkEvent, Route};
use std::time::Duration;

#[derive(Debug)]
pub struct FakeLink {
    next_conn: u64,
    connected: Option<(u64, DeviceKey)>,
    pairing_scan: bool,
    commands: Vec<LinkCommand>,
    writes: Vec<Vec<u8>>,
    holds: Vec<(DeviceKey, Duration)>,
}

impl Default for FakeLink {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeLink {
    pub fn new() -> Self {
        Self { next_conn: 1, connected: None, pairing_scan: false, commands: Vec::new(), writes: Vec::new(), holds: Vec::new() }
    }

    /// The device advertises, the backend connects: `adv_seen`, then `Connected`. Scanning stops.
    pub fn connect(&mut self, device: DeviceKey, route: Route, mtu: usize) -> Vec<LinkEvent> {
        let conn = self.next_conn;
        self.next_conn += 1;
        self.connected = Some((conn, device));
        vec![
            LinkEvent::Diag(Diag::new(conn, "adv_seen").at(0)),
            LinkEvent::Connected { conn, device, route, mtu },
        ]
    }

    /// One notification from the connected device.
    pub fn notify(&self, bytes: Vec<u8>) -> LinkEvent {
        LinkEvent::Notification(bytes)
    }

    /// The device goes away. Scanning resumes. `None` when nothing was connected.
    pub fn drop_link(&mut self, reason: DisconnectReason) -> Option<LinkEvent> {
        let (conn, device) = self.connected.take()?;
        Some(LinkEvent::Disconnected { conn, device, reason })
    }

    /// What the application sent. A `Disconnect` answers with the `Disconnected` event of a real backend.
    pub fn apply(&mut self, command: LinkCommand) -> Option<LinkEvent> {
        self.commands.push(command.clone());
        match command {
            LinkCommand::Write(bytes) => {
                self.writes.push(bytes);
                None
            }
            LinkCommand::Disconnect => self.drop_link(DisconnectReason::Local),
            LinkCommand::Hold { device, for_ } => {
                self.holds.push((device, for_));
                None
            }
            LinkCommand::SetPairingScan(on) => {
                self.pairing_scan = on;
                None
            }
        }
    }

    /// The backend scans exactly when no connection exists.
    pub fn is_scanning(&self) -> bool {
        self.connected.is_none()
    }

    pub fn is_connected(&self) -> bool {
        self.connected.is_some()
    }

    /// The pairing UUID is scanned for as well.
    pub fn pairing_scan(&self) -> bool {
        self.pairing_scan
    }

    pub fn commands(&self) -> &[LinkCommand] {
        &self.commands
    }

    /// Every `Write` so far, oldest first.
    pub fn writes(&self) -> &[Vec<u8>] {
        &self.writes
    }

    /// Every `Hold` so far, oldest first.
    pub fn holds(&self) -> &[(DeviceKey, Duration)] {
        &self.holds
    }

    /// The writes since the last call; commands and holds stay recorded.
    pub fn take_writes(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.writes)
    }

    /// Forgets the recorded commands (not the connection state).
    pub fn clear_record(&mut self) {
        self.commands.clear();
        self.writes.clear();
        self.holds.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scanning_stops_while_connected_and_resumes_after() {
        let mut link = FakeLink::new();
        assert!(link.is_scanning());
        link.connect(DeviceKey(7), Route::Selected, 185);
        assert!(!link.is_scanning());
        let ended = link.apply(LinkCommand::Disconnect);
        assert!(matches!(ended, Some(LinkEvent::Disconnected { reason: DisconnectReason::Local, .. })));
        assert!(link.is_scanning());
    }

    #[test]
    fn connections_get_increasing_serials() {
        let mut link = FakeLink::new();
        let first = link.connect(DeviceKey(1), Route::Selected, 185);
        link.drop_link(DisconnectReason::Remote);
        let second = link.connect(DeviceKey(1), Route::Selected, 185);
        let serial = |events: &[LinkEvent]| match events[1] {
            LinkEvent::Connected { conn, .. } => conn,
            _ => unreachable!(),
        };
        assert_eq!((serial(&first), serial(&second)), (1, 2));
    }
}
