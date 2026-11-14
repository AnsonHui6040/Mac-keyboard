//! Statistics over receiver diagnostic logs (`rk-diag stats`). Pure: lines in, a [`Summary`] out.
//!
//! Only counts and millisecond numbers come out; no field other than the event names, result and kind words is read.

use std::collections::BTreeMap;

/// Everything `rk-diag stats` reports.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Summary {
    /// Lines that were counted (inside the `--since` window).
    pub lines: u64,
    /// Lines without a readable `wall=` stamp; never counted.
    pub skipped_lines: u64,
    /// `adv_seen` events.
    pub connections: u64,
    /// Milliseconds from `adv_seen` to the first `auth result=ok` of each connection, sorted ascending.
    pub adv_to_auth_ms: Vec<u64>,
    pub auth_results: BTreeMap<String, u64>,
    pub disconnected: BTreeMap<String, u64>,
    pub retry: BTreeMap<String, u64>,
    pub connect_failed: BTreeMap<String, u64>,
    pub write_failed: BTreeMap<String, u64>,
    pub stale_link: u64,
    pub hold: u64,
}

/// The share of the ok connections that took at most this long.
pub const FAST_MS: u64 = 3000;

/// Parses `2026-11-14T20:23:00Z`, with optional fraction and `+hh:mm` offset, into Unix milliseconds.
pub fn parse_rfc3339_ms(text: &str) -> Option<u64> {
    let (date, rest) = text.split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (d.next()?.parse().ok()?, d.next()?.parse().ok()?, d.next()?.parse().ok()?);
    if d.next().is_some() || !(1..=12).contains(&m) || !(1..=31).contains(&day) {
        return None;
    }
    let (clock, offset_min) = if let Some(c) = rest.strip_suffix('Z') {
        (c, 0)
    } else {
        let at = rest.rfind(['+', '-'])?;
        let (c, off) = rest.split_at(at);
        let (h, mi) = off[1..].split_once(':')?;
        let minutes = h.parse::<i64>().ok()? * 60 + mi.parse::<i64>().ok()?;
        (c, if off.starts_with('-') { -minutes } else { minutes })
    };
    let mut t = clock.split(':');
    let (h, mi): (i64, i64) = (t.next()?.parse().ok()?, t.next()?.parse().ok()?);
    let sec_part = t.next()?;
    if t.next().is_some() || h > 23 || mi > 59 {
        return None;
    }
    let (sec, frac) = sec_part.split_once('.').unwrap_or((sec_part, ""));
    let sec: i64 = sec.parse().ok()?;
    if sec > 60 || !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut ms: i64 = 0;
    for (i, b) in frac.bytes().take(3).enumerate() {
        ms += i64::from(b - b'0') * [100, 10, 1][i];
    }
    let total = (days_from_civil(y, m, day) * 86_400 + h * 3600 + mi * 60 + sec - offset_min * 60) * 1000 + ms;
    u64::try_from(total).ok()
}

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Nearest-rank percentile of an ascending list; `None` for an empty list.
pub fn percentile(sorted: &[u64], percent: u64) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let n = sorted.len() as u64;
    let rank = (percent * n).div_ceil(100).clamp(1, n);
    Some(sorted[(rank - 1) as usize])
}

/// The value of the first `key=` field of a line.
fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    line.split_whitespace().find_map(|w| w.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
}

fn bump(map: &mut BTreeMap<String, u64>, kind: Option<&str>) {
    *map.entry(kind.unwrap_or("unknown").to_string()).or_insert(0) += 1;
}

