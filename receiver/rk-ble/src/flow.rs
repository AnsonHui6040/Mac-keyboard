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
