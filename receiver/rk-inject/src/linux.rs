//! Linux injection through the RemoteDesktop portal (WL1 S4, S5, S9).
//!
//! # Threading
//!
//! `Injector` is synchronous, the portal is not. `LinuxInjector` owns one worker thread; the worker owns the portal
//! session and every timer (move coalescing, the end of a smooth scroll). Callers send a command and, for calls whose
//! result matters (`text`, keys, buttons), wait for the reply, so an `ack` of `posted` means the portal accepted the
//! keys. `pointer_move` and `scroll` only queue. All portal calls themselves go through the small `PortalSession` trait;
//! `ashpd_portal` is its one real implementation and the tests use a fake.
//!
//! Nothing here logs or keeps typed text: the log hook and `InjectReport` carry event kinds, lengths, counts and times.

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::keysym::{
    self, button_code, scroll_axis, InjectPath, InjectReport, MoveCoalescer, Segment, KEY_GAP, MOVE_MAX_HZ,
    PASTE_SETTLE, PASTE_WAIT, SCROLL_IDLE, XK_BACKSPACE, XK_CONTROL_L, XK_LOWER_V, XK_RETURN,
};
use crate::{Button, InjectError, Injector};

mod ashpd_portal;

pub use ashpd_portal::AshpdConnector;

/// How long a mouse button stays down in a click, and the pause between the clicks of a multi-click.
const CLICK_HOLD: Duration = Duration::from_millis(15);
const CLICK_GAP: Duration = Duration::from_millis(40);
const MAX_CLICK_COUNT: u8 = 3;
/// This many portal calls in a row failing means the session is gone.
const LOST_AFTER_FAILURES: u32 = 3;
/// A session that closed is brought back silently at most once in this time; after that the user decides.
const SILENT_RESTORE_INTERVAL_US: u64 = 60_000_000;
/// How soon a failed clear of the clipboard is tried again.
const CLEAR_RETRY_US: u64 = 1_000_000;

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

/// Called from the portal's own task when the session it was created for is closed from the outside.
pub type Closed = Arc<dyn Fn() + Send + Sync>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectError {
    /// The user said no (or closed the dialog).
    Denied,
    /// No portal, or it answered with something unusable. The message never contains typed text.
    Unavailable(String),
}

pub struct Connected<S> {
    pub session: S,
    /// The restore token to use next time; the portal hands out a fresh one for every start.
    pub restore_token: Option<String>,
}

/// One granted RemoteDesktop session (keyboard and pointer, plus the clipboard when the portal offers it).
pub trait PortalSession {
    fn keysym(&mut self, sym: i32, pressed: bool) -> Result<(), InjectError>;
    fn pointer_motion(&mut self, dx: f64, dy: f64) -> Result<(), InjectError>;
    fn pointer_button(&mut self, code: i32, pressed: bool) -> Result<(), InjectError>;
    fn pointer_axis(&mut self, dx: f64, dy: f64, finish: bool) -> Result<(), InjectError>;
    fn has_clipboard(&self) -> bool;
    /// The text now on the clipboard; `None` when it is empty or not text.
    fn clipboard_read(&mut self) -> Result<Option<String>, InjectError>;
    /// Becomes the clipboard owner and serves `text` to whoever pastes.
    fn clipboard_set(&mut self, text: &str) -> Result<(), InjectError>;
    /// Gives the clipboard up: nothing this session served can be pasted afterwards.
    fn clipboard_clear(&mut self) -> Result<(), InjectError>;
    fn sleep(&mut self, duration: Duration);
}

pub trait PortalConnector {
    type Session: PortalSession;
    /// Opens a session. With a restore token and a still valid grant no dialog appears; without one the user sees the
    /// portal's permission dialog and this call returns when they answer.
    fn connect(&mut self, restore_token: Option<&str>, on_closed: Closed) -> Result<Connected<Self::Session>, ConnectError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Authorization {
    /// Waiting for the portal (a permission dialog may be open).
    Pending,
    Granted,
    /// Refused, unavailable, or lost after being granted: the tray offers 「重新授權」.
    Denied,
}

impl Authorization {
    fn to_u8(self) -> u8 {
        match self {
            Self::Pending => 0,
            Self::Granted => 1,
            Self::Denied => 2,
        }
    }

    fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Granted,
            2 => Self::Denied,
            _ => Self::Pending,
        }
    }
}

/// `None` when there is no token file (or it is empty).
pub fn read_token(path: &Path) -> Option<String> {
    let token = std::fs::read_to_string(path).ok()?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_string())
}

/// Writes the token with mode 0600, through a temporary file so a crash never leaves half a token.
pub fn write_token(path: &Path, token: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    let temporary = path.with_extension("tmp");
    let _ = std::fs::remove_file(&temporary);
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
    file.write_all(token.as_bytes())?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// State the worker shares with the `LinuxInjector` handle.
struct Shared {
    state: AtomicU8,
    paste: AtomicBool,
    /// The last call whose result the caller waited for (text, keys, buttons, clicks).
    report: Mutex<Option<InjectReport>>,
    /// The last portal call made for pointer moves and scrolls, which happen on timers.
    pointer_report: Mutex<Option<InjectReport>>,
    /// The worker has to bring the session back (closed from outside, repeated failures, a call that timed out).
    recover: AtomicBool,
    /// Counts sessions; a closed signal of an older session is ignored.
    generation: AtomicU64,
    /// The generation of the last session the portal closed from the outside.
    closed_generation: AtomicU64,
    /// `InjectPath` of the last `text` call, as a number.
    text_path: AtomicU8,
    /// The injector is being dropped: `text` stops between runs, and the worker leaves instead of recovering.
    stop: AtomicBool,
    /// The worker is inside a paste: the user's clipboard is not whole until it has been given back.
    in_paste: AtomicBool,
}

impl Shared {
    fn new(paste: bool) -> Arc<Self> {
        Arc::new(Self {
            state: AtomicU8::new(Authorization::Pending.to_u8()),
            paste: AtomicBool::new(paste),
            report: Mutex::new(None),
            pointer_report: Mutex::new(None),
            recover: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            closed_generation: AtomicU64::new(0),
            text_path: AtomicU8::new(0),
            stop: AtomicBool::new(false),
            in_paste: AtomicBool::new(false),
        })
    }

    fn authorization(&self) -> Authorization {
        Authorization::from_u8(self.state.load(Ordering::SeqCst))
    }

    fn set_text_path(&self, path: InjectPath) {
        let code = match path {
            InjectPath::Keysym => 0,
            InjectPath::Paste => 1,
            InjectPath::Unicode => 2,
        };
        self.text_path.store(code, Ordering::SeqCst);
    }

    fn text_path_name(&self) -> &'static str {
        match self.text_path.load(Ordering::SeqCst) {
            1 => InjectPath::Paste.as_str(),
            2 => InjectPath::Unicode.as_str(),
            _ => InjectPath::Keysym.as_str(),
        }
    }

    fn set_authorization(&self, authorization: Authorization) {
        self.state.store(authorization.to_u8(), Ordering::SeqCst);
    }
}

#[derive(Clone, Copy)]
enum Slot {
    Call,
    Pointer,
}

struct Engine<C: PortalConnector> {
    connector: C,
    session: Option<C::Session>,
    token_path: PathBuf,
    shared: Arc<Shared>,
    log: Log,
    clock: Box<dyn Fn() -> u64 + Send>,
    /// Wakes the worker loop (the closed hook runs on a portal task, the worker may be waiting for commands).
    wake: Closed,
    coalescer: MoveCoalescer,
    moves_held: usize,
    scroll_finish_at: Option<u64>,
    calls: u32,
    failures: u32,
    /// A paste is going on: a lost session is only dropped once the clipboard has been given back.
    in_paste: bool,
    /// The typed run could not be cleared from the clipboard; the session stays open until it can.
    clipboard_dirty: bool,
    clear_retry_at: Option<u64>,
    last_silent_restore_us: Option<u64>,
    /// A key or button release failed: the compositor may still think it is held down.
    keys_possibly_held: bool,
    /// The user asked for a new grant while the typed run was still on the clipboard.
    reauthorize_pending: bool,
    /// The clipboard failure is what made the injector not ready, so clearing it makes it ready again.
    restore_on_clear: bool,
}

impl<C: PortalConnector> Engine<C> {
    fn new(
        connector: C,
        token_path: PathBuf,
        shared: Arc<Shared>,
        log: Log,
        clock: Box<dyn Fn() -> u64 + Send>,
        wake: Closed,
    ) -> Self {
        Self {
            connector,
            session: None,
            token_path,
            shared,
            log,
            clock,
            wake,
            coalescer: MoveCoalescer::new(MOVE_MAX_HZ),
            moves_held: 0,
            scroll_finish_at: None,
            calls: 0,
            failures: 0,
            in_paste: false,
            clipboard_dirty: false,
            clear_retry_at: None,
            last_silent_restore_us: None,
            keys_possibly_held: false,
            reauthorize_pending: false,
            restore_on_clear: false,
        }
    }

    fn now(&self) -> u64 {
        (self.clock)()
    }

    fn emit(&self, line: &str) {
        (self.log)(line);
    }

    /// Asks the portal for a session; `use_saved_token = false` forces the permission dialog.
    fn authorize(&mut self, use_saved_token: bool) {
        self.finish_clipboard();
        if !use_saved_token {
            self.last_silent_restore_us = None;
        }
        self.keys_possibly_held = false;
        self.restore_on_clear = false;
        self.session = None;
        self.shared.recover.store(false, Ordering::SeqCst);
        self.shared.set_authorization(Authorization::Pending);
        let generation = self.shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let on_closed = self.closed_hook(generation);
        self.failures = 0;
        self.moves_held = 0;
        self.scroll_finish_at = None;
        self.coalescer = MoveCoalescer::new(MOVE_MAX_HZ);

        let saved = if use_saved_token { read_token(&self.token_path) } else { None };
        self.emit(&format!("ev=portal_open has_token={}", saved.is_some()));
        let started = Instant::now();
        match self.connector.connect(saved.as_deref(), on_closed) {
            Ok(connected) => {
                let token_saved = connected
                    .restore_token
                    .as_deref()
                    .is_some_and(|token| write_token(&self.token_path, token).is_ok());
                self.emit(&format!(
                    "ev=portal_started clipboard={} token_saved={token_saved} elapsed_ms={}",
                    connected.session.has_clipboard(),
                    started.elapsed().as_millis()
                ));
                self.session = Some(connected.session);
                self.shared.set_authorization(Authorization::Granted);
            }
            Err(error) => {
                let reason = if error == ConnectError::Denied { "denied" } else { "unavailable" };
                self.emit(&format!("ev=portal_failed reason={reason} elapsed_ms={}", started.elapsed().as_millis()));
                self.shared.set_authorization(Authorization::Denied);
            }
        }
    }

