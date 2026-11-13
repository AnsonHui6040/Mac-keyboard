//! The pointer plaintext, the host's button and scroll logic and the movement playout (protocol v4 §8.3 to §8.5).
//!
//! Everything here is a pure state machine: time arrives as microseconds on the caller's monotonic clock, and the result is
//! a list of abstract [`PointerAction`]s for an injection backend to perform. Nothing here logs.

use crate::channel::{ChannelOpenError, ChannelSet};
use crate::message::AckResult;
use std::fmt;

/// Length of the pointer plaintext (§8.3).
pub const PAYLOAD_LEN: usize = 16;

/// The `opcode` of a pointer packet (§8.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opcode {
    Move = 0x01,
    Scroll = 0x02,
    Click = 0x10,
    ButtonState = 0x11,
    Heartbeat = 0x12,
}

impl Opcode {
    fn from_byte(b: u8) -> Option<Self> {
        Some(match b {
            0x01 => Self::Move,
            0x02 => Self::Scroll,
            0x10 => Self::Click,
            0x11 => Self::ButtonState,
            0x12 => Self::Heartbeat,
            _ => return None,
        })
    }
}

/// The `arg` of a scroll packet (§8.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollPhase {
    Changed = 0,
    Began = 1,
    Ended = 2,
    Cancelled = 3,
}

impl ScrollPhase {
    fn from_byte(b: u8) -> Option<Self> {
        Some(match b {
            0 => Self::Changed,
            1 => Self::Began,
            2 => Self::Ended,
            3 => Self::Cancelled,
            _ => return None,
        })
    }
}

const LEFT_BUTTON_BIT: u8 = 0x01;
const RESERVED_BUTTON_BITS: u8 = 0x0C;
const RESERVED_STATUS_BITS: u8 = 0xF8;

/// The 16-byte plaintext of a pointer packet (§8.3). `dx` and `dy` are in 1/16 of a phone point, `dt` in tenths of a
/// millisecond.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct PointerPayload {
    pub opcode: Opcode,
    pub buttons: u8,
    pub dx: i16,
    pub dy: i16,
    pub dt: u16,
    pub action_id: u32,
    pub arg: u8,
    pub status: u8,
    pub button_seq: u16,
}

impl fmt::Debug for PointerPayload {
    /// Only the opcode: no displacement, timing or button state reaches a log.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PointerPayload {{ opcode: {:?} }}", self.opcode)
    }
}

impl PointerPayload {
    /// A packet with `action_id`, `arg` and `status` at 0.
    pub fn new(opcode: Opcode, buttons: u8, dx: i16, dy: i16, dt: u16, button_seq: u16) -> Self {
        Self { opcode, buttons, dx, dy, dt, action_id: 0, arg: 0, status: 0, button_seq }
    }

    /// `None` when the whole packet is unreadable (§8.3): length not 16, unknown `opcode`, a bit that must be zero is not,
    /// a scroll `arg` above 3, a click button above 1 or a click count outside 1 to 3.
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let b: &[u8; PAYLOAD_LEN] = bytes.try_into().ok()?;
        let opcode = Opcode::from_byte(b[0])?;
        if b[1] & RESERVED_BUTTON_BITS != 0 || b[13] & RESERVED_STATUS_BITS != 0 {
            return None;
        }
        let arg = b[12];
        match opcode {
            Opcode::Scroll => {
                ScrollPhase::from_byte(arg)?;
            }
            Opcode::Click => {
                // Bits 2-3 are reserved, only the left and right button exist, and a count is 1 to 3.
                if arg & 0x0C != 0 || arg & 0x03 > 1 || !(1..=3).contains(&(arg >> 4)) {
                    return None;
                }
            }
            Opcode::Move | Opcode::ButtonState | Opcode::Heartbeat => {}
        }
        Some(Self {
            opcode,
            buttons: b[1],
            dx: i16::from_be_bytes([b[2], b[3]]),
            dy: i16::from_be_bytes([b[4], b[5]]),
            dt: u16::from_be_bytes([b[6], b[7]]),
            action_id: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
            arg,
            status: b[13],
            button_seq: u16::from_be_bytes([b[14], b[15]]),
        })
    }

    /// The 16 plaintext bytes.
    pub fn encode(&self) -> [u8; PAYLOAD_LEN] {
        let mut b = [0u8; PAYLOAD_LEN];
        b[0] = self.opcode as u8;
        b[1] = self.buttons;
        b[2..4].copy_from_slice(&self.dx.to_be_bytes());
        b[4..6].copy_from_slice(&self.dy.to_be_bytes());
        b[6..8].copy_from_slice(&self.dt.to_be_bytes());
        b[8..12].copy_from_slice(&self.action_id.to_be_bytes());
        b[12] = self.arg;
        b[13] = self.status;
        b[14..16].copy_from_slice(&self.button_seq.to_be_bytes());
        b
    }

    /// `buttons` bit 0: the left button is held.
    pub fn left_down(&self) -> bool {
        self.buttons & LEFT_BUTTON_BIT != 0
    }

    /// The phase of a scroll packet; `None` for other opcodes.
    pub fn scroll_phase(&self) -> Option<ScrollPhase> {
        (self.opcode == Opcode::Scroll).then(|| ScrollPhase::from_byte(self.arg)).flatten()
    }

    /// The button of a click: 0 left, 1 right.
    pub fn click_button(&self) -> u8 {
        self.arg & 0x03
    }

    /// The count of a click: 1 to 3.
    pub fn click_count(&self) -> u8 {
        self.arg >> 4
    }

    /// The `arg` of a click: count in the high 4 bits, button in the low 2.
    pub fn click_arg(button: u8, count: u8) -> u8 {
        (count << 4) | (button & 0x03)
    }
}

/// `a` is newer than `b` in 16-bit sequence arithmetic: `0 < (a - b) mod 65536 < 32768` (§8.4).
pub fn is_newer_button_seq(a: u16, b: u16) -> bool {
    let difference = a.wrapping_sub(b);
    difference != 0 && difference < 0x8000
}

/// What the host does for a packet, in terms an injection backend understands. Distances are in host points after the
/// speed curve.
#[derive(Clone, Copy, PartialEq)]
pub enum PointerAction {
    /// Move the cursor; `dragging` posts a drag instead of a move.
    Move { dx: f64, dy: f64, dragging: bool },
    Click { count: u8 },
    RightClick,
    LeftButton { down: bool },
    Scroll { dx: f64, dy: f64, phase: ScrollPhase },
}

impl fmt::Debug for PointerAction {
    /// The kind of action only: no displacement.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Move { dragging, .. } => write!(f, "Move {{ dragging: {dragging} }}"),
            Self::Click { count } => write!(f, "Click {{ count: {count} }}"),
            Self::RightClick => f.write_str("RightClick"),
            Self::LeftButton { down } => write!(f, "LeftButton {{ down: {down} }}"),
            Self::Scroll { phase, .. } => write!(f, "Scroll {{ phase: {phase:?} }}"),
        }
    }
}

/// The speed curve of the cursor: `g(v) = g0 + (gmax - g0) * v^2 / (v^2 + v0^2)`, `v` being the finger speed in points per
/// second. The curve is a receiver policy, not part of the wire format; the constants are those of the Mac receiver.
pub mod acceleration {
    pub const BASE_GAIN: f64 = 1.25;
    pub const MAX_GAIN: f64 = 3.5;
    pub const KNEE_SPEED: f64 = 550.0;
    pub const MIN_DT_SECONDS: f64 = 0.005;
    pub const MAX_DT_SECONDS: f64 = 0.150;

    /// The gain at a finger speed in points per second.
    pub fn gain(speed: f64) -> f64 {
        let v2 = speed * speed;
        BASE_GAIN + (MAX_GAIN - BASE_GAIN) * v2 / (v2 + KNEE_SPEED * KNEE_SPEED)
    }

    /// `dt` of a packet as seconds, clamped to 5 to 150 ms so a first packet or one after a long stall does not read as
    /// an extreme speed.
    pub fn seconds(dt_tenths_ms: u16) -> f64 {
        (f64::from(dt_tenths_ms) * 0.0001).clamp(MIN_DT_SECONDS, MAX_DT_SECONDS)
    }

