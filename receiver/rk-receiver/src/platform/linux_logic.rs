//! The parts of the Linux shell that need no desktop: file locations, the autostart file, the menu as data, the arguments
//! of the dialogs, the key store that falls back to a file. They live outside the `cfg` module so that every host tests them.

use crate::config::{hex, unhex};
use crate::i18n::{self, Lang, Text};
use crate::store::{decode_record, encode_record, upsert, PhoneBackend, StoreError};
use crate::ui::{NoticeKind, TrayState, UiCommand};
use rk_core::identity::PairedPhone;
use std::io::Write;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Duration;
use std::path::{Path, PathBuf};

#[cfg(test)]
mod tests;

// ---------------------------------------------------------------- autostart

/// The program path as the `Exec=` key of a desktop entry wants it: a path with a reserved character is put in double
/// quotes, with `\`, `"`, `$` and the backtick escaped (and the backslash of that escape doubled, as every string value
/// of a desktop file requires); a literal `%` is written `%%`.
pub fn desktop_exec_quote(exe: &Path) -> String {
    const RESERVED: &str = " \t\n\"'\\<>~|&;$*?#()`";
    let text = exe.to_string_lossy().replace('%', "%%");
    if !text.chars().any(|c| RESERVED.contains(c)) {
        return text;
    }
    let mut quoted = String::from("\"");
    for c in text.chars() {
        match c {
            // A backslash is escaped by a backslash for the Exec key, and both again for the file: four in all.
            '\\' => quoted.push_str("\\\\\\\\"),
            '"' | '`' | '$' => {
                quoted.push_str("\\\\");
                quoted.push(c);
            }
            _ => quoted.push(c),
        }
    }
    quoted.push('"');
    quoted
}

pub fn autostart_desktop_file(exe: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Remote Keyboard\nExec={}\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        desktop_exec_quote(exe)
    )
}

pub fn autostart_file(home: &Path, xdg_config_home: Option<&Path>) -> PathBuf {
    let config = xdg_config_home.map_or_else(|| home.join(".config"), Path::to_path_buf);
    config.join("autostart").join("remote-keyboard.desktop")
}

/// Writes or removes the autostart file. `false` when it could not be done.
pub fn write_autostart(file: &Path, exe: &Path, enabled: bool) -> bool {
    if enabled {
        if let Some(dir) = file.parent() {
            if std::fs::create_dir_all(dir).is_err() {
                return false;
            }
        }
        return std::fs::write(file, autostart_desktop_file(exe)).is_ok();
    }
    match std::fs::remove_file(file) {
        Ok(()) => true,
        Err(error) => error.kind() == std::io::ErrorKind::NotFound,
    }
}

// ---------------------------------------------------------------- paths and environment

/// `$XDG_DATA_HOME/remote-keyboard/phones.json`, `~/.local/share/...` by default: the keys when there is no Secret Service.
pub fn data_file(home: &Path, xdg_data_home: Option<&Path>) -> PathBuf {
    let data = xdg_data_home.map_or_else(|| home.join(".local").join("share"), Path::to_path_buf);
    data.join("remote-keyboard").join("phones.json")
}

/// The portal's restore token: `$XDG_CONFIG_HOME/remote-keyboard/portal-token`, next to `config.json`.
pub fn portal_token_file(config_file: &Path) -> PathBuf {
    config_file.with_file_name("portal-token")
}

/// `$XDG_RUNTIME_DIR/remote-keyboard.lock`; without a runtime directory the state directory takes it.
pub fn lock_file(xdg_runtime_dir: Option<&Path>, fallback_dir: &Path) -> PathBuf {
    xdg_runtime_dir.unwrap_or(fallback_dir).join("remote-keyboard.lock")
}

/// Where the diagnostics zip is put: on the desktop, else next to the logs.
pub fn export_dir(home: &Path, desktop_exists: bool, log_dir: &Path) -> PathBuf {
    if desktop_exists {
        home.join("Desktop")
    } else {
        log_dir.to_path_buf()
    }
}

/// `PRETTY_NAME` of an `/etc/os-release` file.
pub fn pretty_name(os_release: &str) -> Option<String> {
    os_release.lines().find_map(|line| line.strip_prefix("PRETTY_NAME=")).map(|v| v.trim().trim_matches('"').to_string())
}

/// The first of `LC_ALL`, `LC_MESSAGES`, `LANG` that is set and not empty decides.
pub fn lang_from_env(lc_all: Option<&str>, lc_messages: Option<&str>, lang: Option<&str>) -> Lang {
    let locale = [lc_all, lc_messages, lang].into_iter().flatten().find(|v| !v.is_empty()).unwrap_or("");
    Lang::from_locale(locale)
}