    /// What the portal calls when it closes this session from the outside (the user stopped sharing, the portal restarted).
    /// The injector is not ready from that moment on; the worker then tries the saved token before bothering the user.
    fn closed_hook(&self, generation: u64) -> Closed {
        let shared = self.shared.clone();
        let wake = self.wake.clone();
        Arc::new(move || {
            if shared.generation.load(Ordering::SeqCst) == generation {
                shared.closed_generation.store(generation, Ordering::SeqCst);
                shared.set_authorization(Authorization::Pending);
                shared.recover.store(true, Ordering::SeqCst);
                wake();
            }
        })
    }

    /// Brings the session back with the saved token (no dialog if the grant is still valid). Only once a minute: a session
    /// that closes again right after a silent restore was closed on purpose (the user stopped sharing), so it stays not ready
    /// until the user picks 重新授權.
    fn recover(&mut self) {
        self.let_go_of_closed_session();
        if self.clipboard_dirty {
            // Closing the session now would leave the typed run on the clipboard; the request is kept for later.
            self.shared.recover.store(true, Ordering::SeqCst);
            return;
        }
        let now = self.now();
        if self.last_silent_restore_us.is_some_and(|last| now.saturating_sub(last) < SILENT_RESTORE_INTERVAL_US) {
            self.emit("ev=portal_recover_suppressed");
            self.restore_on_clear = false;
            self.shared.set_authorization(Authorization::Denied);
            return;
        }
        self.last_silent_restore_us = Some(now);
        self.emit("ev=portal_recover");
        self.authorize(true);
    }

    /// The user asked for a new grant (dialog). Waits for a typed run that is still on the clipboard.
    fn request_reauthorize(&mut self) {
        self.let_go_of_closed_session();
        if self.clipboard_dirty {
            self.reauthorize_pending = true;
            return;
        }
        self.authorize(false);
    }

    /// The portal closed the current session from the outside.
    fn closed_by_portal(&self) -> bool {
        self.session.is_some()
            && self.shared.closed_generation.load(Ordering::SeqCst) == self.shared.generation.load(Ordering::SeqCst)
    }

    /// Keeping a session the portal closed protects nothing: its clipboard source is gone with it. A typed run that could not
    /// be cleared gets one last clear, then nothing waits for that session any more (no retries, no deferred recovery).
    fn let_go_of_closed_session(&mut self) {
        if self.clipboard_dirty && self.closed_by_portal() {
            self.emit("ev=clipboard_session_closed");
            self.finish_clipboard();
            self.restore_on_clear = false;
        }
    }

    /// Ends the session: the portal calls failed too often.
    fn lose_session(&mut self) {
        self.session = None;
        self.shared.set_authorization(Authorization::Denied);
        self.shared.recover.store(true, Ordering::SeqCst);
        self.emit("ev=portal_lost");
    }

    /// One portal call: counted for the report, and the session is dropped after repeated failures.
    fn portal<T>(&mut self, call: impl FnOnce(&mut C::Session) -> Result<T, InjectError>) -> Result<T, InjectError> {
        let Some(session) = self.session.as_mut() else {
            return Err(InjectError::NotReady);
        };
        self.calls += 1;
        let result = call(session);
        if result.is_ok() {
            self.failures = 0;
        } else {
            self.failures += 1;
            // While a paste is going on, or the typed run could not be cleared, the session has to stay: ending it would leave
            // the typed run on the clipboard.
            if self.failures >= LOST_AFTER_FAILURES && !self.in_paste && !self.clipboard_dirty {
                self.lose_session();
            }
        }
        result
    }

    fn pause(&mut self, duration: Duration) {
        if let Some(session) = self.session.as_mut() {
            session.sleep(duration);
        }
    }

    /// Runs `work` and records what happened, without content, in the given report slot.
    fn reported(
        &mut self,
        slot: Slot,
        path: InjectPath,
        units: usize,
        work: impl FnOnce(&mut Self) -> Result<(), InjectError>,
    ) -> Result<(), InjectError> {
        self.calls = 0;
        let result = if self.session.is_some() { work(self) } else { Err(InjectError::NotReady) };
        let report = InjectReport { path, units, portal_calls: self.calls, error_kind: result.as_ref().err().map(InjectError::kind) };
        let target = match slot {
            Slot::Call => &self.shared.report,
            Slot::Pointer => &self.shared.pointer_report,
        };
        *lock(target) = Some(report);
        self.settle_held_keys();
        result
    }

    /// Release of a key. A release that failed may leave the key held down in the compositor.
    fn release_key(&mut self, sym: i32) -> Result<(), InjectError> {
        let result = self.portal(|s| s.keysym(sym, false));
        self.keys_possibly_held |= result.is_err();
        result
    }

    fn release_button(&mut self, code: i32) -> Result<(), InjectError> {
        let result = self.portal(|s| s.pointer_button(code, false));
        self.keys_possibly_held |= result.is_err();
        result
    }

    /// Once the call and its clipboard give-back are over: if a release failed the session is closed, which makes the
    /// compositor release every key it holds for it (otherwise the next letter could arrive as Ctrl+letter). The session then
    /// comes back through the normal recovery rules.
    fn settle_held_keys(&mut self) {
        if self.keys_possibly_held && !self.in_paste && !self.clipboard_dirty && self.session.is_some() {
            self.keys_possibly_held = false;
            self.emit("ev=keys_possibly_held");
            self.lose_session();
        }
    }

    /// Press, then release. The release is always tried once the press went through.
    fn tap(&mut self, sym: i32) -> Result<(), InjectError> {
        self.portal(|s| s.keysym(sym, true))?;
        self.release_key(sym)
    }

