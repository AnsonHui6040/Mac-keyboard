//! The command line: `--version`, `--print-paths`, `--diag`, `--log-level debug`.

use crate::log::Level;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Run the receiver.
    Run,
    Version,
    PrintPaths,
    /// Print `diag.txt` and exit.
    Diag,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cli {
    pub mode: Mode,
    pub log_level: Level,
}

/// `args` excludes the program name.
pub fn parse<S: AsRef<str>>(args: &[S]) -> Result<Cli, String> {
    let mut cli = Cli { mode: Mode::Run, log_level: Level::Info };
    let mut args = args.iter().map(AsRef::as_ref);
    while let Some(arg) = args.next() {
        match arg {
            "--version" => cli.mode = Mode::Version,
            "--print-paths" => cli.mode = Mode::PrintPaths,
            "--diag" => cli.mode = Mode::Diag,
            "--log-level" => {
                let value = args.next().ok_or("--log-level needs a value: info or debug")?;
                cli.log_level = Level::parse(value).ok_or_else(|| format!("unknown log level {value:?}: use info or debug"))?;
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(cli)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_arguments_runs_the_receiver_at_info_level() {
        assert_eq!(parse::<&str>(&[]), Ok(Cli { mode: Mode::Run, log_level: Level::Info }));
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
    fn bad_input_is_an_error_not_a_silent_default() {
        assert!(parse(&["--log-level"]).is_err());
        assert!(parse(&["--log-level", "trace"]).is_err());
        assert!(parse(&["--nonsense"]).is_err());
    }
}
