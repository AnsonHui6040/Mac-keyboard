//! An [`Injector`] wrapper that writes one diagnostic line per injection: what kind, which path, how many units, how long,
//! and whether it worked. The text itself never reaches the log.

use crate::clock::Clock;
use crate::log::Logger;
use rk_ble::Value;
use rk_inject::{Button, InjectError, Injector};
use std::sync::Arc;

pub struct LoggingInjector {
    inner: Box<dyn Injector>,
    log: Logger,
    clock: Arc<dyn Clock>,
}

fn result_word(result: &Result<(), InjectError>) -> &'static str {
    match result {
        Ok(()) => "ok",
        Err(InjectError::NotReady) => "err:not_ready",
        Err(InjectError::Failed(_)) => "err:failed",
        Err(InjectError::Unsupported) => "err:unsupported",
    }
}

impl LoggingInjector {
    pub fn new(inner: Box<dyn Injector>, log: Logger, clock: Arc<dyn Clock>) -> Self {
        Self { inner, log, clock }
    }

    fn timed(
        &mut self,
        op: &'static str,
        pointer: bool,
        units: usize,
        call: impl FnOnce(&mut dyn Injector) -> Result<(), InjectError>,
    ) -> Result<(), InjectError> {
        let started = self.clock.mono_ms();
        let result = call(self.inner.as_mut());
        let fields = [
            ("op", Value::S(op)),
            ("path", Value::S(if pointer { "pointer" } else { self.inner.path() })),
            ("units", Value::U(units as u64)),
            ("ms", Value::U(self.clock.mono_ms().saturating_sub(started))),
            ("result", Value::S(result_word(&result))),
        ];
        // A pointer moves dozens of times a second: those lines are for debugging only.
        if pointer {
            self.log.debug("inject", None, &fields);
        } else {
            self.log.info("inject", None, &fields);
        }
        result
    }
}

impl Injector for LoggingInjector {
    fn text(&mut self, s: &str) -> Result<(), InjectError> {
        let units = s.chars().count();
        self.timed("text", false, units, |i| i.text(s))
    }
    fn backspace(&mut self) -> Result<(), InjectError> {
        self.timed("backspace", false, 1, |i| i.backspace())
    }
    fn enter(&mut self) -> Result<(), InjectError> {
        self.timed("enter", false, 1, |i| i.enter())
    }
    fn pointer_move(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.timed("pointer", true, 1, |i| i.pointer_move(dx, dy))
    }
    fn button(&mut self, b: Button, down: bool) -> Result<(), InjectError> {
        self.timed("pointer", true, 1, |i| i.button(b, down))
    }
    fn click(&mut self, b: Button, count: u8) -> Result<(), InjectError> {
        self.timed("pointer", true, usize::from(count), |i| i.click(b, count))
    }
    fn scroll(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.timed("pointer", true, 1, |i| i.scroll(dx, dy))
    }
    fn ready(&self) -> bool {
        self.inner.ready()
    }
    fn trusted(&self) -> bool {
        self.inner.trusted()
    }
    fn path(&self) -> &'static str {
        self.inner.path()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::FakeClock;
    use crate::log::{Level, MemorySink};
    use rk_inject::{Call, RecordingInjector};

    fn wrapped(level: Level) -> (LoggingInjector, RecordingInjector, MemorySink) {
        let sink = MemorySink::new();
        let clock = Arc::new(FakeClock::new(1_794_651_630_123));
        let log = Logger::new(Box::new(sink.clone()), clock.clone(), level);
        let recording = RecordingInjector::new();
        (LoggingInjector::new(Box::new(recording.clone()), log, clock), recording, sink)
    }

    #[test]
    fn text_batch_is_logged_with_op_path_units_and_result_but_not_the_text() {
        let (mut inj, rec, sink) = wrapped(Level::Info);
        inj.text("機密🙂").unwrap();
        assert_eq!(rec.calls(), vec![Call::Text("機密🙂".into())]);
        let line = &sink.lines()[0];
        assert!(line.contains("ev=inject op=text path=unicode units=3 ms=0 result=ok"), "{line}");
        assert!(!line.contains("機密"));
    }

    #[test]
    fn failure_is_logged_by_kind_and_still_returned() {
        let (mut inj, rec, sink) = wrapped(Level::Info);
        rec.set_failing(true);
        assert!(inj.backspace().is_err());
        assert!(sink.lines()[0].contains("op=backspace path=unicode units=1 ms=0 result=err:failed"));
    }

    #[test]
    fn pointer_lines_appear_only_at_debug_level() {
        let (mut quiet, _, quiet_sink) = wrapped(Level::Info);
        quiet.pointer_move(1.0, 2.0).unwrap();
        assert!(quiet_sink.lines().is_empty());
        let (mut loud, _, loud_sink) = wrapped(Level::Debug);
        loud.pointer_move(1.0, 2.0).unwrap();
        let line = &loud_sink.lines()[0];
        assert!(line.contains("lvl=debug ev=inject op=pointer path=pointer units=1"), "{line}");
        assert!(!line.contains("1.0") && !line.contains("2.0"), "no displacement in the log");
    }
}
