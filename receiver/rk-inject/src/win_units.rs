//! The parts of the Windows injector that need no Windows: how text becomes key inputs, when to pause between them, and how
//! small pointer and wheel movements add up to whole units.
//!
//! Kept apart from `windows.rs` so the Mac and CI test runs cover them.

use std::fmt;

/// One thing to type: either one Unicode scalar as its UTF-16 units, or the Enter key.
///
/// A scalar outside the BMP is two units (a surrogate pair). `SendInput` takes those back to back as one call; the pause
/// between characters goes between scalars, never between the two halves of a pair.
#[derive(Clone, PartialEq, Eq)]
pub enum KeyInput {
    /// The UTF-16 units of one scalar (one or two), in order.
    Scalar(Vec<u16>),
    /// A line break in the text becomes the Enter key; a Unicode `\n` would not make a new line in every program.
    Return,
}

/// The text is never written to a log, so neither is it in `Debug` output.
impl fmt::Debug for KeyInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Scalar(units) => write!(f, "Scalar({} units)", units.len()),
            Self::Return => f.write_str("Return"),
        }
    }
}

/// Splits `text` into key inputs, one per Unicode scalar. `\r\n`, `\n` and a lone `\r` each become one [`KeyInput::Return`].
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
            '\n' => out.push(KeyInput::Return),
            _ => {
                let mut buf = [0u16; 2];
                out.push(KeyInput::Scalar(c.encode_utf16(&mut buf).to_vec()));
            }
        }
    }
    out
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
                KeyInput::Return => vec![],
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