/// The arguments for starting the receiver again: those that only belonged to the first start are left out, and the
/// controller that was chosen is named outright, so the new start never falls back to the system default (`hci0`).
pub fn restart_args(args: &[String], adapter: &str) -> Vec<String> {
    let mut kept = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--pair" => {}
            "--adapter" => {
                args.next();
            }
            _ => kept.push(arg.clone()),
        }
    }
    kept.extend(["--adapter".to_string(), adapter.to_string()]);
    kept
}

// ---------------------------------------------------------------- tray menu

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuEntry {
    /// A line of text that cannot be clicked.
    Info { label: String },
    Item { id: String, label: String },
    Check { id: String, label: String, checked: bool },
    Sub { label: String, entries: Vec<MenuEntry> },
    Separator,
}

/// The Bluetooth controllers there are and which one is in use (`None`: the system default).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AdapterChoices {
    pub names: Vec<String>,
    pub current: Option<String>,
}

impl AdapterChoices {
    /// The controller in use: the configured one, else what BlueZ takes by default (`hci0`, or the first by name).
    pub fn effective(&self) -> Option<String> {
        if self.current.is_some() {
            return self.current.clone();
        }
        if self.names.iter().any(|n| n == "hci0") {
            return Some("hci0".to_string());
        }
        self.names.iter().min().cloned()
    }
}

pub fn status_label(state: &TrayState, lang: Lang) -> String {
    match &state.connected_phone {
        Some(phone) => i18n::status_connected(lang, phone),
        None if !state.receiving => i18n::text(lang, Text::StatusStopped).to_string(),
        None if state.needs_authorization => i18n::text(lang, Text::StatusNeedsAuthorization).to_string(),
        None if state.pairing_open => i18n::text(lang, Text::StatusPairing).to_string(),
        None => i18n::text(lang, Text::StatusIdle).to_string(),
    }
}

/// A notice that is still true is shown before the state.
pub fn tooltip_text(state: &TrayState, lang: Lang, notice: Option<NoticeKind>) -> String {
    let line = match notice {
        Some(kind) => i18n::notice(lang, kind).to_string(),
        None => status_label(state, lang),
    };
    format!("{} - {line}", i18n::text(lang, Text::AppName))
}

fn item(id: &str, label: &str) -> MenuEntry {
    MenuEntry::Item { id: id.to_string(), label: label.to_string() }
}

fn check(id: &str, label: &str, checked: bool) -> MenuEntry {
    MenuEntry::Check { id: id.to_string(), label: label.to_string(), checked }
}

/// The controller submenu: only when there is a choice to make. The checked one is the configured controller, or `hci0`
/// (else the first by name) when none is configured, which is what BlueZ defaults to.
fn adapter_menu(adapters: &AdapterChoices, lang: Lang) -> Option<MenuEntry> {
    if adapters.names.len() < 2 {
        return None;
    }
    let current = adapters.effective();
    let entries = adapters.names.iter().map(|name| check(&format!("adapter:{name}"), name, current.as_deref() == Some(name.as_str()))).collect();
    Some(MenuEntry::Sub { label: i18n::text(lang, Text::BluetoothAdapter).to_string(), entries })
}

pub fn menu_entries(state: &TrayState, lang: Lang, adapters: &AdapterChoices) -> Vec<MenuEntry> {
    let text = |key| i18n::text(lang, key);
    let phones: Vec<MenuEntry> = if state.phones.is_empty() {
        vec![MenuEntry::Info { label: text(Text::NoPairedPhones).to_string() }]
    } else {
        state
            .phones
            .iter()
            .map(|phone| MenuEntry::Sub { label: phone.name.clone(), entries: vec![item(&format!("delete:{}", hex(&phone.id)), text(Text::Delete))] })
            .collect()
    };
    let mut entries = vec![
        MenuEntry::Info { label: status_label(state, lang) },
        item("receiving", text(if state.receiving { Text::StopReceiving } else { Text::StartReceiving })),
        item("rename", &format!("{}　{}", state.host_name, text(Text::Rename))),
        MenuEntry::Separator,
        // Pairing needs the scan that 停止 switched off: greyed out until 開始.
        if state.receiving { item("pair", text(Text::PairNewPhone)) } else { MenuEntry::Info { label: text(Text::PairNewPhone).to_string() } },
        MenuEntry::Sub { label: text(Text::PairedPhones).to_string(), entries: phones },
        MenuEntry::Separator,
        check("trackpad", text(Text::AllowTrackpad), state.trackpad),
        check("paste", text(Text::PasteNonAscii), state.paste_non_ascii),
        check("autostart", text(Text::Autostart), state.autostart),
        item("reauthorize", text(Text::Reauthorize)),
    ];
    entries.extend(adapter_menu(adapters, lang));
    entries.extend([MenuEntry::Separator, item("export", text(Text::ExportDiagnostics)), item("quit", text(Text::Quit))]);
    entries
}

