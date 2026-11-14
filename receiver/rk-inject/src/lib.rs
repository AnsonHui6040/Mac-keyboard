//! What a receiver can do to the computer it runs on: type, move the pointer, click, scroll.
//!
//! The trait is shared by every platform. Platform injectors (Windows `SendInput`, Linux RemoteDesktop portal) sit in
//! their own modules; this file holds only the trait and the two doubles the tests use.

#![forbid(unsafe_code)]

use std::sync::{Arc, Mutex, MutexGuard};
use thiserror::Error;

/// A pointer button the protocol knows about (§8.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
}

/// Why an injection did not happen. The text never carries what the user typed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum InjectError {
    /// The backend cannot inject right now (no authorization yet, session not available).
    #[error("injection backend not ready")]
    NotReady,
    /// The operating system refused or only partly accepted the input.
    #[error("injection failed: {0}")]
    Failed(String),
    /// This backend has no way to do the requested operation.
    #[error("operation not supported by this backend")]
    Unsupported,
}

impl InjectError {
    /// A short, fixed word for the diagnostic log (`result=err:<kind>`).
    pub fn kind(&self) -> &'static str {
        match self {
            Self::NotReady => "not_ready",
            Self::Failed(_) => "failed",
            Self::Unsupported => "unsupported",
        }
    }
}

/// The input side of a receiver.
pub trait Injector: Send {
    fn text(&mut self, s: &str) -> Result<(), InjectError>;
    fn backspace(&mut self) -> Result<(), InjectError>;
    fn enter(&mut self) -> Result<(), InjectError>;
    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError>;
    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError>;
    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError>;
    fn scroll(&mut self, dx: f64, dy: f64) -> Result<(), InjectError>;
    /// The backend can inject (Linux: the portal session is authorized).
    fn ready(&self) -> bool;
    /// `false` while the user still has to authorize the backend (Linux only).
    fn trusted(&self) -> bool {
        true
    }
    /// How text reaches the target, for the diagnostic log only: `unicode`, `keysym` or `paste`.
    fn path(&self) -> &'static str {
        "unicode"
    }
}

/// Accepts nothing and says so: `ready()` is false, every call fails with `NotReady`.
#[derive(Debug, Default, Clone, Copy)]
pub struct NullInjector;

impl Injector for NullInjector {
    fn text(&mut self, _: &str) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn backspace(&mut self) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn enter(&mut self) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn pointer_move(&mut self, _: f64, _: f64) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn button(&mut self, _: Button, _: bool) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn click(&mut self, _: Button, _: u8) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn scroll(&mut self, _: f64, _: f64) -> Result<(), InjectError> {
        Err(InjectError::NotReady)
    }
    fn ready(&self) -> bool {
        false
    }
}

/// One call a [`RecordingInjector`] saw.
#[derive(Debug, Clone, PartialEq)]
pub enum Call {
    Text(String),
    Backspace,
    Enter,
    Move(f64, f64),
    Button(Button, bool),
    Click(Button, u8),
    Scroll(f64, f64),
}

#[derive(Debug)]
struct Recorded {
    calls: Vec<Call>,
    ready: bool,
    trusted: bool,
    failing: bool,
}

/// Remembers every call and can be told to be unready or to fail. Clones share one record, so a test keeps a handle
/// after boxing the injector into the code under test.
#[derive(Debug, Clone)]
pub struct RecordingInjector {
    state: Arc<Mutex<Recorded>>,
}

impl Default for RecordingInjector {
    fn default() -> Self {
        Self::new()
    }
}

impl RecordingInjector {
    /// Ready and trusted, nothing recorded yet.
    pub fn new() -> Self {
        Self { state: Arc::new(Mutex::new(Recorded { calls: Vec::new(), ready: true, trusted: true, failing: false })) }
    }

    fn state(&self) -> MutexGuard<'_, Recorded> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Everything recorded so far, oldest first.
    pub fn calls(&self) -> Vec<Call> {
        self.state().calls.clone()
    }

    pub fn set_ready(&self, ready: bool) {
        self.state().ready = ready;
    }

    pub fn set_trusted(&self, trusted: bool) {
        self.state().trusted = trusted;
    }

    /// While set, every call is recorded and then fails with `InjectError::Failed`.
    pub fn set_failing(&self, failing: bool) {
        self.state().failing = failing;
    }

    fn record(&mut self, call: Call) -> Result<(), InjectError> {
        let mut state = self.state();
        state.calls.push(call);
        if state.failing {
            Err(InjectError::Failed("recording injector told to fail".into()))
        } else {
            Ok(())
        }
    }
}

impl Injector for RecordingInjector {
    fn text(&mut self, s: &str) -> Result<(), InjectError> {
        self.record(Call::Text(s.to_string()))
    }
    fn backspace(&mut self) -> Result<(), InjectError> {
        self.record(Call::Backspace)
    }
    fn enter(&mut self) -> Result<(), InjectError> {
        self.record(Call::Enter)
    }
    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.record(Call::Move(dx, dy))
    }
    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError> {
        self.record(Call::Button(b, down))
    }
    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError> {
        self.record(Call::Click(b, count))
    }
    fn scroll(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.record(Call::Scroll(dx, dy))
    }
    fn ready(&self) -> bool {
        self.state().ready
    }
    fn trusted(&self) -> bool {
        self.state().trusted
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_injector_is_not_ready_and_refuses_everything() {
        let mut n = NullInjector;
        assert!(!n.ready());
        assert_eq!(n.text("x"), Err(InjectError::NotReady));
        assert_eq!(n.enter(), Err(InjectError::NotReady));
    }

    #[test]
    fn recording_injector_shares_its_record_between_clones() {
        let mut a = RecordingInjector::new();
        let b = a.clone();
        a.text("hi").unwrap();
        a.click(Button::Left, 2).unwrap();
        assert_eq!(b.calls(), vec![Call::Text("hi".into()), Call::Click(Button::Left, 2)]);
        b.set_ready(false);
        assert!(!a.ready());
    }

    #[test]
    fn failing_recording_injector_records_then_errors() {
        let mut a = RecordingInjector::new();
        a.set_failing(true);
        assert!(matches!(a.backspace(), Err(InjectError::Failed(_))));
        assert_eq!(a.calls(), vec![Call::Backspace]);
    }
}
