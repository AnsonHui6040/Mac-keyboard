//! The decisions of the Linux backend that need no radio: which advertisement is ours, which controller to use, how a
//! failed connect is told apart and retried, and which devices are on hold.

use crate::att::AttError;
use crate::{DeviceKey, FailKind, Route};
use std::collections::HashMap;
use std::future::Future;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Linux errno values (the same on every architecture BlueZ runs on).
const ENOSYS: i32 = 38;
const ECONNABORTED: i32 = 103;
const ECONNRESET: i32 = 104;
const ETIMEDOUT: i32 = 110;
const EHOSTUNREACH: i32 = 113;

/// Retries in place after a connection failed before it was usable (WL1 debugging: 9 of 47 needed one).
pub const CONNECT_RETRIES: u32 = 3;

/// The key a device is known by: its Bluetooth address as a number (never logged, only its hash).
pub fn device_key(address: [u8; 6]) -> DeviceKey {
    DeviceKey(address.iter().fold(0u64, |key, byte| (key << 8) | u64::from(*byte)))
}

/// What a failed socket call means. `ENOSYS` is what BlueZ's L2CAP socket answered in the first intervals of a link
/// (WL1: 372–485 ms); `ECONNABORTED` is the controller reporting `le-connection-abort-by-local`.
pub fn fail_kind_of_errno(errno: Option<i32>) -> FailKind {
    match errno {
        Some(ENOSYS) => FailKind::Enosys,
        Some(ECONNABORTED) => FailKind::AbortByLocal,
        Some(ECONNRESET) => FailKind::LinkLost,
        Some(ETIMEDOUT) => FailKind::Timeout,
        Some(EHOSTUNREACH) => FailKind::Unreachable,
        _ => FailKind::AttError,
    }
}

pub fn fail_kind(error: &AttError) -> FailKind {
    match error {
        AttError::Timeout => FailKind::Timeout,
        AttError::Closed => FailKind::LinkLost,
        AttError::Io(errno) => fail_kind_of_errno(*errno),
        AttError::Protocol { .. } | AttError::Malformed | AttError::TooLong => FailKind::AttError,
    }
}

/// Failures of a link that was just made and died in its first intervals: worth another try at once.
pub fn is_retryable(kind: FailKind) -> bool {
    matches!(kind, FailKind::Enosys | FailKind::AbortByLocal | FailKind::LinkLost)
}

/// Runs `attempt` (given the number of failures so far) until it works, fails with something not worth retrying, or has
/// failed `max_retries + 1` times. `on_retry(n, kind)` is called before retry number `n`.
pub async fn with_retries<T, Fut>(
    max_retries: u32,
    mut attempt: impl FnMut(u32) -> Fut,
    mut on_retry: impl FnMut(u32, FailKind),
) -> Result<T, FailKind>
where
    Fut: Future<Output = Result<T, FailKind>>,
{
    let mut failures = 0;
    loop {
        match attempt(failures).await {
            Ok(done) => return Ok(done),
            Err(kind) if failures < max_retries && is_retryable(kind) => {
                failures += 1;
                on_retry(failures, kind);
            }
            Err(kind) => return Err(kind),
        }
    }
}

