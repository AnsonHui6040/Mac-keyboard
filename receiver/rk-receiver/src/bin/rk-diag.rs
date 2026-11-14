//! `rk-diag stats <log file or folder> [--since <RFC3339>] [--out <file>]`: connection-time statistics from receiver logs.

use rk_receiver::diag_stats::{file_order_key, parse_rfc3339_ms, summarize};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "usage: rk-diag stats <log file or folder> [--since <RFC3339 time, e.g. 2026-11-14T20:23:00Z>] [--out <file>]";

fn log_files(path: &Path) -> Result<Vec<PathBuf>, String> {
    if path.is_file() {
        return Ok(vec![path.to_path_buf()]);
    }
    let entries = std::fs::read_dir(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let mut files: Vec<((String, u32), PathBuf)> = entries
        .filter_map(Result::ok)
        .filter_map(|e| file_order_key(&e.file_name().to_string_lossy()).map(|key| (key, e.path())))
        .collect();
    files.sort();
    Ok(files.into_iter().map(|(_, p)| p).collect())
}

fn run(args: &[String]) -> Result<(), String> {
    let mut it = args.iter();
    if it.next().map(String::as_str) != Some("stats") {
        return Err(USAGE.to_string());
    }
    let (mut input, mut since, mut out) = (None, None, None);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--since" => since = Some(it.next().ok_or(USAGE)?.clone()),
            "--out" => out = Some(it.next().ok_or(USAGE)?.clone()),
            other if other.starts_with("--") => return Err(format!("unknown option {other}\n{USAGE}")),
            other if input.is_none() => input = Some(other.to_string()),
            _ => return Err(USAGE.to_string()),
        }
    }
    let input = input.ok_or(USAGE)?;
    let since_ms = match &since {
        Some(text) => Some(parse_rfc3339_ms(text).ok_or(format!("cannot read time {text}\n{USAGE}"))?),
        None => None,
    };
    let files = log_files(Path::new(&input))?;
    if files.is_empty() {
        return Err(format!("no rk-*.log files in {input}"));
    }
    let mut text = String::new();
    for file in &files {
        let bytes = std::fs::read(file).map_err(|e| format!("cannot read {}: {e}", file.display()))?;
        text.push_str(&String::from_utf8_lossy(&bytes));
        text.push('\n');
    }
    let report = format!("files {}\n{}", files.len(), summarize(text.lines(), since_ms).render(since_ms.map(rk_receiver::log::rfc3339_utc_ms).as_deref()));
    print!("{report}");
    if let Some(out) = out {
        std::fs::write(&out, &report).map_err(|e| format!("cannot write {out}: {e}"))?;
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("rk-diag: {message}");
            ExitCode::from(2)
        }
    }
}
