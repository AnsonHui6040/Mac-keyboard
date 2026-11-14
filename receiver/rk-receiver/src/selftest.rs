//! `--inject-selftest`: type a file through the real injector and report only counts. The text never leaves this function,
//! neither on the screen nor in a log.

use rk_inject::Injector;

/// Types `text`, presses Enter and returns the one line the command prints: `units=<n> ms=<elapsed> result=ok|err:<kind>`.
/// `units` counts Unicode scalars, as the injection log does. `now_ms` is a monotonic clock in milliseconds.
pub fn run(injector: &mut dyn Injector, text: &str, now_ms: impl Fn() -> u64) -> String {
    let started = now_ms();
    let result = injector.text(text).and_then(|()| injector.enter());
    let word = match &result {
        Ok(()) => "ok".to_string(),
        Err(error) => format!("err:{}", error.kind()),
    };
    format!("units={} ms={} result={word}", text.chars().count(), now_ms().saturating_sub(started))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_inject::{Call, NullInjector, RecordingInjector};
    use std::cell::Cell;

    fn ticking() -> impl Fn() -> u64 {
        let t = Cell::new(100u64);
        move || {
            let now = t.get();
            t.set(now + 250);
            now
        }
    }

    #[test]
    fn types_the_text_then_presses_enter_and_reports_counts_only() {
        let mut rec = RecordingInjector::new();
        let line = run(&mut rec, "機密🙂", ticking());
        assert_eq!(rec.calls(), vec![Call::Text("機密🙂".into()), Call::Enter]);
        assert_eq!(line, "units=3 ms=250 result=ok");
        assert!(!line.contains("機密"));
    }

    #[test]
    fn a_failed_text_reports_the_kind_and_does_not_press_enter() {
        let mut rec = RecordingInjector::new();
        rec.set_failing(true);
        let line = run(&mut rec, "abc", ticking());
        assert_eq!(rec.calls(), vec![Call::Text("abc".into())]);
        assert_eq!(line, "units=3 ms=250 result=err:failed");
        let mut null = NullInjector;
        assert_eq!(run(&mut null, "x", ticking()), "units=1 ms=250 result=err:not_ready");
    }
}
