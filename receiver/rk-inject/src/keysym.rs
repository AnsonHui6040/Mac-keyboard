//! Everything the Linux injector decides without the operating system: keysym mapping, splitting text into typed and
//! pasted runs, move coalescing, scroll conversion and the content-free report of one injection call.

use std::time::Duration;

use crate::Button;

pub const XK_BACKSPACE: i32 = 0xff08;
pub const XK_TAB: i32 = 0xff09;
pub const XK_RETURN: i32 = 0xff0d;
pub const XK_CONTROL_L: i32 = 0xffe3;
pub const XK_LOWER_V: i32 = 0x76;
/// Unicode keysyms are `UNICODE_KEYSYM_BASE + code point`.
pub const UNICODE_KEYSYM_BASE: i32 = 0x0100_0000;

/// Linux evdev button codes.
pub const BTN_LEFT: i32 = 272;
pub const BTN_RIGHT: i32 = 273;

/// Gap between two typed characters (S4).
pub const KEY_GAP: Duration = Duration::from_millis(3);
/// After the portal clipboard took the run, before Ctrl+V (S5).
pub const PASTE_SETTLE: Duration = Duration::from_millis(60);
/// After Ctrl+V, before the original clipboard comes back (S5): the time the focused application has to fetch the run. With
/// 250 ms, device run B5 (WL9 fix round 4, GNOME Text Editor on a loaded desktop) lost the last pasted run.
pub const PASTE_WAIT: Duration = Duration::from_millis(400);
/// Pointer moves reach the portal at most this often (S9).
pub const MOVE_MAX_HZ: u32 = 120;
/// A smooth scroll is finished this long after its last call (the trackpad design's scroll watchdog).
pub const SCROLL_IDLE: Duration = Duration::from_millis(150);

/// One notify or clipboard call of the portal gets this long before it counts as failed.
pub const PORTAL_CALL_TIMEOUT: Duration = Duration::from_secs(2);
/// How long reading the user's clipboard waits for the first clipboard owner announcement of a session (an empty clipboard
/// sends none).
pub const OWNER_WAIT: Duration = Duration::from_millis(300);
/// How long reading the data of the user's clipboard text may take, once an owner was announced.
pub const ORIGINAL_READ_TIMEOUT: Duration = Duration::from_secs(2);
/// Portal calls of one pasted run, not counting the read of the original (`OWNER_WAIT` and `ORIGINAL_READ_TIMEOUT` cover it):
/// set, two presses, two releases, then the give-back: the restore and, when it fails, two clears (an empty original gets
/// the two clears without a restore).
pub const PORTAL_CALLS_PER_PASTE: u32 = 8;

/// The longest one pasted run can take when every portal call runs into its timeout, plus a second of margin. Dropping the
/// injector waits this long for a paste in progress, because the user's clipboard is not whole until the run is given back.
pub fn paste_worst_case() -> Duration {
    PORTAL_CALL_TIMEOUT * PORTAL_CALLS_PER_PASTE + OWNER_WAIT + ORIGINAL_READ_TIMEOUT + PASTE_SETTLE + PASTE_WAIT + Duration::from_secs(1)
}

/// Provisional: portal scroll units per iPhone point.
pub const SCROLL_GAIN: f64 = 1.0;

pub fn button_code(b: Button) -> i32 {
    match b {
        Button::Left => BTN_LEFT,
        Button::Right => BTN_RIGHT,
    }
}

/// U+0020-U+007E and U+00A0-U+00FF: the legacy keysym equals the code point.
pub fn is_latin1_typable(c: char) -> bool {
    let cp = c as u32;
    (0x20..=0x7e).contains(&cp) || (0xa0..=0xff).contains(&cp)
}