    /// The cursor movement for a packet's displacement in 1/16 points.
    pub fn scaled(dx_sixteenths: i16, dy_sixteenths: i16, dt_tenths_ms: u16) -> (f64, f64) {
        let dx = f64::from(dx_sixteenths) / 16.0;
        let dy = f64::from(dy_sixteenths) / 16.0;
        let speed = dx.hypot(dy) / seconds(dt_tenths_ms);
        let g = gain(speed);
        (dx * g, dy * g)
    }
}

/// Left button is released 350 ms after the last packet (§8.4).
pub const BUTTON_WATCHDOG_MICROS: u64 = 350_000;
/// A scroll is ended 150 ms after the last packet (§8.4).
pub const SCROLL_WATCHDOG_MICROS: u64 = 150_000;

/// The button, click and scroll rules of §8.3 and §8.4 as a state machine. It is handed packets that already passed the
/// replay window and `PointerPayload::decode`.
///
/// - The left button follows the `buttons` of the newest `buttonSeq` seen. A packet with the same or an older `buttonSeq`
///   never changes it. The first packet is applied as it is.
/// - Buttons are applied before the opcode: a move that carries a newer left-button press is a drag, a click that carries
///   one does not click.
/// - Every readable packet restarts the watchdog. After a watchdog release the `buttonSeq` stays, so only a newer one
///   presses again.
#[derive(Debug, Default)]
pub struct PointerEngine {
    left_down: bool,
    scrolling: bool,
    last_button_seq: Option<u16>,
    last_packet_at: u64,
}

impl PointerEngine {
    /// Nothing held, no button history.
    pub fn new() -> Self {
        Self::default()
    }

    /// The left button is held.
    pub fn left_down(&self) -> bool {
        self.left_down
    }

    /// A scroll is going.
    pub fn is_scrolling(&self) -> bool {
        self.scrolling
    }

    /// The watchdog has something to watch.
    pub fn needs_watchdog(&self) -> bool {
        self.left_down || self.scrolling
    }

    /// Applies one readable packet.
    pub fn handle(&mut self, payload: &PointerPayload, now_micros: u64) -> Vec<PointerAction> {
        self.last_packet_at = now_micros;
        let mut actions = Vec::new();
        self.apply_buttons(payload, &mut actions);
        match payload.opcode {
            Opcode::Move => {
                if payload.dx != 0 || payload.dy != 0 {
                    let (dx, dy) = acceleration::scaled(payload.dx, payload.dy, payload.dt);
                    actions.push(PointerAction::Move { dx, dy, dragging: self.left_down });
                }
            }
            Opcode::Scroll => self.scroll(payload, &mut actions),
            Opcode::Click => {
                // Not in the middle of a drag.
                if !self.left_down {
                    match payload.click_button() {
                        0 => actions.push(PointerAction::Click { count: payload.click_count() }),
                        1 => actions.push(PointerAction::RightClick),
                        _ => {}
                    }
                }
            }
            Opcode::ButtonState | Opcode::Heartbeat => {}
        }
        actions
    }

    /// Called regularly while `needs_watchdog`.
    pub fn watchdog(&mut self, now_micros: u64) -> Vec<PointerAction> {
        let mut actions = Vec::new();
        let silent = now_micros.wrapping_sub(self.last_packet_at);
        if self.left_down && silent >= BUTTON_WATCHDOG_MICROS {
            self.left_down = false;
            actions.push(PointerAction::LeftButton { down: false });
        }
        if self.scrolling && silent >= SCROLL_WATCHDOG_MICROS {
            self.scrolling = false;
            actions.push(PointerAction::Scroll { dx: 0.0, dy: 0.0, phase: ScrollPhase::Ended });
        }
        actions
    }

    /// The channel is over: release what is held and forget the button history, so a new session starts from nothing.
    pub fn reset(&mut self) -> Vec<PointerAction> {
        let mut actions = Vec::new();
        if self.left_down {
            actions.push(PointerAction::LeftButton { down: false });
        }
        if self.scrolling {
            actions.push(PointerAction::Scroll { dx: 0.0, dy: 0.0, phase: ScrollPhase::Ended });
        }
        *self = Self::default();
        actions
    }

    fn apply_buttons(&mut self, payload: &PointerPayload, actions: &mut Vec<PointerAction>) {
        if let Some(last) = self.last_button_seq {
            if !is_newer_button_seq(payload.button_seq, last) {
                return;
            }
        }
        self.last_button_seq = Some(payload.button_seq);
        let wants_down = payload.left_down();
        if wants_down != self.left_down {
            self.left_down = wants_down;
            actions.push(PointerAction::LeftButton { down: wants_down });
        }
    }

    fn scroll(&mut self, payload: &PointerPayload, actions: &mut Vec<PointerAction>) {
        let dx = f64::from(payload.dx) / 16.0;
        let dy = f64::from(payload.dy) / 16.0;
        match payload.scroll_phase() {
            Some(ScrollPhase::Began | ScrollPhase::Changed) => {
                // A `changed` with no `began` before it starts the scroll.
                let phase = if self.scrolling { ScrollPhase::Changed } else { ScrollPhase::Began };
                self.scrolling = true;
                actions.push(PointerAction::Scroll { dx, dy, phase });
            }
            Some(ScrollPhase::Ended | ScrollPhase::Cancelled) => {
                // Only ends a scroll that is going; the displacement of the packet is dropped.
                if self.scrolling {
                    self.scrolling = false;
                    actions.push(PointerAction::Scroll { dx: 0.0, dy: 0.0, phase: ScrollPhase::Ended });
                }
            }
            None => {}
        }
    }
}

/// A share of movement that has become due.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlayoutShare {
    pub dx: f64,
    pub dy: f64,
    pub dragging: bool,
}

#[derive(Debug, Clone, Copy)]
struct Segment {
    /// What is still to be played, spread evenly over `from`..`end`.
    dx: f64,
    dy: f64,
    dragging: bool,
    from: f64,
    end: f64,
}

/// Spreads the cursor movement of received move packets over time, so the cursor glides instead of jumping when the radio
/// delivers packets in bunches. Time is passed in; the caller asks for a share once per screen refresh.
///
/// Each `enqueue` becomes a segment: its displacement is played out evenly over the time the phone measured for it (clamped
/// to 4 to 50 ms; none given means 8 ms). A segment starts at `now`, or where the previous one ends when that is later.
/// When the last segment would end more than the allowed lag after `now`, what is still to be played is squeezed so that it
/// ends exactly that far ahead; the allowed lag is 20 ms, or the new segment's span plus 5 ms when that is more. `take`
/// hands out what has become due; movements with a different `dragging` state are never added into one output. `flush`
/// hands out everything left, `discard` drops it. The displacement that goes in is the displacement that comes out, up to
/// floating-point rounding. The constants are Provisional until measured on a device.
#[derive(Debug, Default)]
pub struct PointerPlayout {
    segments: Vec<Segment>,
    last_end: f64,
    squeeze_count: u64,
}

impl PointerPlayout {
    /// The lag floor in microseconds.
    pub const MAX_LAG_MICROS: u64 = 20_000;
    /// Shortest span in microseconds.
    pub const MIN_SPAN_MICROS: u64 = 4_000;
    /// Longest span in microseconds.
    pub const MAX_SPAN_MICROS: u64 = 50_000;
    /// Added to a segment's own span for the lag bound.
    pub const LAG_MARGIN_MICROS: u64 = 5_000;
    /// The span used when a packet did not say.
    pub const DEFAULT_SPAN_MICROS: u64 = 8_000;

    /// Nothing queued.
    pub fn new() -> Self {
        Self::default()
    }

    /// Nothing is waiting to be played.
    pub fn is_idle(&self) -> bool {
        self.segments.is_empty()
    }

    /// How many `enqueue` calls squeezed the queue (a diagnostic counter; it changes nothing).
    pub fn squeeze_count(&self) -> u64 {
        self.squeeze_count
    }

