//! A backend stand-in for tests: it keeps the state a real backend keeps (connected or not, scanning or not, holds,
//! writes) and turns commands into the events a real one would answer with.

use crate::stale::{is_stale_link, Advert, HeldLink};
use crate::{DeviceKey, DisconnectReason, Diag, LinkCommand, LinkEvent, Route, Value};
use std::time::Duration;

#[derive(Debug)]
pub struct FakeLink {
    next_conn: u64,
    connected: Option<(u64, DeviceKey)>,
    route: Route,
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
        Self { next_conn: 1, connected: None, route: Route::Selected, pairing_scan: false, commands: Vec::new(), writes: Vec::new(), holds: Vec::new() }
    }

    /// The device advertises, the backend connects: `adv_seen`, then `Connected`. Scanning stops.
    pub fn connect(&mut self, device: DeviceKey, route: Route, mtu: usize) -> Vec<LinkEvent> {
        let conn = self.next_conn;
        self.next_conn += 1;
        self.connected = Some((conn, device));
        self.route = route;
        vec![
            LinkEvent::Diag(Diag::new(conn, "adv_seen").at(0)),
            LinkEvent::Connected { conn, device, route, mtu },
        ]
    }

    /// An advertisement is seen while a link is held (a real backend keeps watching for the selected UUID then). When the
    /// shared decision calls the held link stale, it ends with `StaleAdvert` (no hold) and the advertiser is connected at
    /// once: `stale_link`, `Disconnected`, `adv_seen`, `Connected`. Otherwise nothing happens. `route` is which of our
    /// UUIDs the advert carries.
    pub fn advert_while_connected(&mut self, device: DeviceKey, route: Option<Route>, subscribed_for: Duration, mtu: usize) -> Vec<LinkEvent> {
        let Some((conn, held)) = self.connected else { return Vec::new() };
        let link = HeldLink { route: self.route, device: held, subscribed_for: Some(subscribed_for) };
        if !is_stale_link(link, Advert { device, route }) {
            return Vec::new();
        }
        let ms = u64::try_from(subscribed_for.as_millis()).unwrap_or(u64::MAX);
        let mut events = vec![
            LinkEvent::Diag(Diag::new(conn, "stale_link").with("ms", Value::U(ms))),
            LinkEvent::Disconnected { conn, device: held, reason: DisconnectReason::StaleAdvert },
        ];
        events.extend(self.connect(device, Route::Selected, mtu));
        events
    }

    /// One notification from the connected device.
    pub fn notify(&self, bytes: Vec<u8>) -> LinkEvent {
        let conn = self.connected.map_or(0, |(conn, _)| conn);
        LinkEvent::Notification { conn, bytes }
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

    /// The backend looks for new targets exactly when no connection exists (while one does, it only watches for the
    /// selected UUID of the held link, see `advert_while_connected`).
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
    fn a_selected_advert_after_the_grace_replaces_the_stale_link_at_once() {
        use crate::stale::STALE_ADVERT_GRACE;
        let mut link = FakeLink::new();
        link.connect(DeviceKey(7), Route::Selected, 185);
        // Too early, another phone, the pairing UUID: the link stays.
        assert!(link.advert_while_connected(DeviceKey(7), Some(Route::Selected), STALE_ADVERT_GRACE, 185).is_empty());
        assert!(link.advert_while_connected(DeviceKey(8), Some(Route::Selected), Duration::from_secs(5), 185).is_empty());
        assert!(link.advert_while_connected(DeviceKey(7), Some(Route::Pairing), Duration::from_secs(5), 185).is_empty());
        assert!(link.is_connected());
        // Late enough: the old link goes (reason stale_advert, no hold) and the advertiser is connected at once.
        let events = link.advert_while_connected(DeviceKey(7), Some(Route::Selected), Duration::from_secs(5), 185);
        assert!(matches!(events[0], LinkEvent::Diag(ref d) if d.ev == "stale_link"), "{events:?}");
        assert!(matches!(events[1], LinkEvent::Disconnected { conn: 1, reason: DisconnectReason::StaleAdvert, .. }));
        assert!(matches!(events[3], LinkEvent::Connected { conn: 2, route: Route::Selected, .. }), "{events:?}");
        assert!(link.holds().is_empty());
        assert!(link.is_connected());
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
