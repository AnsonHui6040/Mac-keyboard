//! Is the controller still hearing anything? The decision to power-cycle a Bluetooth adapter that has gone deaf or keeps
//! failing connections, as a plain value fed with events and the time. It touches no radio and reads no clock, so every rule
//! is tested on the host. The Linux backend (`linux.rs`) feeds it and supplies the controller ([`PowerControl`]); the steps
//! of the power cycle itself ([`power_cycle`], [`restore_power`]) are here too, so that their failure paths are tested
//! against a fake.
//!
//! All numbers are Provisional (design doc, Linux scanning section).

use crate::diag::{Diag, FailKind, Value};
use std::collections::HashSet;
use std::hash::Hash;
use std::time::{Duration, Instant};
use tokio::time::{sleep, timeout};

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
/// A controller we switched off and could not switch on again: the first retry waits this long, then it doubles...
pub const POWER_ON_RETRY_FIRST: Duration = Duration::from_secs(1);
/// ... up to this. It is retried for as long as it takes; the half-hour pause does not apply to it.
pub const POWER_ON_RETRY_MAX: Duration = Duration::from_secs(30);

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

/// Whether a failed connection attempt says something about the controller. Only a failure at the radio level does:
/// - `Unreachable`, `Enosys`, `AbortByLocal`, `Timeout`: the link never came up, or the controller itself dropped it.
///
/// Anything the phone answered over the air does not (the radio did its part), and it also ends a streak of failures:
/// - `AttError`: the phone's GATT server replied with an error, typically while the phone is closing its keyboard and the
///   service is momentarily gone (three of them within 90 ms must not power-cycle the adapter).
/// - `NotSelected`, `AuthFailed`, `UnsupportedVersion`: the phone refused, or its app is the wrong version.
/// - `PeerBye`: the phone ended the session itself.
/// - `LinkLost`: the link had come up and carried traffic before it dropped, so the controller was working.
pub fn counts_against_adapter(kind: FailKind) -> bool {
    match kind {
        FailKind::Unreachable | FailKind::Enosys | FailKind::AbortByLocal | FailKind::Timeout => true,
        FailKind::AttError | FailKind::NotSelected | FailKind::AuthFailed | FailKind::UnsupportedVersion | FailKind::PeerBye | FailKind::LinkLost => false,
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
    /// Why the last cycle (or skipped attempt) happened.
    last_reason: Option<ResetReason>,
    /// A scan is running: only then does time without an advertisement mean a deaf controller.
    scanning: bool,
    /// We switched the controller off and it is not on yet.
    power_on: Option<PowerOn>,
}

/// The state of a controller that we switched off and have to switch on again.
#[derive(Debug)]
struct PowerOn {
    retry_at: Instant,
    failures: u32,
}

impl AdapterHealth {
    pub fn new(now: Instant) -> Self {
        Self { receiving: true, linked: false, quiet_since: now, failures: 0, last_cycle: None, gap: MIN_GAP, healthy_since_cycle: false, paused_until: None, last_reason: None, scanning: false, power_on: None }
    }

    /// A scan starts: the silence is counted from here.
    pub fn scan_started(&mut self, now: Instant) {
        self.scanning = true;
        self.quiet_since = now;
    }

    /// The scan ended (a device was found, receiving was switched off, it failed): time passing now is not silence.
    pub fn scan_stopped(&mut self) {
        self.scanning = false;
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
        // Other devices advertising say nothing about a phone that keeps failing: only a link heals those cycles.
        if self.last_reason != Some(ResetReason::ConnectFailures) {
            self.healthy();
        }
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
        if !self.receiving || self.linked || self.power_on.is_some() {
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
        if self.scanning && now.saturating_duration_since(self.quiet_since) >= DEAF_AFTER {
            return Some(ResetReason::NoAdverts);
        }
        None
    }

    /// What a health tick does: an owed power-on that is due comes before everything (while it is owed [`check`](Self::check)
    /// judges nothing, so a scan would otherwise run deaf-blind until it ends), then the plain check.
    pub fn tick(&self, now: Instant) -> Tick {
        if self.power_on_due(now) {
            return Tick::RestorePower;
        }
        match self.check(now) {
            Some(reason) => Tick::Cycle(reason),
            None => Tick::Idle,
        }
    }

    /// The adapter was power-cycled.
    pub fn cycled(&mut self, now: Instant, reason: ResetReason) {
        self.last_reason = Some(reason);
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

    /// A cycle was skipped because the controller is in use by something else: it counts as an attempt for the gap.
    pub fn cycle_skipped(&mut self, now: Instant, reason: ResetReason) {
        self.cycled(now, reason);
    }

    /// Whether we switched the controller off and have not yet got it back on.
    pub fn power_on_owed(&self) -> bool {
        self.power_on.is_some()
    }

    /// Whether the next attempt to switch the controller back on is due.
    pub fn power_on_due(&self, now: Instant) -> bool {
        self.power_on.as_ref().is_some_and(|owed| now >= owed.retry_at)
    }

    /// We asked for the controller to go off, and could not switch it on again.
    pub fn we_switched_off(&mut self, now: Instant) {
        self.power_on = Some(PowerOn { retry_at: now, failures: 0 });
    }

    /// An attempt to switch the controller back on failed.
    pub fn power_on_failed(&mut self, now: Instant) {
        if let Some(owed) = &mut self.power_on {
            let wait = POWER_ON_RETRY_FIRST.saturating_mul(1u32.checked_shl(owed.failures).unwrap_or(u32::MAX)).min(POWER_ON_RETRY_MAX);
            owed.failures = owed.failures.saturating_add(1);
            owed.retry_at = now + wait;
        }
    }

    /// The controller is on again: judging starts over, and the gap since the cycle holds.
    pub fn power_on_restored(&mut self, now: Instant) {
        self.power_on = None;
        self.last_cycle = Some(now);
        self.healthy_since_cycle = false;
        self.quiet_since = now;
        self.failures = 0;
    }

    fn healthy(&mut self) {
        self.healthy_since_cycle = true;
        self.gap = MIN_GAP;
    }
}

/// What one health tick decides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tick {
    Idle,
    /// A controller we switched off is to be switched on now.
    RestorePower,
    Cycle(ResetReason),
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

/// A D-Bus call of a power cycle failed (as opposed to taking too long).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PowerFault;

/// What a power cycle needs from the controller. The Linux backend implements it with BlueZ; tests with a fake.
#[allow(async_fn_in_trait)]
pub trait PowerControl {
    async fn is_powered(&self) -> Result<bool, PowerFault>;
    async fn set_powered(&self, on: bool) -> Result<(), PowerFault>;
    /// Whether a device that is not one of our phones is connected on this controller.
    async fn other_connection(&self) -> Result<bool, PowerFault>;
}

/// How long each step of a power cycle may take.
#[derive(Debug, Clone, Copy)]
pub struct CycleTiming {
    /// One read (`Powered`, the connected devices).
    pub read: Duration,
    pub off: Duration,
    /// How long the controller stays off.
    pub off_for: Duration,
    /// One attempt to switch it on; there are two.
    pub on: Duration,
}

impl CycleTiming {
    pub const PRODUCTION: Self = Self { read: Duration::from_millis(1500), off: Duration::from_secs(2), off_for: Duration::from_millis(500), on: Duration::from_secs(3) };

    /// The longest a cycle can take: two reads, the off call, the wait, two on attempts.
    pub fn worst_case(&self) -> Duration {
        self.read * 2 + self.off + self.off_for + self.on * 2
    }
}

/// The whole cycle is over after this at the latest.
pub const CYCLE_CAP: Duration = Duration::from_secs(12);

/// Why a cycle was not started.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Skip {
    /// Someone else switched the controller off.
    Off,
    /// A device that is not one of ours is connected through this controller.
    Busy,
}

/// What a power cycle or a restore did, as the log wants it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Report {
    /// The controller is about to be switched off.
    Started,
    Cycled,
    Skipped(Skip),
    Failed(ResetFailure),
    /// A controller we had switched off is on again.
    Restored,
}

/// Whether a device with these `UUIDs` is one of our phones.
pub fn is_our_phone(uuids: &HashSet<uuid::Uuid>, select: uuid::Uuid, pairing: uuid::Uuid) -> bool {
    uuids.contains(&select) || uuids.contains(&pairing)
}

fn failure_of<T>(result: Result<Result<T, PowerFault>, tokio::time::error::Elapsed>) -> Result<T, ResetFailure> {
    match result {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(PowerFault)) => Err(ResetFailure::Unavailable),
        Err(_) => Err(ResetFailure::Timeout),
    }
}