    /// Queues one movement. `span_micros` is the time the finger took for it, from the packet; 0 when it did not say.
    pub fn enqueue(&mut self, dx: f64, dy: f64, dragging: bool, span_micros: u64, now_micros: u64) {
        let span = if span_micros == 0 {
            Self::DEFAULT_SPAN_MICROS
        } else {
            span_micros.clamp(Self::MIN_SPAN_MICROS, Self::MAX_SPAN_MICROS)
        };
        let now = now_micros as f64;
        let start = if self.segments.is_empty() { now } else { now.max(self.last_end) };
        let end = start + span as f64;
        self.segments.push(Segment { dx, dy, dragging, from: start, end });
        self.last_end = end;
        let allowed = now + Self::MAX_LAG_MICROS.max(span + Self::LAG_MARGIN_MICROS) as f64;
        if self.last_end <= allowed {
            return;
        }
        self.squeeze_count += 1;
        // Squeeze the part that lies after `now`; what is already behind `now` stays where it is.
        let factor = (allowed - now) / (self.last_end - now);
        let squeezed = |t: f64| if t > now { now + (t - now) * factor } else { t };
        for segment in &mut self.segments {
            segment.from = squeezed(segment.from);
            segment.end = squeezed(segment.end);
        }
        self.last_end = allowed;
    }

    /// What is due up to `now`, or `None` when no segment has moved on. When the next segment has another `dragging` state
    /// the result stops short of it; ask again for the rest.
    pub fn take(&mut self, now_micros: u64) -> Option<PlayoutShare> {
        let now = now_micros as f64;
        let mut sum: Option<PlayoutShare> = None;
        let mut finished = 0;
        for index in 0..self.segments.len() {
            let segment = self.segments[index];
            if sum.is_some_and(|current| current.dragging != segment.dragging) {
                break;
            }
            let until = now.min(segment.end);
            if until <= segment.from {
                break;
            }
            let share = if until >= segment.end { 1.0 } else { (until - segment.from) / (segment.end - segment.from) };
            let dx = if share == 1.0 { segment.dx } else { segment.dx * share };
            let dy = if share == 1.0 { segment.dy } else { segment.dy * share };
            sum = Some(PlayoutShare {
                dx: sum.map_or(0.0, |s| s.dx) + dx,
                dy: sum.map_or(0.0, |s| s.dy) + dy,
                dragging: segment.dragging,
            });
            if share == 1.0 {
                finished += 1;
            } else {
                let rest = &mut self.segments[index];
                rest.dx -= dx;
                rest.dy -= dy;
                rest.from = until;
                break;
            }
        }
        self.segments.drain(..finished);
        sum
    }

    /// Everything still to be played, now, as one output per run of the same `dragging` state (the order barrier before a
    /// click or a button).
    pub fn flush(&mut self) -> Vec<PlayoutShare> {
        let mut runs: Vec<PlayoutShare> = Vec::new();
        for segment in self.segments.drain(..) {
            match runs.last_mut() {
                Some(last) if last.dragging == segment.dragging => {
                    last.dx += segment.dx;
                    last.dy += segment.dy;
                }
                _ => runs.push(PlayoutShare { dx: segment.dx, dy: segment.dy, dragging: segment.dragging }),
            }
        }
        runs
    }

    /// Forgets everything that has not been played (the channel is over).
    pub fn discard(&mut self) {
        self.segments.clear();
    }
}

/// Failed packets in a row after which the channel is closed and the grant renewed (§8.5).
pub const MAX_CONSECUTIVE_FAILURES: u32 = 8;

/// Why a pointer packet was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PointerRejection {
    /// The channel is not open, the switch is off or there is no connection (§8.5).
    NotOpen,
    /// The packet failed the checks of §8.2.
    Channel(ChannelOpenError),
    /// The packet verified but its plaintext is unreadable (§8.3).
    Unreadable,
}

/// What a call to `PointerReceiver` leaves for the adapter.
#[derive(Clone, Default, PartialEq)]
pub struct PointerEffects {
    /// To perform now, in order.
    pub actions: Vec<PointerAction>,
    /// The `status` the keyboard last saw is out of date (a grant appeared, changed or went away): send a new one.
    pub status_changed: bool,
    /// The answer to a `pointerOpen` or `pointerClose`.
    pub ack: Option<AckResult>,
    /// Set when a packet was dropped.
    pub rejection: Option<PointerRejection>,
}

impl fmt::Debug for PointerEffects {
    /// The number of actions, not the actions: nothing about where the cursor went reaches a log.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PointerEffects")
            .field("actions", &self.actions.len())
            .field("status_changed", &self.status_changed)
            .field("ack", &self.ack)
            .field("rejection", &self.rejection)
            .finish()
    }
}

/// The host side of the pointer channel (§8.5): the switch 「允許觸控板控制」, the grant, open and close, the checks of every
/// packet, the button logic and the movement playout.
///
/// - With the switch on, each authenticated connection gets its own `grant`, and so does every turning on. Turning it off
///   closes the channel and takes the grant away.
/// - `pointerOpen` needs an authenticated connection, the switch on and the current grant. Every packet checks again.
/// - `pointerClose`, a lost connection, the switch going off and eight failed packets in a row close the channel and let go
///   of whatever is held. After eight failures the grant is renewed and `status_changed` is set.
/// - Movement is queued in the playout and handed out by `frame_tick`; anything else (a click, a button, a scroll, the
///   watchdog letting go) first flushes the movement before it, so the order the phone sent is the order performed. When the
///   channel closes the movement not yet played is dropped.
pub struct PointerReceiver {
    enabled: bool,
    channels: Option<ChannelSet>,
    grants: Box<dyn FnMut() -> u32 + Send>,
    grant: Option<u32>,
    open: bool,
    engine: PointerEngine,
    playout: PointerPlayout,
    consecutive_failures: u32,
}

impl fmt::Debug for PointerReceiver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PointerReceiver([redacted])")
    }
}

impl PointerReceiver {
    /// `grants` yields a fresh `pointerGrant` on every call; the caller owns the random source.
    pub fn new(enabled: bool, grants: Box<dyn FnMut() -> u32 + Send>) -> Self {
        Self {
            enabled,
            channels: None,
            grants,
            grant: None,
            open: false,
            engine: PointerEngine::new(),
            playout: PointerPlayout::new(),
            consecutive_failures: 0,
        }
    }

    /// The grant of the current connection; `None` without a connection or with the switch off.
    pub fn grant(&self) -> Option<u32> {
        self.grant
    }

    /// The channel is open.
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// The switch is on.
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// The switch 「允許觸控板控制」 was turned.
    pub fn set_enabled(&mut self, on: bool) -> PointerEffects {
        let mut effects = PointerEffects::default();
        if on == self.enabled {
            return effects;
        }
        self.enabled = on;
        if on {
            if self.channels.is_some() {
                self.grant = Some((self.grants)());
                effects.status_changed = true;
            }
        } else {
            effects.actions = self.close_channel();
            effects.status_changed = self.grant.take().is_some();
        }
        effects
    }

    /// A new authenticated connection (§8.5 rule 1). It brings its own counters, so nothing of an earlier one is kept. The
    /// first `status` is sent by the caller right after this, so the new grant is not announced separately.
    pub fn attach(&mut self, channels: ChannelSet) -> PointerEffects {
        let actions = self.close_channel();
        self.channels = Some(channels);
        self.grant = self.enabled.then(|| (self.grants)());
        PointerEffects { actions, ..PointerEffects::default() }
    }

    /// The connection ended (§8.5: connection lost or authentication failed).
    pub fn detach(&mut self) -> PointerEffects {
        let actions = self.close_channel();
        self.channels = None;
        self.grant = None;
        PointerEffects { actions, ..PointerEffects::default() }
    }

    /// `pointerOpen` (§8.5 rule 3): the permission is checked here, not taken from an earlier answer.
    pub fn handle_open(&mut self, grant: u32) -> PointerEffects {
        let allowed = self.channels.is_some() && self.enabled && self.grant == Some(grant);
        if !allowed {
            return PointerEffects { ack: Some(AckResult::NotAuthorized), ..PointerEffects::default() };
        }
        self.playout.discard();
        let actions = self.engine.reset();
        self.open = true;
        self.consecutive_failures = 0;
        PointerEffects { actions, ack: Some(AckResult::Posted), ..PointerEffects::default() }
    }

    /// `pointerClose` (§8.5 rule 5): no authorization check, always answered `posted`.
    pub fn handle_close(&mut self) -> PointerEffects {
        let actions = self.close_channel();
        PointerEffects { actions, ack: Some(AckResult::Posted), ..PointerEffects::default() }
    }

