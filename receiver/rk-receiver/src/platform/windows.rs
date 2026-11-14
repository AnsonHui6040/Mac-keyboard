//! The Windows shell: tray icon and menu, dialogs, Credential Manager, registry autostart and the single-instance mutex.
//!
//! Everything platform independent is in the rest of the crate; this file only turns Windows facilities into the traits
//! and channels the application uses. It is verified by building and running on Windows, not by the Mac test run.

use super::{claim_instance, windows_paths, Instance, InstanceLock, Paths};
use crate::app::{App, AppDeps};
use crate::clock::{Clock, SystemClock};
use crate::cli::Cli;
use crate::config::{hex, Config, ConfigOrigin, FileConfigStore};
use crate::diag::{self, AdapterInfo, DiagInfo};
use crate::i18n::{self, Lang, Text};
use crate::icons;
use crate::log::{FileSink, Logger};
use crate::random::OsRandom;
use crate::runner::{self, UiSink};
use crate::store::{decode_record, encode_record, CachedPhoneStore, ConfigStore, PhoneBackend, PhoneStore, RefusingConfigStore, StoreError};
use crate::ui::{IconState, NoticeKind, TrayState, UiCommand, UiEvent};
use rk_core::identity::{HostPlatform, PairedPhone};
use rk_inject::windows::WindowsInjector;
use rk_inject::Injector;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};
use windows::core::{w, BOOL, PCWSTR, PWSTR};
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HANDLE, HWND, LPARAM, WPARAM};
use windows::Win32::Globalization::GetUserDefaultUILanguage;
use windows::Win32::Security::Credentials::{
    CredDeleteW, CredEnumerateW, CredFree, CredWriteW, CREDENTIALW, CRED_ENUMERATE_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
};
use windows::Win32::System::Console::{AttachConsole, GetStdHandle, SetStdHandle, ATTACH_PARENT_PROCESS, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteKeyValueW, RegGetValueW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE,
    KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_SZ,
};
use windows::Win32::System::Threading::{CreateMutexW, GetCurrentThreadId};
use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EnumThreadWindows, GetMessageW, MessageBoxW, PeekMessageW, PostMessageW, PostThreadMessageW, TranslateMessage, IDNO,
    IDYES, MB_ICONINFORMATION, MB_ICONQUESTION, MB_OK, MB_SETFOREGROUND, MB_TOPMOST, MB_YESNO, MSG, PM_NOREMOVE, WM_APP, WM_COMMAND, WM_QUIT,
    WM_USER,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const MUTEX_NAME: PCWSTR = w!("Local\\RemoteKeyboardReceiver");
const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const RUN_VALUE: PCWSTR = w!("RemoteKeyboard");
const CREDENTIAL_PREFIX: &str = "RemoteKeyboard/phone/";
/// Posted to the tray thread when there is something in its queue.
const WM_WAKE: u32 = WM_APP + 1;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn env_path(name: &str) -> PathBuf {
    std::env::var_os(name).map(PathBuf::from).unwrap_or_default()
}

pub fn paths() -> Paths {
    windows_paths(&env_path("APPDATA"), &env_path("LOCALAPPDATA"))
}

pub fn lang() -> Lang {
    // SAFETY: GetUserDefaultUILanguage takes no arguments and cannot fail.
    Lang::from_langid(unsafe { GetUserDefaultUILanguage() })
}

/// The binary is a Windows-subsystem program in release builds, so `--version` and friends have no console unless the
/// parent has one. Attach to it and point the standard handles there; when they are redirected already, leave them.
pub fn prepare_console() {
    // SAFETY: plain Win32 calls; the opened device handle is leaked on purpose because the standard handle keeps using it.
    unsafe {
        let redirected = GetStdHandle(STD_OUTPUT_HANDLE).is_ok_and(|h| !h.is_invalid() && !h.0.is_null());
        if redirected || AttachConsole(ATTACH_PARENT_PROCESS).is_err() {
            return;
        }
        if let Ok(out) = std::fs::OpenOptions::new().write(true).open("CONOUT$") {
            let handle = HANDLE(out.as_raw_handle());
            let _ = SetStdHandle(STD_OUTPUT_HANDLE, handle);
            let _ = SetStdHandle(STD_ERROR_HANDLE, handle);
            std::mem::forget(out);
        }
    }
}

