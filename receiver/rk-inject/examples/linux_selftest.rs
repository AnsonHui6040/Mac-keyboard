//! Device self-test of the Linux injector: types the UTF-8 contents of a file through the RemoteDesktop portal, then
//! presses Enter, then exits.
//!
//! ```text
//! linux_selftest <text-file> [--token <path>] [--delay-secs <n>] [--wait-secs <n>] [--no-paste] [--no-enter] [--hold-secs <n>]
//! ```
//!
//! `--token` defaults to `$XDG_CONFIG_HOME/remote-keyboard/portal-token` (`~/.config/...`). With a valid restore token no
//! dialog appears. If the portal is still waiting for the user after `--wait-secs` (default 20) the program exits with
//! status 3 without typing anything. `--hold-secs` keeps the session open after typing: the clipboard that was restored
//! after a paste is served by the session and is gone once it closes. Output carries lengths and results only, never the text.

#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(linux::run());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("linux_selftest only runs on Linux");
    std::process::exit(2);
}

#[cfg(target_os = "linux")]
mod linux {
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    use rk_inject::linux::{Authorization, LinuxInjector, LinuxOptions};
    use rk_inject::Injector;

    struct Args {
        file: PathBuf,
        token: PathBuf,
        delay: Duration,
        wait: Duration,
        paste: bool,
        enter: bool,
        hold: Duration,
    }

    fn default_token_path() -> PathBuf {
        let config = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .unwrap_or_else(|| PathBuf::from("."));
        config.join("remote-keyboard").join("portal-token")
    }

    fn parse() -> Result<Args, String> {
        let mut args = std::env::args().skip(1);
        let file = PathBuf::from(args.next().ok_or("usage: linux_selftest <text-file> [--token P] [--delay-secs N] [--wait-secs N] [--no-paste] [--no-enter] [--hold-secs N]")?);
        let mut parsed = Args { file, token: default_token_path(), delay: Duration::from_secs(5), wait: Duration::from_secs(20), paste: true, enter: true, hold: Duration::ZERO };
        while let Some(flag) = args.next() {
            let mut value = |name: &str| args.next().ok_or(format!("{name} needs a value"));
            match flag.as_str() {
                "--token" => parsed.token = PathBuf::from(value("--token")?),
                "--delay-secs" => parsed.delay = Duration::from_secs(value("--delay-secs")?.parse().map_err(|_| "bad --delay-secs")?),
                "--wait-secs" => parsed.wait = Duration::from_secs(value("--wait-secs")?.parse().map_err(|_| "bad --wait-secs")?),
                "--no-paste" => parsed.paste = false,
                "--no-enter" => parsed.enter = false,
                "--hold-secs" => parsed.hold = Duration::from_secs(value("--hold-secs")?.parse().map_err(|_| "bad --hold-secs")?),
                other => return Err(format!("unknown argument {other}")),
            }
        }
        Ok(parsed)
    }

    fn describe(injector: &LinuxInjector) -> String {
        match injector.last_report() {
            Some(r) => format!("path={:?} units={} portal_calls={} error={}", r.path, r.units, r.portal_calls, r.error_kind.unwrap_or("none")),
            None => "no report".to_string(),
        }
    }

    pub fn run() -> i32 {
        let args = match parse() {
            Ok(args) => args,
            Err(message) => {
                eprintln!("{message}");
                return 2;
            }
        };
        let text = match std::fs::read_to_string(&args.file) {
            Ok(text) => text.trim_end_matches('\n').to_string(),
            Err(error) => {
                eprintln!("cannot read the text file: {}", error.kind());
                return 2;
            }
        };
        let log: rk_inject::linux::Log = Arc::new(|line| println!("{line}"));
        let mut injector = LinuxInjector::start(args.token.clone(), LinuxOptions { paste_non_ascii: args.paste, log: Some(log), ..LinuxOptions::default() });
        match injector.wait_until_settled(args.wait) {
            Authorization::Granted => {}
            Authorization::Pending => {
                eprintln!("the portal is still waiting for the user (permission dialog); nothing was typed");
                return 3;
            }
            Authorization::Denied => {
                eprintln!("the portal did not grant keyboard control; nothing was typed");
                return 4;
            }
        }
        println!("granted; typing {} characters in {} s", text.chars().count(), args.delay.as_secs());
        std::thread::sleep(args.delay);
        let typed = injector.text(&text);
        println!("text: {typed:?} {}", describe(&injector));
        let entered = if args.enter { injector.enter() } else { Ok(()) };
        if args.enter {
            println!("enter: {entered:?} {}", describe(&injector));
        }
        std::thread::sleep(args.hold);
        if typed.is_ok() && entered.is_ok() {
            0
        } else {
            1
        }
    }
}
