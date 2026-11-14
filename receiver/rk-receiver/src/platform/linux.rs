//! The Linux shell: StatusNotifierItem tray (ksni), zenity dialogs, Secret Service key store, XDG files, autostart desktop
//! entry and the `flock` single-instance lock.
//!
//! Everything platform independent is in the rest of the crate and in `linux_logic`; this file only turns desktop
//! facilities into the traits and channels the application uses. It is verified by building and running on Linux, not by
//! the Mac test run.
//!
//! Threads: the main thread runs the tray, the dialogs and the Secret Service; `rk-app` runs the application (so a slow
//! injection never holds up the tray); `rk-ble` runs the BlueZ link (so it never holds up the application); `rk-keys`
//! talks to the Secret Service for the application's synchronous key store.

use super::linux_logic::{
    action_for, argb_from_rgba, Begin, LoadSlot, autostart_file, data_file, entered_name, entry_args, export_dir, info_args, lang_from_env, lock_file, menu_entries,
    portal_token_file, pretty_name, question_args, restart_args, tooltip_text, write_autostart, Action, AdapterChoices, ChainedBackend, FilePhoneBackend, MenuEntry,
};
use super::{claim_instance, linux_paths, Instance, InstanceLock, Paths};
use crate::app::{App, AppDeps};
use crate::cli::Cli;
use crate::clock::{Clock, SystemClock};
use crate::config::{hex, Config, ConfigOrigin, FileConfigStore};
use crate::diag::{self, AdapterInfo, DiagInfo};
use crate::i18n::{self, Lang, Text};
use crate::icons;
use crate::log::{FileSink, Logger};
use crate::random::OsRandom;
use crate::runner::{self, UiSink};
use crate::store::{decode_record, encode_record, CachedPhoneStore, ConfigStore, PhoneBackend, PhoneStore, RefusingConfigStore, StoreError};
use crate::ui::{IconState, NoticeKind, TrayState, UiCommand, UiEvent};
use ksni::menu::{CheckmarkItem, StandardItem, SubMenu};
use ksni::{Icon, MenuItem, ToolTip, TrayMethods};
use rk_core::identity::{HostPlatform, PairedPhone};
use rk_inject::linux::{LinuxInjector, LinuxOptions};
use rk_inject::Injector;
use secret_service::{EncryptionType, SecretService};
use std::collections::HashMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::runtime::Builder;
use tokio::sync::{mpsc, oneshot};

const DIALOG_TITLE: &str = "Remote Keyboard";
/// How long the Secret Service gets to answer at start-up before the key file is used.
const KEYSTORE_CONNECT_TIMEOUT: Duration = Duration::from_secs(4);
/// A write to the keyring that is not done by then fails (the application thread waits for it).
const KEYSTORE_REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
/// How long the application thread waits for a read of the keyring it has just started: a moment, never more.
const LOAD_WAIT: Duration = Duration::from_millis(200);
/// How long the keyring thread waits for the user to answer the desktop's unlock prompt.
const PROMPT_PATIENCE: Duration = Duration::from_secs(120);
/// §1.5 of the plan: on exit the queued commands (the `bye`) get this long to reach the radio.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
const ADAPTER_REFRESH: Duration = Duration::from_secs(15);
/// `--inject-selftest` waits this long for the portal before it types (and fails with `not_ready`).
const SELFTEST_AUTHORIZATION_WAIT: Duration = Duration::from_secs(20);

fn env_var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn env_path(name: &str) -> Option<PathBuf> {
    env_var(name).map(PathBuf::from)
}

fn home() -> PathBuf {
    env_path("HOME").unwrap_or_default()
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|p| p.into_inner())
}

pub fn paths() -> Paths {
    linux_paths(&home(), env_path("XDG_CONFIG_HOME").as_deref(), env_path("XDG_STATE_HOME").as_deref())
}

fn lang() -> Lang {
    lang_from_env(env_var("LC_ALL").as_deref(), env_var("LC_MESSAGES").as_deref(), env_var("LANG").as_deref())
}

pub fn prepare_console() {}

// ---------------------------------------------------------------- single instance

/// `flock` on a file under `$XDG_RUNTIME_DIR`: the lock goes when the process does, however it ends.
struct FlockLock {
    path: PathBuf,
    held: Option<File>,
}

impl InstanceLock for FlockLock {
    fn try_acquire(&mut self) -> bool {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        // A lock that cannot be made is not a reason to refuse to run.
        let Ok(file) = OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&self.path) else { return true };
        match file.try_lock() {
            Ok(()) => {
                self.held = Some(file);
                true
            }
            Err(TryLockError::WouldBlock) => false,
            Err(TryLockError::Error(_)) => true,
        }
    }
}