/// What a click on a menu item asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Command(UiCommand),
    /// Write or remove the autostart file; the command follows when that worked.
    SetAutostart(bool),
    AskName,
    Export,
    /// Use this controller from the next start on.
    ChooseAdapter(String),
}

pub fn action_for(id: &str, state: &TrayState) -> Option<Action> {
    let command = |c| Some(Action::Command(c));
    match id {
        "receiving" => command(UiCommand::SetReceiving(!state.receiving)),
        "pair" => command(UiCommand::StartPairing),
        "trackpad" => command(UiCommand::SetTrackpad(!state.trackpad)),
        "paste" => command(UiCommand::SetPasteNonAscii(!state.paste_non_ascii)),
        "autostart" => Some(Action::SetAutostart(!state.autostart)),
        "reauthorize" => command(UiCommand::Reauthorize),
        "quit" => command(UiCommand::Quit),
        "rename" => Some(Action::AskName),
        "export" => Some(Action::Export),
        other => {
            if let Some(phone) = other.strip_prefix("delete:") {
                return unhex::<16>(phone).and_then(|id| command(UiCommand::DeletePhone(id)));
            }
            other.strip_prefix("adapter:").map(|name| Action::ChooseAdapter(name.to_string()))
        }
    }
}

/// The tray icon bytes in the order StatusNotifierItem wants: ARGB, network byte order.
pub fn argb_from_rgba(rgba: &[u8]) -> Vec<u8> {
    rgba.as_chunks::<4>().0.iter().flat_map(|px| [px[3], px[0], px[1], px[2]]).collect()
}

// ---------------------------------------------------------------- dialogs

/// Every text is one argument of its own, never a shell line, and never read as markup: phone names are not trusted.
fn dialog(kind: &str, title: &str, text: &str, more: Vec<String>) -> Vec<String> {
    let mut args = vec![kind.to_string(), "--no-markup".to_string(), format!("--title={title}"), format!("--text={text}")];
    args.extend(more);
    args
}

pub fn question_args(title: &str, text: &str, ok: &str, cancel: &str) -> Vec<String> {
    dialog("--question", title, text, vec![format!("--ok-label={ok}"), format!("--cancel-label={cancel}"), "--width=420".to_string()])
}

pub fn entry_args(title: &str, prompt: &str, current: &str) -> Vec<String> {
    dialog("--entry", title, prompt, vec![format!("--entry-text={current}"), "--width=420".to_string()])
}

pub fn info_args(title: &str, text: &str) -> Vec<String> {
    dialog("--info", title, text, vec!["--width=420".to_string()])
}

/// `zenity --question` exits 0 for the OK button; anything else (Cancel, closed, killed) is no.
pub fn answered_yes(exit_code: Option<i32>) -> bool {
    exit_code == Some(0)
}

/// What `zenity --entry` printed, when the user pressed OK and typed something.
pub fn entered_name(exit_code: Option<i32>, stdout: &str) -> Option<String> {
    let name = stdout.trim();
    (exit_code == Some(0) && !name.is_empty()).then(|| name.to_string())
}

// ---------------------------------------------------------------- reading the keyring without waiting for it

/// What `LoadSlot::begin` says.
#[derive(Debug)]
pub enum Begin {
    /// The last read has finished: its answer.
    Done(Result<Vec<PairedPhone>, StoreError>),
    /// A read is going on (a prompt nobody has answered, a slow keyring): do not start another.
    Busy,
    /// Start a read now. `interactive` says whether it may ask the user to unlock the keyring.
    Start { interactive: bool },
}

#[derive(Debug)]
struct SlotState {
    outstanding: bool,
    result: Option<Result<Vec<PairedPhone>, StoreError>>,
    interactive: bool,
}

/// The hand-over between the application thread, which must never wait for a keyring, and the thread that talks to it.
/// One read at a time; only the very first one (and one the user asked for) may raise a prompt.
#[derive(Debug)]
pub struct LoadSlot {
    state: Mutex<SlotState>,
    done: Condvar,
}

impl Default for LoadSlot {
    fn default() -> Self {
        Self::new()
    }
}

impl LoadSlot {
    /// The first read is the start-up one and may ask for the keyring to be unlocked.
    pub fn new() -> Self {
        Self { state: Mutex::new(SlotState { outstanding: false, result: None, interactive: true }), done: Condvar::new() }
    }

