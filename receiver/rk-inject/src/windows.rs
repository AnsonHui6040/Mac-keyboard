//! The Windows injector: text and pointer input through `SendInput`.
//!
//! Text is sent as `KEYEVENTF_UNICODE` events, one key-down and one key-up per UTF-16 unit, so it does not depend on the
//! keyboard layout or the input method. A pause of `char_interval_ms` sits between characters (Unicode scalars): Notepad
//! reorders or drops characters that arrive too close together (WL1 S2: lost characters with no gap; WL8: reordering at
//! 10 ms in about 3 of 35 runs, none at 20 ms in 25 runs), which is why the default is 20 ms. The two units of a surrogate
//! pair go out in a single `SendInput` call.
//!
//! The calls block the calling thread for the length of the text times the gap. The application calls the injector from its
//! own loop, not from the Bluetooth notification callback, so the callback is never held up by the gap.
//!
//! What events to send, and what to do when Windows takes only part of a batch, is decided in [`crate::win_units`] where
//! the tests run on every host. This file only turns those events into `INPUT` structures and calls Windows.

use crate::win_units::{deliver, events_for, typing_schedule, utf16_inputs, vk_press, MoveAccumulator, RawEvent, Step, Vk, WheelAccumulator};
use crate::{Button, InjectError, Injector};
use std::mem::size_of;
use std::time::Duration;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_HWHEEL,
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL, MOUSEINPUT,
    MOUSE_EVENT_FLAGS, VIRTUAL_KEY, VK_BACK, VK_RETURN, VK_TAB,
};