// ---------------------------------------------------------------- single instance

struct NamedMutex {
    held: Option<HANDLE>,
}

impl InstanceLock for NamedMutex {
    fn try_acquire(&mut self) -> bool {
        // SAFETY: the name is a valid NUL-terminated wide string; the handle is kept for the life of the process.
        let created = unsafe { CreateMutexW(None, false, MUTEX_NAME) };
        let Ok(handle) = created else { return true };
        // SAFETY: read straight after the call it belongs to.
        let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        self.held = Some(handle);
        !existed
    }
}

// ---------------------------------------------------------------- Credential Manager

/// The paired phones, one generic credential each: target `RemoteKeyboard/phone/<phoneId>`, blob = JSON record. Reading it
/// decrypts every secret, so the application only ever sees the cached version.
pub type CredentialPhoneStore = CachedPhoneStore<CredentialBackend>;

#[derive(Default)]
pub struct CredentialBackend;

fn credential_target(id: &[u8; 16]) -> String {
    format!("{CREDENTIAL_PREFIX}{}", hex(id))
}

fn backend_error(what: &str) -> StoreError {
    StoreError::Backend(what.to_string())
}

impl PhoneBackend for CredentialBackend {
    fn load(&self) -> Vec<PairedPhone> {
        let filter = wide(&format!("{CREDENTIAL_PREFIX}*"));
        let (mut count, mut list) = (0u32, std::ptr::null_mut());
        let mut found: Vec<(String, PairedPhone)> = Vec::new();
        // SAFETY: CredEnumerateW fills `count` pointers to credentials owned by the buffer, which is read before CredFree.
        unsafe {
            if CredEnumerateW(PCWSTR(filter.as_ptr()), Some(CRED_ENUMERATE_FLAGS(0)), &mut count, &mut list).is_err() {
                return Vec::new();
            }
            for credential in std::slice::from_raw_parts(list, count as usize) {
                let credential = &**credential;
                let blob = std::slice::from_raw_parts(credential.CredentialBlob, credential.CredentialBlobSize as usize);
                if let Some(phone) = decode_record(blob) {
                    found.push((credential.TargetName.to_string().unwrap_or_default(), phone));
                }
            }
            CredFree(list.cast());
        }
        found.sort_by(|a, b| a.0.cmp(&b.0));
        found.into_iter().map(|(_, phone)| phone).collect()
    }

    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
        let mut target = wide(&credential_target(&phone.identity.id));
        let mut blob = encode_record(phone);
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(target.as_mut_ptr()),
            CredentialBlobSize: u32::try_from(blob.len()).map_err(|_| backend_error("record too large"))?,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            ..Default::default()
        };
        // SAFETY: `credential` points into `target` and `blob`, which outlive the call.
        unsafe { CredWriteW(&credential, 0) }.map_err(|_| backend_error("CredWriteW"))
    }

    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        let target = wide(&credential_target(id));
        // SAFETY: valid NUL-terminated name.
        unsafe { CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, None) }.map_err(|_| backend_error("CredDeleteW"))
    }
}

// ---------------------------------------------------------------- registry

fn exe_path() -> PathBuf {
    std::env::current_exe().unwrap_or_default()
}

pub fn set_autostart(enabled: bool) -> bool {
    // SAFETY: registry calls with valid wide strings; the key is closed again.
    unsafe {
        if enabled {
            let mut key = HKEY::default();
            if RegCreateKeyExW(HKEY_CURRENT_USER, RUN_KEY, None, PCWSTR::null(), REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, None, &mut key, None).is_err() {
                return false;
            }
            let value = wide(&format!("\"{}\"", exe_path().display()));
            let bytes = std::slice::from_raw_parts(value.as_ptr().cast::<u8>(), value.len() * 2);
            let ok = RegSetValueExW(key, RUN_VALUE, None, REG_SZ, Some(bytes)).is_ok();
            let _ = RegCloseKey(key);
            ok
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE);
            true
        }
    }
}