    /// Presses every key in order and releases them in reverse. Every key that went down gets its release attempted, also
    /// when a press or an earlier release failed; the first error is the result.
    fn chord(&mut self, syms: &[i32]) -> Result<(), InjectError> {
        let mut first_error = None;
        let mut pressed = 0;
        for sym in syms {
            match self.portal(|s| s.keysym(*sym, true)) {
                Ok(()) => pressed += 1,
                Err(error) => {
                    first_error = Some(error);
                    break;
                }
            }
        }
        for sym in syms[..pressed].iter().rev() {
            if let Err(error) = self.release_key(*sym) {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    fn text(&mut self, text: &str) -> Result<(), InjectError> {
        let paste = self.shared.paste.load(Ordering::SeqCst) && self.session.as_ref().is_some_and(|s| s.has_clipboard());
        let segments = keysym::segment(text, paste);
        let path = InjectReport::path_for(&segments);
        self.shared.set_text_path(path);
        self.reported(Slot::Call, path, text.chars().count(), |engine| {
            for segment in &segments {
                if engine.shared.stop.load(Ordering::SeqCst) {
                    return Err(InjectError::Failed("stopping".to_string()));
                }
                match segment {
                    Segment::Keys(keys) => {
                        for sym in keys {
                            engine.tap(*sym)?;
                            engine.pause(KEY_GAP);
                        }
                    }
                    Segment::Paste(run) => engine.paste(run)?,
                }
            }
            Ok(())
        })
    }

    /// The run goes in through the clipboard (S5): the session takes the clipboard over, Ctrl+V, then the user's own text is
    /// served again. Nothing of the run stays pasteable afterwards: when there is no original text to give back (empty
    /// clipboard, an image), or giving it back fails, the clipboard is cleared. A clipboard that cannot be read is not
    /// touched at all and the call fails. The session is not ended while the run is on the clipboard.
    fn paste(&mut self, run: &str) -> Result<(), InjectError> {
        self.in_paste = true;
        self.shared.in_paste.store(true, Ordering::SeqCst);
        let result = self.paste_checked(run);
        self.in_paste = false;
        self.shared.in_paste.store(false, Ordering::SeqCst);
        if self.failures >= LOST_AFTER_FAILURES && !self.clipboard_dirty && self.session.is_some() {
            self.lose_session();
        }
        result
    }

    /// Reading the original can take seconds, so the injector being dropped is checked before anything is put on the clipboard.
    fn paste_checked(&mut self, run: &str) -> Result<(), InjectError> {
        let original = self.read_original()?;
        if self.shared.stop.load(Ordering::SeqCst) {
            return Err(InjectError::Failed("stopping".to_string()));
        }
        self.paste_run(run, original)
    }

    /// The original text of the clipboard. Failing to read it says nothing about the session, so it is not counted towards
    /// losing it.
    fn read_original(&mut self) -> Result<Option<String>, InjectError> {
        let session = self.session.as_mut().ok_or(InjectError::NotReady)?;
        self.calls += 1;
        session.clipboard_read().map_err(|_| InjectError::Failed("clipboard_read".to_string()))
    }

    fn paste_run(&mut self, run: &str, original: Option<String>) -> Result<(), InjectError> {
        self.portal(|s| s.clipboard_set(run))?;
        let pasted = self.paste_keys();
        let restored = self.give_back_clipboard(original);
        pasted.and(restored)
    }

    fn paste_keys(&mut self) -> Result<(), InjectError> {
        self.pause(PASTE_SETTLE);
        self.chord(&[XK_CONTROL_L, XK_LOWER_V])?;
        self.pause(PASTE_WAIT);
        Ok(())
    }

    fn give_back_clipboard(&mut self, original: Option<String>) -> Result<(), InjectError> {
        match original {
            Some(text) => self.portal(|s| s.clipboard_set(&text)).inspect_err(|_| {
                let _ = self.clear_clipboard();
            }),
            None => self.clear_clipboard(),
        }
    }

    /// Overwrites the typed run with nothing. When that fails twice the session is kept open (closing it would leave the
    /// run on the clipboard) and not ready, and the clear is tried again from the timer.
    fn clear_clipboard(&mut self) -> Result<(), InjectError> {
        let result = self.portal(|s| s.clipboard_clear()).or_else(|_| self.portal(|s| s.clipboard_clear()));
        if result.is_err() && self.session.is_some() {
            self.clipboard_dirty = true;
            self.clear_retry_at = Some(self.now() + CLEAR_RETRY_US);
            if self.shared.authorization() == Authorization::Granted {
                self.restore_on_clear = true;
            }
            self.shared.set_authorization(Authorization::Denied);
            self.emit("ev=clipboard_clear_failed");
        }
        result
    }

    fn retry_clear(&mut self) {
        self.clear_retry_at = None;
        if self.closed_by_portal() {
            // The recovery the closed signal asked for takes it from here.
            self.let_go_of_closed_session();
            return;
        }
        if self.portal(|s| s.clipboard_clear()).is_ok() {
            self.clipboard_dirty = false;
            // Only a denial that the failed clear itself caused is lifted; a suppressed recovery stays for the user to decide.
            if self.restore_on_clear && self.shared.authorization() == Authorization::Denied {
                self.shared.set_authorization(Authorization::Granted);
            }
            self.restore_on_clear = false;
            self.emit("ev=clipboard_clear_ok");
            self.settle_held_keys();
            if std::mem::take(&mut self.reauthorize_pending) {
                self.authorize(false);
            } else if self.shared.recover.load(Ordering::SeqCst) {
                (self.wake)();
            }
        } else {
            self.clear_retry_at = Some(self.now() + CLEAR_RETRY_US);
        }
    }

    /// Last chance to clear a clipboard that still holds a typed run, before the session goes away.
    fn finish_clipboard(&mut self) {
        if self.clipboard_dirty && self.session.is_some() {
            let _ = self.portal(|s| s.clipboard_clear());
        }
        self.clipboard_dirty = false;
        self.clear_retry_at = None;
    }

    fn key(&mut self, sym: i32) -> Result<(), InjectError> {
        self.reported(Slot::Call, InjectPath::Keysym, 1, |engine| engine.tap(sym))
    }

    fn pointer_move(&mut self, dx: f64, dy: f64) {
        if self.session.is_none() {
            return;
        }
        self.moves_held += 1;
        let now = self.now();
        if let Some(whole) = self.coalescer.push(dx, dy, now) {
            self.send_motion(whole);
        }
    }

    fn send_motion(&mut self, (dx, dy): (f64, f64)) {
        let units = std::mem::take(&mut self.moves_held);
        let _ = self.reported(Slot::Pointer, InjectPath::Keysym, units, |engine| engine.portal(|s| s.pointer_motion(dx, dy)));
    }

    /// Sends the held-back movement now, so a click lands where the finger was.
    fn flush_moves(&mut self) {
        let now = self.now();
        if let Some(whole) = self.coalescer.flush_now(now) {
            self.send_motion(whole);
        }
    }

    fn button(&mut self, button: Button, down: bool) -> Result<(), InjectError> {
        self.flush_moves();
        self.end_scroll();
        let code = button_code(button);
        self.reported(Slot::Call, InjectPath::Keysym, 1, |engine| {
            if down {
                engine.portal(|s| s.pointer_button(code, true))
            } else {
                engine.release_button(code)
            }
        })
    }

    fn click(&mut self, button: Button, count: u8) -> Result<(), InjectError> {
        self.flush_moves();
        self.end_scroll();
        let code = button_code(button);
        let count = count.min(MAX_CLICK_COUNT);
        self.reported(Slot::Call, InjectPath::Keysym, usize::from(count), |engine| {
            for index in 0..count {
                engine.portal(|s| s.pointer_button(code, true))?;
                engine.pause(CLICK_HOLD);
                engine.release_button(code)?;
                if index + 1 < count {
                    engine.pause(CLICK_GAP);
                }
            }
            Ok(())
        })
    }

    fn scroll(&mut self, dx: f64, dy: f64) {
        if self.session.is_none() || !dx.is_finite() || !dy.is_finite() {
            return;
        }
        self.flush_moves();
        let (axis_x, axis_y) = scroll_axis(dx, dy);
        let finish_at = self.now() + SCROLL_IDLE.as_micros() as u64;
        let _ = self.reported(Slot::Pointer, InjectPath::Keysym, 1, |engine| {
            engine.portal(|s| s.pointer_axis(axis_x, axis_y, false))
        });
        self.scroll_finish_at = Some(finish_at);
    }

    /// Tells the portal the smooth scroll that is still open has ended.
    fn end_scroll(&mut self) {
        if self.scroll_finish_at.take().is_some() {
            let _ = self.reported(Slot::Pointer, InjectPath::Keysym, 1, |engine| {
                engine.portal(|s| s.pointer_axis(0.0, 0.0, true))
            });
        }
    }

    /// The time (microseconds on the engine's clock) at which `on_timer` has something to do.
    fn next_wakeup(&self) -> Option<u64> {
        [self.coalescer.due_at(), self.scroll_finish_at, self.clear_retry_at].into_iter().flatten().min()
    }

    fn on_timer(&mut self) {
        let now = self.now();
        if let Some(whole) = self.coalescer.flush_due(now) {
            self.send_motion(whole);
        }
        if self.scroll_finish_at.is_some_and(|due| now >= due) {
            self.end_scroll();
        }
        if self.clear_retry_at.is_some_and(|due| now >= due) {
            self.retry_clear();
        }
    }
}

/// Options of `LinuxInjector`.
#[derive(Clone)]
pub struct LinuxOptions {
    /// Non-Latin-1 text goes through the clipboard (default) instead of Unicode keysyms.
    pub paste_non_ascii: bool,
    /// Receives one line per event: kinds, lengths and results, never content.
    pub log: Option<Log>,
    /// How long a caller waits for the portal on top of the per-character budget before the call fails.
    pub call_timeout: Duration,
    /// How long dropping the injector waits for the worker before it lets go of it.
    pub shutdown_wait: Duration,
    /// Dropping the injector while a paste is going on waits this long, so the clipboard is given back first.
    pub paste_shutdown_wait: Duration,
}

impl Default for LinuxOptions {
    fn default() -> Self {
        Self { paste_non_ascii: true, log: None, call_timeout: Duration::from_secs(2), shutdown_wait: Duration::from_secs(3),
            paste_shutdown_wait: keysym::paste_worst_case(),
        }
    }
}

type Reply = mpsc::SyncSender<Result<(), InjectError>>;

enum Command {
    Text(String, Reply),
    Key(i32, Reply),
    Move(f64, f64),
    Button(Button, bool, Reply),
    Click(Button, u8, Reply),
    Scroll(f64, f64),
    Reauthorize,
    /// Only wakes the worker loop.
    Wake,
    Shutdown,
}

fn run_worker<C: PortalConnector>(mut engine: Engine<C>, commands: mpsc::Receiver<Command>) {
    engine.authorize(true);
    loop {
        let command = match engine.next_wakeup() {
            None => match commands.recv() {
                Ok(command) => Some(command),
                Err(_) => break,
            },
            Some(due) => match commands.recv_timeout(Duration::from_micros(due.saturating_sub(engine.now()))) {
                Ok(command) => Some(command),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
        };
        match command {
            Some(Command::Text(text, reply)) => {
                let _ = reply.send(engine.text(&text));
            }
            Some(Command::Key(sym, reply)) => {
                let _ = reply.send(engine.key(sym));
            }
            Some(Command::Move(dx, dy)) => engine.pointer_move(dx, dy),
            Some(Command::Button(button, down, reply)) => {
                let _ = reply.send(engine.button(button, down));
            }
            Some(Command::Click(button, count, reply)) => {
                let _ = reply.send(engine.click(button, count));
            }
            Some(Command::Scroll(dx, dy)) => engine.scroll(dx, dy),
            Some(Command::Reauthorize) => engine.request_reauthorize(),
            Some(Command::Wake) => {}
            Some(Command::Shutdown) => break,
            None => {}
        }
        if engine.shared.stop.load(Ordering::SeqCst) {
            break;
        }
        if engine.shared.recover.swap(false, Ordering::SeqCst) {
            engine.recover();
        }
        engine.on_timer();
    }
    engine.finish_clipboard();
}

pub struct LinuxInjector {
    commands: Option<mpsc::Sender<Command>>,
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
    call_timeout: Duration,
    shutdown_wait: Duration,
    paste_shutdown_wait: Duration,
}

impl LinuxInjector {
    /// Starts the worker and asks the portal for a session with the token saved at `token_path`. Returns at once: until
    /// the portal answers (a permission dialog may be open) `ready()` and `trusted()` are false.
    pub fn start(token_path: PathBuf, options: LinuxOptions) -> Self {
        Self::with_connector(AshpdConnector, token_path, options)
    }

    pub fn with_connector<C>(connector: C, token_path: PathBuf, options: LinuxOptions) -> Self
    where
        C: PortalConnector + Send + 'static,
    {
        let shared = Shared::new(options.paste_non_ascii);
        let log: Log = options.log.unwrap_or_else(|| Arc::new(|_| {}));
        let (commands, receiver) = mpsc::channel();
        let wake_commands = commands.clone();
        let wake: Closed = Arc::new(move || {
            let _ = wake_commands.send(Command::Wake);
        });
        let started = Instant::now();
        let worker_shared = shared.clone();
        let (call_timeout, shutdown_wait, paste_shutdown_wait) =
            (options.call_timeout, options.shutdown_wait, options.paste_shutdown_wait);
        let worker = std::thread::Builder::new()
            .name("rk-inject".to_string())
            .spawn(move || {
                let clock = Box::new(move || started.elapsed().as_micros() as u64);
                run_worker(Engine::new(connector, token_path, worker_shared, log, clock, wake), receiver);
            })
            .ok();
        if worker.is_none() {
            shared.set_authorization(Authorization::Denied);
        }
        Self { commands: Some(commands), shared, worker, call_timeout, shutdown_wait, paste_shutdown_wait }
    }

    pub fn authorization(&self) -> Authorization {
        self.shared.authorization()
    }

    /// Waits until the portal has answered (or `timeout`); returns the state then.
    pub fn wait_until_settled(&self, timeout: Duration) -> Authorization {
        let deadline = Instant::now() + timeout;
        while self.authorization() == Authorization::Pending && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        self.authorization()
    }

    /// Asks for a new grant: closes the session and shows the portal's permission dialog again.
    pub fn reauthorize(&self) {
        self.shared.set_authorization(Authorization::Pending);
        let _ = self.send(Command::Reauthorize);
    }

    pub fn set_paste_non_ascii(&self, on: bool) {
        self.shared.paste.store(on, Ordering::SeqCst);
    }

    /// What the last `text`, `backspace`, `enter`, `button` or `click` did: path, length, portal calls, error kind. Never
    /// content.
    pub fn last_report(&self) -> Option<InjectReport> {
        *lock(&self.shared.report)
    }

    /// The same for the last portal call made for a pointer move or scroll (these run on the worker's timers).
    pub fn last_pointer_report(&self) -> Option<InjectReport> {
        *lock(&self.shared.pointer_report)
    }

    fn send(&self, command: Command) -> Result<(), InjectError> {
        let stopped = || InjectError::Failed("injector stopped".to_string());
        self.commands.as_ref().ok_or_else(stopped)?.send(command).map_err(|_| stopped())
    }

    fn require_granted(&self) -> Result<(), InjectError> {
        if self.shared.authorization() == Authorization::Granted {
            Ok(())
        } else {
            Err(InjectError::NotReady)
        }
    }

    /// Sends a command that carries a reply channel and waits at most `budget` for the answer. A portal that does not
    /// answer in time makes the injector not ready; the worker brings the session back once it is free again.
    fn call(&self, budget: Duration, command: impl FnOnce(Reply) -> Command) -> Result<(), InjectError> {
        self.require_granted()?;
        let (reply, answer) = mpsc::sync_channel(1);
        self.send(command(reply))?;
        match answer.recv_timeout(budget) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.shared.set_authorization(Authorization::Pending);
                self.shared.recover.store(true, Ordering::SeqCst);
                Err(InjectError::Failed("portal call timed out".to_string()))
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(InjectError::Failed("injector stopped".to_string())),
        }
    }
}

impl Drop for LinuxInjector {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        let _ = self.send(Command::Shutdown);
        self.commands = None;
        // The worker closes the portal session on its way out. A text call stops before its next run; a run that is on the
        // clipboard is always given back first, so a paste in progress is waited for (`paste_shutdown_wait`). Anything else
        // that is stuck (a portal that does not answer, a permission dialog nobody answers) is let go after `shutdown_wait`
        // and dies with the process. The deadline is fixed here, once: a paste that ends during the wait does not shorten it,
        // because the worker may still be clearing the clipboard on its way out. A paste cannot begin after this point: the
        // worker sets `in_paste` before it checks `stop`, so it either saw `stop` or this load sees its paste.
        if let Some(worker) = self.worker.take() {
            let limit = if self.shared.in_paste.load(Ordering::SeqCst) {
                self.paste_shutdown_wait.max(self.shutdown_wait)
            } else {
                self.shutdown_wait
            };
            let deadline = Instant::now() + limit;
            while !worker.is_finished() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
            if worker.is_finished() {
                let _ = worker.join();
            }
        }
    }
}

impl Injector for LinuxInjector {
    fn text(&mut self, s: &str) -> Result<(), InjectError> {
        self.call(keysym::text_budget(s, self.call_timeout), |reply| Command::Text(s.to_string(), reply))
    }

    fn backspace(&mut self) -> Result<(), InjectError> {
        self.call(self.call_timeout, |reply| Command::Key(XK_BACKSPACE, reply))
    }

    fn enter(&mut self) -> Result<(), InjectError> {
        self.call(self.call_timeout, |reply| Command::Key(XK_RETURN, reply))
    }

    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.require_granted()?;
        self.send(Command::Move(dx, dy))
    }

    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError> {
        self.call(self.call_timeout, |reply| Command::Button(b, down, reply))
    }

    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError> {
        self.call(self.call_timeout + Duration::from_millis(100) * u32::from(count), |reply| Command::Click(b, count, reply))
    }

    fn scroll(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.require_granted()?;
        self.send(Command::Scroll(dx, dy))
    }

    fn ready(&self) -> bool {
        self.shared.authorization() == Authorization::Granted
    }

    fn trusted(&self) -> bool {
        self.ready()
    }

    fn path(&self) -> &'static str {
        self.shared.text_path_name()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::AtomicI32;

    #[derive(Debug, Clone, PartialEq)]
    enum Op {
        Key(i32, bool),
        Motion(f64, f64),
        Button(i32, bool),
        Axis(f64, f64, bool),
        ClipRead,
        ClipSet(String),
        ClipClear,
        Sleep(Duration),
    }

    type ReadHook = Box<dyn Fn() + Send>;

    /// Who owns the clipboard in the fake desktop and what a Ctrl+V would paste.
    #[derive(Debug, Clone, PartialEq)]
    enum Selection {
        Empty,
        Foreign(String),
        NonText,
        /// This session owns it and serves the text (empty text serves nothing).
        Session(String),
    }

    struct Flags {
        fail_all: AtomicBool,
        fail_keys: AtomicBool,
        fail_releases: AtomicBool,
        fail_press_of: AtomicI32,
        fail_clip_read: AtomicBool,
        fail_clip_set: AtomicBool,
        fail_clip_clear: AtomicBool,
        /// How many clipboard sets still succeed; negative means all.
        clip_sets_allowed: AtomicI32,
        /// Key calls block while this is set (for at most 3 s).
        hang: AtomicBool,
        /// `connect` waits while this is set.
        block_connect: AtomicBool,
        /// Clipboard reads block while this is set (for at most 3 s).
        hang_read: AtomicBool,
        /// Clipboard clears after this many take 1.5 s each; negative means never.
        slow_clears_after: AtomicI32,
        clears_made: AtomicI32,
    }

    #[derive(Clone)]
    struct World {
        ops: Arc<Mutex<Vec<Op>>>,
        selection: Arc<Mutex<Selection>>,
        tokens_seen: Arc<Mutex<Vec<Option<String>>>>,
        closed_hooks: Arc<Mutex<Vec<Closed>>>,
        outcome: Arc<Mutex<Result<(), ConnectError>>>,
        flags: Arc<Flags>,
        /// Runs inside every clipboard read (a user quitting while the original is being read).
        on_read: Arc<Mutex<Option<ReadHook>>>,
    }

    impl World {
        fn new() -> Self {
            Self {
                ops: Arc::default(),
                selection: Arc::new(Mutex::new(Selection::Empty)),
                tokens_seen: Arc::default(),
                closed_hooks: Arc::default(),
                outcome: Arc::new(Mutex::new(Ok(()))),
                on_read: Arc::default(),
                flags: Arc::new(Flags {
                    fail_all: AtomicBool::new(false),
                    fail_keys: AtomicBool::new(false),
                    fail_releases: AtomicBool::new(false),
                    fail_press_of: AtomicI32::new(-1),
                    fail_clip_read: AtomicBool::new(false),
                    fail_clip_set: AtomicBool::new(false),
                    fail_clip_clear: AtomicBool::new(false),
                    clip_sets_allowed: AtomicI32::new(-1),
                    hang: AtomicBool::new(false),
                    block_connect: AtomicBool::new(false),
                    hang_read: AtomicBool::new(false),
                    slow_clears_after: AtomicI32::new(-1),
                    clears_made: AtomicI32::new(0),
                }),
            }
        }

        /// Every call the session received, including the ones that failed.
        fn ops(&self) -> Vec<Op> {
            self.ops.lock().unwrap().clone()
        }

        /// Without the 3 ms gaps between characters.
        fn ops_without_gaps(&self) -> Vec<Op> {
            self.ops().into_iter().filter(|op| *op != Op::Sleep(KEY_GAP)).collect()
        }

        fn set_clipboard(&self, text: &str) {
            *self.selection.lock().unwrap() = Selection::Foreign(text.to_string());
        }

        fn set_selection(&self, selection: Selection) {
            *self.selection.lock().unwrap() = selection;
        }

        /// What Ctrl+V would paste in another application.
        fn clipboard(&self) -> Option<String> {
            match &*self.selection.lock().unwrap() {
                Selection::Foreign(text) => Some(text.clone()),
                Selection::Session(text) if !text.is_empty() => Some(text.clone()),
                _ => None,
            }
        }

        fn set_outcome(&self, outcome: Result<(), ConnectError>) {
            *self.outcome.lock().unwrap() = outcome;
        }

        fn closed_hook(&self, index: usize) -> Closed {
            self.closed_hooks.lock().unwrap()[index].clone()
        }

        fn tokens_seen(&self) -> Vec<Option<String>> {
            self.tokens_seen.lock().unwrap().clone()
        }
    }

    struct FakeSession {
        world: World,
        clipboard_supported: bool,
    }

    impl FakeSession {
        fn record(&self, op: Op) -> Result<(), InjectError> {
            let flags = &self.world.flags;
            let key = matches!(op, Op::Key(..));
            let release = matches!(op, Op::Key(_, false) | Op::Button(_, false));
            let refused = flags.fail_all.load(Ordering::SeqCst)
                || (key && flags.fail_keys.load(Ordering::SeqCst))
                || (release && flags.fail_releases.load(Ordering::SeqCst))
                || (matches!(op, Op::Key(sym, true) if sym == flags.fail_press_of.load(Ordering::SeqCst)))
                || (op == Op::ClipRead && flags.fail_clip_read.load(Ordering::SeqCst))
                || (matches!(op, Op::ClipSet(_)) && flags.fail_clip_set.load(Ordering::SeqCst))
                || (op == Op::ClipClear && flags.fail_clip_clear.load(Ordering::SeqCst));
            if key {
                let started = Instant::now();
                while flags.hang.load(Ordering::SeqCst) && started.elapsed() < Duration::from_secs(3) {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
            self.world.ops.lock().unwrap().push(op);
            if refused {
                Err(InjectError::Failed("fake portal failure".to_string()))
            } else {
                Ok(())
            }
        }
    }

    impl PortalSession for FakeSession {
        fn keysym(&mut self, sym: i32, pressed: bool) -> Result<(), InjectError> {
            self.record(Op::Key(sym, pressed))
        }
        fn pointer_motion(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
            self.record(Op::Motion(dx, dy))
        }
        fn pointer_button(&mut self, code: i32, pressed: bool) -> Result<(), InjectError> {
            self.record(Op::Button(code, pressed))
        }
        fn pointer_axis(&mut self, dx: f64, dy: f64, finish: bool) -> Result<(), InjectError> {
            self.record(Op::Axis(dx, dy, finish))
        }
        fn has_clipboard(&self) -> bool {
            self.clipboard_supported
        }
        fn clipboard_read(&mut self) -> Result<Option<String>, InjectError> {
            let started = Instant::now();
            while self.world.flags.hang_read.load(Ordering::SeqCst) && started.elapsed() < Duration::from_secs(3) {
                std::thread::sleep(Duration::from_millis(5));
            }
            if let Some(hook) = &*self.world.on_read.lock().unwrap() {
                hook();
            }
            self.record(Op::ClipRead)?;
            Ok(match &*self.world.selection.lock().unwrap() {
                Selection::Foreign(text) => Some(text.clone()),
                Selection::Session(text) if !text.is_empty() => Some(text.clone()),
                _ => None,
            })
        }
        fn clipboard_set(&mut self, text: &str) -> Result<(), InjectError> {
            self.record(Op::ClipSet(text.to_string()))?;
            let allowed = &self.world.flags.clip_sets_allowed;
            match allowed.load(Ordering::SeqCst) {
                0 => return Err(InjectError::Failed("fake clipboard refused".to_string())),
                n if n > 0 => allowed.store(n - 1, Ordering::SeqCst),
                _ => {}
            }
            self.world.set_selection(Selection::Session(text.to_string()));
            Ok(())
        }
        fn clipboard_clear(&mut self) -> Result<(), InjectError> {
            let flags = &self.world.flags;
            let made = flags.clears_made.fetch_add(1, Ordering::SeqCst);
            let slow_after = flags.slow_clears_after.load(Ordering::SeqCst);
            if slow_after >= 0 && made >= slow_after {
                std::thread::sleep(Duration::from_millis(1500));
            }
            // A refused call leaves the selection as it was: the compositor still holds the typed run.
            self.record(Op::ClipClear)?;
            self.world.set_selection(Selection::Session(String::new()));
            Ok(())
        }
        fn sleep(&mut self, duration: Duration) {
            self.world.ops.lock().unwrap().push(Op::Sleep(duration));
        }
    }

    #[derive(Clone)]
    struct FakeConnector {
        world: World,
        clipboard_supported: bool,
        connects: Arc<Mutex<u32>>,
    }

    impl FakeConnector {
        fn granted(world: &World) -> Self {
            Self { world: world.clone(), clipboard_supported: true, connects: Arc::new(Mutex::new(0)) }
        }
    }

    impl PortalConnector for FakeConnector {
        type Session = FakeSession;

        fn connect(&mut self, restore_token: Option<&str>, on_closed: Closed) -> Result<Connected<FakeSession>, ConnectError> {
            self.world.tokens_seen.lock().unwrap().push(restore_token.map(str::to_string));
            while self.world.flags.block_connect.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(5));
            }
            let number = {
                let mut connects = self.connects.lock().unwrap();
                *connects += 1;
                *connects
            };
            self.world.outcome.lock().unwrap().clone()?;
            self.world.closed_hooks.lock().unwrap().push(on_closed);
            Ok(Connected {
                session: FakeSession { world: self.world.clone(), clipboard_supported: self.clipboard_supported },
                restore_token: Some(format!("token-{number}")),
            })
        }
    }

    struct Rig {
        engine: Engine<FakeConnector>,
        world: World,
        shared: Arc<Shared>,
        now_us: Arc<std::sync::atomic::AtomicU64>,
    }

    impl Rig {
        fn new(connector: FakeConnector, world: &World, token_name: &str) -> Self {
            let shared = Shared::new(true);
            let now_us = Arc::new(std::sync::atomic::AtomicU64::new(1_000_000));
            let clock_source = now_us.clone();
            let engine = Engine::new(
                connector,
                temp_token_path(token_name),
                shared.clone(),
                Arc::new(|_| {}),
                Box::new(move || clock_source.load(Ordering::SeqCst)),
                Arc::new(|| {}),
            );
            Self { engine, world: world.clone(), shared, now_us }
        }

        fn granted() -> Self {
            let world = World::new();
            let mut rig = Self::new(FakeConnector::granted(&world), &world, "rig");
            rig.engine.authorize(false);
            rig
        }

        fn authorization(&self) -> Authorization {
            self.shared.authorization()
        }

        fn last_report(&self) -> InjectReport {
            self.shared.report.lock().unwrap().expect("a report was recorded")
        }
    }

    fn temp_token_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rk-inject-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("remote-keyboard").join("portal-token")
    }