/// The power cycle: check, switch off, wait, switch on.
///
/// - A controller that is off, or that something other than our phones is connected to, is not touched.
/// - A controller that cannot be read is not touched either, and nothing is paused: the next tick tries again.
/// - Once the off call has been made (even one that timed out: BlueZ may have done it) the controller is switched on, twice
///   if need be, whatever the off call said. If it cannot be switched on, we owe it: [`AdapterHealth::power_on_owed`], to
///   be settled by [`restore_power`], with no new cycle in between and never taken for someone else's choice.
/// - Every step has its own limit ([`CycleTiming`]), so the whole takes [`CycleTiming::worst_case`] at the most.
pub async fn power_cycle<P: PowerControl>(health: &mut AdapterHealth, power: &P, reason: ResetReason, timing: CycleTiming, mut report: impl FnMut(Report)) {
    if health.power_on_owed() {
        return restore_power(health, power, timing, report).await;
    }
    match failure_of(timeout(timing.read, power.is_powered()).await) {
        Err(failure) => return report(Report::Failed(failure)),
        // Off by someone's choice: not ours to switch on.
        Ok(false) => {
            health.cycle_not_ours(Instant::now());
            return report(Report::Skipped(Skip::Off));
        }
        Ok(true) => {}
    }
    match failure_of(timeout(timing.read, power.other_connection()).await) {
        Err(failure) => return report(Report::Failed(failure)),
        Ok(true) => {
            health.cycle_skipped(Instant::now(), reason);
            return report(Report::Skipped(Skip::Busy));
        }
        Ok(false) => {}
    }
    report(Report::Started);
    let off_failure = match failure_of(timeout(timing.off, power.set_powered(false)).await) {
        Ok(()) => None,
        Err(ResetFailure::Timeout) => Some(ResetFailure::Timeout),
        Err(_) => Some(ResetFailure::PowerOff),
    };
    if off_failure.is_none() {
        sleep(timing.off_for).await;
    }
    let mut on_failure = None;
    for _ in 0..2 {
        match failure_of(timeout(timing.on, power.set_powered(true)).await) {
            Ok(()) => {
                on_failure = None;
                break;
            }
            Err(ResetFailure::Timeout) => on_failure = Some(ResetFailure::Timeout),
            Err(_) => on_failure = Some(ResetFailure::PowerOn),
        }
    }
    let now = Instant::now();
    match (off_failure, on_failure) {
        (None, None) => {
            health.cycled(now, reason);
            report(Report::Cycled);
        }
        // The controller is on, but the cycle did not happen: nothing more for a while.
        (Some(failure), None) => {
            health.cycle_failed(now);
            report(Report::Failed(failure));
        }
        (_, Some(failure)) => {
            health.we_switched_off(now);
            report(Report::Failed(failure));
        }
    }
}

