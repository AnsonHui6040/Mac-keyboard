//! The parts that differ between operating systems. Only what is pure lives outside the `cfg` modules, so the rules for
//! file locations and for "only one copy runs" are tested on every host.

use std::path::{Path, PathBuf};

#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub use windows::{inject_selftest, paths, prepare_console, print_diag, run};

#[cfg(not(windows))]
mod other;
#[cfg(not(windows))]
pub use other::{inject_selftest, paths, prepare_console, print_diag, run};

/// Where the receiver keeps its files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub config_file: PathBuf,
    pub log_dir: PathBuf,
}

/// `%APPDATA%\RemoteKeyboard\config.json` and `%LOCALAPPDATA%\RemoteKeyboard\logs\`.
pub fn windows_paths(appdata: &Path, local_appdata: &Path) -> Paths {
    Paths { config_file: appdata.join("RemoteKeyboard").join("config.json"), log_dir: local_appdata.join("RemoteKeyboard").join("logs") }
}

/// `$XDG_CONFIG_HOME/remote-keyboard/config.json` and `$XDG_STATE_HOME/remote-keyboard/logs/`, with the XDG defaults
/// `~/.config` and `~/.local/state` when the variables are not set.
pub fn linux_paths(home: &Path, xdg_config_home: Option<&Path>, xdg_state_home: Option<&Path>) -> Paths {
    let config = xdg_config_home.map_or_else(|| home.join(".config"), Path::to_path_buf);
    let state = xdg_state_home.map_or_else(|| home.join(".local").join("state"), Path::to_path_buf);
    Paths { config_file: config.join("remote-keyboard").join("config.json"), log_dir: state.join("remote-keyboard").join("logs") }
}

/// What `--print-paths` prints.
pub fn paths_text(paths: &Paths) -> String {
    format!("config={}\nlogs={}\n", paths.config_file.display(), paths.log_dir.display())
}

/// "Is another copy already running?", answered by the operating system (a named mutex on Windows, a lock file on Linux).
pub trait InstanceLock {
    /// `true` when this process is the first and now holds the lock.
    fn try_acquire(&mut self) -> bool;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Instance {
    First,
    /// Another copy runs: this process exits quietly.
    Second,
}

pub fn claim_instance(lock: &mut dyn InstanceLock) -> Instance {
    if lock.try_acquire() {
        Instance::First
    } else {
        Instance::Second
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeLock(bool);

    impl InstanceLock for FakeLock {
        fn try_acquire(&mut self) -> bool {
            std::mem::replace(&mut self.0, false)
        }
    }

    #[test]
    fn second_instance_exits() {
        let mut lock = FakeLock(true);
        assert_eq!(claim_instance(&mut lock), Instance::First);
        assert_eq!(claim_instance(&mut lock), Instance::Second);
    }

    #[test]
    fn windows_files_live_under_appdata_and_local_appdata() {
        let p = windows_paths(Path::new(r"C:\Users\a\AppData\Roaming"), Path::new(r"C:\Users\a\AppData\Local"));
        assert_eq!(p.config_file, Path::new(r"C:\Users\a\AppData\Roaming").join("RemoteKeyboard").join("config.json"));
        assert_eq!(p.log_dir, Path::new(r"C:\Users\a\AppData\Local").join("RemoteKeyboard").join("logs"));
    }

    #[test]
    fn linux_files_follow_xdg_with_the_documented_defaults() {
        let home = Path::new("/home/a");
        let defaults = linux_paths(home, None, None);
        let expect = |base: &str, tail: &[&str]| tail.iter().fold(PathBuf::from(base), |p, part| p.join(part));
        assert_eq!(defaults.config_file, expect("/home/a", &[".config", "remote-keyboard", "config.json"]));
        assert_eq!(defaults.log_dir, expect("/home/a", &[".local", "state", "remote-keyboard", "logs"]));
        let custom = linux_paths(home, Some(Path::new("/c")), Some(Path::new("/s")));
        assert_eq!(custom.config_file, expect("/c", &["remote-keyboard", "config.json"]));
        assert_eq!(custom.log_dir, expect("/s", &["remote-keyboard", "logs"]));
    }

    #[test]
    fn print_paths_names_both_files() {
        let paths = linux_paths(Path::new("/h"), None, None);
        let text = paths_text(&paths);
        assert_eq!(text, format!("config={}\nlogs={}\n", paths.config_file.display(), paths.log_dir.display()));
        assert!(text.contains("config.json") && text.contains("logs"));
    }
}