/// Summarizes log lines in file order. A new run starts at every `ev=start` line, because connection numbers restart.
pub fn summarize<'a>(lines: impl IntoIterator<Item = &'a str>, since_unix_ms: Option<u64>) -> Summary {
    let mut s = Summary::default();
    let mut run = 0u64;
    let mut adv_wall: BTreeMap<(u64, u64), u64> = BTreeMap::new();
    let mut auth_ok: std::collections::BTreeSet<(u64, u64)> = std::collections::BTreeSet::new();
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let (Some(wall), Some(ev)) = (field(line, "wall").and_then(parse_rfc3339_ms), field(line, "ev")) else {
            s.skipped_lines += 1;
            continue;
        };
        if ev == "start" {
            run += 1;
        }
        if since_unix_ms.is_some_and(|since| wall < since) {
            continue;
        }
        s.lines += 1;
        let key = field(line, "conn").and_then(|c| c.parse::<u64>().ok()).map(|c| (run, c));
        match ev {
            "adv_seen" => {
                s.connections += 1;
                if let Some(key) = key {
                    adv_wall.entry(key).or_insert(wall);
                }
            }
            "auth" => {
                let result = field(line, "result");
                bump(&mut s.auth_results, result);
                if result == Some("ok") && key.is_some_and(|k| auth_ok.insert(k)) {
                    let from_field = field(line, "ms").and_then(|m| m.parse::<u64>().ok());
                    let from_wall = key.and_then(|k| adv_wall.get(&k)).map(|adv| wall.saturating_sub(*adv));
                    if let Some(ms) = from_field.or(from_wall) {
                        s.adv_to_auth_ms.push(ms);
                    }
                }
            }
            "disconnected" => bump(&mut s.disconnected, field(line, "reason")),
            "retry" => bump(&mut s.retry, field(line, "kind")),
            "connect_failed" => bump(&mut s.connect_failed, field(line, "kind")),
            "write_failed" => bump(&mut s.write_failed, field(line, "kind")),
            "stale_link" => s.stale_link += 1,
            "hold" => s.hold += 1,
            _ => {}
        }
    }
    s.adv_to_auth_ms.sort_unstable();
    s
}

/// Sort key that puts `rk-D.log` before `rk-D.1.log` and days in order; other names give `None`.
pub fn file_order_key(name: &str) -> Option<(String, u32)> {
    let rest = name.strip_prefix("rk-")?.strip_suffix(".log")?;
    let date = rest.get(..10)?;
    parse_rfc3339_ms(&format!("{date}T00:00:00Z"))?;
    match &rest[10..] {
        "" => Some((date.to_string(), 0)),
        tail => Some((date.to_string(), tail.strip_prefix('.')?.parse().ok()?)),
    }
}

fn kinds(map: &BTreeMap<String, u64>) -> String {
    if map.is_empty() {
        return "none".to_string();
    }
    map.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join(" ")
}