/// Switches a controller we switched off back on. Nothing happens when nothing is owed.
pub async fn restore_power<P: PowerControl>(health: &mut AdapterHealth, power: &P, timing: CycleTiming, mut report: impl FnMut(Report)) {
    if !health.power_on_owed() {
        return;
    }
    // Setting `Powered` on a controller that is on is harmless, so there is no reading first.
    match failure_of(timeout(timing.on, power.set_powered(true)).await) {
        Ok(()) => {
            health.power_on_restored(Instant::now());
            report(Report::Restored);
        }
        Err(failure) => {
            health.power_on_failed(Instant::now());
            report(Report::Failed(if failure == ResetFailure::Timeout { ResetFailure::Timeout } else { ResetFailure::PowerOn }));
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

/// `adapter_reset_skipped kind=...`.
pub fn reset_skipped_diag(skip: Skip) -> Diag {
    Diag::new(0, "adapter_reset_skipped").with("kind", Value::S(match skip {
        Skip::Off => "off",
        Skip::Busy => "busy",
    }))
}

/// `adapter_reset_restored`.
pub fn restored_diag() -> Diag {
    Diag::new(0, "adapter_reset_restored")
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
        let mut health = AdapterHealth::new(t0);
        health.scan_started(t0);
        (health, t0)
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
        health.connect_failed(FailKind::AbortByLocal);
        assert_eq!(health.check(t0 + secs(1)), None);
        health.connect_failed(FailKind::Timeout);
        assert_eq!(health.check(t0 + secs(1)), Some(ResetReason::ConnectFailures));
    }

    #[test]
    fn three_timeouts_in_a_row_still_trigger_a_reset() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        assert_eq!(health.check(t0), Some(ResetReason::ConnectFailures));
    }

    #[test]
    fn three_att_errors_in_a_row_do_not_reset_the_adapter() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::AttError);
        }
        assert_eq!(health.check(t0), None, "the phone answered over the air: its GATT service was only gone for a moment");
    }

    #[test]
    fn an_att_error_between_radio_failures_resets_the_count() {
        let (mut health, t0) = start();
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::Timeout);
        health.connect_failed(FailKind::AttError);
        health.connect_failed(FailKind::Timeout);
        assert_eq!(health.check(t0), None, "the answer from the phone ends the streak");
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
        for kind in [FailKind::NotSelected, FailKind::AuthFailed, FailKind::UnsupportedVersion, FailKind::AttError] {
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
        for kind in [FailKind::Unreachable, FailKind::Enosys, FailKind::AbortByLocal, FailKind::Timeout] {
            assert!(counts_against_adapter(kind), "{kind:?}");
        }
    }

    #[test]
    fn failures_are_not_judged_while_receiving_is_off_though_they_would_be_when_it_is_on() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        assert_eq!(health.check(t0), Some(ResetReason::ConnectFailures), "control: these failures do call for a cycle");
        health.receiving(false, t0);
        assert_eq!(health.check(t0), None);
    }

    #[test]
    fn failures_are_not_judged_while_a_link_is_up_though_they_would_be_once_it_is_down() {
        let (mut health, t0) = start();
        health.link_up(t0 + secs(1));
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        assert_eq!(health.check(t0 + secs(2)), None, "a link is up");
        health.link_down(t0 + secs(3));
        assert_eq!(health.check(t0 + secs(3)), Some(ResetReason::ConnectFailures), "control: the count was not what kept it quiet");
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
        health.cycled(t0 + secs(60), ResetReason::NoAdverts);
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
        health.cycled(t0, ResetReason::NoAdverts);
        health.advert(t0 + secs(150));
        assert_eq!(health.check(t0 + secs(150)), None);
    }

    #[test]
    fn the_gap_doubles_while_cycles_are_not_followed_by_a_healthy_sign_up_to_thirty_minutes() {
        let (mut health, t0) = start();
        let mut now = t0 + secs(60);
        let mut waits = Vec::new();
        for _ in 0..8 {
            health.cycled(now, ResetReason::NoAdverts);
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
        health.cycled(t0 + secs(60), ResetReason::NoAdverts);
        health.cycled(t0 + secs(180), ResetReason::NoAdverts);
        health.cycled(t0 + secs(420), ResetReason::NoAdverts);
        health.advert(t0 + secs(430));
        health.cycled(t0 + secs(2000), ResetReason::NoAdverts);
        assert_eq!(health.check(t0 + secs(2000 + 119)), None);
        assert_eq!(health.check(t0 + secs(2000 + 120)), Some(ResetReason::NoAdverts), "back to 120 s, not 960 s");
    }

    #[test]
    fn a_link_is_a_healthy_sign_too() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(60), ResetReason::NoAdverts);
        health.cycled(t0 + secs(180), ResetReason::NoAdverts);
        health.link_up(t0 + secs(190));
        health.link_down(t0 + secs(200));
        health.cycled(t0 + secs(400), ResetReason::NoAdverts);
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

    // ---- the backoff is not defeated by what a failing phone does not heal

    #[test]
    fn adverts_of_other_devices_do_not_end_the_backoff_of_connect_failure_cycles() {
        let (mut health, t0) = start();
        let mut now = t0;
        let mut waits = Vec::new();
        for _ in 0..4 {
            for _ in 0..3 {
                health.connect_failed(FailKind::Timeout);
            }
            assert_eq!(health.check(now + secs(1800)), Some(ResetReason::ConnectFailures));
            health.cycled(now, ResetReason::ConnectFailures);
            // The room is full of advertisers, only the phone fails.
            health.advert(now + secs(1));
            for _ in 0..3 {
                health.connect_failed(FailKind::Timeout);
            }
            let mut wait = 0;
            while health.check(now + secs(wait)).is_none() {
                wait += 1;
                assert!(wait < 4000);
            }
            waits.push(wait);
            now += secs(wait);
        }
        assert_eq!(waits, vec![120, 240, 480, 960]);
    }

    #[test]
    fn a_link_does_end_the_backoff_of_connect_failure_cycles() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(10), ResetReason::ConnectFailures);
        health.cycled(t0 + secs(200), ResetReason::ConnectFailures);
        health.link_up(t0 + secs(210));
        health.link_down(t0 + secs(220));
        health.cycled(t0 + secs(300), ResetReason::ConnectFailures);
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        assert_eq!(health.check(t0 + secs(300 + 119)), None);
        assert_eq!(health.check(t0 + secs(300 + 120)), Some(ResetReason::ConnectFailures), "back to 120 s");
    }

    #[test]
    fn an_advert_still_ends_the_backoff_of_no_advert_cycles() {
        let (mut health, t0) = start();
        health.cycled(t0 + secs(60), ResetReason::NoAdverts);
        health.cycled(t0 + secs(180), ResetReason::NoAdverts);
        health.advert(t0 + secs(190));
        health.cycled(t0 + secs(2000), ResetReason::NoAdverts);
        assert_eq!(health.check(t0 + secs(2000 + 120)), Some(ResetReason::NoAdverts));
    }

    // ---- time that is not spent scanning is not silence

    #[test]
    fn time_spent_connecting_is_not_silence() {
        let (mut health, t0) = start();
        health.advert(t0 + secs(1));
        health.scan_stopped();
        // The phone refuses (a refusal is not counted), the attempts take ninety seconds in all.
        health.connect_failed(FailKind::NotSelected);
        assert_eq!(health.check(t0 + secs(91)), None);
        health.scan_started(t0 + secs(91));
        assert_eq!(health.check(t0 + secs(150)), None);
        assert_eq!(health.check(t0 + secs(151)), Some(ResetReason::NoAdverts), "sixty seconds of scanning");
    }

    #[test]
    fn a_scan_that_starts_starts_the_silence_over() {
        let (mut health, t0) = start();
        health.scan_stopped();
        health.scan_started(t0 + secs(500));
        assert_eq!(health.check(t0 + secs(559)), None);
        assert_eq!(health.check(t0 + secs(560)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn failures_are_judged_even_when_no_scan_runs() {
        let (mut health, t0) = start();
        health.scan_stopped();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        assert_eq!(health.check(t0), Some(ResetReason::ConnectFailures));
    }

    // ---- a controller we switched off is ours to switch on

    #[test]
    fn nothing_is_judged_while_we_owe_the_controller_a_power_on() {
        let (mut health, t0) = start();
        for _ in 0..3 {
            health.connect_failed(FailKind::Timeout);
        }
        health.we_switched_off(t0);
        assert!(health.power_on_owed());
        assert_eq!(health.check(t0 + secs(3600)), None, "neither the failures nor the silence are the controller's fault now");
    }

    #[test]
    fn the_power_on_is_retried_with_a_growing_wait_up_to_thirty_seconds() {
        let (mut health, t0) = start();
        health.we_switched_off(t0);
        assert!(health.power_on_due(t0), "the first try is at once");
        let mut now = t0;
        let mut waits = Vec::new();
        for _ in 0..8 {
            health.power_on_failed(now);
            let mut wait = 0;
            while !health.power_on_due(now + Duration::from_millis(wait)) {
                wait += 100;
                assert!(wait < 40_000);
            }
            waits.push(wait);
            now += Duration::from_millis(wait);
        }
        assert_eq!(waits, vec![1000, 2000, 4000, 8000, 16_000, 30_000, 30_000, 30_000]);
    }

    #[test]
    fn a_failed_power_on_is_not_the_thirty_minute_pause() {
        let (mut health, t0) = start();
        health.we_switched_off(t0);
        health.power_on_failed(t0);
        assert!(health.power_on_due(t0 + secs(2)), "retried within seconds, not after half an hour");
    }

    #[test]
    fn once_the_controller_is_on_again_judging_starts_over_and_the_gap_holds() {
        let (mut health, t0) = start();
        health.we_switched_off(t0);
        health.power_on_restored(t0 + secs(10));
        assert!(!health.power_on_owed());
        assert!(!health.power_on_due(t0 + secs(3600)));
        assert_eq!(health.check(t0 + secs(69)), None);
        assert_eq!(health.check(t0 + secs(130)), Some(ResetReason::NoAdverts), "sixty seconds of silence, and the gap of 120 s is over");
        assert_eq!(health.check(t0 + secs(100)), None, "the gap of 120 s counts from the power-on");
    }

    #[test]
    fn a_skipped_cycle_backs_off_like_a_cycle() {
        let (mut health, t0) = start();
        health.cycle_skipped(t0 + secs(60), ResetReason::NoAdverts);
        health.cycle_skipped(t0 + secs(180), ResetReason::NoAdverts);
        assert_eq!(health.check(t0 + secs(180 + 239)), None);
        assert_eq!(health.check(t0 + secs(180 + 240)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn our_phones_are_those_that_list_the_selected_or_the_pairing_service() {
        let select = uuid::Uuid::from_u128(1);
        let pairing = uuid::Uuid::from_u128(2);
        let other = uuid::Uuid::from_u128(3);
        assert!(is_our_phone(&HashSet::from([select]), select, pairing));
        assert!(is_our_phone(&HashSet::from([other, pairing]), select, pairing));
        assert!(!is_our_phone(&HashSet::from([other]), select, pairing), "a mouse, a headset");
        assert!(!is_our_phone(&HashSet::new(), select, pairing), "unknown is not ours: the controller is left alone");
    }

    // ---- the power cycle against a fake controller

    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;

    #[derive(Clone, Copy, PartialEq, Debug)]
    enum Mode {
        Ok,
        Fault,
        Hang,
    }

    /// A controller that does what it is told. `Hang` never answers; a hung `set_powered(false)` has switched it off, as
    /// BlueZ may have by the time we give up.
    struct Fake {
        powered: Cell<bool>,
        read: Cell<Mode>,
        other: Cell<Mode>,
        other_connected: Cell<bool>,
        off: RefCell<VecDeque<Mode>>,
        on: RefCell<VecDeque<Mode>>,
        calls: RefCell<Vec<&'static str>>,
    }

    impl Fake {
        fn new() -> Self {
            Self { powered: Cell::new(true), read: Cell::new(Mode::Ok), other: Cell::new(Mode::Ok), other_connected: Cell::new(false), off: RefCell::default(), on: RefCell::default(), calls: RefCell::default() }
        }

        fn off_script(self, modes: &[Mode]) -> Self {
            *self.off.borrow_mut() = modes.iter().copied().collect();
            self
        }

        fn on_script(self, modes: &[Mode]) -> Self {
            *self.on.borrow_mut() = modes.iter().copied().collect();
            self
        }

        fn calls(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl PowerControl for Fake {
        async fn is_powered(&self) -> Result<bool, PowerFault> {
            self.calls.borrow_mut().push("read");
            match self.read.get() {
                Mode::Ok => Ok(self.powered.get()),
                Mode::Fault => Err(PowerFault),
                Mode::Hang => std::future::pending().await,
            }
        }

        async fn set_powered(&self, on: bool) -> Result<(), PowerFault> {
            self.calls.borrow_mut().push(if on { "on" } else { "off" });
            let queue = if on { &self.on } else { &self.off };
            let mode = queue.borrow_mut().pop_front().unwrap_or(Mode::Ok);
            match mode {
                Mode::Ok => {
                    self.powered.set(on);
                    Ok(())
                }
                Mode::Fault => Err(PowerFault),
                Mode::Hang => {
                    if !on {
                        self.powered.set(false);
                    }
                    std::future::pending().await
                }
            }
        }

        async fn other_connection(&self) -> Result<bool, PowerFault> {
            self.calls.borrow_mut().push("busy?");
            match self.other.get() {
                Mode::Ok => Ok(self.other_connected.get()),
                Mode::Fault => Err(PowerFault),
                Mode::Hang => std::future::pending().await,
            }
        }
    }

    const FAST: CycleTiming = CycleTiming { read: Duration::from_millis(30), off: Duration::from_millis(30), off_for: Duration::from_millis(1), on: Duration::from_millis(30) };

    async fn cycle(health: &mut AdapterHealth, fake: &Fake) -> Vec<Report> {
        let mut reports = Vec::new();
        power_cycle(health, fake, ResetReason::NoAdverts, FAST, |r| reports.push(r)).await;
        reports
    }

    async fn restore(health: &mut AdapterHealth, fake: &Fake) -> Vec<Report> {
        let mut reports = Vec::new();
        restore_power(health, fake, FAST, |r| reports.push(r)).await;
        reports
    }

    /// A silent controller that has been so for a minute: a cycle is due.
    fn deaf() -> (AdapterHealth, Instant) {
        let (health, t0) = start();
        assert_eq!(health.check(t0 + secs(60)), Some(ResetReason::NoAdverts));
        (health, t0)
    }

    #[tokio::test]
    async fn a_cycle_that_works_checks_switches_off_then_on_and_counts() {
        let (mut health, t0) = deaf();
        let fake = Fake::new();
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Started, Report::Cycled]);
        assert_eq!(fake.calls(), ["read", "busy?", "off", "on"]);
        assert!(fake.powered.get());
        assert!(!health.power_on_owed());
        assert_eq!(health.check(Instant::now() + secs(119)), None, "the gap counts from the cycle");
        let _ = t0;
    }

    #[tokio::test]
    async fn when_the_off_call_times_out_the_controller_is_still_switched_on() {
        let (mut health, _) = deaf();
        let fake = Fake::new().off_script(&[Mode::Hang]);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Started, Report::Failed(ResetFailure::Timeout)]);
        assert_eq!(fake.calls(), ["read", "busy?", "off", "on"], "BlueZ may have powered it off already: on is tried anyway");
        assert!(fake.powered.get(), "it was left on");
        assert!(!health.power_on_owed());
    }

    #[tokio::test]
    async fn when_the_off_call_is_refused_the_controller_is_still_switched_on_and_the_cycle_pauses() {
        let (mut health, _) = deaf();
        let fake = Fake::new().off_script(&[Mode::Fault]);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Started, Report::Failed(ResetFailure::PowerOff)]);
        assert_eq!(fake.calls().last(), Some(&"on"));
        assert_eq!(health.check(Instant::now() + secs(1700)), None, "a cycle that could not be carried out waits half an hour");
    }

    #[tokio::test]
    async fn a_power_on_that_fails_once_is_tried_again_at_once() {
        let (mut health, _) = deaf();
        let fake = Fake::new().on_script(&[Mode::Fault]);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Started, Report::Cycled]);
        assert_eq!(fake.calls(), ["read", "busy?", "off", "on", "on"]);
    }

    #[tokio::test]
    async fn a_health_tick_settles_an_owed_power_on_when_it_is_due_and_judges_nothing_else_meanwhile() {
        let (mut health, _) = deaf();
        let fake = Fake::new().on_script(&[Mode::Fault, Mode::Hang]);
        cycle(&mut health, &fake).await;
        assert!(health.power_on_owed());
        let now = Instant::now();
        assert_eq!(health.tick(now), Tick::RestorePower, "due at once: the scan does not wait for its end");
        assert_eq!(health.tick(now + secs(7200)), Tick::RestorePower, "never turned into a new cycle while owed");
        // A try that failed waits; until it is due the tick leaves the controller alone.
        health.power_on_failed(now);
        assert_eq!(health.tick(now), Tick::Idle);
        assert_eq!(health.tick(now + secs(2)), Tick::RestorePower);
    }

    #[test]
    fn a_health_tick_without_anything_owed_is_the_plain_check() {
        let (health, t0) = start();
        assert_eq!(health.tick(t0 + secs(59)), Tick::Idle);
        assert_eq!(health.tick(t0 + secs(60)), Tick::Cycle(ResetReason::NoAdverts));
    }

    #[tokio::test]
    async fn a_power_on_that_fails_twice_leaves_us_owing_it_and_it_is_retried_later() {
        let (mut health, _) = deaf();
        let fake = Fake::new().on_script(&[Mode::Fault, Mode::Hang]);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Started, Report::Failed(ResetFailure::Timeout)]);
        assert!(!fake.powered.get());
        assert!(health.power_on_owed());
        assert!(health.power_on_due(Instant::now()));
        assert_eq!(health.check(Instant::now() + secs(7200)), None, "no new cycle while the controller is off by our doing");

        // Later: the controller answers again.
        assert_eq!(restore(&mut health, &fake).await, vec![Report::Restored]);
        assert!(fake.powered.get());
        assert!(!health.power_on_owed());
    }

    #[tokio::test]
    async fn a_restore_that_fails_is_retried_with_a_backoff_and_never_pauses_for_half_an_hour() {
        let (mut health, _) = deaf();
        let fake = Fake::new().on_script(&[Mode::Fault, Mode::Fault, Mode::Fault, Mode::Ok]);
        cycle(&mut health, &fake).await;
        assert!(health.power_on_owed());
        let before = Instant::now();
        assert_eq!(restore(&mut health, &fake).await, vec![Report::Failed(ResetFailure::PowerOn)]);
        assert!(health.power_on_owed());
        assert!(!health.power_on_due(before), "a growing wait after a failed try");
        assert!(health.power_on_due(before + secs(2)));
        assert_eq!(restore(&mut health, &fake).await, vec![Report::Restored]);
    }

    #[tokio::test]
    async fn the_cycle_after_a_failed_power_on_does_not_take_our_own_off_for_someone_elses() {
        let (mut health, _) = deaf();
        let fake = Fake::new().on_script(&[Mode::Fault, Mode::Fault]);
        cycle(&mut health, &fake).await;
        assert!(!fake.powered.get());
        // Anything that asks for a cycle now (here: called directly) restores instead and never reports "someone else".
        let reports = cycle(&mut health, &fake).await;
        assert_eq!(reports, vec![Report::Restored]);
        assert!(fake.powered.get());
        assert!(!reports.contains(&Report::Skipped(Skip::Off)));
    }

    #[tokio::test]
    async fn a_controller_someone_else_switched_off_is_left_off() {
        let (mut health, _) = deaf();
        let fake = Fake::new();
        fake.powered.set(false);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Skipped(Skip::Off)]);
        assert_eq!(fake.calls(), ["read"], "nothing was switched");
        assert!(!health.power_on_owed());
    }

    #[tokio::test]
    async fn a_controller_another_program_uses_is_left_alone_and_backed_off_from() {
        let (mut health, _) = deaf();
        let fake = Fake::new();
        fake.other_connected.set(true);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Skipped(Skip::Busy)]);
        assert_eq!(fake.calls(), ["read", "busy?"], "no off, no on");
        assert_eq!(health.check(Instant::now() + secs(119)), None, "backs off like a cycle");
    }

    #[tokio::test]
    async fn an_unreadable_controller_is_a_failure_without_the_half_hour_pause() {
        for mode in [Mode::Fault, Mode::Hang] {
            let (mut health, t0) = deaf();
            let fake = Fake::new();
            fake.read.set(mode);
            let expected = if mode == Mode::Hang { ResetFailure::Timeout } else { ResetFailure::Unavailable };
            assert_eq!(cycle(&mut health, &fake).await, vec![Report::Failed(expected)]);
            assert_eq!(fake.calls(), ["read"]);
            assert_eq!(health.check(t0 + secs(65)), Some(ResetReason::NoAdverts), "tried again at the next tick: {mode:?}");
        }
    }

    #[tokio::test]
    async fn a_connection_list_that_cannot_be_read_does_not_cycle_either() {
        let (mut health, t0) = deaf();
        let fake = Fake::new();
        fake.other.set(Mode::Hang);
        assert_eq!(cycle(&mut health, &fake).await, vec![Report::Failed(ResetFailure::Timeout)]);
        assert!(!fake.calls().contains(&"off"));
        assert_eq!(health.check(t0 + secs(65)), Some(ResetReason::NoAdverts));
    }

    #[test]
    fn the_whole_cycle_is_capped_at_twelve_seconds() {
        assert!(CycleTiming::PRODUCTION.worst_case() <= CYCLE_CAP, "{:?}", CycleTiming::PRODUCTION.worst_case());
        assert_eq!(CYCLE_CAP, secs(12));
    }

    #[tokio::test]
    async fn a_controller_that_answers_nothing_ends_the_cycle_within_the_worst_case_with_the_on_attempts_made() {
        let (mut health, _) = deaf();
        let fake = Fake::new().off_script(&[Mode::Hang]).on_script(&[Mode::Hang, Mode::Hang]);
        let started = Instant::now();
        let reports = cycle(&mut health, &fake).await;
        assert!(started.elapsed() <= FAST.worst_case() + Duration::from_millis(150), "{:?}", started.elapsed());
        assert_eq!(fake.calls(), ["read", "busy?", "off", "on", "on"]);
        assert_eq!(reports, vec![Report::Started, Report::Failed(ResetFailure::Timeout)]);
        assert!(health.power_on_owed());
    }

    #[tokio::test]
    async fn a_restore_with_nothing_owed_does_nothing() {
        let (mut health, _) = start();
        let fake = Fake::new();
        assert_eq!(restore(&mut health, &fake).await, Vec::<Report>::new());
        assert_eq!(fake.calls(), Vec::<&str>::new());
    }

    #[test]
    fn the_skip_words_are_fixed() {
        let skipped = reset_skipped_diag(Skip::Busy);
        assert_eq!((skipped.ev, skipped.debug), ("adapter_reset_skipped", false));
        assert_eq!(skipped.fields, vec![("kind", Value::S("busy"))]);
        assert_eq!(reset_skipped_diag(Skip::Off).fields, vec![("kind", Value::S("off"))]);
        assert_eq!(restored_diag().ev, "adapter_reset_restored");
        assert!(restored_diag().fields.is_empty());
    }
}
