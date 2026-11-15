//! Platform-independent pieces of a backend that are easy to get wrong and are tested without a radio: keeping
//! notifications in order behind `Connected`, the pace of restarting a scan that failed, and handing the last commands to
//! the worker before the program exits.

use crate::LinkCommand;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// What the gate did with a notification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Offer {
    /// The link is live: pass it on now.
    Deliver(Vec<u8>),
    /// `Connected` has not been announced yet: it waits in the gate.
    Held,
}

/// Notifications can arrive from WinRT as soon as the subscription is written, before the application has been told the
/// connection exists. The gate holds them back and hands them over, in order, right after `Connected`.
#[derive(Debug, Default)]
pub struct NotificationGate {
    live: bool,
    held: Vec<Vec<u8>>,
}

impl NotificationGate {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn offer(&mut self, bytes: Vec<u8>) -> Offer {
        if self.live {
            Offer::Deliver(bytes)
        } else {
            self.held.push(bytes);
            Offer::Held
        }
    }

    /// `Connected` has been announced. Returns what arrived before it, oldest first; later offers are delivered at once.
    pub fn open(&mut self) -> Vec<Vec<u8>> {
        self.live = true;
        std::mem::take(&mut self.held)
    }
}

/// The application's switch for receiving, as a backend keeps it: on at start, changed only by `SetScanning`. While it is
/// off the backend starts no scan, makes no connection and does not let its scan retry (the back-off after a failure) or the
/// replacement of a stale link bring either back; a link that exists is left to `Disconnect`.
///
/// Both backends drop `Disconnect` and `Write` while no link is open, so a connection that slips through just as receiving
/// is switched off cannot be ended from the application's side by them; the application's refusal of the late `Connected`
/// (`link_refused why=stopped`, answered with a `Disconnect` that the then-open link does honour) is the last guard.
#[derive(Debug, Clone, Copy)]
pub struct ScanSwitch {
    on: bool,
}

impl Default for ScanSwitch {
    fn default() -> Self {
        Self::new()
    }
}

impl ScanSwitch {
    pub fn new() -> Self {
        Self { on: true }
    }

    /// Takes note of a command; only `SetScanning` matters.
    pub fn apply(&mut self, command: &LinkCommand) {
        if let LinkCommand::SetScanning(on) = command {
            self.on = *on;
        }
    }

    pub fn is_on(&self) -> bool {
        self.on
    }

    /// A device the backend is about to connect to (found by a scan, or named by the end of a stale link): kept while the
    /// switch is on, dropped while it is off.
    pub fn admit<T>(&self, target: Option<T>) -> Option<T> {
        target.filter(|_| self.on)
    }
}

/// The application's side of the worker's commands has closed: the worker has to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ApplicationGone;

/// Decides whether a device found or named earlier may still be connected to: first every command already queued is looked
/// at (`drain`, which applies them to the worker and says whether the application is still there), and only then does the
/// switch get its say. Without the drain a stop that is queued but not read yet would let one more connection through.
pub fn drain_then_admit<S, T>(state: &mut S, drain: impl FnOnce(&mut S) -> bool, switch_of: impl Fn(&S) -> &ScanSwitch, target: Option<T>) -> Result<Option<T>, ApplicationGone> {
    if !drain(state) {
        return Err(ApplicationGone);
    }
    Ok(switch_of(state).admit(target))
}

/// How a connection attempt ended, as far as the switch is concerned.
#[derive(Debug, PartialEq, Eq)]
pub enum Settled<L, E> {
    /// The link is up and receiving is on: announce it.
    Opened(L),
    /// The attempt failed while receiving is on: report it, back off.
    Failed(E),
    /// Receiving was switched off while the attempt ran: nothing is announced, nothing is counted as a failure, and a link
    /// that did come up (`Some`) is only to be released.
    Cancelled(Option<L>),
}

pub fn settle_attempt<L, E>(switch: &ScanSwitch, result: Result<L, E>) -> Settled<L, E> {
    match (switch.is_on(), result) {
        (true, Ok(link)) => Settled::Opened(link),
        (true, Err(error)) => Settled::Failed(error),
        (false, Ok(link)) => Settled::Cancelled(Some(link)),
        (false, Err(_)) => Settled::Cancelled(None),
    }
}

/// How long to wait before starting a scan again after it failed: 2 s, doubling, 30 s at most.
#[derive(Debug, Default)]
pub struct ScanBackoff {
    failures: u32,
}

impl ScanBackoff {
    pub const FIRST: Duration = Duration::from_secs(2);
    pub const MAX: Duration = Duration::from_secs(30);

    pub fn new() -> Self {
        Self::default()
    }

