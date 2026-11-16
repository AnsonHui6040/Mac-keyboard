//! The decision both backends share: is the link we hold a stale one?
//!
//! The keyboard advertises its selected UUID only while it has no subscribed central. When the keyboard is dismissed the
//! old link is not closed by the phone: this side would keep it until the supervision timeout (about 10 s) and the next
//! keyboard would wait for it. An advertisement carrying our selected UUID, seen while we think we are connected, tells us
//! the phone no longer is. The backends keep the advertisement scan running while connected and ask this function.

use crate::att::{AttError, ReadReply};
use crate::{DeviceKey, Route};
use std::time::{Duration, Instant};

/// The advertisement has to be seen this long after the link reached `subscribed` to count (Provisional): the phone may
/// still send the last adverts of its previous round for a moment after it has been connected to.
pub const STALE_ADVERT_GRACE: Duration = Duration::from_millis(1000);

/// How long the confirmation read waits for any reply before the link counts as dead (Provisional). A healthy link
/// answers within a connection interval or two; the keyboard is typed on, so a longer wait would cost keystrokes.
pub const STALE_CONFIRM_TIMEOUT: Duration = Duration::from_millis(1000);

/// After a link has answered the confirmation, further stale adverts on it are ignored for this long (Provisional):
/// the phone keeps advertising next to a live link, and every check costs one round trip on it.
pub const STALE_RECHECK_BACKOFF: Duration = Duration::from_secs(5);

/// The link that is open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeldLink {
    pub route: Route,
    pub device: DeviceKey,
    /// How long ago the link was subscribed; `None` while it is not yet.
    pub subscribed_for: Option<Duration>,
}

/// What the confirmation read of a link that looks stale came back with. The read is of the event characteristic's
/// CCCD: iOS answers it with this connection's own client configuration. Our live subscription reads as notify
/// (0x0001); once the phone has removed and re-added its service, the old connection is no longer subscribed (0x0000)
/// or the handle is gone (an ATT error). The old radio link may still be up then, so a mere reply proves nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    /// The notify bit is set: our subscription is still in place.
    Subscribed,
    /// A reply without the notify bit (or an empty one).
    NotSubscribed,
    /// An ATT Error Response (invalid handle after a service change, or anything else).
    AttError,
    /// No reply within `STALE_CONFIRM_TIMEOUT`.
    TimedOut,
    /// The channel closed or the socket failed.
    Failed,
}

impl ProbeOutcome {
    pub fn of(result: &Result<ReadReply, AttError>) -> Self {
        match result {
            Ok(ReadReply::Answered(value)) if value.first().is_some_and(|b| b & 0x01 != 0) => Self::Subscribed,
            Ok(ReadReply::Answered(_)) => Self::NotSubscribed,
            Ok(ReadReply::AttError) => Self::AttError,
            Err(AttError::Timeout) => Self::TimedOut,
            Err(_) => Self::Failed,
        }
    }
}

/// `true` only while our subscription is confirmed: everything else ends the link as stale.
pub fn link_alive(outcome: ProbeOutcome) -> bool {
    outcome == ProbeOutcome::Subscribed
}

/// When a link last proved itself alive; stale adverts inside the backoff are not checked again.
#[derive(Debug, Default)]
pub struct StaleBackoff {
    alive_at: Option<Instant>,
}

impl StaleBackoff {
    pub fn allows_check(&self, now: Instant) -> bool {
        self.alive_at.is_none_or(|at| now.saturating_duration_since(at) >= STALE_RECHECK_BACKOFF)
    }

    pub fn alive_at(&mut self, now: Instant) {
        self.alive_at = Some(now);
    }
}

/// An advertisement that was seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Advert {
    pub device: DeviceKey,
    /// Which of our UUIDs it carries; `None` for any other advertisement.
    pub route: Option<Route>,
}

/// `true` when the held link must be released and the advertiser connected to at once.
///
/// - Only a link made through the selected UUID can be stale; a pairing link is excluded, and so are pairing adverts.
/// - The advert must come from the device the link is with. Another phone that is paired with this computer advertises
///   its selected UUID too, while it has no host, and must not cost the first phone its working link. (A phone that
///   changed its random address in between is not recognised, and the old link then ends by itself after the timeout.)
/// - "More than the grace" is strict: an advert exactly `STALE_ADVERT_GRACE` after `subscribed` is not yet counted.
pub fn is_stale_link(link: HeldLink, advert: Advert) -> bool {
    link.route == Route::Selected
        && advert.route == Some(Route::Selected)
        && advert.device == link.device
        && link.subscribed_for.is_some_and(|age| age > STALE_ADVERT_GRACE)
}

