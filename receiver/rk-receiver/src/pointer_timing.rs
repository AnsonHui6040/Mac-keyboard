//! Per-stroke timing of the pointer path inside the application, for the diagnostic log.
//!
//! A stroke starts with the first accepted pointer packet and ends when [`rk_core::timing::STROKE_IDLE_US`] pass without
//! another. At its end the application writes one summary (`pointer_timing`: counts and the worst times) and one line per
//! measured interval, each with the histogram fields of [`IntervalHistogram`]:
//!
//! | `ev`                 | what it measures                                                                          |
//! |----------------------|-------------------------------------------------------------------------------------------|
//! | `pointer_timing_arr` | time between the arrivals of consecutive pointer packets, inside the stroke               |
//! | `pointer_timing_dt`  | the time the phone says each move packet covers                                           |
//! | `pointer_timing_out` | time between consecutive movements the playout hands out on frame ticks                   |
//!
//! The summary carries `packets` (accepted), `ble` and `udp` (of them, by the way they arrived: Bluetooth notification or Wi-Fi datagram), `moves` (of them move packets), `frames` (frame ticks in the stroke), `idle`
//! (frame ticks that handed out no movement), `squeeze` (how often the playout squeezed its queue), `lag_us` (the lag bound the playout used last: 20000 on a link with one packet per
//! frame, more where packets arrive in bursts), `inj_max_us` (the longest
//! `pointer_move` call in the application thread), `late_n`, `late_p99_us` and `late_max_us` (how late `on_tick` ran against
//! the wake-up the application asked for). Only counts and times go in; the movement itself never reaches this module.
//!
//! The application's clock counts milliseconds, so every value but `inj_max_us` is a multiple of 1000 microseconds.

use rk_core::pointer::Transport;
use rk_core::timing::{IntervalHistogram, StrokeTracker};

/// One line of the stroke report: the event word and its `(key, value)` fields.
pub type TimingLine = (&'static str, Vec<(&'static str, u64)>);

#[derive(Debug, Default)]
struct Stroke {
    arr: IntervalHistogram,
    dt: IntervalHistogram,
    out: IntervalHistogram,
    late: IntervalHistogram,
    last_arrival_us: u64,
    last_out_us: Option<u64>,
    packets: u64,
    ble: u64,
    udp: u64,
    moves: u64,
    frames: u64,
    idle: u64,
    squeeze_base: u64,
    inj_max_us: u64,
}

/// Collects the timings of the open stroke.
#[derive(Debug, Default)]
pub struct PointerTiming {
    tracker: StrokeTracker,
    stroke: Stroke,
}

impl PointerTiming {
    pub fn new() -> Self {
        Self::default()
    }

    /// An accepted pointer packet arrived. `move_span_micros` is the time a move packet covers; `squeeze_total` is the
    /// playout's squeeze counter from before this packet was handled (taken as the stroke's base when it opens one).
    pub fn on_packet(&mut self, now_us: u64, move_span_micros: Option<u64>, squeeze_total: u64) {
        if self.tracker.is_open() {
            self.stroke.arr.record(now_us.saturating_sub(self.stroke.last_arrival_us));
        } else {
            self.stroke = Stroke { squeeze_base: squeeze_total, ..Stroke::default() };
        }
        self.tracker.touch(now_us);
        self.stroke.last_arrival_us = now_us;
        self.stroke.packets += 1;
        if let Some(span) = move_span_micros {
            self.stroke.moves += 1;
            self.stroke.dt.record(span);
        }
    }

    /// The packet `on_packet` just counted arrived over `transport`.
    pub fn on_transport(&mut self, transport: Transport) {
        match transport {
            Transport::Ble => self.stroke.ble += 1,
            Transport::Udp => self.stroke.udp += 1,
        }
    }

    /// A frame tick ran; `moves_out` movements were handed out.
    pub fn on_frame(&mut self, now_us: u64, moves_out: usize) {
        if !self.tracker.is_open() {
            return;
        }
        self.stroke.frames += 1;
        if moves_out == 0 {
            self.stroke.idle += 1;
            return;
        }
        if let Some(last) = self.stroke.last_out_us {
            self.stroke.out.record(now_us.saturating_sub(last));
        }
        self.stroke.last_out_us = Some(now_us);
    }

    /// One `pointer_move` call took this long in the application thread.
    pub fn on_inject(&mut self, micros: u64) {
        if self.tracker.is_open() {
            self.stroke.inj_max_us = self.stroke.inj_max_us.max(micros);
        }
    }

    /// `on_tick` ran this long after the wake-up the application had asked for.
    pub fn on_late(&mut self, now_us: u64, late_micros: u64) {
        if self.tracker.is_open() && !self.tracker.ended(now_us) {
            self.stroke.late.record(late_micros);
        }
    }

    /// When the open stroke ends if nothing else happens.
    pub fn deadline_us(&self) -> Option<u64> {
        self.tracker.deadline()
    }

