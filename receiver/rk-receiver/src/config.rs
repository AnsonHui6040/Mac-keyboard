//! The receiver's settings, kept as JSON next to nothing secret: the pair keys live in the platform key store.

use crate::store::{ConfigStore, StoreError};
use rk_core::identity::{clamp_name, HostIdentity, HostPlatform};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    #[serde(with = "hex16")]
    pub host_id: [u8; 16],
    pub host_name: String,
    /// 「允許觸控板控制」
    pub trackpad: bool,
    pub autostart: bool,
    /// Pause between typed characters, for targets that drop fast input.
    pub char_interval_ms: u32,
    /// Linux: paste non-ASCII text instead of typing it.
    pub paste_non_ascii: bool,
    /// A specific Bluetooth controller; `None` takes the system default.
    pub adapter: Option<String>,
}

/// Where a configuration came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigOrigin {
    Loaded,
    /// There was no file: a first start.
    Created,
    /// The file was unreadable and was kept under this name.
    Recovered { backup: PathBuf },
    /// The file was unreadable and could not be moved aside (the error kind says why). It is still there: the caller must not
    /// write a new configuration over it.
    NotKept { error: std::io::ErrorKind },
}

/// The name a host has before the user renames it (§4).
pub fn default_host_name(platform: HostPlatform) -> &'static str {
    match platform {
        HostPlatform::Mac => "Mac",
        HostPlatform::Windows => "Windows",
        HostPlatform::Linux => "Linux",
    }
}

impl Config {
    pub fn new(host_id: [u8; 16], platform: HostPlatform) -> Self {
        Self {
            host_id,
            host_name: default_host_name(platform).to_string(),
            trackpad: false,
            autostart: false,
            char_interval_ms: 0,
            paste_non_ascii: false,
            adapter: None,
        }
    }

    /// Sets the name the way §4 asks: cut to 32 bytes on a scalar boundary, the default when nothing is left.
    pub fn set_host_name(&mut self, name: &str, platform: HostPlatform) {
        let clamped = clamp_name(name.trim());
        self.host_name = if clamped.is_empty() { default_host_name(platform).to_string() } else { clamped };
    }

    pub fn host_identity(&self, platform: HostPlatform) -> HostIdentity {
        HostIdentity { id: self.host_id, name: self.host_name.clone(), platform }
    }

    /// Reads the file. Only a missing file makes a fresh configuration with a new `hostId` straight away. A file that exists
    /// but cannot be read or parsed is moved to `config.json.bad-<time>` first, so the old `hostId` is never silently
    /// overwritten. When even that move fails the file stays as it is (`NotKept`) and the caller must keep the new
    /// configuration in memory only.
    pub fn load_or_create(path: &std::path::Path, platform: HostPlatform, new_id: impl FnOnce() -> [u8; 16], now_unix_ms: u64) -> (Self, ConfigOrigin) {
        let text = match fs::read_to_string(path) {
            Ok(text) => Some(text),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return (Config::new(new_id(), platform), ConfigOrigin::Created),
            Err(_) => None,
        };
        if let Some(config) = text.and_then(|text| serde_json::from_str::<Config>(&text).ok()) {
            return (config, ConfigOrigin::Loaded);
        }
        let mut backup = path.as_os_str().to_owned();
        backup.push(format!(".bad-{now_unix_ms}"));
        let backup = PathBuf::from(backup);
        let origin = match fs::rename(path, &backup) {
            Ok(()) => ConfigOrigin::Recovered { backup },
            Err(error) => ConfigOrigin::NotKept { error: error.kind() },
        };
        (Config::new(new_id(), platform), origin)
    }

    /// The configuration on disk for a read-only look (`--diag`, the export): never moves or writes anything. A file that is
    /// missing or unreadable shows as a configuration with an all-zero `hostId`.
    pub fn read_only(path: &std::path::Path, platform: HostPlatform) -> Self {
        fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_else(|| Config::new([0; 16], platform))
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_default()
    }
}

/// Saves the configuration as a JSON file.
#[derive(Debug)]
pub struct FileConfigStore {
    path: PathBuf,
}

impl FileConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl ConfigStore for FileConfigStore {
    fn save(&mut self, config: &Config) -> Result<(), StoreError> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir).map_err(|e| StoreError::Backend(e.kind().to_string()))?;
        }
        let temporary = self.path.with_extension("json.tmp");
        fs::write(&temporary, config.to_json()).map_err(|e| StoreError::Backend(e.kind().to_string()))?;
        fs::rename(&temporary, &self.path).map_err(|e| StoreError::Backend(e.kind().to_string()))
    }
}

