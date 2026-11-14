//! The diagnostics the user can hand over: `diag.txt` (what this machine and this build are) and a zip of the recent logs.
//!
//! Nothing secret goes in: no pair keys, no phone names, no host name, no raw Bluetooth addresses.

use crate::config::{hex, Config};
use crate::log::{date_string, list_names, recent_files};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Cursor, Write};
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// The Bluetooth controller as the platform reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterInfo {
    pub name: String,
    pub address: String,
}

pub struct DiagInfo<'a> {
    pub version: &'a str,
    pub target: &'a str,
    pub os: &'a str,
    pub adapter: Option<&'a AdapterInfo>,
    pub config: &'a Config,
    pub paired_phones: usize,
    pub state: &'a str,
    pub log_level: &'a str,
}

/// A one-way short form of something that must not be written out, 12 hex characters of its SHA-256.
fn hashed(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes())[..6])
}

/// The text of `diag.txt`, one `key: value` per line.
pub fn diag_txt(info: &DiagInfo<'_>) -> String {
    let adapter = match info.adapter {
        Some(a) => format!("adapter_name_hash: {}\nadapter_address_hash: {}", hashed(&a.name), hashed(&a.address)),
        None => "adapter_name_hash: unknown\nadapter_address_hash: unknown".to_string(),
    };
    let c = info.config;
    format!(
        "version: {}\ntarget: {}\nos: {}\n{adapter}\nhost_id: {}\nadapter_configured: {}\npaired_phones: {}\nstate: {}\nlog_level: {}\n\
         trackpad: {}\nautostart: {}\nchar_interval_ms: {}\npaste_non_ascii: {}\n",
        info.version,
        info.target,
        info.os,
        hex(&c.host_id),
        c.adapter.is_some(),
        info.paired_phones,
        info.state,
        info.log_level,
        c.trackpad,
        c.autostart,
        c.char_interval_ms,
        c.paste_non_ascii,
    )
}

fn zip_error(e: zip::result::ZipError) -> io::Error {
    io::Error::other(e)
}

/// `RemoteKeyboard-diag-20261114-102030.zip`
pub fn export_file_name(now_unix_ms: u64) -> String {
    let seconds = now_unix_ms / 1000 % 86_400;
    format!("RemoteKeyboard-diag-{}-{:02}{:02}{:02}.zip", date_string(now_unix_ms).replace('-', ""), seconds / 3600, seconds / 60 % 60, seconds % 60)
}

/// The zip: the logs of the last 7 days and `diag.txt`.
pub fn build_zip(log_dir: &Path, diag: &str, now_unix_ms: u64) -> io::Result<Vec<u8>> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for name in recent_files(&list_names(log_dir), now_unix_ms) {
        let bytes = fs::read(log_dir.join(&name))?;
        writer.start_file(name, options).map_err(zip_error)?;
        writer.write_all(&bytes)?;
    }
    writer.start_file("diag.txt", options).map_err(zip_error)?;
    writer.write_all(diag.as_bytes())?;
    Ok(writer.finish().map_err(zip_error)?.into_inner())
}

/// Writes the zip into `out_dir` and returns its path.
pub fn export(log_dir: &Path, out_dir: &Path, diag: &str, now_unix_ms: u64) -> io::Result<PathBuf> {
    let bytes = build_zip(log_dir, diag, now_unix_ms)?;
    fs::create_dir_all(out_dir)?;
    let path = out_dir.join(export_file_name(now_unix_ms));
    fs::write(&path, bytes)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_core::identity::HostPlatform;
    use std::io::Read;

    const T0: u64 = 1_794_651_630_123; // 2026-11-14T10:20:30.123Z

    fn info<'a>(config: &'a Config, adapter: Option<&'a AdapterInfo>) -> DiagInfo<'a> {
        DiagInfo { version: "0.1.0", target: "x86_64-pc-windows-msvc", os: "Windows 11 build 26300", adapter, config, paired_phones: 2, state: "waiting", log_level: "info" }
    }

    #[test]
    fn diag_txt_tells_what_the_machine_is_and_hashes_the_adapter() {
        let config = Config::new([0xAB; 16], HostPlatform::Windows);
        let adapter = AdapterInfo { name: "Intel(R) Wireless Bluetooth(R)".into(), address: "AA:BB:CC:DD:EE:FF".into() };
        let text = diag_txt(&info(&config, Some(&adapter)));
        for expected in ["version: 0.1.0", "os: Windows 11 build 26300", "paired_phones: 2", "state: waiting", "log_level: info", &format!("host_id: {}", "ab".repeat(16))] {
            assert!(text.contains(expected), "{expected} missing in {text}");
        }
        assert!(text.contains("adapter_name_hash: ") && text.contains("adapter_address_hash: "));
        assert!(!text.contains("Intel") && !text.contains("AA:BB") && !text.contains("aabbcc"), "the adapter is only there as hashes");
    }

    #[test]
    fn diag_txt_leaves_out_the_host_name_and_the_adapter_setting() {
        let mut config = Config::new([1; 16], HostPlatform::Windows);
        config.host_name = "Anson-Private-PC".into();
        config.adapter = Some("hci-secret-name".into());
        let text = diag_txt(&info(&config, None));
        assert!(!text.contains("Anson-Private-PC") && !text.contains("hci-secret-name"));
        assert!(text.contains("adapter_configured: true"));
        assert!(text.contains("adapter_name_hash: unknown"));
    }

    #[test]
    fn export_file_name_carries_date_and_time() {
        assert_eq!(export_file_name(T0), "RemoteKeyboard-diag-20261114-102030.zip");
    }

    fn zip_entries(bytes: Vec<u8>) -> Vec<(String, String)> {
        let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        (0..archive.len())
            .map(|i| {
                let mut file = archive.by_index(i).unwrap();
                let mut text = String::new();
                file.read_to_string(&mut text).unwrap();
                (file.name().unwrap().to_string(), text)
            })
            .collect()
    }

    #[test]
    fn zip_holds_the_last_seven_days_of_logs_and_diag_txt_only() {
        let dir = tempfile::tempdir().unwrap();
        for (name, body) in [("rk-2026-11-14.log", "today"), ("rk-2026-11-10.log", "recent"), ("rk-2026-11-01.log", "old"), ("other.txt", "x")] {
            fs::write(dir.path().join(name), body).unwrap();
        }
        let entries = zip_entries(build_zip(dir.path(), "diag body", T0).unwrap());
        assert_eq!(
            entries,
            vec![
                ("rk-2026-11-10.log".to_string(), "recent".to_string()),
                ("rk-2026-11-14.log".to_string(), "today".to_string()),
                ("diag.txt".to_string(), "diag body".to_string()),
            ]
        );
    }

    #[test]
    fn export_writes_the_zip_into_the_target_folder() {
        let logs = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let path = export(logs.path(), &out.path().join("Desktop"), "d", T0).unwrap();
        assert_eq!(path.file_name().unwrap().to_str().unwrap(), "RemoteKeyboard-diag-20261114-102030.zip");
        assert_eq!(zip_entries(fs::read(path).unwrap())[0].0, "diag.txt");
    }
}