/// The single-instance guard: `Some` for the first process, which keeps it for as long as it runs (the lock goes when the
/// guard is dropped), `None` for a later one.
fn claim_lock(path: PathBuf) -> Option<FlockLock> {
    let mut lock = FlockLock { path, held: None };
    (claim_instance(&mut lock) == Instance::First).then_some(lock)
}

// ---------------------------------------------------------------- Secret Service

type Reply<T> = std_mpsc::Sender<T>;

enum KeyRequest {
    /// The answer goes to the `LoadSlot`; nobody waits for it.
    Load { interactive: bool },
    /// A request that a caller waited for only until `expires`: later it is not carried out any more.
    Put(PairedPhone, Instant, Reply<Result<(), StoreError>>),
    Remove([u8; 16], Instant, Reply<Result<(), StoreError>>),
}

/// The paired phones in the desktop's keyring: one item each, attributes `application=remote-keyboard` and
/// `phone-id=<hex>`, the secret is the record of `store::encode_record`.
///
/// The application's key store is synchronous and runs inside a tokio runtime, so the D-Bus conversation lives on a thread
/// of its own. The application thread never waits for the keyring for more than a moment: a read is handed over through a
/// `LoadSlot` (one at a time; only the first one, and one the user asked for by starting to pair, may raise the unlock
/// prompt), and a write that cannot be done at once fails.
struct SecretServiceBackend {
    requests: std_mpsc::Sender<KeyRequest>,
    loads: Arc<LoadSlot>,
}

fn keyring_error() -> StoreError {
    StoreError::Backend("secret service".to_string())
}

const APPLICATION: &str = "application";
const APPLICATION_NAME: &str = "remote-keyboard";
const PHONE_ID: &str = "phone-id";

/// A prompt that nobody answers must not keep the keyring thread for ever.
async fn answered<T>(prompt: impl std::future::Future<Output = Result<T, secret_service::Error>>) -> Result<T, StoreError> {
    tokio::time::timeout(PROMPT_PATIENCE, prompt).await.map_err(|_| keyring_error())?.map_err(|_| keyring_error())
}

/// Every phone of ours in the keyring. A keyring that is locked (and stays so) or does not answer is an error: that is not
/// the same as having no phones, and the caller must not treat it so. Only an `interactive` read opens a locked keyring
/// (which raises the desktop's prompt); the others report it as locked at once.
async fn keyring_load(service: &SecretService<'_>, interactive: bool) -> Result<Vec<PairedPhone>, StoreError> {
    if interactive {
        let collection = service.get_default_collection().await.map_err(|_| keyring_error())?;
        if collection.is_locked().await.map_err(|_| keyring_error())? {
            answered(collection.unlock()).await?;
        }
    }
    let found = service.search_items(HashMap::from([(APPLICATION, APPLICATION_NAME)])).await.map_err(|_| keyring_error())?;
    if !found.locked.is_empty() {
        if !interactive {
            return Err(keyring_error());
        }
        let locked: Vec<_> = found.locked.iter().collect();
        answered(service.unlock_all(&locked)).await?;
    }
    let mut phones = Vec::new();
    for item in found.unlocked.iter().chain(found.locked.iter()) {
        let secret = item.get_secret().await.map_err(|_| keyring_error())?;
        // An item that is not a record of ours is somebody else's business.
        if let Some(phone) = decode_record(&secret) {
            phones.push(phone);
        }
    }
    phones.sort_by_key(|p| p.identity.id);
    Ok(phones)
}

/// Never raises a prompt: pairing has asked for the keyring to be unlocked before it gets here.
async fn keyring_put(service: &SecretService<'_>, phone: &PairedPhone) -> Result<(), StoreError> {
    let collection = service.get_default_collection().await.map_err(|_| keyring_error())?;
    if collection.is_locked().await.map_err(|_| keyring_error())? {
        return Err(keyring_error());
    }
    let id = hex(&phone.identity.id);
    let attributes = HashMap::from([(APPLICATION, APPLICATION_NAME), (PHONE_ID, id.as_str())]);
    collection.create_item("Remote Keyboard phone key", attributes, &encode_record(phone), true, "application/json").await.map_err(|_| keyring_error())?;
    Ok(())
}

async fn keyring_remove(service: &SecretService<'_>, id: &[u8; 16]) -> Result<(), StoreError> {
    let id = hex(id);
    let found = service.search_items(HashMap::from([(APPLICATION, APPLICATION_NAME), (PHONE_ID, id.as_str())])).await.map_err(|_| keyring_error())?;
    if !found.locked.is_empty() {
        return Err(keyring_error());
    }
    for item in &found.unlocked {
        item.delete().await.map_err(|_| keyring_error())?;
    }
    Ok(())
}

