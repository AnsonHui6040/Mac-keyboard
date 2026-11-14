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

    /// Reads the file, or makes a fresh configuration with a new `hostId` when there is none (or it cannot be read).
    pub fn load_or_create(path: &std::path::Path, platform: HostPlatform, new_id: impl FnOnce() -> [u8; 16]) -> Self {
        let read = fs::read_to_string(path).ok().and_then(|text| serde_json::from_str::<Config>(&text).ok());
        read.unwrap_or_else(|| Config::new(new_id(), platform))
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
        let loaded = Config::load_or_create(&path, HostPlatform::Windows, || [0; 16]);
        assert_eq!(loaded, config);
        assert!(fs::read_to_string(&path).unwrap().contains(&"ab".repeat(16)));
    }

    #[test]
    fn missing_or_broken_file_makes_a_new_host_id() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        assert_eq!(Config::load_or_create(&path, HostPlatform::Windows, || [5; 16]).host_id, [5; 16]);
        fs::write(&path, "{ not json").unwrap();
        assert_eq!(Config::load_or_create(&path, HostPlatform::Windows, || [6; 16]).host_id, [6; 16]);
    }
}