    fn quick_options() -> LinuxOptions {
        LinuxOptions { call_timeout: Duration::from_millis(100), shutdown_wait: Duration::from_millis(200),
            paste_shutdown_wait: Duration::from_secs(5),
            ..LinuxOptions::default()
        }
    }

    fn started(world: &World, name: &str, options: LinuxOptions) -> LinuxInjector {
        let injector = LinuxInjector::with_connector(FakeConnector::granted(world), temp_token_path(name), options);
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Granted);
        injector
    }

    fn wait_ready(injector: &LinuxInjector) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !injector.ready() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(injector.ready(), "the injector did not become ready again");
    }

    fn key_taps(sym: i32) -> [Op; 2] {
        [Op::Key(sym, true), Op::Key(sym, false)]
    }

    fn ctrl_v() -> [Op; 4] {
        [Op::Key(XK_CONTROL_L, true), Op::Key(XK_LOWER_V, true), Op::Key(XK_LOWER_V, false), Op::Key(XK_CONTROL_L, false)]
    }

    fn position(ops: &[Op], wanted: &Op) -> usize {
        ops.iter().position(|op| op == wanted).unwrap_or_else(|| panic!("{wanted:?} not in {ops:?}"))
    }

    #[test]
    fn non_ascii_uses_paste_when_enabled() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.engine.text("a\u{4e2d}b").unwrap();

        let mut expected = Vec::new();
        expected.extend(key_taps(0x61));
        expected.push(Op::ClipRead);
        expected.push(Op::ClipSet("\u{4e2d}".to_string()));
        expected.push(Op::Sleep(PASTE_SETTLE));
        expected.extend(ctrl_v());
        expected.push(Op::Sleep(PASTE_WAIT));
        expected.push(Op::ClipSet("ORIGINAL".to_string()));
        expected.extend(key_taps(0x62));
        assert_eq!(rig.world.ops_without_gaps(), expected);

        let report = rig.last_report();
        assert_eq!(report.path, InjectPath::Paste);
        assert_eq!(report.units, 3);
        assert_eq!(report.error_kind, None);
    }

    #[test]
    fn latin1_text_is_typed_with_a_3_ms_gap() {
        let mut rig = Rig::granted();
        rig.engine.text("hi").unwrap();
        assert_eq!(
            rig.world.ops(),
            vec![
                Op::Key(0x68, true),
                Op::Key(0x68, false),
                Op::Sleep(KEY_GAP),
                Op::Key(0x69, true),
                Op::Key(0x69, false),
                Op::Sleep(KEY_GAP),
            ]
        );
        let report = rig.last_report();
        assert_eq!((report.path, report.units, report.portal_calls), (InjectPath::Keysym, 2, 4));
    }

    #[test]
    fn clipboard_is_restored_after_paste() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("SENTINEL");
        rig.engine.text("\u{4e2d}\u{6587}\u{1F600}").unwrap();
        assert_eq!(rig.world.clipboard().as_deref(), Some("SENTINEL"));

        let ops = rig.world.ops_without_gaps();
        let pasted = position(&ops, &Op::ClipSet("\u{4e2d}\u{6587}\u{1F600}".to_string()));
        let restored = position(&ops, &Op::ClipSet("SENTINEL".to_string()));
        let wait = position(&ops, &Op::Sleep(PASTE_WAIT));
        assert!(pasted < wait && wait < restored, "set, then the paste wait after Ctrl+V, then restore: {ops:?}");
    }

    #[test]
    fn clipboard_is_restored_even_when_ctrl_v_fails() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("SENTINEL");
        rig.world.flags.fail_keys.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert_eq!(rig.world.clipboard().as_deref(), Some("SENTINEL"));
        assert_eq!(rig.last_report().error_kind, Some("failed"));
    }

    #[test]
    fn empty_original_clipboard_is_cleared_after_paste() {
        let mut rig = Rig::granted();
        rig.engine.text("\u{4e2d}").unwrap();
        assert!(rig.world.ops().contains(&Op::ClipClear));
        assert_eq!(rig.world.clipboard(), None, "the typed run must not stay pasteable");
    }

    #[test]
    fn non_text_original_does_not_leave_the_typed_run_behind() {
        let mut rig = Rig::granted();
        rig.world.set_selection(Selection::NonText);
        rig.engine.text("\u{4e2d}").unwrap();
        assert_eq!(rig.world.clipboard(), None);
    }

    #[test]
    fn second_paste_does_not_resurrect_the_first() {
        let mut rig = Rig::granted();
        rig.engine.text("\u{4e2d}").unwrap();
        rig.engine.text("\u{6587}").unwrap();
        let sets: Vec<Op> = rig.world.ops().into_iter().filter(|op| matches!(op, Op::ClipSet(_))).collect();
        assert_eq!(sets, vec![Op::ClipSet("\u{4e2d}".to_string()), Op::ClipSet("\u{6587}".to_string())]);
        assert_eq!(rig.world.clipboard(), None);
    }

    #[test]
    fn unreadable_clipboard_blocks_the_paste() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.fail_clip_read.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let ops = rig.world.ops();
        assert!(!ops.iter().any(|op| matches!(op, Op::ClipSet(_) | Op::ClipClear)), "{ops:?}");
        assert!(!ops.contains(&Op::Key(XK_CONTROL_L, true)), "{ops:?}");
        assert_eq!(rig.world.clipboard().as_deref(), Some("ORIGINAL"));
        assert_eq!(rig.last_report().error_kind, Some("failed"));
    }

    #[test]
    fn failed_set_selection_leaves_the_clipboard_alone() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.fail_clip_set.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let ops = rig.world.ops();
        assert!(!ops.contains(&Op::Key(XK_CONTROL_L, true)), "{ops:?}");
        assert!(!ops.contains(&Op::ClipClear), "nothing was taken over, so nothing is cleared: {ops:?}");
        assert_eq!(rig.world.clipboard().as_deref(), Some("ORIGINAL"));
    }

    #[test]
    fn failed_restore_clears_the_typed_run() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.clip_sets_allowed.store(1, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert!(rig.world.ops().contains(&Op::ClipClear));
        assert_eq!(rig.world.clipboard(), None, "the typed run must not stay pasteable");
    }


    #[test]
    fn session_is_kept_until_the_clipboard_is_given_back() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        let flags = &rig.world.flags;
        flags.fail_press_of.store(XK_LOWER_V, Ordering::SeqCst);
        flags.fail_releases.store(true, Ordering::SeqCst);
        flags.clip_sets_allowed.store(1, Ordering::SeqCst);
        // V press (1), Control release (2) and the restore (3) fail: the third failure must not end the session before the
        // typed run is cleared from the clipboard.
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert!(rig.world.ops().contains(&Op::ClipClear), "{:?}", rig.world.ops());
        assert_eq!(rig.world.clipboard(), None);
    }

    #[test]
    fn failed_clear_keeps_the_session_and_retries_later() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let clears = rig.world.ops().iter().filter(|op| **op == Op::ClipClear).count();
        assert_eq!(clears, 2, "one retry");
        assert!(rig.engine.session.is_some(), "ending the session would leave the typed run on the clipboard");
        assert_ne!(rig.authorization(), Authorization::Granted);
        assert!(!rig.shared.recover.load(Ordering::SeqCst), "no recovery that would close the session");

        rig.world.flags.fail_clip_clear.store(false, Ordering::SeqCst);
        let due = rig.engine.next_wakeup().expect("a retry is scheduled");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.clipboard(), None);
        assert_eq!(rig.authorization(), Authorization::Granted);
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn reauthorize_clears_a_dirty_clipboard_before_it_lets_go_of_the_session() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        rig.world.flags.fail_clip_clear.store(false, Ordering::SeqCst);
        rig.engine.authorize(false);
        assert_eq!(rig.world.clipboard(), None);
        assert_eq!(rig.authorization(), Authorization::Granted);
    }

    #[test]
    fn stop_flag_ends_text_before_the_next_run() {
        let mut rig = Rig::granted();
        rig.shared.stop.store(true, Ordering::SeqCst);
        assert_eq!(rig.engine.text("a\u{4e2d}b"), Err(InjectError::Failed("stopping".to_string())));
        assert!(rig.world.ops().is_empty());
    }

    #[test]
    fn drop_keeps_the_paste_deadline_after_the_paste_ends() {
        let world = World::new();
        let mut injector = started(&world, "drop-deadline", quick_options());
        world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        // The paste's two clears fail fast; the last clear on the worker's way out takes 1.5 s.
        world.flags.slow_clears_after.store(2, Ordering::SeqCst);
        world.flags.hang.store(true, Ordering::SeqCst);
        let release = world.flags.clone();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1400));
            release.hang.store(false, Ordering::SeqCst);
        });
        assert!(injector.text("\u{4e2d}").is_err(), "the call times out while Ctrl+V hangs");
        drop(injector);
        let clears = world.ops().iter().filter(|op| **op == Op::ClipClear).count();
        assert_eq!(clears, 3, "drop let go of the worker before its last clear: {:?}", world.ops());
        releaser.join().unwrap();
    }

    #[test]
    fn drop_waits_for_the_give_back_of_a_paste_in_progress() {
        let world = World::new();
        let mut injector = started(&world, "drop-paste", quick_options());
        world.set_clipboard("ORIGINAL");
        world.flags.hang.store(true, Ordering::SeqCst);
        let release = world.flags.clone();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1400));
            release.hang.store(false, Ordering::SeqCst);
        });
        assert!(injector.text("\u{4e2d}").is_err(), "the caller gives up long before the portal answers");
        let began = Instant::now();
        drop(injector);
        assert!(began.elapsed() >= Duration::from_millis(300), "dropped without waiting: {:?}", began.elapsed());
        assert_eq!(world.clipboard().as_deref(), Some("ORIGINAL"), "the typed run must not outlive the injector");
        releaser.join().unwrap();
    }

    #[test]
    fn second_silent_restore_within_a_minute_needs_the_user() {
        let mut rig = Rig::granted();
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Granted);
        assert_eq!(rig.world.tokens_seen().len(), 2);

        rig.now_us.fetch_add(10_000_000, Ordering::SeqCst);
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Denied);
        assert_eq!(rig.world.tokens_seen().len(), 2, "no second silent connect");

        rig.now_us.fetch_add(61_000_000, Ordering::SeqCst);
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Granted, "a minute later it may try again");
    }

    #[test]
    fn the_user_choosing_reauthorize_resets_the_silent_restore_limit() {
        let mut rig = Rig::granted();
        rig.engine.recover();
        rig.engine.authorize(false);
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Granted);
    }

    #[test]
    fn unreadable_clipboard_does_not_end_the_session() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.fail_clip_read.store(true, Ordering::SeqCst);
        for _ in 0..(LOST_AFTER_FAILURES + 2) {
            assert_eq!(rig.engine.text("\u{4e2d}"), Err(InjectError::Failed("clipboard_read".to_string())));
        }
        assert_eq!(rig.authorization(), Authorization::Granted);
        assert!(!rig.shared.recover.load(Ordering::SeqCst));
    }


    #[test]
    fn failed_ctrl_release_ends_the_session_after_the_give_back() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        let flags = &rig.world.flags;
        flags.fail_press_of.store(XK_LOWER_V, Ordering::SeqCst);
        flags.fail_releases.store(true, Ordering::SeqCst);
        flags.clip_sets_allowed.store(1, Ordering::SeqCst);
        // V press (1), Control release (2), restore (3) fail; the clear then succeeds and resets the failure count. Control
        // may still be held down, so the session has to end anyway, after the typed run is gone.
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert_eq!(rig.world.clipboard(), None);
        assert!(rig.engine.session.is_none(), "closing the session makes the compositor release every key");
        assert!(rig.shared.recover.load(Ordering::SeqCst));
        assert_eq!(rig.authorization(), Authorization::Denied);
    }

    #[test]
    fn a_failed_key_release_ends_the_session() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_releases.store(true, Ordering::SeqCst);
        assert!(rig.engine.key(XK_BACKSPACE).is_err());
        assert!(rig.engine.session.is_none());
        assert!(rig.shared.recover.load(Ordering::SeqCst));
    }

    #[test]
    fn a_failed_button_release_ends_the_session() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_releases.store(true, Ordering::SeqCst);
        assert!(rig.engine.button(Button::Left, false).is_err());
        assert!(rig.engine.session.is_none());
        assert!(rig.shared.recover.load(Ordering::SeqCst));
    }

    #[test]
    fn a_failed_click_release_ends_the_session() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_releases.store(true, Ordering::SeqCst);
        assert!(rig.engine.click(Button::Left, 1).is_err());
        assert!(rig.engine.session.is_none());
    }

    #[test]
    fn a_failed_press_alone_keeps_the_session() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_keys.store(true, Ordering::SeqCst);
        assert!(rig.engine.key(XK_BACKSPACE).is_err());
        assert!(rig.engine.session.is_some(), "nothing is held down after a refused press");
    }

    #[test]
    fn recover_waits_while_the_typed_run_is_still_on_the_clipboard() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let connects = rig.world.tokens_seen().len();
        rig.shared.recover.store(true, Ordering::SeqCst);
        rig.engine.recover();
        assert!(rig.engine.session.is_some(), "closing the session would leave the run on the clipboard");
        assert_eq!(rig.world.tokens_seen().len(), connects);
        assert!(rig.shared.recover.load(Ordering::SeqCst), "the request is kept");

        rig.world.flags.fail_clip_clear.store(false, Ordering::SeqCst);
        let due = rig.engine.next_wakeup().expect("a retry is scheduled");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.clipboard(), None);
        assert!(rig.shared.recover.load(Ordering::SeqCst), "still requested once the clipboard is clean");
    }

    #[test]
    fn reauthorize_waits_while_the_typed_run_is_still_on_the_clipboard() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let connects = rig.world.tokens_seen().len();
        rig.engine.request_reauthorize();
        assert!(rig.engine.session.is_some());
        assert_eq!(rig.world.tokens_seen().len(), connects, "no new dialog while the run is on the clipboard");

        rig.world.flags.fail_clip_clear.store(false, Ordering::SeqCst);
        let due = rig.engine.next_wakeup().expect("a retry is scheduled");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.clipboard(), None);
        assert_eq!(rig.world.tokens_seen().len(), connects + 1, "the new grant follows the clear");
        assert_eq!(rig.world.tokens_seen().last(), Some(&None), "and it asks the user");
        assert_eq!(rig.authorization(), Authorization::Granted);
    }

    /// A paste whose give-back failed, then the portal closes the session (the user stopped sharing).
    fn dirty_then_closed_by_portal() -> (Rig, usize, usize) {
        let mut rig = Rig::granted();
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert!(rig.engine.clipboard_dirty);
        rig.world.closed_hook(0)();
        assert!(rig.shared.recover.load(Ordering::SeqCst));
        let connects = rig.world.tokens_seen().len();
        let clears = rig.world.ops().iter().filter(|op| **op == Op::ClipClear).count();
        (rig, connects, clears)
    }

    fn clears(rig: &Rig) -> usize {
        rig.world.ops().iter().filter(|op| **op == Op::ClipClear).count()
    }

    #[test]
    fn a_session_closed_by_the_portal_is_restored_silently_despite_a_dirty_clipboard() {
        let (mut rig, connects, clears_before) = dirty_then_closed_by_portal();
        rig.shared.recover.store(false, Ordering::SeqCst);
        rig.engine.recover();
        assert_eq!(clears(&rig), clears_before + 1, "one last clear before the closed session is let go");
        assert_eq!(rig.world.tokens_seen().len(), connects + 1, "the closed session is not waited for");
        assert_eq!(rig.world.tokens_seen().last(), Some(&Some("token-1".to_string())));
        assert_eq!(rig.authorization(), Authorization::Granted);
        assert!(!rig.engine.clipboard_dirty);
        assert_eq!(rig.engine.next_wakeup(), None, "no clear retries against the closed session");
    }

    #[test]
    fn reauthorize_does_not_wait_for_a_session_the_portal_closed() {
        let (mut rig, connects, clears_before) = dirty_then_closed_by_portal();
        rig.engine.request_reauthorize();
        assert_eq!(clears(&rig), clears_before + 1, "one last clear");
        assert_eq!(rig.world.tokens_seen().len(), connects + 1, "the dialog is shown at once");
        assert_eq!(rig.world.tokens_seen().last(), Some(&None));
        assert_eq!(rig.authorization(), Authorization::Granted);
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn clear_retries_stop_once_the_portal_closed_the_session() {
        let (mut rig, _, clears_before) = dirty_then_closed_by_portal();
        let due = rig.engine.next_wakeup().expect("a retry was scheduled before the close");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.engine.next_wakeup(), None, "no retry loop against a closed session");
        assert!(!rig.engine.clipboard_dirty);
        assert!(clears(&rig) <= clears_before + 1);
    }

    #[test]
    fn suppressed_recovery_of_a_closed_dirty_session_still_lets_reauthorize_through() {
        let mut rig = Rig::granted();
        rig.engine.recover();
        rig.now_us.fetch_add(10_000_000, Ordering::SeqCst);
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        rig.world.closed_hook(1)();
        rig.shared.recover.store(false, Ordering::SeqCst);
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Denied, "second silent restore within a minute: the user decides");
        assert_eq!(rig.engine.next_wakeup(), None);
        let connects = rig.world.tokens_seen().len();
        rig.engine.request_reauthorize();
        assert_eq!(rig.world.tokens_seen().len(), connects + 1);
        assert_eq!(rig.authorization(), Authorization::Granted);
    }

    #[test]
    fn injector_with_a_dirty_clipboard_comes_back_after_the_portal_closes_it() {
        let world = World::new();
        let mut injector = started(&world, "closed-dirty", quick_options());
        world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(injector.text("\u{4e2d}").is_err());
        assert!(!injector.ready());
        world.closed_hook(0)();
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Granted);
        assert_eq!(world.tokens_seen(), vec![None, Some("token-1".to_string())]);
    }

    #[test]
    fn stop_after_reading_the_original_aborts_the_run() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        let shared = rig.shared.clone();
        *rig.world.on_read.lock().unwrap() = Some(Box::new(move || shared.stop.store(true, Ordering::SeqCst)));
        assert_eq!(rig.engine.text("\u{4e2d}"), Err(InjectError::Failed("stopping".to_string())));
        let ops = rig.world.ops();
        assert!(!ops.iter().any(|op| matches!(op, Op::ClipSet(_) | Op::ClipClear)), "{ops:?}");
        assert!(!ops.contains(&Op::Key(XK_CONTROL_L, true)), "{ops:?}");
        assert_eq!(rig.world.clipboard().as_deref(), Some("ORIGINAL"));
    }

    #[test]
    fn drop_during_the_original_read_waits_and_never_sets_the_clipboard() {
        let world = World::new();
        let mut injector = started(&world, "drop-read", quick_options());
        world.set_clipboard("ORIGINAL");
        world.flags.hang_read.store(true, Ordering::SeqCst);
        let release = world.flags.clone();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1400));
            release.hang_read.store(false, Ordering::SeqCst);
        });
        assert!(injector.text("\u{4e2d}").is_err());
        let began = Instant::now();
        drop(injector);
        assert!(began.elapsed() >= Duration::from_millis(300), "dropped without waiting: {:?}", began.elapsed());
        assert!(!world.ops().iter().any(|op| matches!(op, Op::ClipSet(_))), "{:?}", world.ops());
        assert_eq!(world.clipboard().as_deref(), Some("ORIGINAL"));
        releaser.join().unwrap();
    }

    #[test]
    fn worst_case_paste_makes_portal_calls_per_paste_calls_after_the_read() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.clip_sets_allowed.store(1, Ordering::SeqCst);
        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        assert_eq!(rig.last_report().portal_calls, keysym::PORTAL_CALLS_PER_PASTE + 1, "{:?}", rig.world.ops());
    }

    #[test]
    fn default_paste_wait_covers_one_whole_run() {
        assert_eq!(LinuxOptions::default().paste_shutdown_wait, keysym::paste_worst_case());
    }

    #[test]
    fn a_clear_that_finally_works_does_not_undo_a_suppressed_recovery() {
        let mut rig = Rig::granted();
        rig.engine.recover();
        rig.now_us.fetch_add(10_000_000, Ordering::SeqCst);
        rig.engine.recover();
        assert_eq!(rig.authorization(), Authorization::Denied, "suppressed: the user has to decide");

        rig.world.flags.fail_clip_clear.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        rig.world.flags.fail_clip_clear.store(false, Ordering::SeqCst);
        let due = rig.engine.next_wakeup().expect("a retry is scheduled");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.clipboard(), None);
        assert!(!rig.engine.clipboard_dirty);
        assert_eq!(rig.authorization(), Authorization::Denied);
    }

    #[test]
    fn failed_release_does_not_stop_the_other_releases() {
        let mut rig = Rig::granted();
        rig.world.set_clipboard("ORIGINAL");
        rig.world.flags.fail_releases.store(true, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let ops = rig.world.ops();
        assert!(position(&ops, &Op::Key(XK_LOWER_V, false)) < position(&ops, &Op::Key(XK_CONTROL_L, false)), "{ops:?}");
        assert_eq!(rig.world.clipboard().as_deref(), Some("ORIGINAL"), "the clipboard is still restored");
    }

    #[test]
    fn failed_press_releases_the_keys_already_down() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_press_of.store(XK_LOWER_V, Ordering::SeqCst);
        assert!(rig.engine.text("\u{4e2d}").is_err());
        let ops = rig.world.ops();
        assert!(position(&ops, &Op::Key(XK_CONTROL_L, true)) < position(&ops, &Op::Key(XK_CONTROL_L, false)), "{ops:?}");
    }

    #[test]
    fn failed_release_of_a_tap_is_reported() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_releases.store(true, Ordering::SeqCst);
        assert!(rig.engine.key(XK_BACKSPACE).is_err());
        assert_eq!(rig.world.ops(), key_taps(XK_BACKSPACE).to_vec());
    }

    #[test]
    fn paste_off_uses_unicode_keysyms() {
        let mut rig = Rig::granted();
        rig.shared.paste.store(false, Ordering::SeqCst);
        rig.engine.text("\u{4e2d}").unwrap();
        assert_eq!(rig.world.ops_without_gaps(), key_taps(0x0100_4e2d).to_vec());
        assert_eq!(rig.last_report().path, InjectPath::Unicode);
    }

    #[test]
    fn paste_falls_back_to_unicode_keysyms_without_clipboard() {
        let world = World::new();
        let mut connector = FakeConnector::granted(&world);
        connector.clipboard_supported = false;
        let mut rig = Rig::new(connector, &world, "no-clipboard");
        rig.engine.authorize(false);
        rig.engine.text("\u{4e2d}").unwrap();
        assert_eq!(world.ops_without_gaps(), key_taps(0x0100_4e2d).to_vec());
        assert_eq!(rig.last_report().path, InjectPath::Unicode);
    }

    #[test]
    fn denied_session_reports_untrusted() {
        let world = World::new();
        world.set_outcome(Err(ConnectError::Denied));
        let mut injector =
            LinuxInjector::with_connector(FakeConnector::granted(&world), temp_token_path("denied"), LinuxOptions::default());
        injector.wait_until_settled(Duration::from_secs(5));
        assert_eq!(injector.authorization(), Authorization::Denied);
        assert!(!injector.ready());
        assert!(!injector.trusted());
        assert_eq!(injector.text("abc"), Err(InjectError::NotReady));
        assert!(world.ops().is_empty());
    }

    #[test]
    fn restore_token_is_reused() {
        let path = temp_token_path("reuse");
        let world = World::new();

        let mut first = Rig::new(FakeConnector::granted(&world), &world, "unused");
        first.engine.token_path = path.clone();
        first.engine.authorize(true);
        assert_eq!(first.authorization(), Authorization::Granted);
        assert_eq!(read_token(&path).as_deref(), Some("token-1"));
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let mut second = Rig::new(FakeConnector::granted(&world), &world, "unused");
        second.engine.token_path = path.clone();
        second.engine.authorize(true);
        second.engine.authorize(false);
        assert_eq!(world.tokens_seen(), vec![None, Some("token-1".to_string()), None]);
    }

    #[test]
    fn unavailable_portal_is_not_granted() {
        let world = World::new();
        world.set_outcome(Err(ConnectError::Unavailable("no portal".to_string())));
        let mut rig = Rig::new(FakeConnector::granted(&world), &world, "unavailable");
        rig.engine.authorize(true);
        assert_eq!(rig.authorization(), Authorization::Denied);
        assert_eq!(rig.engine.text("a"), Err(InjectError::NotReady));
        assert_eq!(rig.last_report().error_kind, Some("not_ready"));
    }

    #[test]
    fn repeated_portal_failures_mark_the_session_lost() {
        let mut rig = Rig::granted();
        rig.world.flags.fail_all.store(true, Ordering::SeqCst);
        for _ in 0..LOST_AFTER_FAILURES {
            assert!(rig.engine.key(XK_BACKSPACE).is_err());
        }
        assert_eq!(rig.authorization(), Authorization::Denied);
        assert!(rig.shared.recover.load(Ordering::SeqCst), "the worker is asked to bring the session back");
        assert_eq!(rig.engine.key(XK_BACKSPACE), Err(InjectError::NotReady));
    }

    #[test]
    fn click_presses_and_releases_per_count() {
        let mut rig = Rig::granted();
        rig.engine.click(Button::Right, 2).unwrap();
        assert_eq!(
            rig.world.ops(),
            vec![
                Op::Button(273, true),
                Op::Sleep(CLICK_HOLD),
                Op::Button(273, false),
                Op::Sleep(CLICK_GAP),
                Op::Button(273, true),
                Op::Sleep(CLICK_HOLD),
                Op::Button(273, false),
            ]
        );
    }

    #[test]
    fn held_back_move_goes_out_on_the_timer() {
        let mut rig = Rig::granted();
        rig.engine.pointer_move(5.0, 0.0);
        rig.engine.pointer_move(3.0, 0.0);
        assert_eq!(rig.world.ops(), vec![Op::Motion(5.0, 0.0)]);
        let due = rig.engine.next_wakeup().expect("a move is waiting");
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.ops(), vec![Op::Motion(5.0, 0.0), Op::Motion(3.0, 0.0)]);
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn button_flushes_held_back_moves_first() {
        let mut rig = Rig::granted();
        rig.engine.pointer_move(5.0, 0.0);
        rig.engine.pointer_move(2.0, 0.0);
        rig.engine.button(Button::Left, true).unwrap();
        assert_eq!(rig.world.ops(), vec![Op::Motion(5.0, 0.0), Op::Motion(2.0, 0.0), Op::Button(272, true)]);
    }

    #[test]
    fn smooth_scroll_is_finished_after_it_goes_idle() {
        let mut rig = Rig::granted();
        rig.engine.scroll(0.0, 12.0);
        assert_eq!(rig.world.ops(), vec![Op::Axis(0.0, -12.0, false)]);
        let due = rig.engine.next_wakeup().expect("the scroll is still open");
        assert_eq!(due, 1_000_000 + SCROLL_IDLE.as_micros() as u64);
        rig.now_us.store(due, Ordering::SeqCst);
        rig.engine.on_timer();
        assert_eq!(rig.world.ops().last(), Some(&Op::Axis(0.0, 0.0, true)));
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn non_finite_scroll_is_ignored() {
        let mut rig = Rig::granted();
        rig.engine.scroll(f64::NAN, 1.0);
        rig.engine.scroll(0.0, f64::INFINITY);
        assert!(rig.world.ops().is_empty());
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn scroll_sends_held_back_moves_first() {
        let mut rig = Rig::granted();
        rig.engine.pointer_move(5.0, 0.0);
        rig.engine.pointer_move(2.0, 0.0);
        rig.engine.scroll(0.0, 4.0);
        assert_eq!(rig.world.ops(), vec![Op::Motion(5.0, 0.0), Op::Motion(2.0, 0.0), Op::Axis(0.0, -4.0, false)]);
    }

    #[test]
    fn click_ends_an_open_scroll_first() {
        let mut rig = Rig::granted();
        rig.engine.scroll(0.0, 4.0);
        rig.engine.click(Button::Left, 1).unwrap();
        let ops = rig.world.ops();
        assert!(position(&ops, &Op::Axis(0.0, 0.0, true)) < position(&ops, &Op::Button(272, true)), "{ops:?}");
        assert_eq!(rig.engine.next_wakeup(), None);
    }

    #[test]
    fn closed_hook_marks_recovery_and_ignores_stale_sessions() {
        let mut rig = Rig::granted();
        rig.engine.authorize(false);
        rig.world.closed_hook(0)();
        assert_eq!(rig.authorization(), Authorization::Granted, "a closed signal of the old session means nothing now");
        assert!(!rig.shared.recover.load(Ordering::SeqCst));
        rig.world.closed_hook(1)();
        assert_eq!(rig.authorization(), Authorization::Pending);
        assert!(rig.shared.recover.load(Ordering::SeqCst));
    }

    #[test]
    fn injector_types_through_its_worker_thread() {
        let world = World::new();
        let mut injector = started(&world, "worker", LinuxOptions::default());
        assert!(injector.ready());
        assert!(injector.trusted());
        injector.text("a").unwrap();
        injector.enter().unwrap();
        injector.backspace().unwrap();
        let mut expected = key_taps(0x61).to_vec();
        expected.push(Op::Sleep(KEY_GAP));
        expected.extend(key_taps(XK_RETURN));
        expected.extend(key_taps(XK_BACKSPACE));
        assert_eq!(world.ops(), expected);
        let report = injector.last_report().expect("report");
        assert_eq!((report.path, report.units, report.portal_calls, report.error_kind), (InjectPath::Keysym, 1, 2, None));
    }

    #[test]
    fn path_is_the_route_of_the_last_text_call() {
        let world = World::new();
        let mut injector = started(&world, "path", LinuxOptions::default());
        assert_eq!(injector.path(), "keysym");
        injector.text("a").unwrap();
        assert_eq!(injector.path(), "keysym");
        injector.text("\u{4e2d}").unwrap();
        assert_eq!(injector.path(), "paste");
        injector.backspace().unwrap();
        assert_eq!(injector.path(), "paste", "only text calls change it");
        injector.set_paste_non_ascii(false);
        injector.text("\u{4e2d}").unwrap();
        assert_eq!(injector.path(), "unicode");
    }

    #[test]
    fn reauthorize_asks_for_a_new_grant_without_the_saved_token() {
        let world = World::new();
        let injector = started(&world, "reauth", LinuxOptions::default());
        injector.reauthorize();
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Granted);
        assert_eq!(world.tokens_seen(), vec![None, None]);
    }

    #[test]
    fn closed_session_is_not_ready_at_once_and_comes_back_silently() {
        let world = World::new();
        let injector = started(&world, "closed", LinuxOptions::default());
        world.flags.block_connect.store(true, Ordering::SeqCst);
        world.closed_hook(0)();
        assert!(!injector.ready());
        assert!(!injector.trusted());
        world.flags.block_connect.store(false, Ordering::SeqCst);
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Granted);
        wait_ready(&injector);
        assert_eq!(world.tokens_seen(), vec![None, Some("token-1".to_string())], "the saved token is tried before anything else");
    }

    #[test]
    fn closed_session_needs_reauthorization_when_the_silent_restore_fails() {
        let world = World::new();
        let injector = started(&world, "closed-denied", LinuxOptions::default());
        world.set_outcome(Err(ConnectError::Denied));
        world.closed_hook(0)();
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Denied);
        assert!(!injector.ready());
        assert_eq!(world.tokens_seen(), vec![None, Some("token-1".to_string())]);
    }

    #[test]
    fn closed_signal_of_a_replaced_session_is_ignored() {
        let world = World::new();
        let injector = started(&world, "stale", LinuxOptions::default());
        injector.reauthorize();
        assert_eq!(injector.wait_until_settled(Duration::from_secs(5)), Authorization::Granted);
        world.closed_hook(0)();
        std::thread::sleep(Duration::from_millis(50));
        assert!(injector.ready());
        assert_eq!(world.tokens_seen().len(), 2);
    }

    #[test]
    fn repeated_failures_restore_the_session_silently() {
        let world = World::new();
        let mut injector = started(&world, "failures", LinuxOptions::default());
        world.flags.fail_all.store(true, Ordering::SeqCst);
        for _ in 0..LOST_AFTER_FAILURES {
            assert!(injector.backspace().is_err());
        }
        world.flags.fail_all.store(false, Ordering::SeqCst);
        wait_ready(&injector);
        assert_eq!(world.tokens_seen(), vec![None, Some("token-1".to_string())]);
        injector.backspace().unwrap();
    }

    #[test]
    fn call_times_out_when_the_portal_never_answers() {
        let world = World::new();
        let mut injector = started(&world, "hang", quick_options());
        world.flags.hang.store(true, Ordering::SeqCst);
        let began = Instant::now();
        let result = injector.text("a");
        assert!(matches!(&result, Err(InjectError::Failed(message)) if message.contains("timed out")), "{result:?}");
        assert!(began.elapsed() < Duration::from_secs(2), "{:?}", began.elapsed());
        assert!(!injector.ready(), "a portal that does not answer is not ready");
        world.flags.hang.store(false, Ordering::SeqCst);
        wait_ready(&injector);
        injector.text("b").unwrap();
    }

    #[test]
    fn dropping_a_stuck_injector_is_bounded() {
        let world = World::new();
        let mut injector = started(&world, "drop-hang", quick_options());
        world.flags.hang.store(true, Ordering::SeqCst);
        assert!(injector.text("a").is_err());
        let began = Instant::now();
        drop(injector);
        assert!(began.elapsed() < Duration::from_secs(1), "{:?}", began.elapsed());
        world.flags.hang.store(false, Ordering::SeqCst);
    }
}