impl SecretServiceBackend {
    /// `None` when there is no Secret Service (no keyring daemon on the session bus, or it does not answer in time).
    fn connect(timeout: Duration) -> Option<Self> {
        let (ready_tx, ready_rx) = std_mpsc::channel();
        let (requests, inbox) = std_mpsc::channel::<KeyRequest>();
        let loads = Arc::new(LoadSlot::new());
        let slot = loads.clone();
        let spawned = std::thread::Builder::new().name("rk-keys".into()).spawn(move || {
            let Ok(runtime) = Builder::new_current_thread().enable_all().build() else {
                let _ = ready_tx.send(false);
                return;
            };
            runtime.block_on(async move {
                let Ok(service) = SecretService::connect(EncryptionType::Dh).await else {
                    let _ = ready_tx.send(false);
                    return;
                };
                if service.get_default_collection().await.is_err() {
                    let _ = ready_tx.send(false);
                    return;
                }
                let _ = ready_tx.send(true);
                // This thread has nothing else to do, so waiting on the channel is fine.
                while let Ok(request) = inbox.recv() {
                    match request {
                        KeyRequest::Load { interactive } => slot.finish(keyring_load(&service, interactive).await),
                        KeyRequest::Put(phone, expires, reply) if Instant::now() < expires => {
                            let _ = reply.send(keyring_put(&service, &phone).await);
                        }
                        KeyRequest::Remove(id, expires, reply) if Instant::now() < expires => {
                            let _ = reply.send(keyring_remove(&service, &id).await);
                        }
                        // The caller has given up on it already; doing it now would contradict the answer it got.
                        KeyRequest::Put(..) | KeyRequest::Remove(..) => {}
                    }
                }
            });
        });
        (spawned.is_ok() && ready_rx.recv_timeout(timeout) == Ok(true)).then_some(Self { requests, loads })
    }

    fn ask<T>(&self, make: impl FnOnce(Instant, Reply<T>) -> KeyRequest) -> Option<T> {
        let (reply, answer) = std_mpsc::channel();
        self.requests.send(make(Instant::now() + KEYSTORE_REQUEST_TIMEOUT, reply)).ok()?;
        answer.recv_timeout(KEYSTORE_REQUEST_TIMEOUT).ok()
    }
}

impl PhoneBackend for SecretServiceBackend {
    fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
        match self.loads.begin() {
            Begin::Done(result) => result,
            // The last read has not come back (a prompt nobody has answered): do not wait for it, do not start another.
            Begin::Busy => Err(keyring_error()),
            Begin::Start { interactive } => {
                if self.requests.send(KeyRequest::Load { interactive }).is_err() {
                    self.loads.finish(Err(keyring_error()));
                }
                self.loads.wait(LOAD_WAIT).unwrap_or_else(|| Err(keyring_error()))
            }
        }
    }

    fn unlock(&self) {
        self.loads.want_interactive();
    }

    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
        self.ask(|expires, reply| KeyRequest::Put(phone.clone(), expires, reply)).unwrap_or_else(|| Err(keyring_error()))
    }

    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        let id = *id;
        self.ask(|expires, reply| KeyRequest::Remove(id, expires, reply)).unwrap_or_else(|| Err(keyring_error()))
    }
}

/// The key store of this machine: the Secret Service when there is one, else the key file (and the log says which).
fn phone_store(logger: Option<&Logger>) -> CachedPhoneStore<ChainedBackend> {
    let primary = SecretServiceBackend::connect(KEYSTORE_CONNECT_TIMEOUT);
    if let Some(logger) = logger {
        let backend = if primary.is_some() { "secret_service" } else { "file" };
        logger.info("keystore", None, &[("backend", rk_ble::Value::S(backend))]);
    }
    let file = FilePhoneBackend::new(data_file(&home(), env_path("XDG_DATA_HOME").as_deref()));
    CachedPhoneStore::new(ChainedBackend::new(primary.map(|p| Box::new(p) as Box<dyn PhoneBackend>), file))
}

// ---------------------------------------------------------------- injection

/// The RemoteDesktop portal injector. It restores the saved grant at `$XDG_CONFIG_HOME/remote-keyboard/portal-token` (no
/// dialog), so `ready()` is false for a moment after start and stays false until the user has answered the portal's dialog.
/// The tray's 重新授權 and the paste option reach it through `Injector::reauthorize` and `set_paste_non_ascii`.
///
/// It works on a thread of its own, and the application calls it from `rk-app`, so the portal never holds up the tray or the
/// BlueZ link.
pub fn make_injector(config: &Config, token_file: PathBuf, logger: Option<Logger>) -> Box<dyn Injector> {
    let log = logger.map(|logger| Arc::new(move |line: &str| logger.stamped_line(line)) as rk_inject::linux::Log);
    Box::new(LinuxInjector::start(token_file, LinuxOptions { paste_non_ascii: config.paste_non_ascii, log, ..LinuxOptions::default() }))
}