fn registry_string(subkey: PCWSTR, value: PCWSTR) -> Option<String> {
    let mut buffer = [0u16; 256];
    let mut size = u32::try_from(std::mem::size_of_val(&buffer)).ok()?;
    // SAFETY: the buffer and its size describe the same memory.
    let status = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, subkey, value, RRF_RT_REG_SZ, None, Some(buffer.as_mut_ptr().cast()), Some(&mut size)) };
    status.is_ok().then(|| String::from_utf16_lossy(&buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())]))
}

pub fn os_description() -> String {
    let key = w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    let name = registry_string(key, w!("ProductName")).unwrap_or_else(|| "Windows".into());
    let build = registry_string(key, w!("CurrentBuildNumber")).unwrap_or_else(|| "?".into());
    let display = registry_string(key, w!("DisplayVersion")).unwrap_or_default();
    format!("{name} {display} build {build}").replace("  ", " ")
}

pub fn adapter_info() -> Option<AdapterInfo> {
    // SAFETY: WinRT initialisation on the calling thread; a repeated call is harmless.
    let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
    let adapter = windows::Devices::Bluetooth::BluetoothAdapter::GetDefaultAsync().ok()?.get().ok()?;
    Some(AdapterInfo { name: adapter.DeviceId().ok()?.to_string(), address: format!("{:012X}", adapter.BluetoothAddress().ok()?) })
}

// ---------------------------------------------------------------- injection

/// The `SendInput` injector, with the character gap from the configuration (0 means none).
pub fn make_injector(config: &Config) -> Box<dyn Injector> {
    Box::new(WindowsInjector::new(config.char_interval_ms(HostPlatform::Windows)))
}

/// `--inject-selftest`: after `delay_secs`, type the file through the injector the receiver itself uses, press Enter and print
/// one line of counts. The text is neither printed nor logged. Returns the exit code.
pub fn inject_selftest(file: &Path, delay_secs: u64) -> i32 {
    let Ok(text) = std::fs::read_to_string(file) else {
        println!("units=0 ms=0 result=err:read_file");
        return 1;
    };
    let config = Config::read_only(&paths().config_file, HostPlatform::Windows);
    let mut injector = make_injector(&config);
    std::thread::sleep(std::time::Duration::from_secs(delay_secs));
    let clock = SystemClock::new();
    let line = crate::selftest::run(injector.as_mut(), &text, || clock.mono_ms());
    println!("{line}");
    i32::from(!line.ends_with("result=ok"))
}

// ---------------------------------------------------------------- dialogs

const DIALOG_TITLE: &str = "Remote Keyboard";

fn message_box(title: &str, text: &str, flags: windows::Win32::UI::WindowsAndMessaging::MESSAGEBOX_STYLE) -> bool {
    let (title, text) = (wide(title), wide(text));
    // SAFETY: both strings are NUL-terminated and live through the call.
    unsafe { MessageBoxW(None, PCWSTR(text.as_ptr()), PCWSTR(title.as_ptr()), flags | MB_SETFOREGROUND | MB_TOPMOST) == IDYES }
}

/// The pairing questions on screen: attempt, and the thread that is inside its `MessageBoxW`. A message box belongs to the
/// thread that opened it, so that thread finds the box without guessing by title, and a box is closed by its own attempt.
#[derive(Default)]
struct PairingDialogs {
    open: Mutex<HashMap<u64, u32>>,
}

impl PairingDialogs {
    fn ask(self: &Arc<Self>, attempt: u64, question: String, commands: mpsc::UnboundedSender<UiCommand>) {
        let dialogs = self.clone();
        std::thread::spawn(move || {
            // SAFETY: no arguments.
            let thread = unsafe { GetCurrentThreadId() };
            dialogs.open.lock().unwrap_or_else(|p| p.into_inner()).insert(attempt, thread);
            let yes = message_box(DIALOG_TITLE, &question, MB_YESNO | MB_ICONQUESTION);
            dialogs.open.lock().unwrap_or_else(|p| p.into_inner()).remove(&attempt);
            // The application accepts the answer only for the attempt it belongs to.
            let _ = commands.send(UiCommand::ConfirmPairing(attempt, yes));
        });
    }