/// How long the link had been subscribed when the advertisement was SEEN (not when it was looked at): an advert that
/// arrived before `subscribed` counts as zero, however late it is drained.
pub fn age_at(subscribed_at: Instant, seen_at: Instant) -> Duration {
    seen_at.saturating_duration_since(subscribed_at)
}

/// One property change of the held device, as BlueZ reports it while discovery runs with `DuplicateData`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeldChange {
    Rssi,
    ManufacturerData,
    Other,
}

/// Linux: once connected, BlueZ already lists our UUID for the phone, so a repeated advertisement changes no `UUIDs`.
/// What does arrive for every advertisement is one D-Bus `PropertiesChanged` signal with `RSSI`, plus `ManufacturerData`
/// when the advertisement carries manufacturer data. `bluer` splits that signal into separate events in hash-map order,
/// so the two come in either order, possibly with other properties in between. The keyboard's own advertisement carries
/// only UUIDs and a name; the phone's other advertisements (Apple's, from the same address) carry manufacturer data.
///
/// So every change within `QUIET` of the first one forms one burst, whatever its kind and order; no change ends a burst
/// early. When the burst ends, it counts as one advertisement of the keyboard only if it holds an `RSSI` change and no
/// `ManufacturerData` change, stamped with the time of its first `RSSI` change.
#[derive(Debug, Default)]
pub struct AdvertBursts {
    burst: Option<Burst>,
}

#[derive(Debug, Clone, Copy)]
struct Burst {
    started: Instant,
    first_rssi: Option<Instant>,
    manufacturer_data: bool,
}

impl Burst {
    fn keyboard_advert(self) -> Option<Instant> {
        if self.manufacturer_data {
            None
        } else {
            self.first_rssi
        }
    }
}

impl AdvertBursts {
    /// How long after the first change of a signal the rest of it may still come (measured: under 30 µs, same signal).
    pub const QUIET: Duration = Duration::from_millis(50);

    /// Feeds one change; returns the time of a keyboard advertisement when this change comes `QUIET` or more after the
    /// start of the open burst, which it then concludes before opening the next one.
    pub fn on_change(&mut self, change: HeldChange, now: Instant) -> Option<Instant> {
        let concluded = match self.burst {
            Some(burst) if now >= burst.started + Self::QUIET => self.burst.take().and_then(Burst::keyboard_advert),
            _ => None,
        };
        let burst = self.burst.get_or_insert(Burst { started: now, first_rssi: None, manufacturer_data: false });
        match change {
            HeldChange::Rssi => {
                burst.first_rssi.get_or_insert(now);
            }
            HeldChange::ManufacturerData => burst.manufacturer_data = true,
            HeldChange::Other => {}
        }
        concluded
    }

    /// `QUIET` has passed since the burst started; returns the time of a keyboard advertisement this concludes.
    pub fn on_quiet(&mut self) -> Option<Instant> {
        self.burst.take().and_then(Burst::keyboard_advert)
    }

    /// When `on_quiet` is due, if a burst is open.
    pub fn quiet_at(&self) -> Option<Instant> {
        self.burst.map(|burst| burst.started + Self::QUIET)
    }
}

/// The scan that runs next to a link was stopped by the system: it is started again once, after a pause; a second stop
/// gives up (stale detection is then off for the rest of this link).
#[derive(Debug, Default)]
pub struct WatchRestart {
    used: bool,
    due: Option<Instant>,
}

impl WatchRestart {
    pub const BACKOFF: Duration = Duration::from_millis(500);

    /// The watcher stopped by itself. `true` when a restart is scheduled, `false` when it is given up.
    pub fn stopped(&mut self, now: Instant) -> bool {
        if std::mem::replace(&mut self.used, true) {
            self.due = None;
            return false;
        }
        self.due = Some(now + Self::BACKOFF);
        true
    }