pub fn keysym_for(c: char) -> i32 {
    match c {
        '\n' | '\r' => XK_RETURN,
        '\t' => XK_TAB,
        _ if is_latin1_typable(c) => c as i32,
        _ => UNICODE_KEYSYM_BASE + c as i32,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// Keysyms pressed and released one by one.
    Keys(Vec<i32>),
    /// A run of non-Latin-1 characters that goes through the portal clipboard.
    Paste(String),
}

/// Splits text into runs. Latin-1 characters, newline (Return) and tab become keysyms; other control characters are
/// dropped. Everything else is one `Paste` run per stretch when `paste_non_ascii`, else Unicode keysyms.
pub fn segment(text: &str, paste_non_ascii: bool) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\r' && chars.peek() == Some(&'\n') {
            continue;
        }
        let typed = matches!(c, '\n' | '\r' | '\t') || is_latin1_typable(c);
        if !typed && c.is_control() {
            continue;
        }
        if !typed && paste_non_ascii {
            match out.last_mut() {
                Some(Segment::Paste(run)) => run.push(c),
                _ => out.push(Segment::Paste(c.to_string())),
            }
            continue;
        }
        match out.last_mut() {
            Some(Segment::Keys(keys)) => keys.push(keysym_for(c)),
            _ => out.push(Segment::Keys(vec![keysym_for(c)])),
        }
    }
    out
}

/// Picks the text format to read from a foreign clipboard owner.
pub fn pick_text_mime(offered: &[String]) -> Option<String> {
    const PREFERRED: [&str; 3] = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"];
    PREFERRED
        .iter()
        .find(|want| offered.iter().any(|m| m == **want))
        .map(|m| (*m).to_string())
        .or_else(|| offered.iter().find(|m| m.starts_with("text/plain")).cloned())
}

/// Which way the characters of one call reached the portal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectPath {
    Keysym,
    Paste,
    Unicode,
}

impl InjectPath {
    /// The word `Injector::path` returns and the diagnostic log prints.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Keysym => "keysym",
            Self::Paste => "paste",
            Self::Unicode => "unicode",
        }
    }
}

/// How long a caller should wait for `text` to come back: a base for the portal round trips, a little per typed key,
/// and 0.9 s for every pasted run (60 ms settle, 400 ms wait, the clipboard calls).
pub fn text_budget(text: &str, base: Duration) -> Duration {
    const PER_KEY: Duration = Duration::from_millis(8);
    const PER_PASTE_RUN: Duration = Duration::from_millis(900);
    segment(text, true).iter().fold(base, |total, part| match part {
        Segment::Keys(keys) => total + PER_KEY * keys.len() as u32,
        Segment::Paste(_) => total + PER_PASTE_RUN,
    })
}

/// What the receiver may log about one injection call: never any content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InjectReport {
    pub path: InjectPath,
    pub units: usize,
    pub portal_calls: u32,
    pub error_kind: Option<&'static str>,
}

impl InjectReport {
    pub fn path_for(segments: &[Segment]) -> InjectPath {
        if segments.iter().any(|s| matches!(s, Segment::Paste(_))) {
            return InjectPath::Paste;
        }
        let unicode = segments.iter().any(|s| matches!(s, Segment::Keys(keys) if keys.iter().any(|k| *k >= UNICODE_KEYSYM_BASE)));
        if unicode {
            InjectPath::Unicode
        } else {
            InjectPath::Keysym
        }
    }
}

/// Joins pointer moves to at most `max_hz` portal calls a second. Whole pixels are sent; the fraction stays behind.
#[derive(Debug, Clone)]
pub struct MoveCoalescer {
    interval_us: u64,
    pending: (f64, f64),
    last_emit_us: Option<u64>,
}

impl MoveCoalescer {
    pub fn new(max_hz: u32) -> Self {
        Self { interval_us: 1_000_000 / u64::from(max_hz.max(1)), pending: (0.0, 0.0), last_emit_us: None }
    }

    /// Adds a move; returns what to send now, if the interval since the last send has passed.
    pub fn push(&mut self, dx: f64, dy: f64, now_us: u64) -> Option<(f64, f64)> {
        if dx.is_finite() && dy.is_finite() {
            self.pending.0 += dx;
            self.pending.1 += dy;
        }
        self.flush_due(now_us)
    }

    /// When the held-back movement may go out; `None` when nothing is worth sending.
    pub fn due_at(&self) -> Option<u64> {
        self.whole_pixels()?;
        Some(self.last_emit_us.map_or(0, |last| last + self.interval_us))
    }

    pub fn flush_due(&mut self, now_us: u64) -> Option<(f64, f64)> {
        match self.due_at() {
            Some(due) if now_us >= due => self.flush_now(now_us),
            _ => None,
        }
    }