/// Which advertised route a device offers, if any: the selected UUID wins over the pairing UUID, which counts only while
/// the pairing window is open.
pub fn match_route(advertised: &[Uuid], select: Uuid, pairing: Uuid, pairing_on: bool) -> Option<Route> {
    if advertised.contains(&select) {
        Some(Route::Selected)
    } else if pairing_on && advertised.contains(&pairing) {
        Some(Route::Pairing)
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdapterChoice {
    /// The controller that was asked for is not there. Nothing else is used instead.
    Missing,
    /// The system has no controller.
    None,
}

/// The controller to use. A configured name is used or reported missing, never replaced (the machine has another
/// controller that must stay untouched); without one BlueZ's default applies: `hci0`, else the first by name.
pub fn choose_adapter(names: &[String], wanted: Option<&str>) -> Result<String, AdapterChoice> {
    match wanted {
        Some(name) if names.iter().any(|n| n == name) => Ok(name.to_string()),
        Some(_) => Err(AdapterChoice::Missing),
        None if names.iter().any(|n| n == "hci0") => Ok("hci0".to_string()),
        None => names.iter().min().cloned().ok_or(AdapterChoice::None),
    }
}

/// The number of `hci1`: all a log line may say about which controller is used (a name would be free text).
pub fn hci_index(name: &str) -> Option<u64> {
    let digits = name.strip_prefix("hci")?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// Devices the application asked not to connect to for a while.
#[derive(Debug, Default)]
pub struct Holds {
    until: HashMap<u64, Instant>,
}

impl Holds {
    pub fn hold(&mut self, device: DeviceKey, for_: Duration, now: Instant) {
        self.until.insert(device.0, now + for_);
    }

    pub fn is_held(&self, device: DeviceKey, now: Instant) -> bool {
        self.until.get(&device.0).is_some_and(|until| *until > now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SELECT: Uuid = Uuid::from_u128(1);
    const PAIRING: Uuid = Uuid::from_u128(2);

    #[test]
    fn enosys_and_abort_by_local_are_told_apart_from_the_rest() {
        assert_eq!(fail_kind_of_errno(Some(38)), FailKind::Enosys);
        assert_eq!(fail_kind_of_errno(Some(103)), FailKind::AbortByLocal);
        assert_eq!(fail_kind_of_errno(Some(104)), FailKind::LinkLost);
        assert_eq!(fail_kind_of_errno(Some(110)), FailKind::Timeout);
        assert_eq!(fail_kind_of_errno(Some(113)), FailKind::Unreachable);
        assert_eq!(fail_kind_of_errno(Some(1)), FailKind::AttError);
        assert_eq!(fail_kind_of_errno(None), FailKind::AttError);
    }

    #[test]
    fn att_errors_map_to_failure_kinds() {
        assert_eq!(fail_kind(&AttError::Timeout), FailKind::Timeout);
        assert_eq!(fail_kind(&AttError::Closed), FailKind::LinkLost);
        assert_eq!(fail_kind(&AttError::Io(Some(38))), FailKind::Enosys);
        assert_eq!(fail_kind(&AttError::Protocol { request: 8, code: 10 }), FailKind::AttError);
        assert_eq!(fail_kind(&AttError::Malformed), FailKind::AttError);
        assert_eq!(fail_kind(&AttError::TooLong), FailKind::AttError);
    }

    #[test]
    fn only_a_link_that_died_at_once_is_retried() {
        for kind in [FailKind::Enosys, FailKind::AbortByLocal, FailKind::LinkLost] {
            assert!(is_retryable(kind), "{kind:?}");
        }
        for kind in [FailKind::Timeout, FailKind::AttError, FailKind::Unreachable, FailKind::NotSelected] {
            assert!(!is_retryable(kind), "{kind:?}");
        }
    }

    #[tokio::test]
    async fn enosys_retries_three_times() {
        let mut results = vec![Err(FailKind::Enosys), Err(FailKind::Enosys), Err(FailKind::AbortByLocal), Ok(7)].into_iter();
        let mut calls = Vec::new();
        let mut retries = Vec::new();
        let outcome = with_retries(
            CONNECT_RETRIES,
            |failures| {
                calls.push(failures);
                std::future::ready(results.next().unwrap())
            },
            |n, kind| retries.push((n, kind)),
        )
        .await;
        assert_eq!(outcome, Ok(7));
        assert_eq!(calls, vec![0, 1, 2, 3]);
        assert_eq!(retries, vec![(1, FailKind::Enosys), (2, FailKind::Enosys), (3, FailKind::AbortByLocal)]);
    }

    #[tokio::test]
    async fn the_fourth_failure_is_final() {
        let mut calls = 0;
        let outcome: Result<(), _> = with_retries(
            CONNECT_RETRIES,
            |_| {
                calls += 1;
                std::future::ready(Err(FailKind::Enosys))
            },
            |_, _| {},
        )
        .await;
        assert_eq!(outcome, Err(FailKind::Enosys));
        assert_eq!(calls, 4);
    }

    #[tokio::test]
    async fn a_failure_that_will_not_get_better_is_not_retried() {
        let mut calls = 0;
        let outcome: Result<(), _> = with_retries(
            CONNECT_RETRIES,
            |_| {
                calls += 1;
                std::future::ready(Err(FailKind::Timeout))
            },
            |_, _| panic!("no retry expected"),
        )
        .await;
        assert_eq!(outcome, Err(FailKind::Timeout));
        assert_eq!(calls, 1);
    }

    #[test]
    fn the_selected_uuid_wins_and_pairing_needs_an_open_window() {
        let other = Uuid::from_u128(3);
        assert_eq!(match_route(&[other, SELECT], SELECT, PAIRING, false), Some(Route::Selected));
        assert_eq!(match_route(&[PAIRING, SELECT], SELECT, PAIRING, true), Some(Route::Selected));
        assert_eq!(match_route(&[PAIRING], SELECT, PAIRING, true), Some(Route::Pairing));
        assert_eq!(match_route(&[PAIRING], SELECT, PAIRING, false), None);
        assert_eq!(match_route(&[other], SELECT, PAIRING, true), None);
        assert_eq!(match_route(&[], SELECT, PAIRING, true), None);
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn a_configured_controller_is_used_or_missing_never_replaced() {
        assert_eq!(choose_adapter(&names(&["hci0", "hci1"]), Some("hci1")), Ok("hci1".into()));
        assert_eq!(choose_adapter(&names(&["hci0"]), Some("hci1")), Err(AdapterChoice::Missing));
        assert_eq!(choose_adapter(&[], Some("hci1")), Err(AdapterChoice::Missing));
    }

    #[test]
    fn without_a_choice_the_bluez_default_applies() {
        assert_eq!(choose_adapter(&names(&["hci1", "hci0"]), None), Ok("hci0".into()));
        assert_eq!(choose_adapter(&names(&["hci2", "hci1"]), None), Ok("hci1".into()));
        assert_eq!(choose_adapter(&[], None), Err(AdapterChoice::None));
    }

    #[test]
    fn a_hold_runs_out_and_belongs_to_one_device() {
        let now = Instant::now();
        let mut holds = Holds::default();
        holds.hold(DeviceKey(1), Duration::from_secs(10), now);
        assert!(holds.is_held(DeviceKey(1), now + Duration::from_secs(9)));
        assert!(!holds.is_held(DeviceKey(1), now + Duration::from_secs(10)));
        assert!(!holds.is_held(DeviceKey(2), now));
    }

    #[test]
    fn a_later_hold_replaces_an_earlier_one() {
        let now = Instant::now();
        let mut holds = Holds::default();
        holds.hold(DeviceKey(1), Duration::from_secs(60), now);
        holds.hold(DeviceKey(1), Duration::from_secs(10), now);
        assert!(!holds.is_held(DeviceKey(1), now + Duration::from_secs(11)));
    }

    #[test]
    fn the_controller_is_logged_as_its_number() {
        assert_eq!(hci_index("hci1"), Some(1));
        assert_eq!(hci_index("hci12"), Some(12));
        assert_eq!(hci_index("hci"), None);
        assert_eq!(hci_index("usb0"), None);
        assert_eq!(hci_index("hci1x"), None);
    }

    #[test]
    fn a_device_key_is_the_address_as_a_number() {
        assert_eq!(device_key([0, 0, 0, 0, 1, 2]), DeviceKey(0x0102));
        assert_eq!(device_key([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]), DeviceKey(0xAABB_CCDD_EEFF));
    }
}
