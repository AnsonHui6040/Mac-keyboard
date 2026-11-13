//! Duplicate and out-of-order detection for events (protocol v4 §7.4).

use crate::message::{AckResult, EventKind, KeyboardEvent};
use std::collections::{HashMap, VecDeque};
use uuid::Uuid;

/// How many processed `eventId`s are remembered (§7.4).
pub const CAPACITY: usize = 256;

/// What the host should do with an event it has just read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DedupDecision {
    /// Not seen, and newer than everything seen in its session: process it, then `record` it.
    Fresh,
    /// The same `eventId` was processed: answer with the original result and do nothing else.
    Duplicate(AckResult),
    /// A new `eventId` whose `seq` is not above the highest of its session: answer `outOfOrder`, record nothing.
    OutOfOrder,
    /// `ping`, `probe`, `pointerOpen` and `pointerClose` skip both checks and are never recorded.
    Exempt,
}

fn is_exempt(event: &KeyboardEvent) -> bool {
    matches!(
        event.kind,
        EventKind::Ping { .. } | EventKind::Probe | EventKind::PointerOpen { .. } | EventKind::PointerClose
    )
}

/// The last 256 processed events and the highest `seq` of the current session (§7.4). It lives as long as the receiver
/// runs: a reconnect, a new authentication or another phone does not clear it.
#[derive(Debug)]
pub struct EventDeduplicator {
    capacity: usize,
    results: HashMap<Uuid, AckResult>,
    /// Oldest first; mirrors the keys of `results`.
    order: VecDeque<Uuid>,
    session_id: Option<Uuid>,
    highest_seq: u64,
}

impl EventDeduplicator {
    /// A deduplicator that keeps the last 256 event ids.
    pub fn new() -> Self {
        Self::with_capacity(CAPACITY)
    }

    /// A deduplicator that keeps the last `capacity` event ids (at least one).
    pub fn with_capacity(capacity: usize) -> Self {
        Self { capacity: capacity.max(1), results: HashMap::new(), order: VecDeque::new(), session_id: None, highest_seq: 0 }
    }

    /// Classifies an event; changes nothing. An id that fell out of the window has a `seq` at or below the maximum, so it
    /// reads as out of order, not as fresh.
    pub fn check(&self, event: &KeyboardEvent) -> DedupDecision {
        if is_exempt(event) {
            return DedupDecision::Exempt;
        }
        if let Some(original) = self.results.get(&event.event_id) {
            return DedupDecision::Duplicate(*original);
        }
        if self.session_id == Some(event.session_id) && event.seq <= self.highest_seq {
            return DedupDecision::OutOfOrder;
        }
        DedupDecision::Fresh
    }

    /// Records a processed event and its result; exempt kinds are ignored. A new `sessionId` resets the maximum to zero.
    pub fn record(&mut self, event: &KeyboardEvent, result: AckResult) {
        if is_exempt(event) {
            return;
        }
        if self.session_id != Some(event.session_id) {
            self.session_id = Some(event.session_id);
            self.highest_seq = 0;
        }
        self.highest_seq = self.highest_seq.max(event.seq);
        if self.results.insert(event.event_id, result).is_none() {
            self.order.push_back(event.event_id);
        }
        while self.order.len() > self.capacity {
            if let Some(oldest) = self.order.pop_front() {
                self.results.remove(&oldest);
            }
        }
    }
}

