//! The decision both backends share: is the link we hold a stale one?
//!
//! The keyboard advertises its selected UUID only while it has no subscribed central. When the keyboard is dismissed the
//! old link is not closed by the phone: this side would keep it until the supervision timeout (about 10 s) and the next
//! keyboard would wait for it. An advertisement carrying our selected UUID, seen while we think we are connected, tells us
//! the phone no longer is. The backends keep the advertisement scan running while connected and ask this function.

use crate::{DeviceKey, Route};
use std::time::Duration;

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
}