    /// The wait after one more failure.
    pub fn next_wait(&mut self) -> Duration {
        let wait = Self::FIRST.saturating_mul(1u32.checked_shl(self.failures).unwrap_or(u32::MAX)).min(Self::MAX);
        self.failures = self.failures.saturating_add(1);
        wait
    }

    /// The scan ran: start again from the short wait.
    pub fn reset(&mut self) {
        self.failures = 0;
    }
}

/// Passes commands to the worker in order until the application closes its end, then waits for the worker to say it has
/// finished (it releases the link first), but not longer than `grace`. `true` when the worker finished in time.
pub async fn pump_commands(
    mut commands: mpsc::Receiver<LinkCommand>,
    mut forward: impl FnMut(LinkCommand) -> bool + Send,
    worker_done: oneshot::Receiver<()>,
    grace: Duration,
) -> bool {
    while let Some(command) = commands.recv().await {
        if !forward(command) {
            break;
        }
    }
    // The forwarder holds the worker's command channel; the worker finishes only once that is closed.
    drop(forward);
    tokio::time::timeout(grace, worker_done).await.is_ok_and(|done| done.is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FailKind;
    use std::sync::{Arc, Mutex};

    #[test]
    fn notifications_before_connected_are_held_and_released_in_order() {
        let mut gate = NotificationGate::new();
        assert_eq!(gate.offer(vec![1]), Offer::Held);
        assert_eq!(gate.offer(vec![2]), Offer::Held);
        assert_eq!(gate.open(), vec![vec![1], vec![2]]);
        assert_eq!(gate.offer(vec![3]), Offer::Deliver(vec![3]));
        assert!(gate.open().is_empty());
    }

    #[test]
    fn the_scan_switch_is_on_at_start_and_follows_only_set_scanning() {
        let mut switch = ScanSwitch::new();
        assert!(switch.is_on());
        for other in [LinkCommand::Disconnect, LinkCommand::Write(vec![1]), LinkCommand::SetPairingScan(true), LinkCommand::SetPairingScan(false)] {
            switch.apply(&other);
            assert!(switch.is_on(), "{other:?} does not switch scanning");
        }
        switch.apply(&LinkCommand::SetScanning(false));
        assert!(!switch.is_on());
        // Neither time, nor a Disconnect, nor a pairing scan turns it back on.
        switch.apply(&LinkCommand::Disconnect);
        switch.apply(&LinkCommand::SetPairingScan(true));
        assert!(!switch.is_on());
        switch.apply(&LinkCommand::SetScanning(true));
        assert!(switch.is_on());
    }

    #[test]
    fn a_target_found_or_a_replacement_after_the_switch_went_off_is_dropped() {
        let mut switch = ScanSwitch::new();
        assert_eq!(switch.admit(Some(7)), Some(7));
        assert_eq!(switch.admit::<u8>(None), None);
        switch.apply(&LinkCommand::SetScanning(false));
        assert_eq!(switch.admit(Some(7)), None, "a stale-link replacement or a late advert must not reconnect");
        switch.apply(&LinkCommand::SetScanning(true));
        assert_eq!(switch.admit(Some(7)), Some(7));
    }

    /// A worker's state as the flow functions see it: a queue of commands not yet looked at, and the switch.
    struct Model {
        queue: std::collections::VecDeque<LinkCommand>,
        switch: ScanSwitch,
        closed: bool,
    }

    impl Model {
        fn with(commands: Vec<LinkCommand>) -> Self {
            Self { queue: commands.into(), switch: ScanSwitch::new(), closed: false }
        }

        /// Looks at every queued command; `false` when the application is gone.
        fn drain(&mut self) -> bool {
            while let Some(command) = self.queue.pop_front() {
                self.switch.apply(&command);
            }
            !self.closed
        }
    }

    #[test]
    fn an_advert_is_admitted_only_after_the_commands_queued_before_it_were_looked_at() {
        // The stop is queued but the worker has not read it yet: without the drain the switch still says on.
        let stale = Model::with(vec![LinkCommand::SetScanning(false)]);
        assert_eq!(stale.switch.admit(Some(7)), Some(7), "the unread stop is invisible to a bare admit");
        let mut model = Model::with(vec![LinkCommand::SetScanning(false)]);
        assert_eq!(drain_then_admit(&mut model, Model::drain, |m| &m.switch, Some(7)), Ok(None));
        // Nothing queued: the target stays.
        let mut idle = Model::with(vec![]);
        assert_eq!(drain_then_admit(&mut idle, Model::drain, |m| &m.switch, Some(7)), Ok(Some(7)));
        // Stop then start in the queue: the last word counts.
        let mut again = Model::with(vec![LinkCommand::SetScanning(false), LinkCommand::SetScanning(true)]);
        assert_eq!(drain_then_admit(&mut again, Model::drain, |m| &m.switch, Some(7)), Ok(Some(7)));
        // No target: still none.
        let mut empty = Model::with(vec![]);
        assert_eq!(drain_then_admit::<_, u8>(&mut empty, Model::drain, |m| &m.switch, None), Ok(None));
    }

    #[test]
    fn a_gone_application_is_reported_instead_of_admitting() {
        let mut model = Model::with(vec![]);
        model.closed = true;
        assert_eq!(drain_then_admit(&mut model, Model::drain, |m| &m.switch, Some(7)), Err(ApplicationGone));
    }

    #[test]
    fn stop_sent_before_disconnect_leaves_the_switch_off_when_the_worker_ends_its_link() {
        // The worker ends `serve` on `Disconnect` and then decides what to do next; it has seen exactly the commands up to
        // and including that one. The order the application sends them in decides what it finds.
        let found_next = |commands: Vec<LinkCommand>| {
            let mut model = Model::with(vec![]);
            for command in &commands {
                model.switch.apply(command);
                if *command == LinkCommand::Disconnect {
                    break;
                }
            }
            model.switch.is_on()
        };
        assert!(found_next(vec![LinkCommand::Disconnect, LinkCommand::SetScanning(false)]), "the old order: scanning would restart");
        assert!(!found_next(vec![LinkCommand::SetScanning(false), LinkCommand::Disconnect]), "the new order: the worker parks");
    }

    #[test]
    fn an_attempt_that_ends_while_the_switch_is_off_is_cancelled_not_failed_and_never_opens() {
        let mut switch = ScanSwitch::new();
        assert_eq!(settle_attempt(&switch, Ok::<_, FailKind>(1)), Settled::Opened(1));
        assert_eq!(settle_attempt(&switch, Err::<u8, _>(FailKind::Timeout)), Settled::Failed(FailKind::Timeout));
        switch.apply(&LinkCommand::SetScanning(false));
        // A link that did get made is handed back to be released; it is not announced.
        assert_eq!(settle_attempt(&switch, Ok::<_, FailKind>(1)), Settled::Cancelled(Some(1)));
        // A failure after the stop is not a failure: no back-off, no hold.
        assert_eq!(settle_attempt(&switch, Err::<u8, _>(FailKind::Timeout)), Settled::Cancelled(None));
    }

    #[test]
    fn scan_backoff_doubles_from_two_seconds_to_thirty_and_resets() {
        let mut backoff = ScanBackoff::new();
        let waits: Vec<u64> = (0..7).map(|_| backoff.next_wait().as_secs()).collect();
        assert_eq!(waits, vec![2, 4, 8, 16, 30, 30, 30]);
        backoff.reset();
        assert_eq!(backoff.next_wait(), ScanBackoff::FIRST);
    }

    #[tokio::test]
    async fn pump_forwards_every_queued_command_in_order_then_waits_for_the_worker() {
        let (tx, rx) = mpsc::channel(8);
        let (done_tx, done_rx) = oneshot::channel();
        tx.send(LinkCommand::Write(vec![1])).await.unwrap();
        tx.send(LinkCommand::Disconnect).await.unwrap();
        drop(tx);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        done_tx.send(()).unwrap();
        let finished = pump_commands(rx, move |c| { sink.lock().unwrap().push(c); true }, done_rx, Duration::from_millis(500)).await;
        assert!(finished);
        assert_eq!(*seen.lock().unwrap(), vec![LinkCommand::Write(vec![1]), LinkCommand::Disconnect]);
    }

    #[tokio::test]
    async fn pump_lets_go_of_the_worker_channel_so_the_worker_can_finish() {
        // The real forwarder owns the sending end of the worker's command channel; the worker ends only when it is dropped.
        struct EndsWhenDropped(Option<oneshot::Sender<()>>);
        impl Drop for EndsWhenDropped {
            fn drop(&mut self) {
                if let Some(done) = self.0.take() {
                    let _ = done.send(());
                }
            }
        }
        let (tx, rx) = mpsc::channel(1);
        let (done_tx, done_rx) = oneshot::channel();
        let worker_channel = EndsWhenDropped(Some(done_tx));
        drop(tx);
        let forward = move |_c: LinkCommand| {
            let _keep = &worker_channel;
            true
        };
        assert!(pump_commands(rx, forward, done_rx, Duration::from_millis(500)).await);
    }

    #[tokio::test]
    async fn pump_gives_up_on_a_worker_that_never_finishes() {
        let (tx, rx) = mpsc::channel::<LinkCommand>(1);
        let (_done_tx, done_rx) = oneshot::channel::<()>();
        drop(tx);
        let started = std::time::Instant::now();
        assert!(!pump_commands(rx, |_| true, done_rx, Duration::from_millis(50)).await);
        assert!(started.elapsed() < Duration::from_secs(2), "quitting must not hang");
    }
}