    /// `true` once, when the scheduled restart is due.
    pub fn due(&mut self, now: Instant) -> bool {
        if self.due.is_some_and(|at| now >= at) {
            self.due = None;
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PHONE: DeviceKey = DeviceKey(7);

    fn link(route: Route, ms: Option<u64>) -> HeldLink {
        HeldLink { route, device: PHONE, subscribed_for: ms.map(Duration::from_millis) }
    }

    fn advert(route: Option<Route>) -> Advert {
        Advert { device: PHONE, route }
    }

    #[test]
    fn the_grace_period_is_strict() {
        assert!(!is_stale_link(link(Route::Selected, Some(1_000)), advert(Some(Route::Selected))));
        assert!(is_stale_link(link(Route::Selected, Some(1_001)), advert(Some(Route::Selected))));
        assert!(!is_stale_link(link(Route::Selected, Some(0)), advert(Some(Route::Selected))));
        assert_eq!(STALE_ADVERT_GRACE, Duration::from_millis(1_000));
    }

    #[test]
    fn a_link_that_is_not_subscribed_yet_is_never_stale() {
        assert!(!is_stale_link(link(Route::Selected, None), advert(Some(Route::Selected))));
    }

    #[test]
    fn a_pairing_link_and_a_pairing_advert_are_excluded() {
        assert!(!is_stale_link(link(Route::Pairing, Some(5_000)), advert(Some(Route::Selected))));
        assert!(!is_stale_link(link(Route::Selected, Some(5_000)), advert(Some(Route::Pairing))));
        assert!(!is_stale_link(link(Route::Pairing, Some(5_000)), advert(Some(Route::Pairing))));
    }

    #[test]
    fn an_advert_of_another_uuid_is_ignored() {
        assert!(!is_stale_link(link(Route::Selected, Some(5_000)), advert(None)));
    }

    #[test]
    fn an_advert_of_another_phone_does_not_end_the_link() {
        let other = Advert { device: DeviceKey(8), route: Some(Route::Selected) };
        assert!(!is_stale_link(link(Route::Selected, Some(5_000)), other));
    }

    #[test]
    fn an_advert_seen_before_subscribed_is_not_aged_by_a_late_drain() {
        let subscribed = Instant::now();
        let seen_before = subscribed - Duration::from_millis(5);
        assert_eq!(age_at(subscribed, seen_before), Duration::ZERO);
        assert_eq!(age_at(subscribed, subscribed + Duration::from_millis(1_500)), Duration::from_millis(1_500));
    }

    #[test]
    fn rssi_followed_by_manufacturer_data_is_not_a_keyboard_advert() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, t), None);
        assert_eq!(bursts.on_quiet(), None);
        assert_eq!(bursts.quiet_at(), None);
    }

    #[test]
    fn manufacturer_data_then_rssi_at_the_same_instant_is_not_a_keyboard_advert() {
        // bluer splits one PropertiesChanged signal in HashMap order: ManufacturerData may come first.
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, t), None);
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.quiet_at(), Some(t + AdvertBursts::QUIET));
        assert_eq!(bursts.on_quiet(), None);
        assert_eq!(bursts.quiet_at(), None);
    }

    #[test]
    fn rssi_then_other_then_manufacturer_data_within_quiet_is_not_a_keyboard_advert() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.on_change(HeldChange::Other, t + Duration::from_millis(1)), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, t + Duration::from_millis(2)), None);
        assert_eq!(bursts.on_quiet(), None);
    }

    #[test]
    fn rssi_alone_is_a_keyboard_advert_stamped_at_the_rssi() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.quiet_at(), Some(t + AdvertBursts::QUIET));
        assert_eq!(bursts.on_quiet(), Some(t));
        assert_eq!(bursts.on_quiet(), None);
    }

    #[test]
    fn another_change_joins_the_burst_and_does_not_end_it() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.on_change(HeldChange::Other, t + Duration::from_millis(1)), None);
        assert_eq!(bursts.on_change(HeldChange::Other, t + Duration::from_millis(2)), None);
        assert_eq!(bursts.quiet_at(), Some(t + AdvertBursts::QUIET));
        assert_eq!(bursts.on_quiet(), Some(t));
    }

    #[test]
    fn the_advert_is_stamped_at_the_first_rssi_when_another_change_opened_the_burst() {
        let t = Instant::now();
        let rssi = t + Duration::from_millis(10);
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Other, t), None);
        assert_eq!(bursts.on_change(HeldChange::Rssi, rssi), None);
        assert_eq!(bursts.on_change(HeldChange::Rssi, rssi + Duration::from_millis(5)), None);
        assert_eq!(bursts.quiet_at(), Some(t + AdvertBursts::QUIET));
        assert_eq!(bursts.on_quiet(), Some(rssi));
    }

    #[test]
    fn a_burst_without_rssi_is_not_a_keyboard_advert() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Other, t), None);
        assert_eq!(bursts.on_quiet(), None);
    }

    #[test]
    fn two_bursts_separated_by_more_than_quiet_are_handled_independently() {
        let t = Instant::now();
        let second = t + Duration::from_millis(600);
        let mut bursts = AdvertBursts::default();
        // A keyboard advert, then the phone's Continuity advert: the late change first concludes the earlier burst.
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, second), Some(t));
        assert_eq!(bursts.on_change(HeldChange::Rssi, second), None);
        assert_eq!(bursts.quiet_at(), Some(second + AdvertBursts::QUIET));
        assert_eq!(bursts.on_quiet(), None);
        // A Continuity advert, then a keyboard advert, each concluded by its own quiet.
        let third = second + Duration::from_millis(600);
        let fourth = third + Duration::from_millis(600);
        assert_eq!(bursts.on_change(HeldChange::Rssi, third), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, third), None);
        assert_eq!(bursts.on_quiet(), None);
        assert_eq!(bursts.on_change(HeldChange::Rssi, fourth), None);
        assert_eq!(bursts.on_quiet(), Some(fourth));
    }

    #[test]
    fn a_change_exactly_quiet_after_the_first_opens_a_new_burst() {
        let t = Instant::now();
        let mut bursts = AdvertBursts::default();
        assert_eq!(bursts.on_change(HeldChange::Rssi, t), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, t + AdvertBursts::QUIET), Some(t));
        assert_eq!(bursts.on_quiet(), None);
    }

    #[test]
    fn only_a_subscribed_cccd_keeps_the_link() {
        assert!(link_alive(ProbeOutcome::Subscribed));
        assert!(!link_alive(ProbeOutcome::NotSubscribed));
        assert!(!link_alive(ProbeOutcome::AttError));
        assert!(!link_alive(ProbeOutcome::TimedOut));
        assert!(!link_alive(ProbeOutcome::Failed));
    }

    #[test]
    fn a_read_result_maps_to_an_outcome() {
        use crate::att::{AttError, ReadReply};
        let answered = |bytes: &[u8]| ProbeOutcome::of(&Ok(ReadReply::Answered(bytes.to_vec())));
        assert_eq!(answered(&[0x01, 0x00]), ProbeOutcome::Subscribed);
        assert_eq!(answered(&[0x03, 0x00]), ProbeOutcome::Subscribed, "indicate bit as well is still subscribed");
        assert_eq!(answered(&[0x01]), ProbeOutcome::Subscribed);
        assert_eq!(answered(&[0x00, 0x00]), ProbeOutcome::NotSubscribed);
        assert_eq!(answered(&[0x02, 0x00]), ProbeOutcome::NotSubscribed, "only the notify bit counts");
        assert_eq!(answered(&[]), ProbeOutcome::NotSubscribed);
        assert_eq!(ProbeOutcome::of(&Ok(ReadReply::AttError)), ProbeOutcome::AttError);
        assert_eq!(ProbeOutcome::of(&Err(AttError::Timeout)), ProbeOutcome::TimedOut);
        assert_eq!(ProbeOutcome::of(&Err(AttError::Closed)), ProbeOutcome::Failed);
        assert_eq!(ProbeOutcome::of(&Err(AttError::Io(Some(104)))), ProbeOutcome::Failed);
        assert_eq!(ProbeOutcome::of(&Err(AttError::Malformed)), ProbeOutcome::Failed);
    }

    #[test]
    fn the_confirm_constants_are_the_provisional_ones() {
        assert_eq!(STALE_CONFIRM_TIMEOUT, Duration::from_millis(1_000));
        assert_eq!(STALE_RECHECK_BACKOFF, Duration::from_secs(5));
    }

    #[test]
    fn a_link_that_answered_is_not_checked_again_for_the_backoff() {
        let t = Instant::now();
        let mut backoff = StaleBackoff::default();
        assert!(backoff.allows_check(t), "a fresh link may be checked");
        backoff.alive_at(t);
        assert!(!backoff.allows_check(t));
        assert!(!backoff.allows_check(t + STALE_RECHECK_BACKOFF - Duration::from_millis(1)));
        assert!(backoff.allows_check(t + STALE_RECHECK_BACKOFF));
    }

    #[test]
    fn the_watcher_is_restarted_once_after_the_backoff_then_given_up() {
        let t = Instant::now();
        let mut restart = WatchRestart::default();
        assert!(!restart.due(t));
        assert!(restart.stopped(t));
        assert!(!restart.due(t + WatchRestart::BACKOFF - Duration::from_millis(1)));
        assert!(restart.due(t + WatchRestart::BACKOFF));
        assert!(!restart.due(t + WatchRestart::BACKOFF));
        assert!(!restart.stopped(t + Duration::from_secs(5)));
        assert!(!restart.due(t + Duration::from_secs(10)));
    }
}
