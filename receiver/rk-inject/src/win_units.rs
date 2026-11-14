//! The parts of the Windows injector that need no Windows: how text becomes key inputs, when to pause between them, and how
//! small pointer and wheel movements add up to whole units.
//!
//! Kept apart from `windows.rs` so the Mac and CI test runs cover them.

use crate::{Button, InjectError};
use std::fmt;

/// One thing to type: one Unicode scalar as its UTF-16 units, or the Enter or Tab key.
///
/// A scalar outside the BMP is two units (a surrogate pair). `SendInput` takes those back to back as one call; the pause
/// between characters goes between scalars, never between the two halves of a pair.
#[derive(Clone, PartialEq, Eq)]
pub enum KeyInput {
    /// The UTF-16 units of one scalar (one or two), in order.
    Scalar(Vec<u16>),
    /// A line break in the text becomes the Enter key; a Unicode `\n` would not make a new line in every program.
    Return,
    /// A tab character becomes the Tab key, as on Linux.
    Tab,
}

/// The text is never written to a log, so neither is it in `Debug` output.
impl fmt::Debug for KeyInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Scalar(units) => write!(f, "Scalar({} units)", units.len()),
            Self::Return => f.write_str("Return"),
            Self::Tab => f.write_str("Tab"),
        }
    }
}

/// Splits `text` into key inputs, one per Unicode scalar.
///
/// - `\r\n`, `\n`, a lone `\r`, U+2028 and U+2029 each become one [`KeyInput::Return`]; `\t` becomes [`KeyInput::Tab`].
/// - Every other control character (U+0000 to U+001F, U+007F) is dropped. Sent as a Unicode key event, some programs act on
///   it as the key it stands for: Backspace (U+0008) deletes, Escape (U+001B) closes dialogs, U+0003 is Ctrl+C in a console.
///   Text from a phone must never be able to do that.
pub fn utf16_inputs(text: &str) -> Vec<KeyInput> {
    let mut out = Vec::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push(KeyInput::Return);
            }
            '\n' | '\u{2028}' | '\u{2029}' => out.push(KeyInput::Return),
            '\t' => out.push(KeyInput::Tab),
            c if c.is_ascii_control() => {}
            _ => {
                let mut buf = [0u16; 2];
                out.push(KeyInput::Scalar(c.encode_utf16(&mut buf).to_vec()));
            }
        }
    }
    out
}

/// The virtual keys the injector presses by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vk {
    Back,
    Return,
    Tab,
}

/// One input event in terms of what it does, free of any Windows type. `windows.rs` turns each into an `INPUT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawEvent {
    /// A `KEYEVENTF_UNICODE` key event for one UTF-16 unit.
    Unicode { unit: u16, up: bool },
    Vk { key: Vk, up: bool },
    Button { button: Button, up: bool },
    Move { dx: i32, dy: i32 },
    /// Vertical wheel, signed units (positive turns the wheel up).
    Wheel { units: i32 },
    /// Horizontal wheel, signed units (positive scrolls right).
    HWheel { units: i32 },
}

/// The events of one key press of a virtual key: down, then up.
pub fn vk_press(key: Vk) -> [RawEvent; 2] {
    [RawEvent::Vk { key, up: false }, RawEvent::Vk { key, up: true }]
}

/// The events that type one [`KeyInput`]: down and up for each UTF-16 unit in order, or a press of the named key.
pub fn events_for(input: &KeyInput) -> Vec<RawEvent> {
    match input {
        KeyInput::Scalar(units) => units.iter().flat_map(|&unit| [RawEvent::Unicode { unit, up: false }, RawEvent::Unicode { unit, up: true }]).collect(),
        KeyInput::Return => vk_press(Vk::Return).to_vec(),
        KeyInput::Tab => vk_press(Vk::Tab).to_vec(),
    }
}