    /// Presses "No" on the box of this attempt, if it is still open.
    fn close(&self, attempt: u64) {
        let thread = self.open.lock().unwrap_or_else(|p| p.into_inner()).get(&attempt).copied();
        if let Some(thread) = thread {
            // SAFETY: the callback only posts a message to each top-level window of that thread.
            unsafe {
                let _ = EnumThreadWindows(thread, Some(press_no), LPARAM(0));
            }
        }
    }
}

unsafe extern "system" fn press_no(window: HWND, _: LPARAM) -> BOOL {
    // SAFETY: posting a command message to a window handle that Windows just handed out.
    let _ = unsafe { PostMessageW(Some(window), WM_COMMAND, WPARAM(IDNO.0 as usize), LPARAM(0)) };
    BOOL(1)
}

/// Asks for a new name with the Visual Basic input box through PowerShell (no window of its own). `None` when cancelled.
fn ask_name(lang: Lang, current: &str) -> Option<String> {
    let script = "Add-Type -AssemblyName Microsoft.VisualBasic; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; \
                  [Microsoft.VisualBasic.Interaction]::InputBox($env:RK_PROMPT, $env:RK_TITLE, $env:RK_DEFAULT)";
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script])
        .env("RK_PROMPT", i18n::text(lang, Text::RenamePrompt))
        .env("RK_TITLE", i18n::text(lang, Text::Rename))
        .env("RK_DEFAULT", current)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!name.is_empty()).then_some(name)
}

// ---------------------------------------------------------------- tray

/// Hands tray updates to the thread that owns the tray and wakes it.
struct TraySink {
    queue: std_mpsc::Sender<UiEvent>,
    thread_id: u32,
}

impl UiSink for TraySink {
    fn send(&self, event: UiEvent) {
        if self.queue.send(event).is_ok() {
            // SAFETY: posting a thread message with no payload.
            let _ = unsafe { PostThreadMessageW(self.thread_id, WM_WAKE, WPARAM(0), LPARAM(0)) };
        }
    }
}

fn icon_for(state: IconState) -> Option<Icon> {
    Icon::from_rgba(icons::rgba(state), icons::SIZE as u32, icons::SIZE as u32).ok()
}

fn build_menu(state: &TrayState, lang: Lang) -> Menu {
    let menu = Menu::new();
    let status = match &state.connected_phone {
        Some(phone) => i18n::status_connected(lang, phone),
        None if state.pairing_open => i18n::text(lang, Text::StatusPairing).to_string(),
        None => i18n::text(lang, Text::StatusIdle).to_string(),
    };
    let _ = menu.append(&MenuItem::with_id("status", status, false, None));
    let _ = menu.append(&MenuItem::with_id("rename", format!("{}　{}", state.host_name, i18n::text(lang, Text::Rename)), true, None));
    let _ = menu.append(&PredefinedMenuItem::separator());
    let _ = menu.append(&MenuItem::with_id("pair", i18n::text(lang, Text::PairNewPhone), true, None));
    let phones = Submenu::with_id("phones", i18n::text(lang, Text::PairedPhones), true);
    if state.phones.is_empty() {
        let _ = phones.append(&MenuItem::with_id("none", i18n::text(lang, Text::NoPairedPhones), false, None));
    }
    for phone in &state.phones {
        let entry = Submenu::with_id(format!("phone:{}", hex(&phone.id)), &phone.name, true);
        let _ = entry.append(&MenuItem::with_id(format!("delete:{}", hex(&phone.id)), i18n::text(lang, Text::Delete), true, None));
        let _ = phones.append(&entry);
    }
    let _ = menu.append(&phones);
    let _ = menu.append(&PredefinedMenuItem::separator());
    let _ = menu.append(&CheckMenuItem::with_id("trackpad", i18n::text(lang, Text::AllowTrackpad), true, state.trackpad, None));
    let _ = menu.append(&CheckMenuItem::with_id("autostart", i18n::text(lang, Text::Autostart), true, state.autostart, None));
    let _ = menu.append(&PredefinedMenuItem::separator());
    let _ = menu.append(&MenuItem::with_id("export", i18n::text(lang, Text::ExportDiagnostics), true, None));
    let _ = menu.append(&MenuItem::with_id("quit", i18n::text(lang, Text::Quit), true, None));
    menu
}