/// `--inject-selftest`: wait for the portal grant, then after `delay_secs` type the file through the injector the receiver
/// itself uses, press Enter and print one line of counts. The text is neither printed nor logged. Returns the exit code.
pub fn inject_selftest(file: &Path, delay_secs: u64) -> i32 {
    let Ok(text) = std::fs::read_to_string(file) else {
        println!("units=0 ms=0 result=err:read_file");
        return 1;
    };
    let paths = paths();
    let config = Config::read_only(&paths.config_file, HostPlatform::Linux);
    let mut injector = make_injector(&config, portal_token_file(&paths.config_file), None);
    // With a saved grant this takes a moment; without one the portal's dialog is open until somebody answers it.
    let waiting = std::time::Instant::now();
    while !injector.ready() && waiting.elapsed() < SELFTEST_AUTHORIZATION_WAIT {
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(delay_secs));
    let clock = SystemClock::new();
    let line = crate::selftest::run(injector.as_mut(), &text, || clock.mono_ms());
    println!("{line}");
    i32::from(!line.ends_with("result=ok"))
}

// ---------------------------------------------------------------- BlueZ facts for diagnostics

fn block_on_small<F: std::future::Future>(future: F) -> Option<F::Output> {
    Some(Builder::new_current_thread().enable_all().build().ok()?.block_on(future))
}

fn adapter_info_for(adapters: &[rk_ble::AdapterInfo], wanted: Option<&str>) -> Option<AdapterInfo> {
    let names: Vec<String> = adapters.iter().map(|a| a.name.clone()).collect();
    let name = AdapterChoices { names, current: wanted.map(str::to_string) }.effective()?;
    adapters.iter().find(|a| a.name == name).map(|a| AdapterInfo { name: a.name.clone(), address: a.address.clone() })
}

fn os_description() -> String {
    std::fs::read_to_string("/etc/os-release").ok().and_then(|text| pretty_name(&text)).unwrap_or_else(|| std::env::consts::OS.to_string())
}

fn diag_text(config: &Config, adapter: Option<&AdapterInfo>, phones: usize, state: &str, log_level: &str) -> String {
    diag::diag_txt(&DiagInfo {
        version: env!("CARGO_PKG_VERSION"),
        target: env!("RK_TARGET"),
        os: &os_description(),
        adapter,
        config,
        paired_phones: phones,
        state,
        log_level,
    })
}

/// `--diag`: what `diag.txt` would hold, without starting the receiver.
pub fn print_diag() -> String {
    let config = Config::read_only(&paths().config_file, HostPlatform::Linux);
    let adapters = block_on_small(rk_ble::adapters()).unwrap_or_default();
    let adapter = adapter_info_for(&adapters, config.adapter.as_deref());
    diag_text(&config, adapter.as_ref(), phone_store(None).phones().len(), "not running", "info")
}

// ---------------------------------------------------------------- dialogs

fn spawn_zenity(args: &[String]) -> std::io::Result<tokio::process::Child> {
    Command::new("zenity").args(args).stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).spawn()
}

/// The pairing questions on screen, by attempt: a oneshot that closes the attempt's dialog.
#[derive(Default)]
struct Dialogs {
    open: Mutex<HashMap<u64, oneshot::Sender<()>>>,
}

// ---------------------------------------------------------------- the shell and the tray

/// What a menu click does, and what the tray shows. Shared between the tray callbacks and the event loop.
struct Shell {
    runtime: tokio::runtime::Handle,
    commands: mpsc::UnboundedSender<UiCommand>,
    state: Mutex<TrayState>,
    adapters: Mutex<AdapterChoices>,
    lang: Lang,
    paths: Paths,
    clock: Arc<dyn Clock>,
    log: Logger,
    log_level: &'static str,
    dialogs: Dialogs,
    /// A controller was chosen in the menu: start again with it once the receiver has ended.
    restart: Mutex<Option<String>>,
    /// `config.json` could not be read or moved aside, so nothing of this run is saved: choosing a controller is pointless.
    config_protected: bool,
}

impl Shell {
    fn send(&self, command: UiCommand) {
        let _ = self.commands.send(command);
    }