    /// One `0x03` notification, whole. Every packet checks again: channel open, connection authenticated, switch on.
    pub fn handle_packet(&mut self, packet: &[u8], now_micros: u64) -> PointerEffects {
        let mut effects = PointerEffects::default();
        if !(self.open && self.enabled && self.grant.is_some()) {
            effects.rejection = Some(PointerRejection::NotOpen);
            return effects;
        }
        let Some(channels) = self.channels.as_mut() else {
            effects.rejection = Some(PointerRejection::NotOpen);
            return effects;
        };
        match channels.opener().open(packet) {
            Err(error) => {
                effects.rejection = Some(PointerRejection::Channel(error));
                self.consecutive_failures += 1;
                if self.consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    effects.actions = self.close_channel();
                    // The phone is told only by a new grant: its status no longer matches the one it opened with, so it
                    // opens again.
                    self.grant = Some((self.grants)());
                    effects.status_changed = true;
                }
            }
            Ok(plain) => {
                self.consecutive_failures = 0;
                match PointerPayload::decode(&plain) {
                    None => effects.rejection = Some(PointerRejection::Unreadable),
                    Some(payload) => {
                        let actions = self.engine.handle(&payload, now_micros);
                        effects.actions = self.route(actions, u64::from(payload.dt) * 100, now_micros);
                    }
                }
            }
        }
        effects
    }

    /// Called regularly while `needs_watchdog`.
    pub fn watchdog_tick(&mut self, now_micros: u64) -> PointerEffects {
        let actions = self.engine.watchdog(now_micros);
        PointerEffects { actions: self.route(actions, 0, now_micros), ..PointerEffects::default() }
    }

    /// One display refresh while `needs_frames`: what has become due.
    pub fn frame_tick(&mut self, now_micros: u64) -> PointerEffects {
        let mut actions = Vec::new();
        while let Some(share) = self.playout.take(now_micros) {
            actions.push(PointerAction::Move { dx: share.dx, dy: share.dy, dragging: share.dragging });
        }
        PointerEffects { actions, ..PointerEffects::default() }
    }

    /// A button is held or a scroll is going.
    pub fn needs_watchdog(&self) -> bool {
        self.engine.needs_watchdog()
    }

    /// Movement is waiting to be played.
    pub fn needs_frames(&self) -> bool {
        !self.playout.is_idle()
    }

    /// Moves go to the playout; every other action first lets out the moves queued before it, then runs.
    fn route(&mut self, actions: Vec<PointerAction>, span_micros: u64, now_micros: u64) -> Vec<PointerAction> {
        let mut out = Vec::new();
        for action in actions {
            if let PointerAction::Move { dx, dy, dragging } = action {
                self.playout.enqueue(dx, dy, dragging, span_micros, now_micros);
            } else {
                out.extend(self.playout.flush().into_iter().map(|s| PointerAction::Move { dx: s.dx, dy: s.dy, dragging: s.dragging }));
                out.push(action);
            }
        }
        out
    }

    /// Closes the channel: the unplayed movement is dropped, everything held is released.
    fn close_channel(&mut self) -> Vec<PointerAction> {
        self.playout.discard();
        self.open = false;
        self.consecutive_failures = 0;
        self.engine.reset()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secret::PairKey;
    use std::sync::{Arc, Mutex};

    const MS: u64 = 1_000;

    fn left() -> u8 {
        0x01
    }

    fn payload(opcode: Opcode, buttons: u8, seq: u16) -> PointerPayload {
        PointerPayload::new(opcode, buttons, 0, 0, 0, seq)
    }

    fn mv(buttons: u8, seq: u16, dx: i16, dy: i16) -> PointerPayload {
        PointerPayload::new(Opcode::Move, buttons, dx, dy, 100, seq)
    }

    fn click(button: u8, count: u8, buttons: u8, seq: u16) -> PointerPayload {
        PointerPayload { arg: PointerPayload::click_arg(button, count), ..payload(Opcode::Click, buttons, seq) }
    }

    fn scroll(phase: ScrollPhase, dx: i16, dy: i16, seq: u16) -> PointerPayload {
        PointerPayload { arg: phase as u8, dx, dy, ..payload(Opcode::Scroll, 0, seq) }
    }

    // ---- payload

    #[test]
    fn the_protocol_example_decodes_and_encodes_back() {
        let bytes = [0x01, 0x10, 0x00, 0x18, 0xff, 0xf8, 0x00, 0x53, 0, 0, 0, 0, 0, 0, 0, 0];
        let p = PointerPayload::decode(&bytes).unwrap();
        assert_eq!(p, PointerPayload::new(Opcode::Move, 0x10, 24, -8, 83, 0));
        assert_eq!(p.encode(), bytes);
    }

    #[test]
    fn every_field_round_trips_at_its_extremes() {
        let p = PointerPayload {
            opcode: Opcode::Click,
            buttons: 0xF3,
            dx: i16::MIN,
            dy: i16::MAX,
            dt: u16::MAX,
            action_id: 0xDEAD_BEEF,
            arg: PointerPayload::click_arg(1, 3),
            status: 0x07,
            button_seq: u16::MAX,
        };
        assert_eq!(PointerPayload::decode(&p.encode()), Some(p));
    }

    #[test]
    fn a_packet_that_is_not_16_bytes_is_unreadable() {
        let ok = payload(Opcode::Heartbeat, 0, 0).encode();
        assert!(PointerPayload::decode(&ok).is_some());
        assert!(PointerPayload::decode(&ok[..15]).is_none());
        assert!(PointerPayload::decode(&[ok.as_slice(), &[0]].concat()).is_none());
        assert!(PointerPayload::decode(&[]).is_none());
    }

    #[test]
    fn an_opcode_outside_the_table_is_unreadable() {
        for code in [0x00u8, 0x03, 0x0F, 0x13, 0x20, 0x7E, 0xFF] {
            let mut bytes = payload(Opcode::Move, 0, 0).encode();
            bytes[0] = code;
            assert!(PointerPayload::decode(&bytes).is_none(), "opcode {code:#x}");
        }
    }

    #[test]
    fn a_reserved_bit_that_is_not_zero_makes_the_packet_unreadable() {
        for bit in [0x04u8, 0x08] {
            let mut bytes = payload(Opcode::Move, 0, 0).encode();
            bytes[1] |= bit;
            assert!(PointerPayload::decode(&bytes).is_none(), "buttons bit {bit:#x}");
        }
        for bit in [0x08u8, 0x10, 0x20, 0x40, 0x80] {
            let mut bytes = payload(Opcode::Move, 0, 0).encode();
            bytes[13] |= bit;
            assert!(PointerPayload::decode(&bytes).is_none(), "status bit {bit:#x}");
        }
        // The documented bits are fine: left, right, touch count, and the three status flags.
        let mut bytes = payload(Opcode::Move, 0xF3, 0).encode();
        bytes[13] = 0x07;
        assert!(PointerPayload::decode(&bytes).is_some());
    }

    #[test]
    fn a_scroll_arg_above_3_is_unreadable() {
        for arg in 0..=3u8 {
            assert!(PointerPayload::decode(&scroll(ScrollPhase::from_byte(arg).unwrap(), 0, 0, 0).encode()).is_some());
        }
        let mut bytes = scroll(ScrollPhase::Changed, 0, 0, 0).encode();
        bytes[12] = 4;
        assert!(PointerPayload::decode(&bytes).is_none());
    }

    #[test]
    fn a_click_with_a_bad_button_count_or_reserved_bits_is_unreadable() {
        assert!(PointerPayload::decode(&click(0, 1, 0, 0).encode()).is_some());
        assert!(PointerPayload::decode(&click(1, 3, 0, 0).encode()).is_some());
        for arg in [0x00u8, 0x02, 0x03, 0x04, 0x08, 0x14, 0x18, 0x15, 0x1C, 0x40, 0x50, 0xF0, 0x12 | 0x0C, 0x12, 0x13] {
            let mut bytes = click(0, 1, 0, 0).encode();
            bytes[12] = arg;
            // Valid ones among these: 0x12 is (count 1, button 2) which is invalid because only buttons 0 and 1 exist.
            assert!(PointerPayload::decode(&bytes).is_none(), "arg {arg:#04x}");
        }
        let mut bytes = click(0, 1, 0, 0).encode();
        bytes[12] = 0x11;
        assert!(PointerPayload::decode(&bytes).is_some(), "right click, count 1");
    }

    #[test]
    fn the_arg_of_moves_and_button_state_packets_is_not_checked() {
        for opcode in [Opcode::Move, Opcode::ButtonState, Opcode::Heartbeat] {
            let mut bytes = payload(opcode, 0, 0).encode();
            bytes[12] = 0xFF;
            assert!(PointerPayload::decode(&bytes).is_some(), "{opcode:?}");
        }
    }

    #[test]
    fn button_sequence_arithmetic_wraps() {
        assert!(is_newer_button_seq(1, 0));
        assert!(is_newer_button_seq(0, 65_535), "wrap around");
        assert!(is_newer_button_seq(32_767, 0));
        assert!(!is_newer_button_seq(32_768, 0), "half way is not newer");
        assert!(!is_newer_button_seq(5, 5));
        assert!(!is_newer_button_seq(0, 1));
        assert!(!is_newer_button_seq(65_535, 0));
        assert!(is_newer_button_seq(100, 65_500));
        assert!(!is_newer_button_seq(65_500, 100));
    }

    // ---- acceleration

    #[test]
    fn the_speed_curve_runs_from_the_base_gain_toward_the_maximum() {
        assert!((acceleration::gain(0.0) - 1.25).abs() < 1e-12);
        assert!((acceleration::gain(550.0) - (1.25 + 2.25 / 2.0)).abs() < 1e-12, "half way at the knee");
        assert!(acceleration::gain(1e9) < 3.5 && acceleration::gain(1e9) > 3.49);
        assert!(acceleration::gain(100.0) < acceleration::gain(1000.0));
    }

    #[test]
    fn dt_is_clamped_to_5_to_150_milliseconds() {
        assert!((acceleration::seconds(0) - 0.005).abs() < 1e-12);
        assert!((acceleration::seconds(500) - 0.050).abs() < 1e-12);
        assert!((acceleration::seconds(u16::MAX) - 0.150).abs() < 1e-12);
    }

    #[test]
    fn scaling_keeps_the_direction_and_applies_the_gain() {
        let (dx, dy) = acceleration::scaled(-160, 0, 1000); // -10 points in 100 ms
        assert!(dx < -10.0 && dy == 0.0);
        let (dx2, dy2) = acceleration::scaled(0, 0, 0);
        assert_eq!((dx2, dy2), (0.0, 0.0));
    }

    // ---- engine

    fn left_button_actions(actions: &[PointerAction]) -> Vec<bool> {
        actions.iter().filter_map(|a| if let PointerAction::LeftButton { down } = a { Some(*down) } else { None }).collect()
    }

    #[test]
    fn the_first_packet_applies_its_buttons_whatever_its_sequence() {
        let mut e = PointerEngine::new();
        let a = e.handle(&payload(Opcode::ButtonState, left(), 40_000), 0);
        assert_eq!(a, vec![PointerAction::LeftButton { down: true }]);
        assert!(e.left_down());
    }

    #[test]
    fn only_a_newer_sequence_changes_the_button() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 10), 0);
        // Same sequence, button up: ignored. Older: ignored.
        assert!(e.handle(&payload(Opcode::Heartbeat, 0, 10), 1).is_empty());
        assert!(e.handle(&payload(Opcode::Heartbeat, 0, 9), 2).is_empty());
        assert!(e.left_down());
        // Newer: released.
        assert_eq!(left_button_actions(&e.handle(&payload(Opcode::ButtonState, 0, 11), 3)), vec![false]);
        assert!(!e.left_down());
        // A late heartbeat of the old press cannot press again.
        assert!(e.handle(&payload(Opcode::Heartbeat, left(), 10), 4).is_empty());
        assert!(!e.left_down());
    }

    #[test]
    fn a_sequence_that_wrapped_is_still_newer() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, 0, 65_535), 0);
        assert_eq!(left_button_actions(&e.handle(&payload(Opcode::ButtonState, left(), 0), 1)), vec![true]);
    }

    #[test]
    fn buttons_are_applied_before_the_opcode_so_a_move_with_a_new_press_is_a_drag() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, 0, 1), 0);
        let actions = e.handle(&mv(left(), 2, 160, 0), 1);
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0], PointerAction::LeftButton { down: true });
        assert!(matches!(actions[1], PointerAction::Move { dragging: true, dx, .. } if dx > 10.0));
    }

    #[test]
    fn a_move_without_displacement_does_nothing_but_the_buttons() {
        let mut e = PointerEngine::new();
        assert!(e.handle(&mv(0, 0, 0, 0), 0).is_empty());
        assert!(matches!(e.handle(&mv(0, 1, 0, 16), 1)[..], [PointerAction::Move { dragging: false, .. }]));
    }

    #[test]
    fn a_click_does_not_click_while_the_left_button_is_held_or_pressed_by_the_same_packet() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 1), 0);
        assert!(e.handle(&click(0, 1, left(), 1), 1).is_empty());
        assert!(e.handle(&click(1, 1, left(), 1), 2).is_empty(), "no right click during a drag either");
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, 0, 1), 0);
        let actions = e.handle(&click(0, 2, left(), 2), 1);
        assert_eq!(actions, vec![PointerAction::LeftButton { down: true }], "the press is applied, the click is not");
    }

    #[test]
    fn clicks_follow_the_button_and_the_count() {
        let mut e = PointerEngine::new();
        for count in 1..=3 {
            assert_eq!(e.handle(&click(0, count, 0, 1), 0), vec![PointerAction::Click { count }]);
        }
        assert_eq!(e.handle(&click(1, 1, 0, 1), 0), vec![PointerAction::RightClick]);
    }

    #[test]
    fn scroll_begins_continues_and_ends() {
        let mut e = PointerEngine::new();
        assert_eq!(
            e.handle(&scroll(ScrollPhase::Began, 32, -16, 0), 0),
            vec![PointerAction::Scroll { dx: 2.0, dy: -1.0, phase: ScrollPhase::Began }]
        );
        assert!(e.is_scrolling());
        assert_eq!(
            e.handle(&scroll(ScrollPhase::Changed, 16, 16, 0), 1),
            vec![PointerAction::Scroll { dx: 1.0, dy: 1.0, phase: ScrollPhase::Changed }]
        );
        // End drops the packet's own displacement.
        assert_eq!(
            e.handle(&scroll(ScrollPhase::Ended, 160, 160, 0), 2),
            vec![PointerAction::Scroll { dx: 0.0, dy: 0.0, phase: ScrollPhase::Ended }]
        );
        assert!(!e.is_scrolling());
    }

    #[test]
    fn a_changed_without_a_began_starts_the_scroll() {
        let mut e = PointerEngine::new();
        assert!(matches!(e.handle(&scroll(ScrollPhase::Changed, 16, 0, 0), 0)[..], [PointerAction::Scroll { phase: ScrollPhase::Began, .. }]));
        assert!(matches!(e.handle(&scroll(ScrollPhase::Began, 16, 0, 0), 1)[..], [PointerAction::Scroll { phase: ScrollPhase::Changed, .. }]), "a second began continues");
    }

    #[test]
    fn ended_and_cancelled_outside_a_scroll_do_nothing() {
        let mut e = PointerEngine::new();
        assert!(e.handle(&scroll(ScrollPhase::Ended, 16, 16, 0), 0).is_empty());
        assert!(e.handle(&scroll(ScrollPhase::Cancelled, 16, 16, 0), 1).is_empty());
        e.handle(&scroll(ScrollPhase::Began, 16, 16, 0), 2);
        assert_eq!(e.handle(&scroll(ScrollPhase::Cancelled, 16, 16, 0), 3).len(), 1);
        assert!(!e.is_scrolling());
    }

    #[test]
    fn the_button_watchdog_releases_after_350_milliseconds_and_keeps_the_sequence() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 5), 1_000_000);
        assert!(e.needs_watchdog());
        assert!(e.watchdog(1_000_000 + 349_999).is_empty());
        assert_eq!(e.watchdog(1_000_000 + 350_000), vec![PointerAction::LeftButton { down: false }]);
        assert!(!e.needs_watchdog());
        // The sequence stays: a repeat of the old press does not press again, a newer one does.
        assert!(e.handle(&payload(Opcode::Heartbeat, left(), 5), 2_000_000).is_empty());
        assert_eq!(left_button_actions(&e.handle(&payload(Opcode::ButtonState, left(), 6), 2_000_001)), vec![true]);
    }

    #[test]
    fn every_packet_restarts_the_watchdog() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 1), 0);
        e.handle(&payload(Opcode::Heartbeat, left(), 1), 300_000);
        assert!(e.watchdog(600_000).is_empty(), "300 ms since the heartbeat");
        assert_eq!(e.watchdog(650_000).len(), 1);
    }

    #[test]
    fn the_scroll_watchdog_ends_the_scroll_after_150_milliseconds() {
        let mut e = PointerEngine::new();
        e.handle(&scroll(ScrollPhase::Began, 16, 16, 0), 0);
        assert!(e.watchdog(149_999).is_empty());
        assert_eq!(e.watchdog(150_000), vec![PointerAction::Scroll { dx: 0.0, dy: 0.0, phase: ScrollPhase::Ended }]);
        assert!(!e.is_scrolling());
        assert!(e.watchdog(1_000_000).is_empty());
    }

    #[test]
    fn both_watchdogs_can_fire_together() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 1), 0);
        e.handle(&PointerPayload { buttons: left(), ..scroll(ScrollPhase::Began, 16, 16, 1) }, 0);
        assert_eq!(e.watchdog(400_000).len(), 2);
    }

    #[test]
    fn reset_releases_everything_and_forgets_the_sequence() {
        let mut e = PointerEngine::new();
        e.handle(&payload(Opcode::ButtonState, left(), 100), 0);
        e.handle(&scroll(ScrollPhase::Began, 16, 16, 100), 0);
        let released = e.reset();
        assert_eq!(released.len(), 2);
        assert!(!e.left_down() && !e.is_scrolling() && !e.needs_watchdog());
        // A new session starts from nothing: an old-looking sequence is applied as the first.
        assert_eq!(left_button_actions(&e.handle(&payload(Opcode::ButtonState, left(), 3), 5)), vec![true]);
        assert!(PointerEngine::new().reset().is_empty());
    }

    // ---- playout (ported from PointerPlayoutTests.swift)

    #[test]
    fn a_single_segment_is_handed_out_linearly() {
        let mut p = PointerPlayout::new();
        p.enqueue(10.0, -20.0, false, 10 * MS, 100 * MS);
        assert!(!p.is_idle());
        assert_eq!(p.take(100 * MS), None, "nothing has elapsed yet");
        let half = p.take(105 * MS).unwrap();
        assert!((half.dx - 5.0).abs() < 1e-9 && (half.dy + 10.0).abs() < 1e-9 && !half.dragging);
        let rest = p.take(200 * MS).unwrap();
        assert!((rest.dx - 5.0).abs() < 1e-9 && (rest.dy + 10.0).abs() < 1e-9);
        assert!(p.is_idle());
        assert_eq!(p.take(300 * MS), None);
    }

    #[test]
    fn two_packets_arriving_together_play_back_to_back() {
        let mut p = PointerPlayout::new();
        p.enqueue(8.0, 0.0, false, 8 * MS, 0);
        p.enqueue(8.0, 0.0, false, 8 * MS, 0);
        for step in 1..=4u64 {
            let moved = p.take(step * 4 * MS).unwrap();
            assert!((moved.dx - 4.0).abs() < 1e-9, "step {step}");
        }
        assert!(p.is_idle());
    }

    #[test]
    fn a_segment_starts_where_the_last_ended_when_that_is_still_running() {
        let mut p = PointerPlayout::new();
        p.enqueue(10.0, 0.0, false, 10 * MS, 0);
        p.enqueue(10.0, 0.0, false, 10 * MS, 5 * MS);
        assert!((p.take(10 * MS).unwrap().dx - 10.0).abs() < 1e-9, "the second has not started before 10 ms");
        assert!((p.take(15 * MS).unwrap().dx - 5.0).abs() < 1e-9);
    }

    #[test]
    fn a_missing_or_tiny_span_uses_the_default_and_a_long_one_is_capped() {
        let mut zero = PointerPlayout::new();
        zero.enqueue(8.0, 0.0, false, 0, 0);
        assert!((zero.take(4 * MS).unwrap().dx - 4.0).abs() < 1e-9, "0 means the 8 ms default");
        let mut tiny = PointerPlayout::new();
        tiny.enqueue(8.0, 0.0, false, 1, 0);
        assert!((tiny.take(2 * MS).unwrap().dx - 4.0).abs() < 1e-9, "raised to 4 ms");
        let mut long = PointerPlayout::new();
        long.enqueue(25.0, 0.0, false, 900 * MS, 0);
        assert!((long.take(25 * MS).unwrap().dx - 12.5).abs() < 1e-9, "capped to 50 ms");
        assert!((long.take(50 * MS).unwrap().dx - 12.5).abs() < 1e-9);
        assert!(long.is_idle());
    }

    #[test]
    fn lag_is_capped_by_compressing_what_is_left() {
        let mut p = PointerPlayout::new();
        for _ in 0..10 {
            p.enqueue(10.0, 0.0, false, 8 * MS, 0);
        }
        assert_eq!(p.take(0), None);
        let all = p.take(PointerPlayout::MAX_LAG_MICROS).unwrap();
        assert!((all.dx - 100.0).abs() < 1e-9);
        assert!(p.is_idle());
    }

    #[test]
    fn the_lag_bound_is_span_plus_five_for_long_packets_and_twenty_for_short_ones() {
        let mut long = PointerPlayout::new();
        long.enqueue(30.0, 0.0, false, 30 * MS, 0);
        long.enqueue(30.0, 0.0, false, 30 * MS, 0);
        let at20 = long.take(20 * MS).unwrap();
        assert!(at20.dx < 60.0 - 1e-6, "not all out by 20 ms");
        assert!((at20.dx - 60.0 * 20.0 / 35.0).abs() < 1e-9);
        assert!((long.take(35 * MS).unwrap().dx - (60.0 - at20.dx)).abs() < 1e-9);
        assert!(long.is_idle());

        let mut single = PointerPlayout::new();
        single.enqueue(50.0, 0.0, false, 50 * MS, 0);
        assert!((single.take(10 * MS).unwrap().dx - 10.0).abs() < 1e-9, "a lone 50 ms packet is never squeezed");

        let mut short = PointerPlayout::new();
        for _ in 0..5 {
            short.enqueue(8.0, 0.0, false, 8 * MS, 0);
        }
        assert!((short.take(20 * MS).unwrap().dx - 40.0).abs() < 1e-9);
        assert!(short.is_idle());
    }

    struct SplitMix64(u64);

    impl SplitMix64 {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
    }

    #[test]
    fn a_steady_stream_of_long_packets_plays_smoothly_frame_by_frame() {
        let mut rng = SplitMix64(0x5EED);
        let mut p = PointerPlayout::new();
        let frame = 8_333u64;
        let ideal = 30.0 * frame as f64 / 30_000.0;
        let mut next_packet = 0u64;
        let mut outputs = Vec::new();
        let mut frame_time = 0u64;
        while frame_time < 1_200 * MS {
            frame_time += frame;
            // Packets arrive every 30 ms with up to 3 ms of jitter either way.
            while next_packet < 40 {
                let arrival = (next_packet * 30 * MS + 30 * MS + rng.next() % 7_001) - 3_500;
                if arrival > frame_time {
                    break;
                }
                p.enqueue(30.0, 0.0, false, 30 * MS, arrival);
                next_packet += 1;
            }
            outputs.push(p.take(frame_time).map_or(0.0, |s| s.dx));
        }
        let steady: Vec<f64> = outputs[8..outputs.len() - 10].iter().copied().take(100).collect();
        assert!(steady.len() > 80);
        for (i, v) in steady.iter().enumerate() {
            assert!(*v > 0.0, "frame {i} is empty mid-stream");
            assert!(*v <= ideal * 1.3, "frame {i} runs too fast");
        }
    }

    #[test]
    fn squeeze_count_only_counts_squeezes() {
        let mut p = PointerPlayout::new();
        p.enqueue(1.0, 0.0, false, 8_000, 0);
        assert_eq!(p.squeeze_count(), 0);
        for _ in 0..5 {
            p.enqueue(1.0, 0.0, false, 8_000, 0);
        }
        assert!(p.squeeze_count() > 0);
    }

    #[test]
    fn a_short_queue_is_not_compressed() {
        let mut p = PointerPlayout::new();
        p.enqueue(10.0, 0.0, false, 10 * MS, 0);
        p.enqueue(10.0, 0.0, false, 10 * MS, 0);
        assert!((p.take(10 * MS).unwrap().dx - 10.0).abs() < 1e-9);
    }

    #[test]
    fn a_change_of_dragging_state_is_never_merged_into_one_output() {
        let mut p = PointerPlayout::new();
        p.enqueue(4.0, 0.0, false, 4 * MS, 0);
        p.enqueue(6.0, 0.0, true, 4 * MS, 0);
        let first = p.take(100 * MS).unwrap();
        assert!((first.dx - 4.0).abs() < 1e-9 && !first.dragging);
        let second = p.take(100 * MS).unwrap();
        assert!((second.dx - 6.0).abs() < 1e-9 && second.dragging);
        assert_eq!(p.take(100 * MS), None);
        assert!(p.is_idle());
    }

    #[test]
    fn the_same_dragging_state_is_merged_across_segments() {
        let mut p = PointerPlayout::new();
        p.enqueue(4.0, 1.0, true, 4 * MS, 0);
        p.enqueue(6.0, 2.0, true, 4 * MS, 0);
        let all = p.take(100 * MS).unwrap();
        assert!((all.dx - 10.0).abs() < 1e-9 && (all.dy - 3.0).abs() < 1e-9);
    }

    #[test]
    fn flush_hands_out_everything_at_once_in_runs_of_the_same_dragging_state() {
        let mut p = PointerPlayout::new();
        p.enqueue(4.0, 0.0, false, 8 * MS, 0);
        p.enqueue(2.0, 0.0, false, 8 * MS, 0);
        p.enqueue(7.0, 0.0, true, 8 * MS, 0);
        p.take(4 * MS);
        let flushed = p.flush();
        assert_eq!(flushed.len(), 2);
        assert!(!flushed[0].dragging && flushed[1].dragging);
        assert!((flushed[1].dx - 7.0).abs() < 1e-9);
        assert!(p.is_idle());
        assert!(p.flush().is_empty());
    }

    #[test]
    fn discard_drops_everything() {
        let mut p = PointerPlayout::new();
        p.enqueue(4.0, 0.0, false, 8 * MS, 0);
        p.discard();
        assert!(p.is_idle());
        assert_eq!(p.take(100 * MS), None);
        assert!(p.flush().is_empty());
    }

    #[test]
    fn total_displacement_is_conserved_for_random_sequences() {
        let mut rng = SplitMix64(0xC0FFEE);
        for _ in 0..200 {
            let mut p = PointerPlayout::new();
            let mut now = 1_000_000u64;
            let (mut in_x, mut in_y, mut out_x, mut out_y) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
            for _ in 0..(rng.next() % 60 + 1) {
                now += rng.next() % (30 * MS);
                let dx = ((rng.next() % 2001) as f64 - 1000.0) / 16.0;
                let dy = ((rng.next() % 2001) as f64 - 1000.0) / 16.0;
                p.enqueue(dx, dy, rng.next().is_multiple_of(5), rng.next() % (60 * MS), now);
                in_x += dx;
                in_y += dy;
                now += rng.next() % (20 * MS);
                match rng.next() % 3 {
                    0 => {
                        while let Some(m) = p.take(now) {
                            out_x += m.dx;
                            out_y += m.dy;
                        }
                    }
                    1 => {
                        for m in p.flush() {
                            out_x += m.dx;
                            out_y += m.dy;
                        }
                    }
                    _ => {}
                }
            }
            while let Some(m) = p.take(now + 10_000_000) {
                out_x += m.dx;
                out_y += m.dy;
            }
            for m in p.flush() {
                out_x += m.dx;
                out_y += m.dy;
            }
            assert!(p.is_idle());
            assert!((out_x - in_x).abs() < 1e-9 && (out_y - in_y).abs() < 1e-9);
        }
    }

    // ---- receiver

    struct Rig {
        host: PointerReceiver,
        phone: ChannelSet,
        issued: Arc<Mutex<Vec<u32>>>,
    }

    fn rig(enabled: bool) -> Rig {
        let issued = Arc::new(Mutex::new(Vec::new()));
        let counter = Arc::clone(&issued);
        let grants = Box::new(move || {
            let mut v = counter.lock().unwrap();
            let next = 100 + v.len() as u32;
            v.push(next);
            next
        });
        let key = PairKey::new([3; 32]);
        let mut host = PointerReceiver::new(enabled, grants);
        host.attach(ChannelSet::new(&key, &[1; 16], &[2; 16]));
        Rig { host, phone: ChannelSet::new(&key, &[1; 16], &[2; 16]), issued }
    }

    fn send(r: &mut Rig, p: &PointerPayload, now: u64) -> PointerEffects {
        let packet = r.phone.sealer().seal(&p.encode()).unwrap();
        r.host.handle_packet(&packet, now)
    }

    fn open(r: &mut Rig) {
        let grant = r.host.grant().unwrap();
        assert_eq!(r.host.handle_open(grant).ack, Some(AckResult::Posted));
    }

    #[test]
    fn a_connection_gets_a_grant_only_with_the_switch_on() {
        assert_eq!(rig(true).host.grant(), Some(100));
        assert_eq!(rig(false).host.grant(), None);
    }

    #[test]
    fn open_needs_a_connection_the_switch_and_the_current_grant() {
        let mut r = rig(true);
        assert_eq!(r.host.handle_open(999).ack, Some(AckResult::NotAuthorized), "wrong grant");
        assert!(!r.host.is_open());
        assert_eq!(r.host.handle_open(100).ack, Some(AckResult::Posted));
        assert!(r.host.is_open());

        let mut off = rig(false);
        assert_eq!(off.host.handle_open(100).ack, Some(AckResult::NotAuthorized), "switch off");

        let mut none = PointerReceiver::new(true, Box::new(|| 1));
        assert_eq!(none.handle_open(1).ack, Some(AckResult::NotAuthorized), "no connection");
    }

    #[test]
    fn close_is_always_posted_and_closes() {
        let mut r = rig(true);
        open(&mut r);
        assert_eq!(r.host.handle_close().ack, Some(AckResult::Posted));
        assert!(!r.host.is_open());
        assert_eq!(r.host.handle_close().ack, Some(AckResult::Posted), "also when not open");
    }

    #[test]
    fn packets_are_dropped_until_the_channel_is_open_and_do_not_count_as_failures() {
        let mut r = rig(true);
        for i in 0..20 {
            let e = send(&mut r, &mv(0, 0, 16, 0), i);
            assert_eq!(e.rejection, Some(PointerRejection::NotOpen));
            assert!(e.actions.is_empty() && !e.status_changed);
        }
        open(&mut r);
        // The dropped packets used counters 1 to 20; the next ones are fine.
        assert_eq!(send(&mut r, &mv(0, 0, 16, 0), 100).rejection, None);
    }

    #[test]
    fn a_replayed_packet_is_dropped_and_a_good_one_clears_the_failure_count() {
        let mut r = rig(true);
        open(&mut r);
        let packet = r.phone.sealer().seal(&mv(0, 0, 16, 0).encode()).unwrap();
        assert_eq!(r.host.handle_packet(&packet, 0).rejection, None);
        for _ in 0..7 {
            assert_eq!(r.host.handle_packet(&packet, 1).rejection, Some(PointerRejection::Channel(ChannelOpenError::Replayed)));
        }
        assert_eq!(send(&mut r, &mv(0, 0, 16, 0), 2).rejection, None, "a good packet in between");
        for _ in 0..7 {
            r.host.handle_packet(&packet, 3);
        }
        assert!(r.host.is_open(), "7 failures after a success are not 8 in a row");
    }

    #[test]
    fn eight_failed_packets_in_a_row_close_the_channel_and_renew_the_grant() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 1), 0);
        let packet = r.phone.sealer().seal(&mv(0, 0, 16, 0).encode()).unwrap();
        r.host.handle_packet(&packet, 1);
        let mut last = PointerEffects::default();
        for i in 0..8 {
            last = r.host.handle_packet(&packet, 2 + i);
        }
        assert!(!r.host.is_open());
        assert!(last.status_changed, "the status must be sent again");
        assert_eq!(last.actions, vec![PointerAction::LeftButton { down: false }], "the held button is let go");
        assert_eq!(r.host.grant(), Some(101), "a new grant");
        assert_eq!(r.issued.lock().unwrap().len(), 2);
        // The old grant no longer opens; the new one does.
        assert_eq!(r.host.handle_open(100).ack, Some(AckResult::NotAuthorized));
        assert_eq!(r.host.handle_open(101).ack, Some(AckResult::Posted));
    }

    #[test]
    fn forged_packets_count_as_failures_too() {
        let mut r = rig(true);
        open(&mut r);
        let mut last = PointerEffects::default();
        for i in 0..8u64 {
            let mut forged = vec![0x03];
            forged.extend_from_slice(&(1000 + i).to_be_bytes());
            forged.extend_from_slice(&[0; 32]);
            last = r.host.handle_packet(&forged, i);
            assert_eq!(last.rejection, Some(PointerRejection::Channel(ChannelOpenError::AuthFailed)));
        }
        assert!(last.status_changed && !r.host.is_open());
    }

    #[test]
    fn an_unreadable_plaintext_is_dropped_without_counting_as_a_failure() {
        let mut r = rig(true);
        open(&mut r);
        for _ in 0..20 {
            let mut bytes = mv(0, 0, 16, 0).encode();
            bytes[13] = 0x80;
            let packet = r.phone.sealer().seal(&bytes).unwrap();
            assert_eq!(r.host.handle_packet(&packet, 0).rejection, Some(PointerRejection::Unreadable));
        }
        assert!(r.host.is_open());
    }

    #[test]
    fn movement_is_played_out_and_a_click_first_lets_out_the_movement_before_it() {
        let mut r = rig(true);
        open(&mut r);
        let t0 = 1_000_000;
        let e = send(&mut r, &PointerPayload::new(Opcode::Move, 0, 160, 0, 200, 1), t0);
        assert!(e.actions.is_empty(), "movement waits for the frame tick");
        assert!(r.host.needs_frames());
        let e = send(&mut r, &click(0, 1, 0, 1), t0 + 1_000);
        assert_eq!(e.actions.len(), 2);
        assert!(matches!(e.actions[0], PointerAction::Move { .. }), "the move comes first");
        assert_eq!(e.actions[1], PointerAction::Click { count: 1 });
        assert!(!r.host.needs_frames());
    }

    #[test]
    fn the_frame_tick_hands_out_what_is_due() {
        let mut r = rig(true);
        open(&mut r);
        let t0 = 5_000_000;
        send(&mut r, &PointerPayload::new(Opcode::Move, 0, 160, 0, 200, 1), t0);
        let early = r.host.frame_tick(t0 + 8_000);
        let late = r.host.frame_tick(t0 + 100_000);
        let sum = |e: &PointerEffects| e.actions.iter().map(|a| if let PointerAction::Move { dx, .. } = a { *dx } else { 0.0 }).sum::<f64>();
        assert!(sum(&early) > 0.0 && sum(&late) > 0.0);
        assert!(!r.host.needs_frames());
        let (g, total) = (acceleration::scaled(160, 0, 200).0, sum(&early) + sum(&late));
        assert!((g - total).abs() < 1e-9, "everything that went in came out");
    }

    #[test]
    fn the_watchdog_lets_go_of_a_held_button_after_350_milliseconds_of_silence() {
        let mut r = rig(true);
        open(&mut r);
        let t0 = 1_000_000;
        let e = send(&mut r, &payload(Opcode::ButtonState, left(), 1), t0);
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: true }]);
        assert!(r.host.needs_watchdog());
        assert!(r.host.watchdog_tick(t0 + 300_000).actions.is_empty());
        let e = r.host.watchdog_tick(t0 + 350_000);
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: false }]);
        assert!(!r.host.needs_watchdog());
    }

    #[test]
    fn closing_the_channel_releases_everything_and_drops_unplayed_movement() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 1), 0);
        send(&mut r, &mv(left(), 1, 160, 0), 1);
        assert!(r.host.needs_frames());
        let e = r.host.handle_close();
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: false }]);
        assert!(!r.host.needs_frames() && !r.host.needs_watchdog());
        assert!(r.host.frame_tick(10_000_000).actions.is_empty(), "the movement was dropped, not performed");
    }

    #[test]
    fn turning_the_switch_off_closes_the_channel_takes_the_grant_and_asks_for_a_status() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 1), 0);
        let e = r.host.set_enabled(false);
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: false }]);
        assert!(e.status_changed);
        assert_eq!(r.host.grant(), None);
        assert!(!r.host.is_open());
        assert_eq!(send(&mut r, &mv(0, 2, 16, 0), 5).rejection, Some(PointerRejection::NotOpen));
        // Turning it off again changes nothing.
        assert_eq!(r.host.set_enabled(false), PointerEffects::default());
    }

    #[test]
    fn turning_the_switch_on_gives_a_new_grant_and_asks_for_a_status() {
        let mut r = rig(false);
        let e = r.host.set_enabled(true);
        assert!(e.status_changed);
        assert_eq!(r.host.grant(), Some(100));
        // Without a connection there is nothing to grant.
        let mut none = PointerReceiver::new(false, Box::new(|| 7));
        assert_eq!(none.set_enabled(true), PointerEffects::default());
        assert_eq!(none.grant(), None);
    }

    #[test]
    fn a_new_connection_closes_the_old_channel_and_gets_its_own_grant() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 1), 0);
        let key = PairKey::new([9; 32]);
        let e = r.host.attach(ChannelSet::new(&key, &[5; 16], &[6; 16]));
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: false }]);
        assert!(!e.status_changed, "the caller sends the first status of the connection itself");
        assert_eq!(r.host.grant(), Some(101));
        assert!(!r.host.is_open());
        // The old phone's packets do not open under the new keys.
        assert_eq!(r.host.handle_open(101).ack, Some(AckResult::Posted));
        assert_eq!(send(&mut r, &mv(0, 2, 16, 0), 5).rejection, Some(PointerRejection::Channel(ChannelOpenError::AuthFailed)));
    }

    #[test]
    fn losing_the_connection_releases_everything() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 1), 0);
        let e = r.host.detach();
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: false }]);
        assert_eq!(r.host.grant(), None);
        assert!(!r.host.is_open());
        assert_eq!(r.host.handle_open(100).ack, Some(AckResult::NotAuthorized));
    }

    #[test]
    fn reopening_starts_with_no_button_history() {
        let mut r = rig(true);
        open(&mut r);
        send(&mut r, &payload(Opcode::ButtonState, left(), 500), 0);
        r.host.handle_close();
        open(&mut r);
        // An older-looking sequence is the first packet of the new session.
        let e = send(&mut r, &payload(Opcode::ButtonState, left(), 3), 10);
        assert_eq!(e.actions, vec![PointerAction::LeftButton { down: true }]);
    }

    #[test]
    fn debug_output_of_payloads_actions_and_effects_has_no_displacement() {
        let payload = PointerPayload::new(Opcode::Move, 0x11, 1234, -5678, 4321, 9876);
        let shown = format!("{payload:?}");
        assert_eq!(shown, "PointerPayload { opcode: Move }");
        let actions = [
            PointerAction::Move { dx: 123.456, dy: -789.012, dragging: true },
            PointerAction::Scroll { dx: 345.678, dy: 901.234, phase: ScrollPhase::Began },
            PointerAction::Click { count: 2 },
            PointerAction::RightClick,
            PointerAction::LeftButton { down: true },
        ];
        let effects = PointerEffects { actions: actions.to_vec(), ..PointerEffects::default() };
        let shown = format!("{actions:?} {effects:?}");
        for digits in ["123", "456", "789", "012", "345", "678", "901", "234"] {
            assert!(!shown.contains(digits), "{digits} leaked: {shown}");
        }
        assert!(shown.contains("Move { dragging: true }") && shown.contains("Scroll { phase: Began }"));
        assert!(shown.contains("actions: 5"));
    }

    #[test]
    fn debug_output_hides_the_state() {
        assert_eq!(format!("{:?}", rig(true).host), "PointerReceiver([redacted])");
    }
}
