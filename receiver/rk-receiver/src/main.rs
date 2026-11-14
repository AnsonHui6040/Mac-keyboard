// A release build on Windows is a tray program without a console window; `prepare_console` gives the command-line modes
// their output back.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use rk_receiver::cli::{self, Mode};
use rk_receiver::platform;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let parsed = cli::parse(&args);
    if !matches!(parsed, Ok(cli::Cli { mode: Mode::Run, .. })) {
        platform::prepare_console();
    }
    let cli = match parsed {
        Ok(cli) => cli,
        Err(message) => {
            eprintln!("rk-receiver: {message}");
            return ExitCode::from(2);
        }
    };
    match cli.mode {
        Mode::Version => println!("rk-receiver {}", env!("CARGO_PKG_VERSION")),
        Mode::PrintPaths => print!("{}", platform::paths_text(&platform::paths())),
        Mode::Diag => print!("{}", platform::print_diag()),
        Mode::Run => return ExitCode::from(u8::try_from(platform::run(&cli)).unwrap_or(1)),
    }
    ExitCode::SUCCESS
}