    fn click(self: &Arc<Self>, id: &str) {
        let state = lock(&self.state).clone();
        match action_for(id, &state) {
            Some(Action::Command(command)) => self.send(command),
            Some(Action::SetAutostart(on)) => {
                let file = autostart_file(&home(), env_path("XDG_CONFIG_HOME").as_deref());
                let exe = std::env::current_exe().unwrap_or_default();
                if write_autostart(&file, &exe, on) {
                    self.send(UiCommand::SetAutostart(on));
                } else {
                    self.log.info("autostart_failed", None, &[]);
                }
            }
            Some(Action::AskName) => self.ask_name(state.host_name),
            Some(Action::Export) => self.export(),
            Some(Action::ChooseAdapter(_)) if self.config_protected => self.info(i18n::notice(self.lang, NoticeKind::ConfigNotSaved)),
            Some(Action::ChooseAdapter(name)) if lock(&self.adapters).effective().as_deref() != Some(name.as_str()) => {
                // The new start is told the controller outright, whatever happens to the saved setting.
                *lock(&self.restart) = Some(name.clone());
                self.send(UiCommand::SetAdapter(Some(name)));
                self.send(UiCommand::Quit);
            }
            Some(Action::ChooseAdapter(_)) | None => {}
        }
    }

    fn ask_name(self: &Arc<Self>, current: String) {
        let shell = self.clone();
        self.runtime.spawn(async move {
            let args = entry_args(i18n::text(shell.lang, Text::Rename), i18n::text(shell.lang, Text::RenamePrompt), &current);
            let Ok(output) = Command::new("zenity").args(&args).stdin(Stdio::null()).stderr(Stdio::null()).output().await else { return };
            if let Some(name) = entered_name(output.status.code(), &String::from_utf8_lossy(&output.stdout)) {
                shell.send(UiCommand::Rename(name));
            }
        });
    }

    fn info(self: &Arc<Self>, text: &'static str) {
        self.runtime.spawn(async move {
            if let Ok(mut child) = spawn_zenity(&info_args(DIALOG_TITLE, text)) {
                let _ = child.wait().await;
            }
        });
    }

    /// Zips the logs and `diag.txt`, then opens the folder it is in.
    fn export(self: &Arc<Self>) {
        let shell = self.clone();
        self.runtime.spawn(async move {
            let state = lock(&shell.state).clone();
            let config = Config::read_only(&shell.paths.config_file, HostPlatform::Linux);
            let adapters = rk_ble::adapters().await;
            let adapter = adapter_info_for(&adapters, config.adapter.as_deref());
            let word = match state.icon {
                IconState::Connected => "connected",
                IconState::Attention => "attention",
                IconState::Disconnected => "waiting",
            };
            let text = diag_text(&config, adapter.as_ref(), state.phones.len(), word, shell.log_level);
            let home = home();
            let target = export_dir(&home, home.join("Desktop").is_dir(), &shell.paths.log_dir);
            let (log_dir, now) = (shell.paths.log_dir.clone(), shell.clock.wall_unix_ms());
            let zip_dir = target.clone();
            let written = tokio::task::spawn_blocking(move || diag::export(&log_dir, &zip_dir, &text, now)).await;
            match written {
                Ok(Ok(_)) => {
                    if let Ok(mut opener) = Command::new("xdg-open").arg(&target).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
                        let _ = opener.wait().await;
                    }
                }
                _ => shell.info(i18n::text(shell.lang, Text::DiagnosticsFailed)),
            }
        });
    }

    /// Shows the pairing question. Only the answer to this attempt counts (the application checks the number); the dialog
    /// is taken away again when the attempt ends first.
    fn ask_pairing(self: &Arc<Self>, attempt: u64, phone_name: &str, sas: &str) {
        let (close, closed) = oneshot::channel();
        lock(&self.dialogs.open).insert(attempt, close);
        let args = question_args(
            i18n::text(self.lang, Text::PairingTitle),
            &i18n::pairing_question(self.lang, phone_name, sas),
            i18n::text(self.lang, Text::PairingMatch),
            i18n::text(self.lang, Text::PairingNoMatch),
        );
        let shell = self.clone();
        self.runtime.spawn(async move {
            let answer = match spawn_zenity(&args) {
                Err(_) => {
                    shell.log.info("dialog_unavailable", None, &[]);
                    Some(false)
                }
                Ok(mut child) => tokio::select! {
                    status = child.wait() => Some(super::linux_logic::answered_yes(status.ok().and_then(|s| s.code()))),
                    _ = closed => {
                        // The attempt is over: the dialog goes, nobody is waiting for its answer.
                        let _ = child.kill().await;
                        None
                    }
                },
            };
            lock(&shell.dialogs.open).remove(&attempt);
            if let Some(yes) = answer {
                shell.send(UiCommand::ConfirmPairing(attempt, yes));
            }
        });
    }

    fn close_pairing(&self, attempt: u64) {
        if let Some(close) = lock(&self.dialogs.open).remove(&attempt) {
            let _ = close.send(());
        }
    }
}

