//! Is the controller still hearing anything? The decision to power-cycle a Bluetooth adapter that has gone deaf or keeps
//! failing connections, as a plain value fed with events and the time. It touches no radio and reads no clock, so every rule
//! is tested on the host. The Linux backend (`linux.rs`) feeds it and carries out the power cycle.
//!
//! All numbers are Provisional (design doc, Linux scanning section).

use crate::diag::{Diag, FailKind, Value};
use std::collections::HashSet;
use std::hash::Hash;
use std::time::{Duration, Instant};

/// No advertisement from any device for this long while scanning, with no link: the controller is deaf.
pub const DEAF_AFTER: Duration = Duration::from_secs(60);
/// This many connection attempts in a row that fail at the radio level: the controller is degraded.
pub const DEGRADED_AFTER: u32 = 3;
/// The shortest time between two power cycles.
pub const MIN_GAP: Duration = Duration::from_secs(120);
/// The gap doubles while cycles do not help, up to this.
pub const MAX_GAP: Duration = Duration::from_secs(30 * 60);
/// After a power cycle that could not be carried out, nothing is tried for this long.
pub const FAILED_PAUSE: Duration = Duration::from_secs(30 * 60);

/// Why the adapter is to be power-cycled (the `reason=` field of the log).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetReason {
    NoAdverts,
    ConnectFailures,
}

impl ResetReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NoAdverts => "no_adverts",
            Self::ConnectFailures => "connect_failures",
        }
    }
}

/// Whether a failed connection attempt says something about the controller. The phone's refusals and its app's version say
/// nothing: the radio did its part.
pub fn counts_against_adapter(kind: FailKind) -> bool {
    match kind {
        FailKind::Unreachable | FailKind::Enosys | FailKind::AbortByLocal | FailKind::AttError | FailKind::Timeout => true,
        FailKind::NotSelected | FailKind::AuthFailed | FailKind::UnsupportedVersion | FailKind::PeerBye | FailKind::LinkLost => false,
    }
}

#[derive(Debug)]
pub struct AdapterHealth {
    receiving: bool,
    linked: bool,
    /// Where the current silence is counted from.
    quiet_since: Instant,
    failures: u32,
    last_cycle: Option<Instant>,
    /// The wait that must have passed since `last_cycle` before the next one.
    gap: Duration,
    /// An advertisement or a link has been seen since the last cycle.
    healthy_since_cycle: bool,
    paused_until: Option<Instant>,
}

impl AdapterHealth {
    pub fn new(now: Instant) -> Self {
        Self { receiving: true, linked: false, quiet_since: now, failures: 0, last_cycle: None, gap: MIN_GAP, healthy_since_cycle: false, paused_until: None }
    }

    /// The application's receive switch changed. Nothing is judged while it is off, and what came before is forgotten when
    /// it goes on.
    pub fn receiving(&mut self, on: bool, now: Instant) {
        if on && !self.receiving {
            self.quiet_since = now;
            self.failures = 0;
        }
        self.receiving = on;
    }

    /// An advertisement from any device (not one BlueZ merely still had cached).
    pub fn advert(&mut self, now: Instant) {
        self.quiet_since = now;
        self.healthy();
    }

    pub fn link_up(&mut self, now: Instant) {
        self.linked = true;
        self.failures = 0;
        self.quiet_since = now;
        self.healthy();
    }

    pub fn link_down(&mut self, now: Instant) {
        self.linked = false;
        self.quiet_since = now;
    }

    /// A connection attempt failed before the link was ready (not one cancelled by the receive switch: that one is not
    /// reported here at all).
    pub fn connect_failed(&mut self, kind: FailKind) {
        if counts_against_adapter(kind) {
            self.failures = self.failures.saturating_add(1);
        } else {
            self.failures = 0;
        }
    }

    /// The scan could not run (radio off, no controller, session broken): not a deaf controller, the silence starts over.
    pub fn scan_failed(&mut self, now: Instant) {
        self.quiet_since = now;
    }