/// The key-up and button-up events still owed for the keys and buttons that `sent` pressed and did not release, the one
/// pressed last first.
fn pending_releases(sent: &[RawEvent]) -> Vec<RawEvent> {
    let mut down: Vec<RawEvent> = Vec::new();
    for &event in sent {
        match event {
            RawEvent::Unicode { unit, up: false } => down.push(RawEvent::Unicode { unit, up: false }),
            RawEvent::Vk { key, up: false } => down.push(RawEvent::Vk { key, up: false }),
            RawEvent::Button { button, up: false } => down.push(RawEvent::Button { button, up: false }),
            RawEvent::Unicode { unit, up: true } => down.retain(|d| *d != RawEvent::Unicode { unit, up: false }),
            RawEvent::Vk { key, up: true } => down.retain(|d| *d != RawEvent::Vk { key, up: false }),
            RawEvent::Button { button, up: true } => down.retain(|d| *d != RawEvent::Button { button, up: false }),
            RawEvent::Move { .. } | RawEvent::Wheel { .. } | RawEvent::HWheel { .. } => {}
        }
    }
    down.into_iter()
        .rev()
        .map(|event| match event {
            RawEvent::Unicode { unit, .. } => RawEvent::Unicode { unit, up: true },
            RawEvent::Vk { key, .. } => RawEvent::Vk { key, up: true },
            RawEvent::Button { button, .. } => RawEvent::Button { button, up: true },
            other => other,
        })
        .collect()
}

/// Hands `events` to `send` (which returns how many Windows took, always from the front) and checks the answer.
///
/// All taken: `Ok`. Fewer taken: the keys and buttons that already went down are released with a second call (best effort)
/// so nothing stays pressed, and the result is `Failed("sendinput_short")`; the kind is a fixed word, never the text.
pub fn deliver(events: &[RawEvent], send: &mut dyn FnMut(&[RawEvent]) -> usize) -> Result<(), InjectError> {
    if events.is_empty() {
        return Ok(());
    }
    let taken = send(events).min(events.len());
    if taken == events.len() {
        return Ok(());
    }
    let release = pending_releases(&events[..taken]);
    if !release.is_empty() {
        let _ = send(&release);
    }
    Err(InjectError::Failed("sendinput_short".into()))
}

/// One step of typing a batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step<'a> {
    Send(&'a KeyInput),
    /// Sleep this many milliseconds.
    Wait(u32),
}

/// The order of sends and pauses for `inputs`: a pause of `interval_ms` between two characters, none before the first or
/// after the last, none at all when `interval_ms` is 0.
pub fn typing_schedule(inputs: &[KeyInput], interval_ms: u32) -> Vec<Step<'_>> {
    let mut steps = Vec::with_capacity(inputs.len() * 2);
    for (i, input) in inputs.iter().enumerate() {
        if i > 0 && interval_ms > 0 {
            steps.push(Step::Wait(interval_ms));
        }
        steps.push(Step::Send(input));
    }
    steps
}

/// Pointer points to wheel units: 120 units are one notch, and 40 points of finger travel make one notch (Provisional, §8.4
/// of the trackpad design and the plan's WL8).
pub const WHEEL_UNITS_PER_POINT: f64 = 120.0 / 40.0;

/// Turns scroll distances in points into whole wheel units for one axis and keeps the part that is left over, so a slow
/// scroll made of tiny steps still moves. Changing direction drops the leftover: it belonged to the old direction.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct WheelAccumulator {
    rest: f64,
}

impl WheelAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `points` of scroll (signed) and returns the whole units now due, which can be 0. A value that is not a finite
    /// number is ignored.
    pub fn push(&mut self, points: f64) -> i32 {
        if !points.is_finite() {
            return 0;
        }
        let units = points * WHEEL_UNITS_PER_POINT;
        if units != 0.0 && self.rest != 0.0 && units.is_sign_negative() != self.rest.is_sign_negative() {
            self.rest = 0.0;
        }
        let total = self.rest + units;
        let whole = total.trunc();
        self.rest = total - whole;
        whole as i32
    }
}

/// The same for pointer movement on both axes: whole pixels go out, the fraction waits for the next move.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct MoveAccumulator {
    rest_x: f64,
    rest_y: f64,
}

impl MoveAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a move in points and returns the whole pixels `(dx, dy)` now due. A value that is not finite counts as 0.
    pub fn push(&mut self, dx: f64, dy: f64) -> (i32, i32) {
        (take_whole(&mut self.rest_x, dx), take_whole(&mut self.rest_y, dy))
    }
}