struct RkTray {
    shell: Arc<Shell>,
    state: TrayState,
    notice: Option<NoticeKind>,
    adapters: AdapterChoices,
}

fn to_menu_item(entry: MenuEntry, shell: &Arc<Shell>) -> MenuItem<RkTray> {
    match entry {
        MenuEntry::Info { label } => StandardItem { label, enabled: false, ..Default::default() }.into(),
        MenuEntry::Item { id, label } => {
            let shell = shell.clone();
            StandardItem { label, activate: Box::new(move |_: &mut RkTray| shell.click(&id)), ..Default::default() }.into()
        }
        MenuEntry::Check { id, label, checked } => {
            let shell = shell.clone();
            CheckmarkItem { label, checked, activate: Box::new(move |_: &mut RkTray| shell.click(&id)), ..Default::default() }.into()
        }
        MenuEntry::Sub { label, entries } => SubMenu { label, submenu: entries.into_iter().map(|e| to_menu_item(e, shell)).collect(), ..Default::default() }.into(),
        MenuEntry::Separator => MenuItem::Separator,
    }
}

impl ksni::Tray for RkTray {
    fn id(&self) -> String {
        "remote-keyboard".into()
    }

    fn title(&self) -> String {
        i18n::text(self.shell.lang, Text::AppName).into()
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        let size = i32::try_from(icons::SIZE).unwrap_or(32);
        vec![Icon { width: size, height: size, data: argb_from_rgba(&icons::rgba(self.state.icon)) }]
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip { title: tooltip_text(&self.state, self.shell.lang, self.notice), ..Default::default() }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        menu_entries(&self.state, self.shell.lang, &self.adapters).into_iter().map(|entry| to_menu_item(entry, &self.shell)).collect()
    }
}

/// Hands application updates to the thread that owns the tray.
struct ChannelSink(mpsc::UnboundedSender<UiEvent>);