fn key(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn mouse(dx: i32, dy: i32, data: u32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn virtual_key(key: Vk) -> VIRTUAL_KEY {
    match key {
        Vk::Back => VK_BACK,
        Vk::Return => VK_RETURN,
        Vk::Tab => VK_TAB,
    }
}

fn button_flag(button: Button, up: bool) -> MOUSE_EVENT_FLAGS {
    match (button, up) {
        (Button::Left, false) => MOUSEEVENTF_LEFTDOWN,
        (Button::Left, true) => MOUSEEVENTF_LEFTUP,
        (Button::Right, false) => MOUSEEVENTF_RIGHTDOWN,
        (Button::Right, true) => MOUSEEVENTF_RIGHTUP,
    }
}

/// One event as the `INPUT` structure Windows wants. A wheel delta goes into `mouseData` as its two's-complement bits.
fn to_input(event: &RawEvent) -> INPUT {
    let key_flags = |up: bool| if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    match *event {
        RawEvent::Unicode { unit, up } => key(VIRTUAL_KEY(0), unit, KEYEVENTF_UNICODE | key_flags(up)),
        RawEvent::Vk { key: vk, up } => key(virtual_key(vk), 0, key_flags(up)),
        RawEvent::Button { button, up } => mouse(0, 0, 0, button_flag(button, up)),
        RawEvent::Move { dx, dy } => mouse(dx, dy, 0, MOUSEEVENTF_MOVE),
        RawEvent::Wheel { units } => mouse(0, 0, units as u32, MOUSEEVENTF_WHEEL),
        RawEvent::HWheel { units } => mouse(0, 0, units as u32, MOUSEEVENTF_HWHEEL),
    }
}

/// Hands the events to Windows in one `SendInput` call and returns how many it took.
fn os_send(events: &[RawEvent]) -> usize {
    let inputs: Vec<INPUT> = events.iter().map(to_input).collect();
    let size = i32::try_from(size_of::<INPUT>()).unwrap_or(i32::MAX);
    // SAFETY: `inputs` is a valid slice of fully initialised INPUT structures and `size` is the size of one.
    let taken = unsafe { SendInput(&inputs, size) };
    usize::try_from(taken).unwrap_or(0)
}

/// Sends a batch, and releases what went down if Windows took only part of it.
///
/// A count short of the batch is a failure (`sendinput_short`). Known limit: Windows blocks input to a window that runs with
/// higher privileges (UIPI) without saying so; `SendInput` still returns the full count and `GetLastError` stays 0, so such
/// input is lost silently and cannot be detected here.
fn send(events: &[RawEvent]) -> Result<(), InjectError> {
    deliver(events, &mut os_send)
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
        send(&vk_press(Vk::Back))
    }

    fn enter(&mut self) -> Result<(), InjectError> {
        send(&vk_press(Vk::Return))
    }

    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        let (x, y) = self.motion.push(dx, dy);
        if x == 0 && y == 0 {
            return Ok(());
        }
        send(&[RawEvent::Move { dx: x, dy: y }])
    }

    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError> {
        send(&[RawEvent::Button { button: b, up: !down }])
    }

    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError> {
        let events: Vec<RawEvent> = (0..count).flat_map(|_| [RawEvent::Button { button: b, up: false }, RawEvent::Button { button: b, up: true }]).collect();
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
            events.push(RawEvent::Wheel { units: vertical });
        }
        if horizontal != 0 {
            events.push(RawEvent::HWheel { units: horizontal });
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

    #[test]
    #[cfg(target_pointer_width = "64")]
    fn the_input_structure_has_the_size_windows_expects_on_64_bit() {
        // SendInput refuses a call whose `cbSize` is not the size of INPUT on the running Windows (40 bytes on x86_64).
        assert_eq!(size_of::<INPUT>(), 40);
    }

    fn keyboard(event: &RawEvent) -> KEYBDINPUT {
        // SAFETY: the events used in these tests are keyboard events.
        unsafe { to_input(event).Anonymous.ki }
    }

    #[test]
    fn a_unicode_event_has_no_virtual_key_the_unit_as_scan_code_and_the_unicode_flag() {
        let down = keyboard(&RawEvent::Unicode { unit: 0xD83D, up: false });
        assert_eq!((down.wVk, down.wScan), (VIRTUAL_KEY(0), 0xD83D));
        assert!(down.dwFlags.contains(KEYEVENTF_UNICODE) && !down.dwFlags.contains(KEYEVENTF_KEYUP));
        assert!(keyboard(&RawEvent::Unicode { unit: 0x61, up: true }).dwFlags.contains(KEYEVENTF_KEYUP));
    }

    #[test]
    fn named_keys_map_to_their_virtual_keys() {
        assert_eq!(keyboard(&RawEvent::Vk { key: Vk::Back, up: false }).wVk, VK_BACK);
        assert_eq!(keyboard(&RawEvent::Vk { key: Vk::Return, up: false }).wVk, VK_RETURN);
        let up = keyboard(&RawEvent::Vk { key: Vk::Tab, up: true });
        assert_eq!(up.wVk, VK_TAB);
        assert!(up.dwFlags.contains(KEYEVENTF_KEYUP));
    }

    #[test]
    fn wheel_delta_keeps_its_sign_in_mouse_data() {
        // SAFETY: a mouse event.
        let mi = unsafe { to_input(&RawEvent::Wheel { units: -120 }).Anonymous.mi };
        assert_eq!(mi.mouseData as i32, -120);
        assert_eq!(mi.dwFlags, MOUSEEVENTF_WHEEL);
        // SAFETY: a mouse event.
        assert_eq!(unsafe { to_input(&RawEvent::HWheel { units: 120 }).Anonymous.mi.dwFlags }, MOUSEEVENTF_HWHEEL);
    }

    #[test]
    fn buttons_and_moves_map_to_their_mouse_flags() {
        // SAFETY: mouse events.
        unsafe {
            assert_eq!(to_input(&RawEvent::Button { button: Button::Right, up: false }).Anonymous.mi.dwFlags, MOUSEEVENTF_RIGHTDOWN);
            assert_eq!(to_input(&RawEvent::Button { button: Button::Left, up: true }).Anonymous.mi.dwFlags, MOUSEEVENTF_LEFTUP);
            let mi = to_input(&RawEvent::Move { dx: -3, dy: 4 }).Anonymous.mi;
            assert_eq!((mi.dx, mi.dy, mi.dwFlags), (-3, 4, MOUSEEVENTF_MOVE));
        }
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