impl Summary {
    /// Stable plain text, one `key value…` line per fact.
    pub fn render(&self, since: Option<&str>) -> String {
        let mut out = String::from("rk-diag stats\n");
        out.push_str(&format!("window {}\n", since.map_or("all".to_string(), |s| format!("since {s}"))));
        out.push_str(&format!("lines counted={} skipped={}\n", self.lines, self.skipped_lines));
        out.push_str(&format!("connections {}\n", self.connections));
        match (self.adv_to_auth_ms.first(), self.adv_to_auth_ms.last()) {
            (Some(min), Some(max)) => {
                let v = &self.adv_to_auth_ms;
                let (median, p95) = (percentile(v, 50).unwrap_or(0), percentile(v, 95).unwrap_or(0));
                out.push_str(&format!("adv_to_auth_ms count={} min={min} median={median} p95={p95} max={max}\n", v.len()));
                let fast = v.iter().filter(|&&ms| ms <= FAST_MS).count();
                let tenths = (fast * 1000 + v.len() / 2) / v.len();
                out.push_str(&format!("share_within_{FAST_MS}ms={}.{}% ({fast}/{})\n", tenths / 10, tenths % 10, v.len()));
            }
            _ => out.push_str("adv_to_auth_ms count=0\n"),
        }
        out.push_str(&format!("auth_result {}\n", kinds(&self.auth_results)));
        out.push_str(&format!("disconnected_reason {}\n", kinds(&self.disconnected)));
        out.push_str(&format!("retry_kind {}\n", kinds(&self.retry)));
        out.push_str(&format!("connect_failed_kind {}\n", kinds(&self.connect_failed)));
        out.push_str(&format!("write_failed_kind {}\n", kinds(&self.write_failed)));
        out.push_str(&format!("stale_link {}\n", self.stale_link));
        out.push_str(&format!("hold {}\n", self.hold));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(wall: &str, ev: &str, rest: &str) -> String {
        format!("wall={wall} mono_ms=1 lvl=info ev={ev} {rest}")
    }

    #[test]
    fn percentiles_match_known_sample() {
        let sample: Vec<u64> = (1..=100).collect();
        assert_eq!(percentile(&sample, 50), Some(50));
        assert_eq!(percentile(&sample, 95), Some(95));
        assert_eq!(percentile(&sample, 100), Some(100));
        assert_eq!(percentile(&[7], 95), Some(7));
        assert_eq!(percentile(&[], 50), None);
        assert_eq!(percentile(&[10, 20, 30, 40], 50), Some(20));
    }

    #[test]
    fn rfc3339_parses_z_fraction_and_offset() {
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:01.250Z"), Some(1250));
        assert_eq!(parse_rfc3339_ms("2026-11-14T20:23:00Z"), Some(1_794_687_780_000));
        assert_eq!(parse_rfc3339_ms("1970-01-01T08:00:00+08:00"), Some(0));
        assert_eq!(parse_rfc3339_ms("yesterday"), None);
    }

    #[test]
    fn summary_counts_failures_by_kind() {
        let mut lines = vec![
            line("2026-11-14T20:00:00.000Z", "start", "version=0.1.0 phones=1"),
            line("2026-11-14T20:00:01.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:00:01.500Z", "retry", "conn=1 ms=500 attempt=1 kind=enosys"),
            line("2026-11-14T20:00:02.000Z", "retry", "conn=1 ms=900 attempt=2 kind=enosys"),
            line("2026-11-14T20:00:03.000Z", "auth", "conn=1 ms=2000 result=ok"),
            line("2026-11-14T20:00:04.000Z", "stale_link", "conn=1 ms=3000 ms=1100"),
            line("2026-11-14T20:00:04.100Z", "disconnected", "conn=1 ms=3100 reason=stale_advert"),
            line("2026-11-14T20:00:05.000Z", "adv_seen", "conn=2 ms=0 device=aa route=selected"),
            line("2026-11-14T20:00:05.400Z", "connect_failed", "conn=2 ms=400 kind=att_error"),
            line("2026-11-14T20:00:10.400Z", "auth", "conn=2 ms=5300 result=timeout"),
            line("2026-11-14T20:00:10.400Z", "hold", "conn=2 secs=10 device=aa"),
            line("2026-11-14T20:00:11.000Z", "write_failed", "conn=2 ms=5900 kind=link_lost"),
            line("2026-11-14T20:00:11.100Z", "disconnected", "conn=2 ms=6000 reason=timeout"),
        ];
        lines.push(line("2026-11-14T20:00:12.000Z", "att_write", "conn=2 ms=1 took_ms=3 result=ok"));
        let s = summarize(lines.iter().map(String::as_str), None);
        assert_eq!(s.connections, 2);
        assert_eq!(s.adv_to_auth_ms, vec![2000]);
        assert_eq!(s.auth_results.get("ok"), Some(&1));
        assert_eq!(s.auth_results.get("timeout"), Some(&1));
        assert_eq!(s.retry.get("enosys"), Some(&2));
        assert_eq!(s.connect_failed.get("att_error"), Some(&1));
        assert_eq!(s.write_failed.get("link_lost"), Some(&1));
        assert_eq!(s.disconnected.get("stale_advert"), Some(&1));
        assert_eq!(s.disconnected.get("timeout"), Some(&1));
        assert_eq!((s.stale_link, s.hold), (1, 1));
    }

    #[test]
    fn ignores_lines_from_other_runs() {
        let lines = [
            line("2026-11-14T19:00:00.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T19:00:01.000Z", "auth", "conn=1 ms=1000 result=ok"),
            line("2026-11-14T20:00:00.000Z", "start", "version=0.1.0 phones=1"),
            line("2026-11-14T20:30:00.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:30:04.000Z", "auth", "conn=1 ms=4000 result=ok"),
        ];
        let since = parse_rfc3339_ms("2026-11-14T20:23:00Z");
        let s = summarize(lines.iter().map(String::as_str), since);
        assert_eq!(s.connections, 1);
        assert_eq!(s.adv_to_auth_ms, vec![4000]);
        assert_eq!(s.lines, 2);
    }

    #[test]
    fn a_restarted_receiver_reuses_connection_numbers_without_merging() {
        let lines = [
            line("2026-11-14T20:00:00.000Z", "start", "version=0.1.0 phones=1"),
            line("2026-11-14T20:00:01.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:00:02.000Z", "auth", "conn=1 ms=1000 result=ok"),
            line("2026-11-14T20:10:00.000Z", "start", "version=0.1.0 phones=1"),
            line("2026-11-14T20:10:01.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:10:03.000Z", "auth", "conn=1 ms=2000 result=ok"),
        ];
        let s = summarize(lines.iter().map(String::as_str), None);
        assert_eq!(s.adv_to_auth_ms, vec![1000, 2000]);
    }

    #[test]
    fn real_format_lines_and_garbage() {
        let lines = [
            "wall=2026-11-14T20:05:28.778Z mono_ms=48945 lvl=info ev=adv_seen conn=2 ms=0 device=85aa8f48 route=selected",
            "wall=2026-11-14T20:05:33.538Z mono_ms=53704 lvl=info ev=auth conn=2 ms=4759 result=ok",
            "wall=2026-11-14T20:05:34.499Z mono_ms=54666 lvl=info ev=stale_link conn=2 ms=5720 ms=1141",
            "not a log line",
            "",
        ];
        let s = summarize(lines, None);
        assert_eq!(s.adv_to_auth_ms, vec![4759]);
        assert_eq!(s.stale_link, 1);
        assert_eq!(s.lines, 3);
        assert_eq!(s.skipped_lines, 1);
    }

    #[test]
    fn auth_without_ms_falls_back_to_the_wall_difference_and_only_the_first_ok_counts() {
        let lines = [
            line("2026-11-14T20:00:00.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:00:01.500Z", "auth", "conn=1 result=ok"),
            line("2026-11-14T20:00:09.000Z", "auth", "conn=1 ms=9000 result=ok"),
        ];
        let s = summarize(lines.iter().map(String::as_str), None);
        assert_eq!(s.adv_to_auth_ms, vec![1500]);
    }

    #[test]
    fn render_reports_the_fast_share_and_numbers_only() {
        let lines = [
            line("2026-11-14T20:00:00.000Z", "adv_seen", "conn=1 ms=0 device=aa route=selected"),
            line("2026-11-14T20:00:02.000Z", "auth", "conn=1 ms=2000 result=ok"),
            line("2026-11-14T20:01:00.000Z", "adv_seen", "conn=2 ms=0 device=bb route=selected"),
            line("2026-11-14T20:01:05.000Z", "auth", "conn=2 ms=5000 result=ok"),
        ];
        let text = summarize(lines.iter().map(String::as_str), None).render(Some("2026-11-14T20:00:00Z"));
        assert!(text.contains("adv_to_auth_ms count=2 min=2000 median=2000 p95=5000 max=5000"), "{text}");
        assert!(text.contains("share_within_3000ms=50.0% (1/2)"), "{text}");
        assert!(text.contains("since 2026-11-14T20:00:00Z"), "{text}");
        assert!(!text.contains("device"), "{text}");
    }

    #[test]
    fn files_sort_by_day_then_index() {
        let mut names = vec!["rk-2026-11-14.1.log", "rk-2026-11-14.log", "rk-2026-11-13.log", "notes.txt"];
        names.retain(|n| file_order_key(n).is_some());
        names.sort_by_key(|n| file_order_key(n));
        assert_eq!(names, ["rk-2026-11-13.log", "rk-2026-11-14.log", "rk-2026-11-14.1.log"]);
    }
}