impl UiSink for ChannelSink {
    fn send(&self, event: UiEvent) {
        let _ = self.0.send(event);
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

/// Signals the end of a thread when it is dropped, normal end and panic alike.
struct DoneOnDrop(Option<std_mpsc::Sender<()>>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        if let Some(done) = self.0.take() {
            let _ = done.send(());
        }
    }
}

/// Runs the receiver: single instance, logger, store, the link and application threads, then the tray loop here.
pub fn run(cli: &Cli) -> i32 {
    let paths = paths();
    let runtime_dir = env_path("XDG_RUNTIME_DIR");
    let state_dir = paths.log_dir.parent().map(PathBuf::from).unwrap_or_default();
    // Held until this function returns: a guard that is dropped at once would let a second copy start.
    let Some(_instance_guard) = claim_lock(lock_file(runtime_dir.as_deref(), &state_dir)) else { return 0 };
    let lang = lang();
    let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
    let logger = Logger::new(Box::new(FileSink::new(paths.log_dir.clone(), clock.clone())), clock.clone(), cli.log_level);
    let new_id = || crate::random::SharedRandom::new(Box::new(OsRandom)).bytes::<16>();
    let (config, origin) = Config::load_or_create(&paths.config_file, HostPlatform::Linux, new_id, clock.wall_unix_ms());
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
    let store = phone_store(Some(&logger));
    let injector = make_injector(&config, portal_token_file(&paths.config_file), Some(logger.clone()));
    let initial = TrayState {
        icon: IconState::Disconnected,
        connected_phone: None,
        pairing_open: false,
        host_name: config.host_name.clone(),
        phones: Vec::new(),
        trackpad: config.trackpad,
        autostart: config.autostart,
        paste_non_ascii: config.paste_non_ascii,
        needs_authorization: false,
    };
    let configured = cli.adapter.clone().or_else(|| config.adapter.clone());
    let app = App::new(AppDeps {
        config,
        platform: HostPlatform::Linux,
        store: Box::new(store),
        config_store,
        injector,
        clock: clock.clone(),
        random: Box::new(OsRandom),
        logger: logger.clone(),
        pair_at_start: cli.pair,
    });
    // `--adapter` wins over the configuration for this run; it is not written back.
    let mut link_config = app.link_config();
    link_config.adapter = configured.clone();

    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let (ui_tx, ui_rx) = mpsc::unbounded_channel();
    let (event_tx, event_rx) = mpsc::channel(256);
    let (link_tx, link_rx) = mpsc::channel(64);
    let (app_done_tx, app_done_rx) = std_mpsc::channel();
    let (link_done_tx, link_done_rx) = std_mpsc::channel();

    let link_thread = std::thread::Builder::new().name("rk-ble".into()).spawn(move || {
        let _done = DoneOnDrop(Some(link_done_tx));
        if let Ok(runtime) = Builder::new_current_thread().enable_all().build() {
            runtime.block_on(rk_ble::run(link_config, event_tx, link_rx));
        }
    });
    let app_clock = clock.clone();
    let app_thread = std::thread::Builder::new().name("rk-app".into()).spawn(move || {
        let _done = DoneOnDrop(Some(app_done_tx));
        if let Ok(runtime) = Builder::new_current_thread().enable_all().build() {
            runtime.block_on(runner::run(app, event_rx, link_tx, command_rx, ChannelSink(ui_tx), app_clock));
        }
    });
    if link_thread.is_err() || app_thread.is_err() {
        return 1;
    }

    let Ok(runtime) = Builder::new_current_thread().enable_all().build() else { return 1 };
    let shell = Arc::new(Shell {
        runtime: runtime.handle().clone(),
        commands: command_tx,
        state: Mutex::new(initial.clone()),
        adapters: Mutex::new(AdapterChoices { names: Vec::new(), current: configured }),
        lang,
        paths,
        clock,
        log: logger,
        log_level: cli.log_level.as_str(),
        dialogs: Dialogs::default(),
        restart: Mutex::new(None),
        config_protected: startup_notice == Some(NoticeKind::ConfigNotSaved),
    });
    runtime.block_on(tray_loop(shell.clone(), initial, startup_notice, ui_rx, app_done_rx));
    shell.log.debug("shutdown", None, &[("stage", rk_ble::Value::S("tray_done"))]);
    // The application has ended and let go of the link's channel: the link says goodbye and stops, for a moment at most.
    let link_finished = link_done_rx.recv_timeout(SHUTDOWN_GRACE).is_ok();
    shell.log.debug("shutdown", None, &[("stage", rk_ble::Value::S("link_done")), ("in_time", rk_ble::Value::B(link_finished))]);
    drop(runtime);
    let restart_with = lock(&shell.restart).take();
    if let Some(adapter) = restart_with {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let error = std::process::Command::new(std::env::current_exe().unwrap_or_default()).args(restart_args(&args, &adapter)).exec();
        shell.log.info("restart_failed", None, &[("kind", rk_ble::Value::S(error_word(error.kind())))]);
        return 1;
    }
    0
}

/// The main thread's work: the tray, its updates, the dialogs, the signals. Ends when the application has ended.
async fn tray_loop(shell: Arc<Shell>, initial: TrayState, startup_notice: Option<NoticeKind>, mut ui_rx: mpsc::UnboundedReceiver<UiEvent>, app_done: std_mpsc::Receiver<()>) {
    let tray = RkTray { shell: shell.clone(), state: initial, notice: None, adapters: AdapterChoices::default() };
    // The desktop's tray host may not be up yet when the session starts: wait for it instead of giving up.
    let handle = match tray.assume_sni_available(true).spawn().await {
        Ok(handle) => Some(handle),
        Err(_) => {
            shell.log.info("tray", None, &[("available", rk_ble::Value::B(false))]);
            None
        }
    };
    let mut notice = None;
    if let Some(kind) = startup_notice {
        show_notice(&shell, handle.as_ref(), &mut notice, kind).await;
    }

    // Quit through the application, so the phone gets its `bye`.
    let signals = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    let interrupts = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).ok();
    let quit_on = |signal: Option<tokio::signal::unix::Signal>, shell: Arc<Shell>| {
        if let Some(mut signal) = signal {
            tokio::spawn(async move {
                signal.recv().await;
                shell.send(UiCommand::Quit);
            });
        }
    };
    quit_on(signals, shell.clone());
    quit_on(interrupts, shell.clone());

    // Which controllers there are: asked now and now and then, for the menu.
    if let Some(handle) = handle.clone() {
        let shell = shell.clone();
        tokio::spawn(async move {
            loop {
                let names: Vec<String> = rk_ble::adapters().await.into_iter().map(|a| a.name).collect();
                let choices = {
                    let mut adapters = lock(&shell.adapters);
                    adapters.names = names;
                    adapters.clone()
                };
                if handle.update(|tray: &mut RkTray| tray.adapters = choices).await.is_none() {
                    return;
                }
                tokio::time::sleep(ADAPTER_REFRESH).await;
            }
        });
    }

    let ended = tokio::task::spawn_blocking(move || {
        let _ = app_done.recv();
    });
    tokio::pin!(ended);
    loop {
        tokio::select! {
            event = ui_rx.recv() => match event {
                Some(event) => handle_ui_event(&shell, handle.as_ref(), &mut notice, event).await,
                None => break,
            },
            _ = &mut ended => break,
        }
    }
    if let Some(handle) = handle {
        handle.shutdown().await;
    }
}