fn tooltip(state: &TrayState, lang: Lang, notice: Option<NoticeKind>) -> String {
    let line = match (&state.connected_phone, notice) {
        (_, Some(kind)) => i18n::notice(lang, kind).to_string(),
        (Some(phone), None) => i18n::status_connected(lang, phone),
        (None, None) => i18n::text(lang, Text::StatusIdle).to_string(),
    };
    format!("{} - {line}", i18n::text(lang, Text::AppName))
}

fn parse_phone_id(text: &str) -> Option<[u8; 16]> {
    crate::config::unhex::<16>(text)
}

/// What a menu click means. Dialogs run on their own threads so the tray keeps answering.
struct MenuActions {
    commands: mpsc::UnboundedSender<UiCommand>,
    state: Arc<Mutex<Option<TrayState>>>,
    lang: Lang,
    paths: Paths,
    clock: Arc<dyn Clock>,
}

impl MenuActions {
    fn current(&self) -> Option<TrayState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }

    fn click(&self, id: &str) {
        let state = self.current();
        let flag = |pick: fn(&TrayState) -> bool| !state.as_ref().is_some_and(pick);
        let command = match id {
            "pair" => Some(UiCommand::StartPairing),
            "trackpad" => Some(UiCommand::SetTrackpad(flag(|s| s.trackpad))),
            "autostart" => {
                let on = flag(|s| s.autostart);
                set_autostart(on).then_some(UiCommand::SetAutostart(on))
            }
            "quit" => Some(UiCommand::Quit),
            "rename" => {
                self.rename(state.map(|s| s.host_name).unwrap_or_default());
                None
            }
            "export" => {
                self.export();
                None
            }
            other => other.strip_prefix("delete:").and_then(parse_phone_id).map(UiCommand::DeletePhone),
        };
        if let Some(command) = command {
            let _ = self.commands.send(command);
        }
    }

    fn rename(&self, current: String) {
        let (commands, lang) = (self.commands.clone(), self.lang);
        std::thread::spawn(move || {
            if let Some(name) = ask_name(lang, &current) {
                let _ = commands.send(UiCommand::Rename(name));
            }
        });
    }

    fn export(&self) {
        let (state, paths, lang, clock) = (self.current(), self.paths.clone(), self.lang, self.clock.clone());
        std::thread::spawn(move || {
            let config = Config::read_only(&paths.config_file, HostPlatform::Windows);
            let phones = state.as_ref().map_or(0, |s| s.phones.len());
            let word = match state.as_ref().map(|s| s.icon) {
                Some(IconState::Connected) => "connected",
                Some(IconState::Attention) => "attention",
                _ => "waiting",
            };
            let text = diag_text(&config, phones, word, "info");
            let desktop = env_path("USERPROFILE").join("Desktop");
            let target = if desktop.is_dir() { desktop } else { paths.log_dir.clone() };
            match diag::export(&paths.log_dir, &target, &text, clock.wall_unix_ms()) {
                Ok(zip) => reveal(&zip),
                Err(_) => {
                    message_box(DIALOG_TITLE, i18n::text(lang, Text::DiagnosticsFailed), MB_OK | MB_ICONINFORMATION);
                }
            }
        });
    }
}

/// Opens Explorer on the folder with the file selected.
fn reveal(path: &Path) {
    let _ = Command::new("explorer.exe").raw_arg(format!("/select,\"{}\"", path.display())).spawn();
}

