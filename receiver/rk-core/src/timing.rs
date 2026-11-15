//! Timing statistics for the receiver's diagnostic log: how long things took and how often they came, never what they
//! carried. Everything here is pure; callers pass time in microseconds.
//!
//! A "stroke" is one burst of pointer activity: it begins with the first event and ends when [`STROKE_IDLE_US`] pass with no
//! further event. Each layer keeps a [`StrokeTracker`] and an [`IntervalHistogram`] per measured interval and writes one
//! summary when its stroke ends.

/// A stroke ends after this long without an event.
pub const STROKE_IDLE_US: u64 = 300_000;
/// Upper bounds of the histogram buckets in milliseconds; a last bucket takes everything above.
pub const BUCKET_BOUNDS_MS: [u64; 10] = [2, 5, 10, 15, 20, 30, 40, 50, 75, 150];
/// Raw samples kept for the percentiles; later samples still count in the buckets, the count and the maximum.
pub const SAMPLE_CAP: usize = 4096;

/// The keys of [`IntervalHistogram::fields`], in order.
pub const FIELD_KEYS: [&str; 16] =
    ["n", "p50_us", "p90_us", "p99_us", "max_us", "b2", "b5", "b10", "b15", "b20", "b30", "b40", "b50", "b75", "b150", "bover"];

/// Durations in microseconds: percentiles from the raw samples and counts per bucket.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IntervalHistogram {
    samples: Vec<u64>,
    buckets: [u64; 11],
    count: u64,
    max_us: u64,
}

impl IntervalHistogram {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(&mut self, micros: u64) {
        self.count += 1;
        self.max_us = self.max_us.max(micros);
        let bucket = BUCKET_BOUNDS_MS.iter().position(|bound| micros <= bound * 1_000).unwrap_or(BUCKET_BOUNDS_MS.len());
        self.buckets[bucket] += 1;
        if self.samples.len() < SAMPLE_CAP {
            self.samples.push(micros);
        }
    }

    /// How many durations were recorded.
    pub fn count(&self) -> u64 {
        self.count
    }

    /// The longest duration recorded; 0 when none.
    pub fn max_us(&self) -> u64 {
        self.max_us
    }

    /// Nearest-rank percentile (`percent` 1 to 100) of the kept samples; `None` when nothing was recorded.
    pub fn percentile_us(&self, percent: u32) -> Option<u64> {
        let mut sorted = self.samples.clone();
        sorted.sort_unstable();
        Self::rank(&sorted, percent)
    }

    fn rank(sorted: &[u64], percent: u32) -> Option<u64> {
        if sorted.is_empty() {
            return None;
        }
        let percent = u64::from(percent.clamp(1, 100));
        let rank = (percent * sorted.len() as u64).div_ceil(100).max(1);
        sorted.get(usize::try_from(rank - 1).unwrap_or(usize::MAX)).copied()
    }

    /// Counts per bucket: one for each of [`BUCKET_BOUNDS_MS`], then the overflow.
    pub fn buckets(&self) -> [u64; 11] {
        self.buckets
    }

    /// `(key, value)` pairs under [`FIELD_KEYS`]; every value is 0 for an empty histogram.
    pub fn fields(&self) -> Vec<(&'static str, u64)> {
        let mut sorted = self.samples.clone();
        sorted.sort_unstable();
        let percentile = |percent| Self::rank(&sorted, percent).unwrap_or(0);
        let mut values = vec![self.count, percentile(50), percentile(90), percentile(99), self.max_us];
        values.extend(self.buckets);
        FIELD_KEYS.iter().copied().zip(values).collect()
    }
}

/// Tells when a stroke has ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StrokeTracker {
    last_us: Option<u64>,
}