async fn show_notice(shell: &Arc<Shell>, handle: Option<&ksni::Handle<RkTray>>, notice: &mut Option<NoticeKind>, kind: NoticeKind) {
    // Notices that stay true while the tray shows them go to the tooltip; a dialog each time would pile up (the Bluetooth
    // notice comes back until the radio is on). The rest are said once, in a dialog.
    if matches!(kind, NoticeKind::NeedsRepair | NoticeKind::UpdatePhone | NoticeKind::BluetoothOff | NoticeKind::KeyStoreUnavailable) {
        *notice = Some(kind);
        if let Some(handle) = handle {
            let current = *notice;
            handle.update(|tray: &mut RkTray| tray.notice = current).await;
        }
    } else {
        shell.info(i18n::notice(shell.lang, kind));
    }
}

async fn handle_ui_event(shell: &Arc<Shell>, handle: Option<&ksni::Handle<RkTray>>, notice: &mut Option<NoticeKind>, event: UiEvent) {
    match event {
        UiEvent::State(state) => {
            if state.icon != IconState::Attention {
                *notice = None;
            }
            *lock(&shell.state) = state.clone();
            if let Some(handle) = handle {
                let current = *notice;
                handle
                    .update(|tray: &mut RkTray| {
                        tray.state = state;
                        tray.notice = current;
                    })
                    .await;
            }
        }
        UiEvent::PairingRequest { attempt, phone_name, sas } => shell.ask_pairing(attempt, &phone_name, &sas),
        UiEvent::PairingClosed => {}
        UiEvent::PairingDialogClose(attempt) => shell.close_pairing(attempt),
        UiEvent::Notice(kind) => show_notice(shell, handle, notice, kind).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_lock_is_held_by_the_first_process_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run").join("remote-keyboard.lock");
        let mut first = FlockLock { path: path.clone(), held: None };
        let mut second = FlockLock { path: path.clone(), held: None };
        assert_eq!(claim_instance(&mut first), Instance::First);
        assert_eq!(claim_instance(&mut second), Instance::Second);
        drop(first);
        assert_eq!(claim_instance(&mut FlockLock { path, held: None }), Instance::First, "the lock goes with its holder");
    }

    #[test]
    fn the_guard_of_the_lock_goes_to_the_first_caller_only_and_must_be_kept() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("remote-keyboard.lock");
        let first = claim_lock(path.clone());
        assert!(first.is_some());
        assert!(claim_lock(path.clone()).is_none(), "the second instance gets no guard");
        drop(first);
        assert!(claim_lock(path).is_some(), "a guard that was dropped no longer holds the lock");
    }

    /// Against the real keyring of the desktop session; adds one item of its own and removes it again.
    #[test]
    #[ignore = "needs a desktop session with a Secret Service: run by hand with --ignored"]
    fn secret_service_round_trip() {
        use rk_core::identity::{PhoneIdentity, PhonePlatform};
        use rk_core::secret::PairKey;
        let mut backend = SecretServiceBackend::connect(Duration::from_secs(10)).expect("a Secret Service on the session bus");
        let phone = PairedPhone {
            identity: PhoneIdentity { id: [0xEE; 16], name: "rk test phone".into(), platform: PhonePlatform::Ios },
            pair_key: PairKey::new([0x5A; 32]),
        };
        // A read answers within a moment or says "not yet"; ask until it has.
        let load = |backend: &SecretServiceBackend| {
            for _ in 0..50 {
                if let Ok(phones) = backend.load() {
                    return phones;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            panic!("the keyring never answered");
        };
        load(&backend);
        backend.put(&phone).unwrap();
        backend.put(&phone).unwrap(); // the same phone again replaces, it does not add
        let found: Vec<_> = load(&backend).into_iter().filter(|p| p.identity.id == [0xEE; 16]).collect();
        assert_eq!(found, vec![phone.clone()]);
        backend.remove(&phone.identity.id).unwrap();
        assert!(load(&backend).iter().all(|p| p.identity.id != [0xEE; 16]));
        backend.remove(&phone.identity.id).unwrap(); // removing what is not there is fine
    }

    #[test]
    fn the_diagnostics_pick_the_configured_controller_else_the_default() {
        let list = |names: &[&str]| -> Vec<rk_ble::AdapterInfo> {
            names.iter().map(|n| rk_ble::AdapterInfo { name: (*n).to_string(), address: format!("addr-{n}") }).collect()
        };
        let both = list(&["hci1", "hci0"]);
        assert_eq!(adapter_info_for(&both, Some("hci1")).unwrap().address, "addr-hci1");
        assert_eq!(adapter_info_for(&both, None).unwrap().name, "hci0");
        assert_eq!(adapter_info_for(&[], None), None);
    }
}