pub fn diag_text(config: &Config, phones: usize, state: &str, log_level: &str) -> String {
    let adapter = adapter_info();
    diag::diag_txt(&DiagInfo {
        version: env!("CARGO_PKG_VERSION"),
        target: env!("RK_TARGET"),
        os: &os_description(),
        adapter: adapter.as_ref(),
        config,
        paired_phones: phones,
        state,
        log_level,
    })
}

/// `--diag`: what `diag.txt` would hold, without starting the receiver.
pub fn print_diag() -> String {
    let config = Config::read_only(&paths().config_file, HostPlatform::Windows);
    diag_text(&config, CredentialPhoneStore::new(CredentialBackend).phones().len(), "not running", "info")
}

fn apply_state(tray: &TrayIcon, state: &TrayState, lang: Lang, notice: Option<NoticeKind>) {
    tray.set_menu(Some(Box::new(build_menu(state, lang))));
    let _ = tray.set_icon(icon_for(state.icon));
    let _ = tray.set_tooltip(Some(tooltip(state, lang, notice)));
}

/// Runs the receiver: single instance, logger, store, link thread, application, then the tray loop on this thread.
pub fn run(cli: &Cli) -> i32 {
    if claim_instance(&mut NamedMutex { held: None }) == Instance::Second {
        return 0;
    }
    let (paths, lang) = (paths(), lang());
    let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
    let logger = Logger::new(Box::new(FileSink::new(paths.log_dir.clone(), clock.clone())), clock.clone(), cli.log_level);
    let new_id = || crate::random::SharedRandom::new(Box::new(OsRandom)).bytes::<16>();
    let (config, origin) = Config::load_or_create(&paths.config_file, HostPlatform::Windows, new_id, clock.wall_unix_ms());
    let mut config_store: Box<dyn ConfigStore> = Box::new(FileConfigStore::new(paths.config_file.clone()));
    let mut startup_notice = None;
    match origin {
        ConfigOrigin::Loaded => {}
        ConfigOrigin::Created => logger.info("config_created", None, &[]),
        // The unreadable file is still there under another name; a new host id starts a new identity, so say so.
        ConfigOrigin::Recovered { .. } => logger.info("config_corrupt", None, &[("kept_as_bad", rk_ble::Value::B(true))]),
        // The file could not be moved aside: it stays as it is, nothing is written over it this run.
        ConfigOrigin::NotKept { error } => {
            logger.info("config_corrupt", None, &[("kept_as_bad", rk_ble::Value::B(false)), ("error", rk_ble::Value::S(error_word(error)))]);
            config_store = Box::new(RefusingConfigStore);
            startup_notice = Some(NoticeKind::ConfigNotSaved);
        }
    }
    if config_store.save(&config).is_err() && startup_notice.is_none() {
        logger.info("config_save_failed", None, &[]);
    }
    let injector = make_injector(&config);
    let app = App::new(AppDeps {
        config,
        platform: HostPlatform::Windows,
        store: Box::new(CredentialPhoneStore::new(CredentialBackend)),
        config_store,
        injector,
        clock: clock.clone(),
        random: Box::new(OsRandom),
        logger,
        pair_at_start: cli.pair,
    });

    // The first update can come from the application thread before this thread has asked for a message: make sure the
    // thread has a message queue, or a thread message posted to it is lost.
    let mut probe = MSG::default();
    // SAFETY: peeks without removing anything; its only effect is creating the queue.
    let _ = unsafe { PeekMessageW(&mut probe, None, WM_USER, WM_USER, PM_NOREMOVE) };
    let (ui_queue, ui_events) = std_mpsc::channel();
    if let Some(notice) = startup_notice {
        let _ = ui_queue.send(UiEvent::Notice(notice));
    }
    // SAFETY: no arguments.
    let thread_id = unsafe { GetCurrentThreadId() };
    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let state = Arc::new(Mutex::new(None::<TrayState>));
    let dialogs = Arc::new(PairingDialogs::default());
    let actions = MenuActions { commands: command_tx.clone(), state: state.clone(), lang, paths, clock: clock.clone() };
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| actions.click(&event.id.0)));

    let link_config = app.link_config();
    let worker = std::thread::spawn(move || {
        // Whatever ends this thread, the tray loop must end too, or the process would sit in the tray with nothing behind it.
        let _quit = QuitTrayOnDrop(thread_id);
        let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_time().build() else { return };
        runtime.block_on(async move {
            let (event_tx, event_rx) = mpsc::channel(256);
            let (link_tx, link_rx) = mpsc::channel(64);
            let link = tokio::spawn(rk_ble::run(link_config, event_tx, link_rx));
            runner::run(app, event_rx, link_tx, command_rx, TraySink { queue: ui_queue, thread_id }, clock).await;
            // `link_tx` went with `runner::run`: the link now carries out what is queued (the `bye`, the hang-up) and ends.
            let _ = link.await;
        });
    });

    let tray = TrayIconBuilder::new().with_icon(icon_for(IconState::Disconnected).expect("generated icon is valid")).build();
    let Ok(tray) = tray else { return 1 };
    let mut notice = None;
    // Updates that were posted before the loop started.
    for event in ui_events.try_iter() {
        handle_ui_event(event, &tray, &state, lang, &command_tx, &dialogs, &mut notice);
    }
    let mut message = MSG::default();
    // SAFETY: a standard message loop on the thread that created the tray.
    while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
        if message.message == WM_WAKE {
            for event in ui_events.try_iter() {
                handle_ui_event(event, &tray, &state, lang, &command_tx, &dialogs, &mut notice);
            }
            continue;
        }
        // SAFETY: the message came from GetMessageW.
        unsafe {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    // A panic of the application thread shows here as an error.
    i32::from(worker.join().is_err())
}