impl StrokeTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// An event at `now_us`: the stroke starts if none is open, otherwise it goes on.
    pub fn touch(&mut self, now_us: u64) {
        self.last_us = Some(now_us);
    }

    /// A stroke is open.
    pub fn is_open(&self) -> bool {
        self.last_us.is_some()
    }

    /// When the open stroke ends if nothing else happens.
    pub fn deadline(&self) -> Option<u64> {
        self.last_us.map(|last| last.saturating_add(STROKE_IDLE_US))
    }

    /// The open stroke has gone quiet for [`STROKE_IDLE_US`] at `now_us`.
    pub fn ended(&self, now_us: u64) -> bool {
        self.deadline().is_some_and(|deadline| now_us >= deadline)
    }

    /// Forgets the open stroke.
    pub fn close(&mut self) {
        self.last_us = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filled(values: &[u64]) -> IntervalHistogram {
        let mut h = IntervalHistogram::new();
        for v in values {
            h.record(*v);
        }
        h
    }

    #[test]
    fn an_empty_histogram_reports_zeros_and_no_percentile() {
        let h = IntervalHistogram::new();
        assert_eq!(h.count(), 0);
        assert_eq!(h.percentile_us(50), None);
        let fields = h.fields();
        assert_eq!(fields.len(), FIELD_KEYS.len());
        assert!(fields.iter().all(|(_, v)| *v == 0));
    }

    #[test]
    fn percentiles_use_the_nearest_rank() {
        let h = filled(&(1..=100).map(|n| n * 1000).collect::<Vec<_>>());
        assert_eq!(h.percentile_us(50), Some(50_000));
        assert_eq!(h.percentile_us(90), Some(90_000));
        assert_eq!(h.percentile_us(99), Some(99_000));
        assert_eq!(h.percentile_us(100), Some(100_000));
        assert_eq!(h.max_us(), 100_000);
    }

    #[test]
    fn percentiles_do_not_depend_on_the_order_of_recording() {
        assert_eq!(filled(&[9_000, 1_000, 5_000]).percentile_us(50), Some(5_000));
        assert_eq!(filled(&[7_000]).percentile_us(99), Some(7_000));
    }

    #[test]
    fn each_duration_lands_in_the_bucket_whose_bound_it_does_not_exceed() {
        // 2 ms is still bucket b2, 2.001 ms is b5; 150 ms is b150, above it is the overflow.
        let h = filled(&[0, 2_000, 2_001, 5_000, 10_001, 45_000, 150_000, 150_001, 9_000_000]);
        assert_eq!(h.buckets(), [2, 2, 0, 1, 0, 0, 0, 1, 0, 1, 2]);
        assert_eq!(h.buckets().iter().sum::<u64>(), h.count());
    }

    #[test]
    fn fields_carry_the_fixed_keys_in_order() {
        let h = filled(&[3_000, 3_000, 40_000]);
        let fields = h.fields();
        let keys: Vec<&str> = fields.iter().map(|(k, _)| *k).collect();
        assert_eq!(keys, FIELD_KEYS);
        let get = |key: &str| fields.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).unwrap();
        assert_eq!((get("n"), get("max_us"), get("p50_us"), get("b5"), get("b40")), (3, 40_000, 3_000, 2, 1));
    }

    #[test]
    fn past_the_cap_samples_still_count_in_buckets_count_and_max() {
        let mut h = IntervalHistogram::new();
        for _ in 0..SAMPLE_CAP {
            h.record(1_000);
        }
        h.record(80_000);
        assert_eq!(h.count(), SAMPLE_CAP as u64 + 1);
        assert_eq!(h.max_us(), 80_000);
        assert_eq!(h.buckets()[9], 1, "the 80 ms sample is in b150");
        assert_eq!(h.percentile_us(100), Some(1_000), "the percentiles look at the kept samples only");
    }

    #[test]
    fn a_stroke_ends_after_the_idle_time_without_events() {
        let mut t = StrokeTracker::new();
        assert!(!t.is_open() && t.deadline().is_none() && !t.ended(10_000_000));
        t.touch(1_000_000);
        assert!(t.is_open());
        assert_eq!(t.deadline(), Some(1_000_000 + STROKE_IDLE_US));
        assert!(!t.ended(1_000_000 + STROKE_IDLE_US - 1));
        assert!(t.ended(1_000_000 + STROKE_IDLE_US));
    }

    #[test]
    fn an_event_moves_the_deadline_and_close_forgets_the_stroke() {
        let mut t = StrokeTracker::new();
        t.touch(0);
        t.touch(200_000);
        assert_eq!(t.deadline(), Some(200_000 + STROKE_IDLE_US));
        assert!(!t.ended(400_000));
        t.close();
        assert!(!t.is_open() && t.deadline().is_none());
    }
}