    /// What to do now, if anything.
    pub fn check(&self, now: Instant) -> Option<ResetReason> {
        if !self.receiving || self.linked {
            return None;
        }
        if self.paused_until.is_some_and(|until| now < until) {
            return None;
        }
        if self.last_cycle.is_some_and(|at| now.saturating_duration_since(at) < self.gap) {
            return None;
        }
        if self.failures >= DEGRADED_AFTER {
            return Some(ResetReason::ConnectFailures);
        }
        if now.saturating_duration_since(self.quiet_since) >= DEAF_AFTER {
            return Some(ResetReason::NoAdverts);
        }
        None
    }

    /// The adapter was power-cycled.
    pub fn cycled(&mut self, now: Instant) {
        self.gap = if self.last_cycle.is_some() && !self.healthy_since_cycle { self.gap.saturating_mul(2).min(MAX_GAP) } else { MIN_GAP };
        self.last_cycle = Some(now);
        self.healthy_since_cycle = false;
        self.quiet_since = now;
        self.failures = 0;
    }

    /// The power cycle could not be carried out.
    pub fn cycle_failed(&mut self, now: Instant) {
        self.paused_until = Some(now + FAILED_PAUSE);
    }

    /// The adapter was found powered off by someone else: not ours to switch on. Judging starts over.
    pub fn cycle_not_ours(&mut self, now: Instant) {
        self.quiet_since = now;
        self.failures = 0;
    }

    fn healthy(&mut self) {
        self.healthy_since_cycle = true;
        self.gap = MIN_GAP;
    }
}

/// Why a power cycle could not be carried out (the `kind=` field of `adapter_reset_failed`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetFailure {
    /// No session, no such controller, or BlueZ does not answer.
    Unavailable,
    PowerOff,
    PowerOn,
    Timeout,
}

impl ResetFailure {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => "unavailable",
            Self::PowerOff => "power_off",
            Self::PowerOn => "power_on",
            Self::Timeout => "timeout",
        }
    }
}

/// `adapter_reset reason=... hci=<n>`: the controller is about to be power-cycled.
pub fn reset_diag(reason: ResetReason, hci: Option<u64>) -> Diag {
    let diag = Diag::new(0, "adapter_reset").with("reason", Value::S(reason.as_str()));
    match hci {
        Some(index) => diag.with("hci", Value::U(index)),
        None => diag,
    }
}

/// `adapter_reset_failed kind=...`.
pub fn reset_failed_diag(failure: ResetFailure) -> Diag {
    Diag::new(0, "adapter_reset_failed").with("kind", Value::S(failure.as_str()))
}

/// The devices BlueZ still lists when a discovery starts (those it keeps across the purge: paired and connected ones).
/// BlueZ reports them again as "added" at the start of every discovery; only a device not among them was heard just now.
#[derive(Debug)]
pub struct KnownDevices<T> {
    known: HashSet<T>,
}

impl<T: Eq + Hash> KnownDevices<T> {
    pub fn new(known: impl IntoIterator<Item = T>) -> Self {
        Self { known: known.into_iter().collect() }
    }

