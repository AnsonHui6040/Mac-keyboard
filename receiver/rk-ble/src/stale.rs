//! The decision both backends share: is the link we hold a stale one?
//!
//! The keyboard advertises its selected UUID only while it has no subscribed central. When the keyboard is dismissed the
//! old link is not closed by the phone: this side would keep it until the supervision timeout (about 10 s) and the next
//! keyboard would wait for it. An advertisement carrying our selected UUID, seen while we think we are connected, tells us
//! the phone no longer is. The backends keep the advertisement scan running while connected and ask this function.

use crate::{DeviceKey, Route};
use std::time::{Duration, Instant};

/// The advertisement has to be seen this long after the link reached `subscribed` to count (Provisional): the phone may
/// still send the last adverts of its previous round for a moment after it has been connected to.
pub const STALE_ADVERT_GRACE: Duration = Duration::from_millis(1000);

/// The link that is open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeldLink {
    pub route: Route,
    pub device: DeviceKey,
    /// How long ago the link was subscribed; `None` while it is not yet.
    pub subscribed_for: Option<Duration>,
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
/// What does arrive for every advertisement is an `RSSI` change, directly followed (same D-Bus signal) by a
/// `ManufacturerData` change when the advertisement carries manufacturer data. The keyboard's own advertisement carries
/// only UUIDs and a name; the phone's other advertisements (Apple's, from the same address) carry manufacturer data.
/// So an `RSSI` change NOT followed by `ManufacturerData` is counted as one advertisement of the keyboard, stamped with
/// the time of the `RSSI` change.
#[derive(Debug, Default)]
pub struct AdvertBursts {
    pending: Option<Instant>,
}

impl AdvertBursts {
    /// How long after an `RSSI` change its `ManufacturerData` may still come (measured: under 30 µs, same signal).
    pub const QUIET: Duration = Duration::from_millis(50);

    /// Feeds one change; returns the time of a keyboard advertisement this concludes.
    pub fn on_change(&mut self, change: HeldChange, now: Instant) -> Option<Instant> {
        match change {
            HeldChange::Rssi => self.pending.replace(now),
            HeldChange::ManufacturerData => {
                self.pending = None;
                None
            }
            HeldChange::Other => self.pending.take(),
        }
    }

    /// `QUIET` has passed since the last change; returns the time of a keyboard advertisement this concludes.
    pub fn on_quiet(&mut self) -> Option<Instant> {
        self.pending.take()
    }

    /// When `on_quiet` is due, if anything is pending.
    pub fn quiet_at(&self) -> Option<Instant> {
        self.pending.map(|at| at + Self::QUIET)
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
        assert_eq!(bursts.quiet_at(), None);
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
    fn a_second_rssi_or_another_change_concludes_the_pending_one() {
        let t = Instant::now();
        let later = t + Duration::from_millis(600);
        let mut bursts = AdvertBursts::default();
        bursts.on_change(HeldChange::Rssi, t);
        assert_eq!(bursts.on_change(HeldChange::Rssi, later), Some(t));
        assert_eq!(bursts.on_change(HeldChange::Other, later), Some(later));
        assert_eq!(bursts.on_change(HeldChange::Other, later), None);
        assert_eq!(bursts.on_change(HeldChange::ManufacturerData, later), None);
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