/// Posts `WM_QUIT` to the tray thread when dropped, on a normal end and on a panic alike.
struct QuitTrayOnDrop(u32);

impl Drop for QuitTrayOnDrop {
    fn drop(&mut self) {
        // SAFETY: posting a thread message with no payload.
        let _ = unsafe { PostThreadMessageW(self.0, WM_QUIT, WPARAM(0), LPARAM(0)) };
    }
}

/// A fixed word for an I/O error kind, for the log.
fn error_word(kind: std::io::ErrorKind) -> &'static str {
    match kind {
        std::io::ErrorKind::PermissionDenied => "permission_denied",
        std::io::ErrorKind::AlreadyExists => "already_exists",
        std::io::ErrorKind::InvalidData => "invalid_data",
        _ => "other",
    }
}

fn handle_ui_event(
    event: UiEvent,
    tray: &TrayIcon,
    shared: &Arc<Mutex<Option<TrayState>>>,
    lang: Lang,
    commands: &mpsc::UnboundedSender<UiCommand>,
    dialogs: &Arc<PairingDialogs>,
    notice: &mut Option<NoticeKind>,
) {
    match event {
        UiEvent::State(state) => {
            if state.icon != IconState::Attention {
                *notice = None;
            }
            apply_state(tray, &state, lang, *notice);
            *shared.lock().unwrap_or_else(|p| p.into_inner()) = Some(state);
        }
        UiEvent::PairingRequest { attempt, phone_name, sas } => {
            dialogs.ask(attempt, i18n::pairing_question(lang, &phone_name, &sas), commands.clone());
        }
        UiEvent::PairingClosed => {}
        UiEvent::PairingDialogClose(attempt) => dialogs.close(attempt),
        UiEvent::Notice(kind) => {
            // Notices that stay true while the tray shows them go to the tooltip; a modal box each time would pile up (the
            // Bluetooth notice comes back until the radio is on). The rest are said once, in a box.
            if matches!(kind, NoticeKind::NeedsRepair | NoticeKind::UpdatePhone | NoticeKind::BluetoothOff) {
                *notice = Some(kind);
                if let Some(state) = shared.lock().unwrap_or_else(|p| p.into_inner()).clone() {
                    let _ = tray.set_tooltip(Some(tooltip(&state, lang, *notice)));
                }
            } else {
                let text = i18n::notice(lang, kind);
                std::thread::spawn(move || {
                    message_box(DIALOG_TITLE, text, MB_OK | MB_ICONINFORMATION);
                });
            }
        }
    }
}