    pub fn is_advert(&self, device: &T) -> bool {
        !self.known.contains(device)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn start() -> (AdapterHealth, Instant) {
        let t0 = Instant::now();
        (AdapterHealth::new(t0), t0)
    }

    #[test]
    fn silence_for_sixty_seconds_while_scanning_is_deaf() {
        let (health, t0) = start();
        assert_eq!(health.check(t0 + secs(59)), None);
        assert_eq!(health.check(t0 + secs(60)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn adverts_from_any_device_keep_it_alive() {
        let (mut health, t0) = start();
        health.advert(t0 + secs(50));
        assert_eq!(health.check(t0 + secs(109)), None);
        assert_eq!(health.check(t0 + secs(110)), Some(ResetReason::NoAdverts));
        health.advert(t0 + secs(100));
        assert_eq!(health.check(t0 + secs(110)), None);
    }

    #[test]
    fn nothing_is_judged_while_a_link_is_up_and_the_silence_counts_from_its_end() {
        let (mut health, t0) = start();
        health.link_up(t0 + secs(5));
        assert_eq!(health.check(t0 + secs(3600)), None);
        health.link_down(t0 + secs(3600));
        assert_eq!(health.check(t0 + secs(3659)), None, "a link that lasted an hour is not an hour of silence");
        assert_eq!(health.check(t0 + secs(3660)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn nothing_is_judged_while_receiving_is_off_and_the_silence_starts_over_when_it_is_on_again() {
        let (mut health, t0) = start();
        health.receiving(false, t0 + secs(10));
        assert_eq!(health.check(t0 + secs(7200)), None);
        health.receiving(true, t0 + secs(7200));
        assert_eq!(health.check(t0 + secs(7259)), None);
        assert_eq!(health.check(t0 + secs(7260)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn switching_receiving_on_while_it_is_already_on_changes_nothing() {
        let (mut health, t0) = start();
        health.receiving(true, t0 + secs(50));
        assert_eq!(health.check(t0 + secs(60)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn three_failed_attempts_in_a_row_are_degraded_at_once() {
        let (mut health, t0) = start();
        health.advert(t0);
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::AttError);
        assert_eq!(health.check(t0 + secs(1)), None);
        health.connect_failed(FailKind::Timeout);
        assert_eq!(health.check(t0 + secs(1)), Some(ResetReason::ConnectFailures));
    }

    #[test]
    fn a_success_in_between_resets_the_count() {
        let (mut health, t0) = start();
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::Timeout);
        health.link_up(t0 + secs(1));
        health.link_down(t0 + secs(2));
        health.connect_failed(FailKind::Timeout);
        assert_eq!(health.check(t0 + secs(3)), None);
    }

    #[test]
    fn refusals_by_the_phone_are_not_counted_and_end_the_streak() {
        let (mut health, t0) = start();
        for kind in [FailKind::NotSelected, FailKind::AuthFailed, FailKind::UnsupportedVersion] {
            health.connect_failed(kind);
            health.connect_failed(kind);
            health.connect_failed(kind);
            assert_eq!(health.check(t0), None, "{kind:?} says nothing about the controller");
        }
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::AuthFailed);
        health.connect_failed(FailKind::Timeout);
        assert_eq!(health.check(t0), None, "the refusal reached the phone: the streak starts over");
    }

    #[test]
    fn every_radio_level_failure_counts() {
        for kind in [FailKind::Unreachable, FailKind::Enosys, FailKind::AbortByLocal, FailKind::AttError, FailKind::Timeout] {
            assert!(counts_against_adapter(kind), "{kind:?}");
        }
    }

    #[test]
    fn failures_are_never_judged_while_a_link_is_up_or_receiving_is_off() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        health.receiving(false, t0);
        assert_eq!(health.check(t0), None);
        health.receiving(true, t0);
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        health.link_up(t0 + secs(1));
        assert_eq!(health.check(t0 + secs(2)), None);
    }

    #[test]
    fn a_failed_scan_is_not_a_deaf_controller() {
        let (mut health, t0) = start();
        health.scan_failed(t0 + secs(50));
        assert_eq!(health.check(t0 + secs(100)), None);
        assert_eq!(health.check(t0 + secs(110)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn after_a_cycle_the_next_needs_both_the_gap_and_a_new_silence() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(60));
        assert_eq!(health.check(t0 + secs(119)), None);
        assert_eq!(health.check(t0 + secs(179)), None, "sixty seconds of new silence, but the gap is 120 s");
        assert_eq!(health.check(t0 + secs(180)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn a_cycle_clears_the_failure_count() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        health.cycled(t0);
        health.advert(t0 + secs(150));
        assert_eq!(health.check(t0 + secs(150)), None);
    }

    #[test]
    fn the_gap_doubles_while_cycles_are_not_followed_by_a_healthy_sign_up_to_thirty_minutes() {
        let (mut health, t0) = start();
        let mut now = t0 + secs(60);
        let mut waits = Vec::new();
        for _ in 0..8 {
            health.cycled(now);
            // How long until `check` fires again, probing by the second.
            let mut wait = 0;
            while health.check(now + secs(wait)).is_none() {
                wait += 1;
                assert!(wait < 4000);
            }
            waits.push(wait);
            now += secs(wait);
        }
        assert_eq!(waits, vec![120, 240, 480, 960, 1800, 1800, 1800, 1800]);
    }

    #[test]
    fn a_healthy_sign_resets_the_backoff() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(60));
        health.cycled(t0 + secs(180));
        health.cycled(t0 + secs(420));
        health.advert(t0 + secs(430));
        health.cycled(t0 + secs(2000));
        assert_eq!(health.check(t0 + secs(2000 + 119)), None);
        assert_eq!(health.check(t0 + secs(2000 + 120)), Some(ResetReason::NoAdverts), "back to 120 s, not 960 s");
    }

    #[test]
    fn a_link_is_a_healthy_sign_too() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(60));
        health.cycled(t0 + secs(180));
        health.link_up(t0 + secs(190));
        health.link_down(t0 + secs(200));
        health.cycled(t0 + secs(400));
        assert_eq!(health.check(t0 + secs(400 + 120)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn a_cycle_that_could_not_be_carried_out_pauses_everything_for_thirty_minutes() {
        let (mut health, t0) = start();
        assert_eq!(health.check(t0 + secs(60)), Some(ResetReason::NoAdverts));
        health.cycle_failed(t0 + secs(60));
        assert_eq!(health.check(t0 + secs(60 + 1799)), None);
        assert_eq!(health.check(t0 + secs(60 + 1800)), Some(ResetReason::NoAdverts), "the silence is still there afterwards");
    }

    #[test]
    fn an_adapter_someone_else_switched_off_is_left_alone_and_judging_starts_over() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        health.cycle_not_ours(t0 + secs(5));
        assert_eq!(health.check(t0 + secs(64)), None);
        assert_eq!(health.check(t0 + secs(65)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn only_a_device_not_already_known_after_the_purge_is_an_advert() {
        let known = KnownDevices::new([1u8, 2]);
        assert!(!known.is_advert(&1), "BlueZ lists paired and connected devices at the start of every discovery");
        assert!(known.is_advert(&3));
        assert!(KnownDevices::<u8>::new([]).is_advert(&1));
    }

    #[test]
    fn the_reset_events_carry_only_fixed_words_and_the_controller_number() {
        let diag = reset_diag(ResetReason::NoAdverts, Some(1));
        assert_eq!((diag.ev, diag.conn, diag.debug), ("adapter_reset", 0, false));
        assert_eq!(diag.fields, vec![("reason", Value::S("no_adverts")), ("hci", Value::U(1))]);
        assert_eq!(reset_diag(ResetReason::ConnectFailures, None).fields, vec![("reason", Value::S("connect_failures"))]);
        let failed = reset_failed_diag(ResetFailure::PowerOn);
        assert_eq!((failed.ev, failed.debug), ("adapter_reset_failed", false));
        assert_eq!(failed.fields, vec![("kind", Value::S("power_on"))]);
        let words: Vec<_> = [ResetFailure::Unavailable, ResetFailure::PowerOff, ResetFailure::PowerOn, ResetFailure::Timeout].iter().map(|f| f.as_str()).collect();
        assert_eq!(words, ["unavailable", "power_off", "power_on", "timeout"]);
    }

    #[test]
    fn the_log_words_are_fixed() {
        assert_eq!(ResetReason::NoAdverts.as_str(), "no_adverts");
        assert_eq!(ResetReason::ConnectFailures.as_str(), "connect_failures");
    }
}
