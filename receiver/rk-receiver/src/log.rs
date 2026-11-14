//! The diagnostic log: one line per event, `wall=… mono_ms=… lvl=… ev=… conn=… k=v…`.
//!
//! Lines are built from typed values only ([`rk_ble::Value`] has no free-text variant), so typed text, names, keys, nonces,
//! proofs, pairing codes and pointer movement have no way in. Files rotate by day and by size and expire after 7 days.

use crate::clock::Clock;
use rk_ble::{Diag, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// One file is closed at this size.
pub const MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// Files per day.
pub const FILES_PER_DAY: usize = 3;
/// A log is kept for this many calendar days, today included.
pub const RETENTION_DAYS: u64 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Info,
    Debug,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Debug => "debug",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "info" => Some(Self::Info),
            "debug" => Some(Self::Debug),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------- calendar

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of a day count since 1970-01-01.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn day_of(unix_ms: u64) -> i64 {
    i64::try_from(unix_ms / 86_400_000).unwrap_or(i64::MAX / 2)
}

/// `2026-11-14T10:20:30.123Z` (UTC).
pub fn rfc3339_utc_ms(unix_ms: u64) -> String {
    let (y, m, d) = civil_from_days(day_of(unix_ms));
    let ms_of_day = unix_ms % 86_400_000;
    let (h, mi, s, ms) = (ms_of_day / 3_600_000, ms_of_day / 60_000 % 60, ms_of_day / 1000 % 60, ms_of_day % 1000);
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{ms:03}Z")
}

/// `2026-11-14` (UTC), the date a log file is named after.
pub fn date_string(unix_ms: u64) -> String {
    let (y, m, d) = civil_from_days(day_of(unix_ms));
    format!("{y:04}-{m:02}-{d:02}")
}

// ---------------------------------------------------------------- one line

/// Builds one log line. Fields are written in the order given.
pub fn format_line(wall_unix_ms: u64, mono_ms: u64, level: Level, ev: &str, conn: Option<u64>, fields: &[(&str, Value)]) -> String {
    let mut line = format!("wall={} mono_ms={mono_ms} lvl={} ev={ev}", rfc3339_utc_ms(wall_unix_ms), level.as_str());
    if let Some(conn) = conn {
        line.push_str(&format!(" conn={conn}"));
    }
    for (key, value) in fields {
        line.push(' ');
        line.push_str(key);
        line.push('=');
        match value {
            Value::U(n) => line.push_str(&n.to_string()),
            Value::B(b) => line.push_str(if *b { "true" } else { "false" }),
            Value::S(word) => line.push_str(word),
            Value::Id(id) => line.push_str(id.as_str()),
        }
    }
    line
}

// ---------------------------------------------------------------- sinks and the logger

pub trait LogSink: Send {
    fn write_line(&mut self, line: &str);
}

/// Keeps lines in memory; clones share the same list. For tests and for `--diag`.
#[derive(Debug, Clone, Default)]
pub struct MemorySink {
    lines: Arc<Mutex<Vec<String>>>,
}

impl MemorySink {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn lines(&self) -> Vec<String> {
        self.lines.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

impl LogSink for MemorySink {
    fn write_line(&mut self, line: &str) {
        self.lines.lock().unwrap_or_else(|p| p.into_inner()).push(line.to_string());
    }
}

struct Inner {
    sink: Box<dyn LogSink>,
    clock: Arc<dyn Clock>,
    level: Level,
}

/// The logger every part of the program shares.
#[derive(Clone)]
pub struct Logger {
    inner: Arc<Mutex<Inner>>,
}

impl Logger {
    pub fn new(sink: Box<dyn LogSink>, clock: Arc<dyn Clock>, level: Level) -> Self {
        Self { inner: Arc::new(Mutex::new(Inner { sink, clock, level })) }
    }

    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn write(&self, level: Level, ev: &str, conn: Option<u64>, fields: &[(&str, Value)]) {
        let mut inner = self.inner();
        if level > inner.level {
            return;
        }
        let line = format_line(inner.clock.wall_unix_ms(), inner.clock.mono_ms(), level, ev, conn, fields);
        inner.sink.write_line(&line);
    }

    pub fn info(&self, ev: &str, conn: Option<u64>, fields: &[(&str, Value)]) {
        self.write(Level::Info, ev, conn, fields);
    }

    pub fn debug(&self, ev: &str, conn: Option<u64>, fields: &[(&str, Value)]) {
        self.write(Level::Debug, ev, conn, fields);
    }

    /// Writes a backend's diagnostic event; `ms` carries the time since the advertisement was seen.
    pub fn diag(&self, diag: &Diag) {
        let mut fields: Vec<(&str, Value)> = Vec::with_capacity(diag.fields.len() + 1);
        if let Some(ms) = diag.since_adv_ms {
            fields.push(("ms", Value::U(ms)));
        }
        fields.extend(diag.fields.iter().map(|(k, v)| (*k, v.clone())));
        let level = if diag.debug { Level::Debug } else { Level::Info };
        self.write(level, diag.ev, Some(diag.conn), &fields);
    }
}

// ---------------------------------------------------------------- files

/// `rk-2026-11-14.log`, `rk-2026-11-14.1.log`, `rk-2026-11-14.2.log`.
pub fn file_name(date: &str, index: usize) -> String {
    if index == 0 {
        format!("rk-{date}.log")
    } else {
        format!("rk-{date}.{index}.log")
    }
}

/// The day count of a log file name, `None` for any other file.
fn file_day(name: &str) -> Option<i64> {
    let rest = name.strip_prefix("rk-")?;
    let date = rest.get(..10)?;
    let tail = &rest[10..];
    let valid_tail = tail == ".log" || (tail.starts_with('.') && tail.ends_with(".log") && tail[1..tail.len() - 4].bytes().all(|b| b.is_ascii_digit()) && tail.len() > 5);
    if !valid_tail {
        return None;
    }
    let mut parts = date.split('-');
    let (y, m, d) = (parts.next()?.parse::<i64>().ok()?, parts.next()?.parse::<i64>().ok()?, parts.next()?.parse::<i64>().ok()?);
    if parts.next().is_some() || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

/// Log files older than the retention, given the names in the folder and the time now. Other files are never listed.
pub fn expired_files(names: &[String], now_unix_ms: u64) -> Vec<String> {
    let today = day_of(now_unix_ms);
    let keep_from = today - i64::try_from(RETENTION_DAYS).unwrap_or(7) + 1;
    names.iter().filter(|n| file_day(n).is_some_and(|day| day < keep_from)).cloned().collect()
}

/// The log files of the last [`RETENTION_DAYS`] days among `names`, oldest first.
pub fn recent_files(names: &[String], now_unix_ms: u64) -> Vec<String> {
    let today = day_of(now_unix_ms);
    let keep_from = today - i64::try_from(RETENTION_DAYS).unwrap_or(7) + 1;
    let mut kept: Vec<(i64, String)> =
        names.iter().filter_map(|n| file_day(n).filter(|day| *day >= keep_from).map(|day| (day, n.clone()))).collect();
    kept.sort();
    kept.into_iter().map(|(_, n)| n).collect()
}

/// Where the next line of a day goes, given the sizes of today's three files (`None` = the file does not exist).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    /// Append to this file, creating it when it does not exist.
    Append(usize),
    /// All three are full: drop the oldest, move the others down and start the last one afresh.
    ShiftThenNew,
}

pub fn choose_slot(sizes: &[Option<u64>; FILES_PER_DAY], max_bytes: u64) -> Slot {
    sizes.iter().position(|size| size.is_none_or(|bytes| bytes < max_bytes)).map_or(Slot::ShiftThenNew, Slot::Append)
}

/// Writes lines into the log folder, one file per day, three files per day at most.
pub struct FileSink {
    dir: PathBuf,
    clock: Arc<dyn Clock>,
    max_bytes: u64,
    pruned_on: Option<String>,
}

impl FileSink {
    pub fn new(dir: PathBuf, clock: Arc<dyn Clock>) -> Self {
        Self::with_max_bytes(dir, clock, MAX_FILE_BYTES)
    }

    pub fn with_max_bytes(dir: PathBuf, clock: Arc<dyn Clock>, max_bytes: u64) -> Self {
        Self { dir, clock, max_bytes, pruned_on: None }
    }

    fn prune(&mut self, today: &str) {
        if self.pruned_on.as_deref() == Some(today) {
            return;
        }
        self.pruned_on = Some(today.to_string());
        for name in expired_files(&list_names(&self.dir), self.clock.wall_unix_ms()) {
            let _ = fs::remove_file(self.dir.join(name));
        }
    }

    fn open_slot(&self, date: &str) -> Option<fs::File> {
        let size_of = |i: usize| fs::metadata(self.dir.join(file_name(date, i))).ok().map(|m| m.len());
        let sizes = [size_of(0), size_of(1), size_of(2)];
        let index = match choose_slot(&sizes, self.max_bytes) {
            Slot::Append(i) => i,
            Slot::ShiftThenNew => {
                let _ = fs::remove_file(self.dir.join(file_name(date, 0)));
                let _ = fs::rename(self.dir.join(file_name(date, 1)), self.dir.join(file_name(date, 0)));
                let _ = fs::rename(self.dir.join(file_name(date, 2)), self.dir.join(file_name(date, 1)));
                2
            }
        };
        fs::OpenOptions::new().create(true).append(true).open(self.dir.join(file_name(date, index))).ok()
    }
}

impl LogSink for FileSink {
    /// A log that cannot be written is dropped silently: logging must never take the receiver down.
    fn write_line(&mut self, line: &str) {
        let date = date_string(self.clock.wall_unix_ms());
        if fs::create_dir_all(&self.dir).is_err() {
            return;
        }
        self.prune(&date);
        if let Some(mut file) = self.open_slot(&date) {
            let _ = writeln!(file, "{line}");
        }
    }
}

/// The file names in a folder, without any path.
pub fn list_names(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .map(|entries| entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::FakeClock;

    // 2026-11-14T10:20:30.123Z
    const T0: u64 = 1_794_651_630_123;

    fn logger(level: Level) -> (Logger, MemorySink, Arc<FakeClock>) {
        let sink = MemorySink::new();
        let clock = Arc::new(FakeClock::new(T0));
        (Logger::new(Box::new(sink.clone()), clock.clone(), level), sink, clock)
    }

    #[test]
    fn rfc3339_has_millisecond_precision_in_utc() {
        assert_eq!(rfc3339_utc_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(rfc3339_utc_ms(T0), "2026-11-14T10:20:30.123Z");
        assert_eq!(rfc3339_utc_ms(951_782_400_000 + 86_399_999), "2000-02-29T23:59:59.999Z");
    }

    #[test]
    fn line_has_the_documented_shape() {
        let (log, sink, clock) = logger(Level::Info);
        clock.advance(250);
        log.info("hello_sent", Some(3), &[("ms", Value::U(412)), ("ok", Value::B(true)), ("route", Value::S("selected"))]);
        assert_eq!(
            sink.lines(),
            vec!["wall=2026-11-14T10:20:30.373Z mono_ms=250 lvl=info ev=hello_sent conn=3 ms=412 ok=true route=selected"]
        );
    }

    #[test]
    fn line_without_a_connection_has_no_conn_field() {
        let (log, sink, _) = logger(Level::Info);
        log.info("start", None, &[]);
        assert!(!sink.lines()[0].contains("conn="));
    }

    #[test]
    fn debug_lines_are_written_only_at_debug_level() {
        let (info, info_sink, _) = logger(Level::Info);
        info.debug("att_write", Some(1), &[]);
        info.info("keep", None, &[]);
        assert_eq!(info_sink.lines().len(), 1);
        let (debug, debug_sink, _) = logger(Level::Debug);
        debug.debug("att_write", Some(1), &[]);
        assert!(debug_sink.lines()[0].contains("lvl=debug ev=att_write conn=1"));
    }

    #[test]
    fn backend_diag_carries_ms_since_adv_and_its_level() {
        let (log, sink, _) = logger(Level::Info);
        log.diag(&Diag::new(2, "discovered").at(931).with("tries", Value::U(3)));
        log.diag(&Diag::new(2, "att_call").debug());
        let lines = sink.lines();
        assert_eq!(lines.len(), 1, "the debug event is not written at info level");
        assert!(lines[0].ends_with("ev=discovered conn=2 ms=931 tries=3"), "{}", lines[0]);
    }

    #[test]
    fn file_names_per_day_and_index() {
        assert_eq!(file_name("2026-11-14", 0), "rk-2026-11-14.log");
        assert_eq!(file_name("2026-11-14", 2), "rk-2026-11-14.2.log");
    }

    #[test]
    fn files_older_than_seven_days_expire_and_other_files_are_left_alone() {
        let names: Vec<String> = [
            "rk-2026-11-14.log",
            "rk-2026-11-08.log",
            "rk-2026-11-07.log",
            "rk-2026-11-07.2.log",
            "notes.txt",
            "rk-garbage.log",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let mut expired = expired_files(&names, T0);
        expired.sort();
        assert_eq!(expired, vec!["rk-2026-11-07.2.log", "rk-2026-11-07.log"]);
    }

    #[test]
    fn recent_files_are_the_last_seven_days_oldest_first() {
        let names: Vec<String> = ["rk-2026-11-14.log", "rk-2026-11-08.1.log", "rk-2026-11-08.log", "rk-2026-11-01.log", "x"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(recent_files(&names, T0), vec!["rk-2026-11-08.1.log", "rk-2026-11-08.log", "rk-2026-11-14.log"]);
    }

    #[test]
    fn slot_is_the_first_file_with_room_and_rotates_when_all_are_full() {
        let cap = 100;
        assert_eq!(choose_slot(&[None, None, None], cap), Slot::Append(0));
        assert_eq!(choose_slot(&[Some(99), None, None], cap), Slot::Append(0));
        assert_eq!(choose_slot(&[Some(100), None, None], cap), Slot::Append(1));
        assert_eq!(choose_slot(&[Some(100), Some(150), Some(5)], cap), Slot::Append(2));
        assert_eq!(choose_slot(&[Some(100), Some(100), Some(100)], cap), Slot::ShiftThenNew);
    }

    #[test]
    fn file_sink_rotates_by_size_keeps_three_files_and_prunes_old_days() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("rk-2026-11-01.log"), "old\n").unwrap();
        fs::write(dir.path().join("keep.txt"), "x").unwrap();
        let clock = Arc::new(FakeClock::new(T0));
        let mut sink = FileSink::with_max_bytes(dir.path().to_path_buf(), clock, 40);
        let line = "0123456789012345678901234567890123456789"; // 40 bytes, so every line fills a file
        for _ in 0..4 {
            sink.write_line(line);
        }
        let mut names = list_names(dir.path());
        names.sort();
        assert_eq!(names, vec!["keep.txt", "rk-2026-11-14.1.log", "rk-2026-11-14.2.log", "rk-2026-11-14.log"]);
    }

    #[test]
    fn file_sink_survives_an_unwritable_folder() {
        let dir = tempfile::tempdir().unwrap();
        let blocker = dir.path().join("file");
        fs::write(&blocker, "x").unwrap();
        let mut sink = FileSink::new(blocker.join("logs"), Arc::new(FakeClock::new(T0)));
        sink.write_line("must not panic");
    }
}