    /// The report of the stroke when it has ended at `now_us`, which then closes; `None` while it is open or when there is
    /// none. `squeeze_total` is the playout's counter now and `lag_micros` the lag bound it used last (a time, no movement).
    pub fn finish_if_ended(&mut self, now_us: u64, squeeze_total: u64, lag_micros: u64) -> Option<Vec<TimingLine>> {
        if !self.tracker.ended(now_us) {
            return None;
        }
        self.tracker.close();
        let stroke = std::mem::take(&mut self.stroke);
        let summary = vec![
            ("packets", stroke.packets),
            ("ble", stroke.ble),
            ("udp", stroke.udp),
            ("moves", stroke.moves),
            ("frames", stroke.frames),
            ("idle", stroke.idle),
            ("squeeze", squeeze_total.saturating_sub(stroke.squeeze_base)),
            ("lag_us", lag_micros),
            ("inj_max_us", stroke.inj_max_us),
            ("late_n", stroke.late.count()),
            ("late_p99_us", stroke.late.percentile_us(99).unwrap_or(0)),
            ("late_max_us", stroke.late.max_us()),
        ];
        Some(vec![
            ("pointer_timing", summary),
            ("pointer_timing_arr", stroke.arr.fields()),
            ("pointer_timing_dt", stroke.dt.fields()),
            ("pointer_timing_out", stroke.out.fields()),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_core::timing::STROKE_IDLE_US;

    fn get(line: &TimingLine, key: &str) -> u64 {
        line.1.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).unwrap_or_else(|| panic!("{key} missing"))
    }

    #[test]
    fn nothing_is_reported_without_a_stroke_or_while_it_is_open() {
        let mut t = PointerTiming::new();
        assert!(t.finish_if_ended(10_000_000, 0, 20_000).is_none());
        t.on_packet(1_000_000, Some(8_000), 0);
        assert_eq!(t.deadline_us(), Some(1_000_000 + STROKE_IDLE_US));
        assert!(t.finish_if_ended(1_000_000 + STROKE_IDLE_US - 1, 0, 20_000).is_none());
        assert!(t.finish_if_ended(1_000_000 + STROKE_IDLE_US, 0, 20_000).is_some());
        assert!(t.finish_if_ended(99_000_000, 0, 20_000).is_none(), "reported once");
        assert_eq!(t.deadline_us(), None);
    }

    #[test]
    fn arrivals_dt_and_outputs_go_to_their_own_histograms() {
        let mut t = PointerTiming::new();
        t.on_packet(0, Some(8_000), 0);
        t.on_packet(12_000, Some(9_000), 0);
        t.on_packet(40_000, None, 0);
        t.on_frame(8_000, 1);
        t.on_frame(16_000, 0);
        t.on_frame(24_000, 2);
        t.on_inject(150);
        t.on_inject(90);
        let lines = t.finish_if_ended(1_000_000, 3, 50_000).unwrap();
        let by = |name: &str| lines.iter().find(|l| l.0 == name).unwrap();
        let (summary, arr, dt, out) = (by("pointer_timing"), by("pointer_timing_arr"), by("pointer_timing_dt"), by("pointer_timing_out"));
        assert_eq!((get(summary, "packets"), get(summary, "moves"), get(summary, "frames"), get(summary, "idle")), (3, 2, 3, 1));
        assert_eq!((get(summary, "squeeze"), get(summary, "inj_max_us"), get(summary, "lag_us")), (3, 150, 50_000));
        assert_eq!((get(arr, "n"), get(arr, "max_us")), (2, 28_000));
        assert_eq!((get(dt, "n"), get(dt, "max_us")), (2, 9_000));
        assert_eq!((get(out, "n"), get(out, "max_us")), (1, 16_000), "8 ms to 24 ms skipping the starved frame");
    }

    #[test]
    fn the_summary_counts_accepted_packets_by_the_transport_they_came_over() {
        let mut t = PointerTiming::new();
        for (i, transport) in [Transport::Ble, Transport::Udp, Transport::Udp, Transport::Ble, Transport::Udp].into_iter().enumerate() {
            t.on_packet(i as u64 * 10_000, None, 0);
            t.on_transport(transport);
        }
        let lines = t.finish_if_ended(1_000_000, 0, 20_000).unwrap();
        let summary = &lines[0];
        assert_eq!((get(summary, "packets"), get(summary, "ble"), get(summary, "udp")), (5, 2, 3));
        t.on_packet(2_000_000, None, 0);
        t.on_transport(Transport::Udp);
        let next = t.finish_if_ended(3_000_000, 0, 20_000).unwrap();
        assert_eq!((get(&next[0], "ble"), get(&next[0], "udp")), (0, 1), "a new stroke starts its counts from zero");
    }

    #[test]
    fn a_new_stroke_starts_from_zero_and_takes_its_squeeze_base_when_it_opens() {
        let mut t = PointerTiming::new();
        t.on_packet(0, Some(8_000), 0);
        t.on_inject(500);
        t.finish_if_ended(1_000_000, 4, 20_000).unwrap();
        t.on_packet(2_000_000, Some(8_000), 4);
        let lines = t.finish_if_ended(3_000_000, 6, 20_000).unwrap();
        let summary = &lines[0];
        assert_eq!((get(summary, "packets"), get(summary, "squeeze"), get(summary, "inj_max_us")), (1, 2, 0));
        assert_eq!(get(&lines[1], "n"), 0, "no interval carries over from the first stroke");
    }

    #[test]
    fn lateness_counts_only_inside_an_open_stroke_that_has_not_ended() {
        let mut t = PointerTiming::new();
        t.on_late(0, 5_000);
        t.on_packet(0, None, 0);
        t.on_late(8_000, 3_000);
        t.on_late(STROKE_IDLE_US, 99_000);
        let lines = t.finish_if_ended(STROKE_IDLE_US, 0, 20_000).unwrap();
        assert_eq!((get(&lines[0], "late_n"), get(&lines[0], "late_max_us"), get(&lines[0], "late_p99_us")), (1, 3_000, 3_000));
    }
}
