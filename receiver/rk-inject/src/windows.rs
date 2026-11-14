//! The Windows injector: text and pointer input through `SendInput`.
//!
//! Text is sent as `KEYEVENTF_UNICODE` events, one key-down and one key-up per UTF-16 unit, so it does not depend on the
//! keyboard layout or the input method. A pause of `char_interval_ms` sits between characters (Unicode scalars): Notepad
//! drops characters that arrive with no gap (WL1 S2), while 10 ms was enough. The two units of a surrogate pair go out in a
//! single `SendInput` call.
//!
//! The calls block the calling thread for the length of the text times the gap. The application calls the injector from its
//! own loop, not from the Bluetooth notification callback, so the callback is never held up by the gap.

use crate::win_units::{typing_schedule, utf16_inputs, KeyInput, MoveAccumulator, Step, WheelAccumulator};
use crate::{Button, InjectError, Injector};
use std::mem::size_of;
use std::time::Duration;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_HWHEEL,
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL, MOUSEINPUT,
    MOUSE_EVENT_FLAGS, VIRTUAL_KEY, VK_BACK, VK_RETURN,
};

fn key(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn mouse(dx: i32, dy: i32, data: u32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

/// Key-down then key-up of a virtual key.
fn vk_press(vk: VIRTUAL_KEY) -> [INPUT; 2] {
    [key(vk, 0, KEYBD_EVENT_FLAGS(0)), key(vk, 0, KEYEVENTF_KEYUP)]
}

/// Down and up for each UTF-16 unit, in order.
fn unicode_events(units: &[u16]) -> Vec<INPUT> {
    units.iter().flat_map(|&u| [key(VIRTUAL_KEY(0), u, KEYEVENTF_UNICODE), key(VIRTUAL_KEY(0), u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)]).collect()
}

fn events_for(input: &KeyInput) -> Vec<INPUT> {
    match input {
        KeyInput::Scalar(units) => unicode_events(units),
        KeyInput::Return => vk_press(VK_RETURN).to_vec(),
    }
}

fn button_flag(b: Button, down: bool) -> MOUSE_EVENT_FLAGS {
    match (b, down) {
        (Button::Left, true) => MOUSEEVENTF_LEFTDOWN,
        (Button::Left, false) => MOUSEEVENTF_LEFTUP,
        (Button::Right, true) => MOUSEEVENTF_RIGHTDOWN,
        (Button::Right, false) => MOUSEEVENTF_RIGHTUP,
    }
}

/// One mouse-wheel event; `units` is signed and goes into `mouseData` as its two's-complement bits, as the API wants.
fn wheel_event(flag: MOUSE_EVENT_FLAGS, units: i32) -> INPUT {
    mouse(0, 0, units as u32, flag)
}

/// Hands the events to Windows in one call. Fewer accepted than sent (blocked by another desktop, a higher-privilege window
/// or an input hook) is a failure; the kind is a fixed word, never the text.
fn send(events: &[INPUT]) -> Result<(), InjectError> {
    if events.is_empty() {
        return Ok(());
    }
    let size = i32::try_from(size_of::<INPUT>()).unwrap_or(i32::MAX);
    // SAFETY: `events` is a valid slice of fully initialised INPUT structures and `size` is the size of one.
    let accepted = unsafe { SendInput(events, size) };
    if usize::try_from(accepted).is_ok_and(|n| n == events.len()) {
        Ok(())
    } else {
        Err(InjectError::Failed("sendinput_short".into()))
    }
}

/// Types, moves and clicks with `SendInput`.
#[derive(Debug)]
pub struct WindowsInjector {
    char_interval_ms: u32,
    motion: MoveAccumulator,
    wheel_y: WheelAccumulator,
    wheel_x: WheelAccumulator,
}

impl WindowsInjector {
    /// `char_interval_ms` is the pause between typed characters; 0 means none.
    pub fn new(char_interval_ms: u32) -> Self {
        Self { char_interval_ms, motion: MoveAccumulator::new(), wheel_y: WheelAccumulator::new(), wheel_x: WheelAccumulator::new() }
    }
}

impl Injector for WindowsInjector {
    fn text(&mut self, s: &str) -> Result<(), InjectError> {
        let inputs = utf16_inputs(s);
        for step in typing_schedule(&inputs, self.char_interval_ms) {
            match step {
                Step::Send(input) => send(&events_for(input))?,
                Step::Wait(ms) => std::thread::sleep(Duration::from_millis(u64::from(ms))),
            }
        }
        Ok(())
    }

    fn backspace(&mut self) -> Result<(), InjectError> {
        send(&vk_press(VK_BACK))
    }

    fn enter(&mut self) -> Result<(), InjectError> {
        send(&vk_press(VK_RETURN))
    }

    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        let (x, y) = self.motion.push(dx, dy);
        if x == 0 && y == 0 {
            return Ok(());
        }
        send(&[mouse(x, y, 0, MOUSEEVENTF_MOVE)])
    }

    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError> {
        send(&[mouse(0, 0, 0, button_flag(b, down))])
    }

    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError> {
        let events: Vec<INPUT> = (0..count).flat_map(|_| [mouse(0, 0, 0, button_flag(b, true)), mouse(0, 0, 0, button_flag(b, false))]).collect();
        send(&events)
    }

    /// `(dx, dy)` is how far the content follows the finger, in points: the same meaning the Linux injector takes, which
    /// negates it for the system. For Windows a finger moving down (`dy > 0`) must move the content down, which is the wheel
    /// turning up: a positive `WHEEL` delta. A finger moving right (`dx > 0`) moves the content right, which is scrolling
    /// left: a negative `HWHEEL` delta, since a positive one scrolls right. 40 points make one 120-unit notch (Provisional).
    fn scroll(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        let vertical = self.wheel_y.push(dy);
        let horizontal = self.wheel_x.push(-dx);
        let mut events = Vec::with_capacity(2);
        if vertical != 0 {
            events.push(wheel_event(MOUSEEVENTF_WHEEL, vertical));
        }
        if horizontal != 0 {
            events.push(wheel_event(MOUSEEVENTF_HWHEEL, horizontal));
        }
        send(&events)
    }

    fn ready(&self) -> bool {
        true
    }

    fn path(&self) -> &'static str {
        "unicode"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit_of(event: &INPUT) -> (u16, bool) {
        // SAFETY: every event built in this module for the test is a keyboard event.
        let ki = unsafe { event.Anonymous.ki };
        (ki.wScan, ki.dwFlags.contains(KEYEVENTF_KEYUP))
    }

    #[test]
    fn a_surrogate_pair_is_four_events_in_order_in_one_call() {
        let events = events_for(&KeyInput::Scalar(vec![0xD83D, 0xDE00]));
        let seen: Vec<(u16, bool)> = events.iter().map(unit_of).collect();
        assert_eq!(seen, vec![(0xD83D, false), (0xD83D, true), (0xDE00, false), (0xDE00, true)]);
    }

    #[test]
    fn unicode_events_carry_no_virtual_key_and_the_unicode_flag() {
        let events = events_for(&KeyInput::Scalar(vec![0x61]));
        // SAFETY: keyboard events.
        let first = unsafe { events[0].Anonymous.ki };
        assert_eq!(first.wVk, VIRTUAL_KEY(0));
        assert!(first.dwFlags.contains(KEYEVENTF_UNICODE));
    }

    #[test]
    fn return_is_a_virtual_key_press() {
        let events = events_for(&KeyInput::Return);
        // SAFETY: keyboard events.
        let (down, up) = unsafe { (events[0].Anonymous.ki, events[1].Anonymous.ki) };
        assert_eq!((down.wVk, up.wVk), (VK_RETURN, VK_RETURN));
        assert!(up.dwFlags.contains(KEYEVENTF_KEYUP) && !down.dwFlags.contains(KEYEVENTF_KEYUP));
    }

    #[test]
    fn wheel_delta_keeps_its_sign_in_mouse_data() {
        // SAFETY: a mouse event.
        let data = unsafe { wheel_event(MOUSEEVENTF_WHEEL, -120).Anonymous.mi.mouseData };
        assert_eq!(data as i32, -120);
    }

    #[test]
    fn an_empty_batch_is_not_sent() {
        assert_eq!(send(&[]), Ok(()));
    }

    #[test]
    fn scroll_and_move_below_one_unit_send_nothing() {
        let mut injector = WindowsInjector::new(0);
        assert_eq!(injector.scroll(0.0, 0.1), Ok(()));
        assert_eq!(injector.pointer_move(0.2, 0.2), Ok(()));
        assert!(injector.ready());
        assert_eq!(injector.path(), "unicode");
    }
}