    fn lock(&self) -> MutexGuard<'_, SlotState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn begin(&self) -> Begin {
        let mut state = self.lock();
        if let Some(result) = state.result.take() {
            return Begin::Done(result);
        }
        if state.outstanding {
            return Begin::Busy;
        }
        state.outstanding = true;
        Begin::Start { interactive: std::mem::replace(&mut state.interactive, false) }
    }

    /// The reading thread's answer.
    pub fn finish(&self, result: Result<Vec<PairedPhone>, StoreError>) {
        let mut state = self.lock();
        state.outstanding = false;
        state.result = Some(result);
        self.done.notify_all();
    }

    /// Waits for the answer of the read that was just started, at most `timeout`.
    pub fn wait(&self, timeout: Duration) -> Option<Result<Vec<PairedPhone>, StoreError>> {
        let state = self.lock();
        let (mut state, _) = self.done.wait_timeout_while(state, timeout, |s| s.result.is_none()).unwrap_or_else(|p| p.into_inner());
        state.result.take()
    }

    /// A finished read's answer is waiting to be taken by `begin`.
    pub fn has_answer(&self) -> bool {
        self.lock().result.is_some()
    }

    /// The user asked for something that needs the keys: the next read may raise the unlock prompt.
    pub fn want_interactive(&self) {
        self.lock().interactive = true;
    }
}

// ---------------------------------------------------------------- keys without Secret Service

/// The paired phones in a file that only the user can read, for desktops without a Secret Service.
pub struct FilePhoneBackend {
    path: PathBuf,
}

impl FilePhoneBackend {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

/// A new file for writing, readable by the owner only (on the systems that have such a thing). It must not exist yet, so
/// the mode is the one asked for and not that of some leftover.
fn private_file_options() -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options
}

fn file_error(what: &str) -> StoreError {
    StoreError::Backend(what.to_string())
}

impl FilePhoneBackend {
    /// The phones in the file: none when there is no file, an error when there is one that is not ours to read.
    fn read(&self) -> Result<Vec<PairedPhone>, StoreError> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(_) => return Err(file_error("phones file unreadable")),
        };
        let records: Vec<serde_json::Value> = serde_json::from_str(&text).map_err(|_| file_error("phones file unreadable"))?;
        records.iter().map(|record| decode_record(record.to_string().as_bytes()).ok_or_else(|| file_error("phones file unreadable"))).collect()
    }

    fn write(&self, phones: &[PairedPhone]) -> Result<(), StoreError> {
        let records: Vec<serde_json::Value> = phones.iter().filter_map(|p| serde_json::from_slice(&encode_record(p)).ok()).collect();
        let text = serde_json::to_string_pretty(&records).map_err(|_| file_error("phones file not written"))?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|_| file_error("phones directory not created"))?;
        }
        let temporary = self.path.with_extension("json.tmp");
        // A crash may have left one behind, with any mode.
        let _ = std::fs::remove_file(&temporary);
        let mut file = private_file_options().open(&temporary).map_err(|_| file_error("phones file not written"))?;
        file.write_all(text.as_bytes()).map_err(|_| file_error("phones file not written"))?;
        // On disk before the rename makes it the file: a crash leaves the old list or the new one, never half of it.
        file.sync_all().map_err(|_| file_error("phones file not written"))?;
        drop(file);
        std::fs::rename(&temporary, &self.path).map_err(|_| file_error("phones file not written"))
    }
}

impl PhoneBackend for FilePhoneBackend {
    fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
        self.read()
    }

    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
        let mut phones = self.read()?;
        upsert(&mut phones, phone.clone())?;
        self.write(&phones)
    }

    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        let mut phones = self.read()?;
        let before = phones.len();
        phones.retain(|p| &p.identity.id != id);
        if phones.len() == before {
            return Ok(());
        }
        self.write(&phones)
    }
}

/// A key store (Secret Service) when there is one, with the file next to it: phones that are in the file stay visible,
/// new ones go to the key store, and a key store that refuses is an error, not a reason to write keys in the clear.
pub struct ChainedBackend {
    primary: Option<Box<dyn PhoneBackend>>,
    file: FilePhoneBackend,
}

impl ChainedBackend {
    pub fn new(primary: Option<Box<dyn PhoneBackend>>, file: FilePhoneBackend) -> Self {
        Self { primary, file }
    }
}

impl PhoneBackend for ChainedBackend {
    fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
        let Some(primary) = &self.primary else { return self.file.load() };
        // The key store that cannot be read makes the whole list unknown; a damaged file next to a good key store does not.
        let mut phones = primary.load()?;
        for phone in self.file.load().unwrap_or_default() {
            if !phones.iter().any(|p| p.identity.id == phone.identity.id) {
                phones.push(phone);
            }
        }
        Ok(phones)
    }

    fn unlock(&self) {
        if let Some(primary) = &self.primary {
            primary.unlock();
        }
    }

    fn answer_ready(&self) -> bool {
        self.primary.as_ref().is_some_and(|primary| primary.answer_ready())
    }

    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
        match &mut self.primary {
            Some(primary) => primary.put(phone),
            None => self.file.put(phone),
        }
    }

    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        if let Some(primary) = &mut self.primary {
            primary.remove(id)?;
        }
        self.file.remove(id)
    }
}
