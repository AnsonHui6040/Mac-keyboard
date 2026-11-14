//! Hosts without a shell of their own yet. Linux gets its tray and BlueZ link in WL10; until then the binary can say what it
//! is (`--version`, `--print-paths`, `--diag`) and nothing more.

use super::{linux_paths, Paths};
use crate::config::Config;
use crate::diag::{self, DiagInfo};
use crate::log::Level;
use rk_core::identity::HostPlatform;
use std::path::PathBuf;

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn paths() -> Paths {
    let home = env_path("HOME").unwrap_or_default();
    linux_paths(&home, env_path("XDG_CONFIG_HOME").as_deref(), env_path("XDG_STATE_HOME").as_deref())
}

/// `PRETTY_NAME` of an `/etc/os-release` file.
pub fn pretty_name(os_release: &str) -> Option<String> {
    os_release.lines().find_map(|line| line.strip_prefix("PRETTY_NAME=")).map(|v| v.trim().trim_matches('"').to_string())
}

pub fn prepare_console() {}

pub fn print_diag() -> String {
    let config = Config::load_or_create(&paths().config_file, HostPlatform::Linux, || [0; 16]);
    let os = std::fs::read_to_string("/etc/os-release").ok().and_then(|text| pretty_name(&text)).unwrap_or_else(|| std::env::consts::OS.to_string());
    diag::diag_txt(&DiagInfo {
        version: env!("CARGO_PKG_VERSION"),
        target: env!("RK_TARGET"),
        os: &os,
        adapter: None,
        config: &config,
        paired_phones: 0,
        state: "not running",
        log_level: "info",
    })
}

pub fn run(_level: Level) -> i32 {
    eprintln!("The receiver for this system comes in WL10.");
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pretty_name_is_read_from_os_release() {
        assert_eq!(pretty_name("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 26.04 LTS\"\nID=ubuntu\n").as_deref(), Some("Ubuntu 26.04 LTS"));
        assert_eq!(pretty_name("ID=x\n"), None);
    }
}
