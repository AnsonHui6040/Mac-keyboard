//! How pointer notifications arrive from the radio, for the diagnostic log (`ev=ble_rx_timing`).
//!
//! The backend stamps each pointer notification (first byte 0x03) when it comes off the link and keeps the gaps between them
//! for one stroke: a burst that ends after [`rk_core::timing::STROKE_IDLE_US`] without another. At its end the stroke's
//! numbers are logged once: `packets`, `same_ci` (notifications that came within 1 ms of the one before, most likely
//! delivered in the same connection event) and the histogram fields of the gaps (`n` of them, `p50_us`, `max_us`, `b2`
//! and so on; see [`rk_core::timing::FIELD_KEYS`]). Only times and counts are kept, nothing of what the packets carry.

use rk_core::timing::{IntervalHistogram, StrokeTracker};

/// A gap this short or shorter counts as the same connection event.
pub const SAME_EVENT_GAP_US: u64 = 1_000;

/// First byte of a pointer notification.
pub const POINTER_MAGIC: u8 = 0x03;

#[derive(Debug, Default)]
pub struct RxTiming {
    tracker: StrokeTracker,
    gaps: IntervalHistogram,
    last_us: u64,
    packets: u64,
    same_ci: u64,
}

impl RxTiming {
    pub fn new() -> Self {
        Self::default()
    }

    /// A notification came in at `now_us` (any monotonic microsecond count). Anything but a pointer packet is ignored.
    pub fn on_notification(&mut self, first_byte: Option<u8>, now_us: u64) {
        if first_byte != Some(POINTER_MAGIC) {
            return;
        }
        if self.tracker.is_open() {
            let gap = now_us.saturating_sub(self.last_us);
            self.gaps.record(gap);
            if gap <= SAME_EVENT_GAP_US {
                self.same_ci += 1;
            }
        }
        self.tracker.touch(now_us);
        self.last_us = now_us;
        self.packets += 1;
    }

    /// A stroke is open (and so a wake-up for [`RxTiming::deadline_us`] is wanted).
    pub fn is_open(&self) -> bool {
        self.tracker.is_open()
    }

    /// When the open stroke ends if nothing else comes.
    pub fn deadline_us(&self) -> Option<u64> {
        self.tracker.deadline()
    }

    /// The report of the stroke when it has ended at `now_us`, which then closes; `None` while it is open or when there is
    /// none. Keys: `packets`, `same_ci`, then [`rk_core::timing::FIELD_KEYS`].
    pub fn finish_if_ended(&mut self, now_us: u64) -> Option<Vec<(&'static str, u64)>> {
        if !self.tracker.ended(now_us) {
            return None;
        }
        self.tracker.close();
        let finished = std::mem::take(self);
        let mut fields = vec![("packets", finished.packets), ("same_ci", finished.same_ci)];
        fields.extend(finished.gaps.fields());
        Some(fields)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_core::timing::STROKE_IDLE_US;

    fn get(fields: &[(&'static str, u64)], key: &str) -> u64 {
        fields.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).unwrap_or_else(|| panic!("{key} missing"))
    }

    #[test]
    fn only_pointer_notifications_open_a_stroke() {
        let mut rx = RxTiming::new();
        rx.on_notification(Some(0x02), 0);
        rx.on_notification(None, 5);
        rx.on_notification(Some(0x07), 9);
        assert!(!rx.is_open() && rx.deadline_us().is_none());
        rx.on_notification(Some(POINTER_MAGIC), 10);
        assert!(rx.is_open());
        assert_eq!(rx.deadline_us(), Some(10 + STROKE_IDLE_US));
    }

    #[test]
    fn a_stroke_reports_its_gaps_once_it_has_been_quiet_for_300_ms() {
        let mut rx = RxTiming::new();
        for at in [0u64, 45_000, 45_400, 90_000, 135_000] {
            rx.on_notification(Some(POINTER_MAGIC), at);
        }
        assert!(rx.finish_if_ended(135_000 + STROKE_IDLE_US - 1).is_none());
        let fields = rx.finish_if_ended(135_000 + STROKE_IDLE_US).expect("the stroke has ended");
        assert_eq!((get(&fields, "packets"), get(&fields, "same_ci"), get(&fields, "n")), (5, 1, 4));
        assert_eq!((get(&fields, "max_us"), get(&fields, "b2"), get(&fields, "b50")), (45_000, 1, 3));
        assert!(rx.finish_if_ended(10_000_000).is_none(), "reported once");
        assert!(!rx.is_open());
    }

    #[test]
    fn a_notification_after_the_report_starts_a_new_stroke_without_the_old_gap() {
        let mut rx = RxTiming::new();
        rx.on_notification(Some(POINTER_MAGIC), 0);
        rx.on_notification(Some(POINTER_MAGIC), 10_000);
        rx.finish_if_ended(1_000_000).unwrap();
        rx.on_notification(Some(POINTER_MAGIC), 2_000_000);
        let fields = rx.finish_if_ended(3_000_000).unwrap();
        assert_eq!((get(&fields, "packets"), get(&fields, "n"), get(&fields, "same_ci")), (1, 0, 0));
    }

    #[test]
    fn the_report_holds_counts_and_times_only() {
        let mut rx = RxTiming::new();
        rx.on_notification(Some(POINTER_MAGIC), 0);
        let fields = rx.finish_if_ended(STROKE_IDLE_US).unwrap();
        let keys: Vec<&str> = fields.iter().map(|(k, _)| *k).collect();
        let mut expected = vec!["packets", "same_ci"];
        expected.extend(rk_core::timing::FIELD_KEYS);
        assert_eq!(keys, expected);
    }
}