mod hex16 {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(id: &[u8; 16], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&super::hex(id))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 16], D::Error> {
        let text = String::deserialize(d)?;
        super::unhex::<16>(&text).ok_or_else(|| serde::de::Error::custom("hostId must be 32 hex characters"))
    }
}

/// Lowercase hexadecimal.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The `N` bytes written as `2 * N` hexadecimal characters, `None` for anything else.
pub fn unhex<const N: usize>(text: &str) -> Option<[u8; N]> {
    if text.len() != 2 * N || !text.is_ascii() {
        return None;
    }
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_host_name_is_windows() {
        let config = Config::new([7; 16], HostPlatform::Windows);
        assert_eq!(config.host_name, "Windows");
        assert_eq!(Config::new([7; 16], HostPlatform::Linux).host_name, "Linux");
    }

    #[test]
    fn host_name_is_cut_on_a_scalar_boundary_and_never_empty() {
        let mut config = Config::new([7; 16], HostPlatform::Windows);
        config.set_host_name(&"測".repeat(11), HostPlatform::Windows);
        assert_eq!(config.host_name, "測".repeat(10));
        config.set_host_name("   ", HostPlatform::Windows);
        assert_eq!(config.host_name, "Windows");
    }

    #[test]
    fn config_round_trips_through_its_file_and_keeps_the_host_id() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("config.json");
        let mut config = Config::new([0xAB; 16], HostPlatform::Windows);
        config.trackpad = true;
        FileConfigStore::new(path.clone()).save(&config).unwrap();
        let (loaded, _) = Config::load_or_create(&path, HostPlatform::Windows, || [0; 16], 1);
        assert_eq!(loaded, config);
        assert!(fs::read_to_string(&path).unwrap().contains(&"ab".repeat(16)));
    }

    #[test]
    fn a_missing_file_makes_a_new_host_id() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let (config, origin) = Config::load_or_create(&path, HostPlatform::Windows, || [5; 16], 1);
        assert_eq!((config.host_id, origin), ([5; 16], ConfigOrigin::Created));
    }

    #[test]
    fn a_broken_file_is_kept_aside_before_a_new_one_is_made() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, "{ not json").unwrap();
        let (config, origin) = Config::load_or_create(&path, HostPlatform::Windows, || [6; 16], 1_794_651_630_123);
        let backup = dir.path().join("config.json.bad-1794651630123");
        assert_eq!(config.host_id, [6; 16]);
        assert_eq!(origin, ConfigOrigin::Recovered { backup: backup.clone() });
        assert_eq!(fs::read_to_string(backup).unwrap(), "{ not json", "the broken file is not lost");
        assert!(!path.exists(), "the caller saves the new one");
    }

    #[test]
    fn a_file_that_cannot_be_read_as_text_is_kept_aside_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, [0xFF, 0xFE, 0xFD]).unwrap(); // not UTF-8: read_to_string fails with InvalidData, not NotFound
        let (config, origin) = Config::load_or_create(&path, HostPlatform::Windows, || [8; 16], 77);
        let backup = dir.path().join("config.json.bad-77");
        assert_eq!(config.host_id, [8; 16]);
        assert_eq!(origin, ConfigOrigin::Recovered { backup: backup.clone() });
        assert_eq!(fs::read(backup).unwrap(), vec![0xFF, 0xFE, 0xFD]);
    }

    #[test]
    fn when_the_broken_file_cannot_be_kept_it_stays_and_nothing_is_to_be_saved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, "{ not json").unwrap();
        // Something is in the way of the backup name, so the rename fails.
        let in_the_way = dir.path().join("config.json.bad-5");
        fs::create_dir(&in_the_way).unwrap();
        fs::write(in_the_way.join("x"), "x").unwrap();
        let (config, origin) = Config::load_or_create(&path, HostPlatform::Windows, || [9; 16], 5);
        assert_eq!(config.host_id, [9; 16], "the receiver runs with a configuration in memory");
        assert!(matches!(origin, ConfigOrigin::NotKept { .. }), "{origin:?}");
        assert_eq!(fs::read_to_string(&path).unwrap(), "{ not json", "the old file is untouched");
    }

    #[test]
    fn a_read_only_look_never_moves_a_broken_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, "{ not json").unwrap();
        assert_eq!(Config::read_only(&path, HostPlatform::Windows).host_id, [0; 16]);
        assert_eq!(fs::read_to_string(&path).unwrap(), "{ not json");
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn a_good_file_is_loaded_as_it_is() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        FileConfigStore::new(path.clone()).save(&Config::new([7; 16], HostPlatform::Windows)).unwrap();
        let (config, origin) = Config::load_or_create(&path, HostPlatform::Windows, || [9; 16], 1);
        assert_eq!((config.host_id, origin), ([7; 16], ConfigOrigin::Loaded));
    }
}