fn take_whole(rest: &mut f64, value: f64) -> i32 {
    if !value.is_finite() {
        return 0;
    }
    let total = *rest + value;
    let whole = total.trunc();
    *rest = total - whole;
    whole as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn units(text: &str) -> Vec<u16> {
        utf16_inputs(text)
            .into_iter()
            .flat_map(|i| match i {
                KeyInput::Scalar(u) => u,
                KeyInput::Return | KeyInput::Tab => vec![],
            })
            .collect()
    }

    #[test]
    fn utf16_units_for_supplementary_plane() {
        assert_eq!(utf16_inputs("😀"), vec![KeyInput::Scalar(vec![0xD83D, 0xDE00])]);
        assert_eq!(utf16_inputs("a"), vec![KeyInput::Scalar(vec![0x61])]);
        assert_eq!(utf16_inputs("測"), vec![KeyInput::Scalar(vec![0x6E2C])]);
    }

    #[test]
    fn combining_sequence_keeps_order() {
        // e, then COMBINING ACUTE ACCENT: two scalars in the order they were written.
        assert_eq!(utf16_inputs("e\u{301}"), vec![KeyInput::Scalar(vec![0x65]), KeyInput::Scalar(vec![0x301])]);
    }

    #[test]
    fn empty_text_sends_nothing() {
        assert!(utf16_inputs("").is_empty());
        assert!(typing_schedule(&utf16_inputs(""), 10).is_empty());
    }

    #[test]
    fn zwj_sequence_stays_whole() {
        let family = "👨\u{200D}👩\u{200D}👧";
        let inputs = utf16_inputs(family);
        assert_eq!(inputs.len(), 5, "three people and two joiners, nothing merged or dropped");
        assert_eq!(units(family), family.encode_utf16().collect::<Vec<_>>());
        assert_eq!(inputs[1], KeyInput::Scalar(vec![0x200D]));
    }

    #[test]
    fn line_breaks_become_one_return_each() {
        assert_eq!(utf16_inputs("a\r\nb\nc\rd").iter().filter(|i| **i == KeyInput::Return).count(), 3);
        assert_eq!(units("a\r\nb"), vec![0x61, 0x62]);
    }

    #[test]
    fn control_characters_are_dropped_except_tab_and_line_breaks() {
        // Backspace, Escape, Ctrl+C, DEL, NUL, bell and vertical tab must not reach the target as characters: a program may
        // treat them as the key they stand for.
        assert_eq!(units("a\u{8}b\u{1b}c\u{3}d\u{7f}e\0f\u{7}g\u{b}h"), "abcdefgh".encode_utf16().collect::<Vec<_>>());
        assert!(utf16_inputs("\u{8}\u{1b}\u{3}\u{7f}\0").is_empty(), "nothing left to type");
        assert!(typing_schedule(&utf16_inputs("\u{8}\u{1b}"), 20).is_empty());
    }

    #[test]
    fn dropped_characters_leave_no_pause_behind() {
        let inputs = utf16_inputs("a\u{8}b");
        assert_eq!(typing_schedule(&inputs, 20).len(), 3, "two characters and one pause");
    }

    #[test]
    fn tab_becomes_the_tab_key() {
        assert_eq!(utf16_inputs("a\tb"), vec![KeyInput::Scalar(vec![0x61]), KeyInput::Tab, KeyInput::Scalar(vec![0x62])]);
    }

    #[test]
    fn line_and_paragraph_separators_become_enter() {
        assert_eq!(utf16_inputs("a\u{2028}b\u{2029}c").iter().filter(|i| **i == KeyInput::Return).count(), 2);
        assert_eq!(units("a\u{2028}b"), vec![0x61, 0x62]);
    }

    #[test]
    fn ordinary_punctuation_and_other_planes_are_kept() {
        let text = "~ !\"#%&'()*+,-./:;<=>?@[\\]^_`{|}~ é 測 😀";
        assert_eq!(units(text), text.encode_utf16().collect::<Vec<_>>());
    }

    // ---- what is handed to SendInput, and what happens when Windows takes only part of it

    fn unicode(unit: u16, up: bool) -> RawEvent {
        RawEvent::Unicode { unit, up }
    }

    #[test]
    fn a_surrogate_pair_is_four_events_down_up_per_unit_in_order() {
        let events = events_for(&KeyInput::Scalar(vec![0xD83D, 0xDE00]));
        assert_eq!(events, vec![unicode(0xD83D, false), unicode(0xD83D, true), unicode(0xDE00, false), unicode(0xDE00, true)]);
    }

    #[test]
    fn return_and_tab_are_virtual_key_presses() {
        assert_eq!(events_for(&KeyInput::Return), vec![RawEvent::Vk { key: Vk::Return, up: false }, RawEvent::Vk { key: Vk::Return, up: true }]);
        assert_eq!(events_for(&KeyInput::Tab), vec![RawEvent::Vk { key: Vk::Tab, up: false }, RawEvent::Vk { key: Vk::Tab, up: true }]);
    }

    /// A stand-in for `SendInput`: takes at most `limit` events of the first call and everything of later calls, and remembers
    /// each call.
    struct FakeSend {
        limit: usize,
        calls: Vec<Vec<RawEvent>>,
    }

    impl FakeSend {
        fn new(limit: usize) -> Self {
            Self { limit, calls: Vec::new() }
        }
        fn send(&mut self, events: &[RawEvent]) -> usize {
            self.calls.push(events.to_vec());
            if self.calls.len() == 1 {
                events.len().min(self.limit)
            } else {
                events.len()
            }
        }
    }

    #[test]
    fn a_batch_that_goes_through_is_sent_once() {
        let mut fake = FakeSend::new(usize::MAX);
        let batch = events_for(&KeyInput::Scalar(vec![0x61]));
        assert_eq!(deliver(&batch, &mut |e| fake.send(e)), Ok(()));
        assert_eq!(fake.calls, vec![batch]);
    }

    #[test]
    fn an_empty_batch_sends_nothing() {
        let mut fake = FakeSend::new(usize::MAX);
        assert_eq!(deliver(&[], &mut |e| fake.send(e)), Ok(()));
        assert!(fake.calls.is_empty());
    }

    #[test]
    fn nothing_accepted_is_the_short_error_and_nothing_needs_releasing() {
        let mut fake = FakeSend::new(0);
        let batch = events_for(&KeyInput::Scalar(vec![0x61]));
        assert_eq!(deliver(&batch, &mut |e| fake.send(e)), Err(InjectError::Failed("sendinput_short".into())));
        assert_eq!(fake.calls.len(), 1, "no release call for keys that never went down");
    }

    #[test]
    fn a_key_that_went_down_is_released_when_the_batch_stops_short() {
        let mut fake = FakeSend::new(3);
        let batch = [events_for(&KeyInput::Scalar(vec![0x61])), events_for(&KeyInput::Scalar(vec![0x62]))].concat();
        assert_eq!(deliver(&batch, &mut |e| fake.send(e)), Err(InjectError::Failed("sendinput_short".into())));
        assert_eq!(fake.calls[1], vec![unicode(0x62, true)], "b went down and never came up");
    }

    #[test]
    fn a_mouse_button_that_went_down_is_released() {
        let mut fake = FakeSend::new(1);
        let batch = [RawEvent::Button { button: Button::Left, up: false }, RawEvent::Button { button: Button::Left, up: true }];
        assert!(deliver(&batch, &mut |e| fake.send(e)).is_err());
        assert_eq!(fake.calls[1], vec![RawEvent::Button { button: Button::Left, up: true }]);
    }

    #[test]
    fn several_keys_still_down_are_released_last_pressed_first() {
        let down = [unicode(1, false), RawEvent::Vk { key: Vk::Back, up: false }, RawEvent::Button { button: Button::Right, up: false }, unicode(1, true)];
        let mut fake = FakeSend::new(3);
        assert!(deliver(&down, &mut |e| fake.send(e)).is_err());
        assert_eq!(fake.calls[1], vec![RawEvent::Button { button: Button::Right, up: true }, RawEvent::Vk { key: Vk::Back, up: true }, unicode(1, true)]);
    }

    #[test]
    fn moves_and_wheel_turns_need_no_release() {
        let batch = [RawEvent::Move { dx: 1, dy: 2 }, RawEvent::Wheel { units: 120 }, RawEvent::HWheel { units: -120 }];
        let mut fake = FakeSend::new(2);
        assert!(deliver(&batch, &mut |e| fake.send(e)).is_err());
        assert_eq!(fake.calls.len(), 1);
    }

    #[test]
    fn a_sender_claiming_more_than_it_was_given_is_not_trusted() {
        let batch = events_for(&KeyInput::Scalar(vec![0x61]));
        assert_eq!(deliver(&batch, &mut |_| 99), Ok(()));
    }

    #[test]
    fn debug_output_does_not_show_the_text() {
        let shown = format!("{:?}", utf16_inputs("機密"));
        assert!(!shown.contains("機") && !shown.contains("6E2C") && !shown.contains("27424"), "{shown}");
    }

    fn sends(steps: &[Step<'_>]) -> usize {
        steps.iter().filter(|s| matches!(s, Step::Send(_))).count()
    }

    #[test]
    fn interval_is_between_code_points_not_units() {
        let inputs = utf16_inputs("a😀b");
        let steps = typing_schedule(&inputs, 10);
        assert_eq!(steps, vec![Step::Send(&inputs[0]), Step::Wait(10), Step::Send(&inputs[1]), Step::Wait(10), Step::Send(&inputs[2])]);
        // The pair is a single send: nothing can be put between its two halves.
        assert_eq!(inputs[1], KeyInput::Scalar(vec![0xD83D, 0xDE00]));
    }

    #[test]
    fn no_pause_before_the_first_or_after_the_last_and_none_at_zero() {
        let one = utf16_inputs("x");
        assert_eq!(typing_schedule(&one, 10), vec![Step::Send(&one[0])]);
        let many = utf16_inputs("abc");
        assert_eq!(sends(&typing_schedule(&many, 0)), 3);
        assert_eq!(typing_schedule(&many, 0).len(), 3);
        assert_eq!(typing_schedule(&many, 7).len(), 5);
    }

    #[test]
    fn small_scroll_deltas_accumulate() {
        let mut wheel = WheelAccumulator::new();
        // 0.125 point is 0.375 unit; eight of them are exactly 3 units, handed out as they become whole.
        let out: Vec<i32> = (0..8).map(|_| wheel.push(0.125)).collect();
        assert_eq!(out, vec![0, 0, 1, 0, 0, 1, 0, 1]);
        assert_eq!(WheelAccumulator::new().push(40.0), 120, "40 points are one notch");
    }

    #[test]
    fn direction_change_drops_remainder() {
        let mut wheel = WheelAccumulator::new();
        assert_eq!(wheel.push(0.25), 0, "0.75 unit is held back");
        // Kept, 0.75 - 1.5 would give 0; dropped, -1.5 gives -1.
        assert_eq!(wheel.push(-0.5), -1);
        assert_eq!(wheel.push(-0.25), -1, "the -0.5 left over carries on in the new direction: -0.5 - 0.75");
    }

    #[test]
    fn non_finite_scroll_and_move_values_are_ignored() {
        let mut wheel = WheelAccumulator::new();
        assert_eq!(wheel.push(f64::NAN), 0);
        assert_eq!(wheel.push(f64::INFINITY), 0);
        assert_eq!(wheel.push(40.0), 120, "the accumulator was not poisoned");
        let mut mv = MoveAccumulator::new();
        assert_eq!(mv.push(f64::NAN, f64::NEG_INFINITY), (0, 0));
        assert_eq!(mv.push(1.0, 2.0), (1, 2));
    }

    #[test]
    fn fractional_moves_accumulate() {
        let mut mv = MoveAccumulator::new();
        let out: Vec<(i32, i32)> = (0..4).map(|_| mv.push(0.5, 0.25)).collect();
        assert_eq!(out, vec![(0, 0), (1, 0), (0, 0), (1, 1)]);
        let mut back = MoveAccumulator::new();
        assert_eq!(back.push(-0.75, 0.0), (0, 0));
        assert_eq!(back.push(-0.75, 0.0), (-1, 0), "-1.5 leaves -0.5 behind, truncated toward zero");
        assert_eq!(back.push(-0.5, 0.0), (-1, 0));
    }
}