    /// Sends what is held back regardless of the interval (before a click, so the cursor is where the finger was).
    pub fn flush_now(&mut self, now_us: u64) -> Option<(f64, f64)> {
        let (x, y) = self.whole_pixels()?;
        self.pending.0 -= x;
        self.pending.1 -= y;
        self.last_emit_us = Some(now_us);
        Some((x, y))
    }

    fn whole_pixels(&self) -> Option<(f64, f64)> {
        let whole = (self.pending.0.round(), self.pending.1.round());
        (whole != (0.0, 0.0)).then_some(whole)
    }
}

/// The finger moved (dx, dy) points and the content follows it; the portal wants the direction the view scrolls.
pub fn scroll_axis(dx: f64, dy: f64) -> (f64, f64) {
    (-dx * SCROLL_GAIN, -dy * SCROLL_GAIN)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keysym_for_ascii() {
        assert_eq!(keysym_for('a'), 0x61);
        assert_eq!(keysym_for(' '), 0x20);
        assert_eq!(keysym_for('~'), 0x7e);
    }

    #[test]
    fn keysym_for_latin1() {
        assert_eq!(keysym_for('\u{00e9}'), 0xe9);
        assert_eq!(keysym_for('\u{00a0}'), 0xa0);
        assert_eq!(keysym_for('\u{00ff}'), 0xff);
    }

    #[test]
    fn keysym_for_supplementary_plane() {
        assert_eq!(keysym_for('\u{1F600}'), 0x0101_F600);
        assert_eq!(keysym_for('\u{4e2d}'), 0x0100_4e2d);
        assert_eq!(keysym_for('\u{0100}'), 0x0100_0100);
    }

    #[test]
    fn newline_and_tab_are_keys() {
        assert_eq!(keysym_for('\n'), XK_RETURN);
        assert_eq!(keysym_for('\t'), XK_TAB);
    }

    #[test]
    fn segments_split_latin1_and_other() {
        assert_eq!(
            segment("abc\u{4e2d}\u{6587}d\u{e9}\u{1F600}", true),
            vec![
                Segment::Keys(vec![0x61, 0x62, 0x63]),
                Segment::Paste("\u{4e2d}\u{6587}".to_string()),
                Segment::Keys(vec![0x64, 0xe9]),
                Segment::Paste("\u{1F600}".to_string()),
            ]
        );
    }

    #[test]
    fn zwj_sequence_stays_in_one_paste_run() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        assert_eq!(segment(family, true), vec![Segment::Paste(family.to_string())]);
    }

    #[test]
    fn non_latin1_is_unicode_keysyms_when_paste_is_off() {
        assert_eq!(segment("a\u{4e2d}", false), vec![Segment::Keys(vec![0x61, 0x0100_4e2d])]);
    }

    #[test]
    fn newline_splits_paste_runs_and_crlf_is_one_return() {
        assert_eq!(
            segment("\u{4e2d}\r\n\u{6587}", true),
            vec![
                Segment::Paste("\u{4e2d}".to_string()),
                Segment::Keys(vec![XK_RETURN]),
                Segment::Paste("\u{6587}".to_string()),
            ]
        );
    }

    #[test]
    fn other_control_characters_are_dropped() {
        assert_eq!(segment("a\u{0}\u{7f}\u{85}b", true), vec![Segment::Keys(vec![0x61, 0x62])]);
        assert!(segment("", true).is_empty());
    }

    #[test]
    fn text_mime_prefers_utf8_plain_text() {
        let offered = |m: &[&str]| m.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            pick_text_mime(&offered(&["image/png", "text/plain", "text/plain;charset=utf-8"])),
            Some("text/plain;charset=utf-8".to_string())
        );
        assert_eq!(pick_text_mime(&offered(&["text/plain;charset=iso-8859-1"])), Some("text/plain;charset=iso-8859-1".to_string()));
        assert_eq!(pick_text_mime(&offered(&["image/png"])), None);
    }

    #[test]
    fn path_is_paste_then_unicode_then_keysym() {
        let paste = segment("a\u{4e2d}", true);
        let unicode = segment("a\u{4e2d}", false);
        let plain = segment("abc", true);
        assert_eq!(InjectReport::path_for(&paste), InjectPath::Paste);
        assert_eq!(InjectReport::path_for(&unicode), InjectPath::Unicode);
        assert_eq!(InjectReport::path_for(&plain), InjectPath::Keysym);
    }

    #[test]
    fn inject_path_names_match_the_trait_doc() {
        assert_eq!(InjectPath::Keysym.as_str(), "keysym");
        assert_eq!(InjectPath::Paste.as_str(), "paste");
        assert_eq!(InjectPath::Unicode.as_str(), "unicode");
    }

    #[test]
    fn text_budget_grows_with_typed_keys_and_paste_runs() {
        let base = Duration::from_secs(2);
        assert_eq!(text_budget("", base), base);
        let typed = text_budget(&"a".repeat(100), base);
        assert!(typed > base && typed < base + Duration::from_secs(5), "{typed:?}");
        let pasted = text_budget("a\u{4e2d}b\u{6587}c\u{1F600}", base);
        assert!(pasted >= base + Duration::from_millis(3 * 700), "{pasted:?}");
    }

    #[test]
    fn paste_wait_gives_the_target_400_ms_to_fetch_the_run() {
        // Device run B5 (fix round 4) lost the last pasted run with 250 ms.
        assert_eq!(PASTE_WAIT, Duration::from_millis(400));
    }

    #[test]
    fn text_budget_of_a_pasted_run_leaves_room_for_its_clipboard_calls() {
        let base = Duration::from_millis(100);
        let budget = text_budget("\u{4e2d}", base);
        assert!(budget >= base + PASTE_SETTLE + PASTE_WAIT + Duration::from_millis(400), "{budget:?}");
    }

    #[test]
    fn paste_worst_case_covers_every_portal_call_of_one_run() {
        let worst = paste_worst_case();
        let calls = PORTAL_CALL_TIMEOUT * PORTAL_CALLS_PER_PASTE;
        assert!(worst >= calls + OWNER_WAIT + ORIGINAL_READ_TIMEOUT + PASTE_SETTLE + PASTE_WAIT + Duration::from_secs(1), "{worst:?}");
        assert!(worst < Duration::from_secs(60), "{worst:?}");
    }

    #[test]
    fn moves_coalesce_to_120_per_second() {
        let mut c = MoveCoalescer::new(MOVE_MAX_HZ);
        let mut sent = 0u32;
        let mut sum = 0.0;
        for i in 0..1000u64 {
            if let Some((dx, dy)) = c.push(1.0, 0.0, i * 1000) {
                assert_eq!(dy, 0.0);
                sent += 1;
                sum += dx;
            }
        }
        assert!((100..=121).contains(&sent), "sent {sent} calls for one second of input");
        let (rest, _) = c.flush_now(1_000_000).unwrap_or((0.0, 0.0));
        assert_eq!(sum + rest, 1000.0);
    }

    #[test]
    fn fractional_moves_keep_their_remainder() {
        let mut c = MoveCoalescer::new(MOVE_MAX_HZ);
        assert_eq!(c.push(0.2, 0.0, 0), None);
        assert_eq!(c.due_at(), None);
        assert_eq!(c.push(0.2, 0.0, 10_000), None);
        assert_eq!(c.push(0.2, 0.0, 20_000), Some((1.0, 0.0)));
        assert_eq!(c.flush_now(30_000), None);
    }

    #[test]
    fn held_back_move_is_due_after_the_interval() {
        let mut c = MoveCoalescer::new(MOVE_MAX_HZ);
        assert_eq!(c.push(5.0, 0.0, 1_000_000), Some((5.0, 0.0)));
        assert_eq!(c.push(3.0, -2.0, 1_001_000), None);
        let due = c.due_at().expect("a move is waiting");
        assert_eq!(due, 1_000_000 + 8_333);
        assert_eq!(c.flush_due(due - 1), None);
        assert_eq!(c.flush_due(due), Some((3.0, -2.0)));
        assert_eq!(c.due_at(), None);
    }

    #[test]
    fn non_finite_moves_are_ignored() {
        let mut c = MoveCoalescer::new(MOVE_MAX_HZ);
        assert_eq!(c.push(f64::NAN, 1.0, 0), None);
        assert_eq!(c.push(f64::INFINITY, 1.0, 0), None);
        assert_eq!(c.flush_now(0), None);
    }

    #[test]
    fn scroll_content_follows_the_finger() {
        assert_eq!(scroll_axis(0.0, 10.0), (0.0, -10.0));
        assert_eq!(scroll_axis(-4.0, 0.0), (4.0, 0.0));
    }
}