impl Default for EventDeduplicator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_event(id: u128, session: u128, seq: u64) -> KeyboardEvent {
        KeyboardEvent {
            event_id: Uuid::from_u128(id),
            session_id: Uuid::from_u128(session),
            seq,
            focus_epoch: Some(1),
            kind: EventKind::Text("a".into()),
        }
    }

    #[test]
    fn an_unseen_event_is_fresh() {
        let d = EventDeduplicator::new();
        assert_eq!(d.check(&text_event(1, 1, 1)), DedupDecision::Fresh);
    }

    #[test]
    fn a_repeated_event_id_returns_the_first_result() {
        let mut d = EventDeduplicator::new();
        let e = text_event(1, 1, 1);
        d.record(&e, AckResult::NoFocus);
        assert_eq!(d.check(&e), DedupDecision::Duplicate(AckResult::NoFocus));
        // Even with a different seq or session: the id decides first.
        assert_eq!(d.check(&text_event(1, 2, 99)), DedupDecision::Duplicate(AckResult::NoFocus));
    }

    #[test]
    fn a_new_id_with_a_seq_not_above_the_maximum_is_out_of_order() {
        let mut d = EventDeduplicator::new();
        d.record(&text_event(1, 1, 5), AckResult::Posted);
        assert_eq!(d.check(&text_event(2, 1, 5)), DedupDecision::OutOfOrder, "equal");
        assert_eq!(d.check(&text_event(3, 1, 4)), DedupDecision::OutOfOrder, "below");
        assert_eq!(d.check(&text_event(4, 1, 6)), DedupDecision::Fresh);
        // check does not record: the refused ids are not remembered.
        assert_eq!(d.check(&text_event(2, 1, 5)), DedupDecision::OutOfOrder);
    }

    #[test]
    fn a_new_session_id_resets_the_maximum() {
        let mut d = EventDeduplicator::new();
        d.record(&text_event(1, 1, 50), AckResult::Posted);
        assert_eq!(d.check(&text_event(2, 2, 1)), DedupDecision::Fresh);
        d.record(&text_event(2, 2, 1), AckResult::Posted);
        assert_eq!(d.check(&text_event(3, 2, 1)), DedupDecision::OutOfOrder);
        assert_eq!(d.check(&text_event(4, 2, 2)), DedupDecision::Fresh);
        // Back to the first session: its maximum was reset by the second.
        d.record(&text_event(5, 1, 1), AckResult::Posted);
        assert_eq!(d.check(&text_event(6, 1, 2)), DedupDecision::Fresh);
    }

    #[test]
    fn only_the_last_256_ids_are_kept_and_an_evicted_one_reads_as_out_of_order() {
        let mut d = EventDeduplicator::new();
        for i in 1..=257u64 {
            d.record(&text_event(u128::from(i), 1, i), AckResult::Posted);
        }
        assert_eq!(d.check(&text_event(2, 1, 2)), DedupDecision::Duplicate(AckResult::Posted), "the 256th newest is kept");
        assert_eq!(d.check(&text_event(1, 1, 1)), DedupDecision::OutOfOrder, "the oldest was evicted");
        assert_eq!(d.check(&text_event(258, 1, 258)), DedupDecision::Fresh);
    }

    #[test]
    fn ping_probe_and_pointer_events_are_exempt_and_never_recorded() {
        let mut d = EventDeduplicator::new();
        d.record(&text_event(1, 1, 5), AckResult::Posted);
        for kind in [
            EventKind::Ping { shown_at_ms: 1, connected_at_ms: 2 },
            EventKind::Probe,
            EventKind::PointerOpen { grant: 7 },
            EventKind::PointerClose,
        ] {
            // Same id as a recorded event and a stale seq: still exempt.
            let e = KeyboardEvent { kind: kind.clone(), ..text_event(1, 1, 1) };
            assert_eq!(d.check(&e), DedupDecision::Exempt, "{kind:?}");
            let big = KeyboardEvent { kind, ..text_event(77, 1, 1_000) };
            d.record(&big, AckResult::Pong);
            assert_eq!(d.check(&big), DedupDecision::Exempt, "recording an exempt event is a no-op");
        }
        // The exempt events with seq 1000 did not raise the maximum nor take a place in the window.
        assert_eq!(d.check(&text_event(8, 1, 6)), DedupDecision::Fresh);
        assert_eq!(d.check(&text_event(77, 1, 6)), DedupDecision::Fresh);
    }

    #[test]
    fn recording_the_same_id_twice_keeps_one_entry_and_the_latest_result() {
        let mut d = EventDeduplicator::with_capacity(2);
        d.record(&text_event(1, 1, 1), AckResult::Posted);
        d.record(&text_event(1, 1, 2), AckResult::InjectFailed);
        d.record(&text_event(2, 1, 3), AckResult::Posted);
        assert_eq!(d.check(&text_event(1, 1, 9)), DedupDecision::Duplicate(AckResult::InjectFailed), "still inside a window of 2");
    }
}
