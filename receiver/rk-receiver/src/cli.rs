//! The command line: `--version`, `--print-paths`, `--diag`, `--log-level debug`, `--pair`.

use crate::log::Level;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// Run the receiver.
    Run,
    Version,
    PrintPaths,
    /// Print `diag.txt` and exit.
    Diag,
    /// Wait `delay_secs`, type the UTF-8 text of `file` through the real injector, press Enter, print one summary line
    /// without the text, and exit. For the automatic checks on a machine with a desktop.
    InjectSelftest { file: PathBuf, delay_secs: u64 },
}

/// How long `--inject-selftest` waits before typing unless `--delay-secs` says otherwise: time to focus the target.
pub const DEFAULT_SELFTEST_DELAY_SECS: u64 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cli {
    pub mode: Mode,
    pub log_level: Level,
    /// Open the 120-second pairing window right after start-up, as the tray item 「配對新手機」 does.
    pub pair: bool,
}

/// `args` excludes the program name.
pub fn parse<S: AsRef<str>>(args: &[S]) -> Result<Cli, String> {
    let mut cli = Cli { mode: Mode::Run, log_level: Level::Info, pair: false };
    let mut selftest_file: Option<PathBuf> = None;
    let mut delay_secs: Option<u64> = None;
    let mut args = args.iter().map(AsRef::as_ref);
    while let Some(arg) = args.next() {
        match arg {
            "--version" => cli.mode = Mode::Version,
            "--print-paths" => cli.mode = Mode::PrintPaths,
            "--diag" => cli.mode = Mode::Diag,
            "--pair" => cli.pair = true,
            "--log-level" => {
                let value = args.next().ok_or("--log-level needs a value: info or debug")?;
                cli.log_level = Level::parse(value).ok_or_else(|| format!("unknown log level {value:?}: use info or debug"))?;
            }
            "--inject-selftest" => selftest_file = Some(PathBuf::from(args.next().ok_or("--inject-selftest needs a file")?)),
            "--delay-secs" => {
                let value = args.next().ok_or("--delay-secs needs a number of seconds")?;
                delay_secs = Some(value.parse().map_err(|_| format!("--delay-secs needs a whole number of seconds, not {value:?}"))?);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    match selftest_file {
        Some(file) if cli.mode == Mode::Run => cli.mode = Mode::InjectSelftest { file, delay_secs: delay_secs.unwrap_or(DEFAULT_SELFTEST_DELAY_SECS) },
        Some(_) => return Err("--inject-selftest cannot be combined with --version, --print-paths or --diag".into()),
        None if delay_secs.is_some() => return Err("--delay-secs only goes with --inject-selftest".into()),
        None => {}
    }
    Ok(cli)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_arguments_runs_the_receiver_at_info_level() {
        assert_eq!(parse::<&str>(&[]), Ok(Cli { mode: Mode::Run, log_level: Level::Info, pair: false }));
    }

    #[test]
    fn the_four_flags_are_understood() {
        assert_eq!(parse(&["--version"]).unwrap().mode, Mode::Version);
        assert_eq!(parse(&["--print-paths"]).unwrap().mode, Mode::PrintPaths);
        assert_eq!(parse(&["--diag"]).unwrap().mode, Mode::Diag);
        assert_eq!(parse(&["--log-level", "debug"]).unwrap().log_level, Level::Debug);
    }

    #[test]
    fn log_level_combines_with_other_flags_in_any_order() {
        let cli = parse(&["--log-level", "debug", "--diag"]).unwrap();
        assert_eq!((cli.mode, cli.log_level), (Mode::Diag, Level::Debug));
    }

    #[test]
    fn pair_asks_for_the_pairing_window_at_start() {
        assert!(parse(&["--pair"]).unwrap().pair);
        assert!(!parse::<&str>(&[]).unwrap().pair);
        let cli = parse(&["--log-level", "debug", "--pair"]).unwrap();
        assert_eq!((cli.mode, cli.pair, cli.log_level), (Mode::Run, true, Level::Debug));
    }

    #[test]
    fn inject_selftest_takes_a_file_and_waits_3_s_unless_told_otherwise() {
        let cli = parse(&["--inject-selftest", "t.txt"]).unwrap();
        assert_eq!(cli.mode, Mode::InjectSelftest { file: PathBuf::from("t.txt"), delay_secs: 3 });
    }

    #[test]
    fn delay_secs_sets_the_wait_before_typing_in_any_order() {
        let a = parse(&["--inject-selftest", "t.txt", "--delay-secs", "7"]).unwrap();
        let b = parse(&["--delay-secs", "7", "--inject-selftest", "t.txt"]).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.mode, Mode::InjectSelftest { file: PathBuf::from("t.txt"), delay_secs: 7 });
        assert_eq!(parse(&["--inject-selftest", "t.txt", "--delay-secs", "0"]).unwrap().mode, Mode::InjectSelftest { file: PathBuf::from("t.txt"), delay_secs: 0 });
    }

    #[test]
    fn selftest_flags_need_their_values_and_each_other() {
        assert!(parse(&["--inject-selftest"]).is_err());
        assert!(parse(&["--delay-secs", "3"]).is_err(), "a delay with nothing to type");
        assert!(parse(&["--inject-selftest", "t.txt", "--delay-secs"]).is_err());
        assert!(parse(&["--inject-selftest", "t.txt", "--delay-secs", "soon"]).is_err());
        assert!(parse(&["--inject-selftest", "t.txt", "--diag"]).is_err(), "one job per run");
    }

    #[test]
    fn bad_input_is_an_error_not_a_silent_default() {
        assert!(parse(&["--log-level"]).is_err());
        assert!(parse(&["--log-level", "trace"]).is_err());
        assert!(parse(&["--nonsense"]).is_err());
    }
}
