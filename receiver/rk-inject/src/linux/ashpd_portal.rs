//! The real `PortalConnector`: ashpd 0.13 RemoteDesktop and Clipboard portals (the approach of the WL1 S4, S5, S9 spikes).
//!
//! All calls run on one process-wide tokio runtime (ashpd keeps a single session-bus connection that is tied to the runtime
//! that created it) and are made synchronous with `block_on`; the worker thread of `LinuxInjector` is the only caller.
//! Errors become short messages from the portal; no typed text is ever part of one.

use std::future::Future;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use ashpd::desktop::clipboard::{Clipboard, RequestClipboardOptions, SetSelectionOptions};
use ashpd::desktop::remote_desktop::{
    DeviceType, KeyState, NotifyKeyboardKeysymOptions, NotifyPointerAxisOptions, NotifyPointerButtonOptions,
    NotifyPointerMotionOptions, RemoteDesktop, SelectDevicesOptions,
};
use ashpd::desktop::{PersistMode, Session};
use futures_util::StreamExt;
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use super::{Closed, ConnectError, Connected, PortalConnector, PortalSession};
use crate::keysym::{pick_text_mime, ORIGINAL_READ_TIMEOUT, OWNER_WAIT, PORTAL_CALL_TIMEOUT};
use crate::InjectError;

const TEXT_MIMES: [&str; 3] = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"];
/// A clipboard bigger than this is not read, so it is never restored half.
const MAX_ORIGINAL_BYTES: usize = 4 * 1024 * 1024;
/// Reading the data of the original clipboard text, once its owner was announced.
const READ_TIMEOUT: Duration = ORIGINAL_READ_TIMEOUT;
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
/// One notify call or clipboard call.
const CALL_TIMEOUT: Duration = PORTAL_CALL_TIMEOUT;
/// The setup calls before the permission dialog; the dialog itself waits for the user as long as it takes.
const SETUP_TIMEOUT: Duration = Duration::from_secs(10);
const TIMED_OUT: &str = "portal call timed out";

fn runtime() -> Result<&'static Runtime, ConnectError> {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }
    let built = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("rk-portal")
        .build()
        .map_err(|e| ConnectError::Unavailable(format!("runtime: {e}")))?;
    Ok(RUNTIME.get_or_init(|| built))
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn failed(error: impl std::fmt::Display) -> InjectError {
    InjectError::Failed(error.to_string())
}

/// A setup call of `open` that has to answer within `SETUP_TIMEOUT`.
async fn setup<T>(call: impl Future<Output = Result<T, ashpd::Error>>) -> Result<T, ConnectError> {
    match tokio::time::timeout(SETUP_TIMEOUT, call).await {
        Ok(result) => result.map_err(connect_error),
        Err(_) => Err(ConnectError::Unavailable("the portal did not answer".to_string())),
    }
}

fn connect_error(error: ashpd::Error) -> ConnectError {
    match error {
        ashpd::Error::Response(_) => ConnectError::Denied,
        other => ConnectError::Unavailable(other.to_string()),
    }
}

/// What the clipboard tasks and the session share.
#[derive(Default)]
struct ClipboardState {
    /// Served to whoever pastes while this session owns the clipboard.
    payload: Mutex<String>,
    /// The latest owner announcement: offered formats and whether this session is the owner.
    owner: Mutex<Option<(Vec<String>, bool)>>,
}

/// The clipboard proxy lives as long as the process: the signal streams borrow it for `'static`.
async fn clipboard_proxy() -> ashpd::Result<&'static Clipboard> {
    static CLIPBOARD: tokio::sync::OnceCell<&'static Clipboard> = tokio::sync::OnceCell::const_new();
    CLIPBOARD
        .get_or_try_init(|| async {
            let proxy: &'static Clipboard = Box::leak(Box::new(Clipboard::new().await?));
            Ok::<_, ashpd::Error>(proxy)
        })
        .await
        .copied()
}

pub struct AshpdConnector;

/// Makes the pipe non-blocking, then `read_limited`.
fn read_fd_limited(fd: std::os::fd::OwnedFd, limit: usize, timeout: Duration) -> std::io::Result<Vec<u8>> {
    // A blocking pipe whose writer never writes would hold the thread for good.
    let flags = rustix::fs::fcntl_getfl(&fd)?;
    rustix::fs::fcntl_setfl(&fd, flags | rustix::fs::OFlags::NONBLOCK)?;
    read_limited(&mut std::fs::File::from(fd), limit, timeout)
}

/// Reads everything from a pipe the portal handed out. Such a pipe can be non-blocking, so "no data yet" is waited out until
/// `timeout`; more than `limit` bytes is an error because the text could not be given back whole.
fn read_limited(reader: &mut impl Read, limit: usize, timeout: Duration) -> std::io::Result<Vec<u8>> {
    use std::io::ErrorKind;
    let deadline = std::time::Instant::now() + timeout;
    let mut data = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => return Ok(data),
            Ok(n) => {
                data.extend_from_slice(&chunk[..n]);
                if data.len() > limit {
                    return Err(ErrorKind::InvalidData.into());
                }
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                if std::time::Instant::now() >= deadline {
                    return Err(ErrorKind::TimedOut.into());
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => return Err(e),
        }
    }
}

/// A value that is dropped with the runtime entered: dropping zbus proxies spawns tasks, which panics on a thread that is not
/// in the runtime's context (the worker thread of `LinuxInjector` never is).
struct InRuntime<T> {
    value: Option<T>,
    runtime: &'static Runtime,
}

impl<T> InRuntime<T> {
    fn new(value: T, runtime: &'static Runtime) -> Self {
        Self { value: Some(value), runtime }
    }
}

impl<T> std::ops::Deref for InRuntime<T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.value.as_ref().expect("the value is only taken while dropping")
    }
}

impl<T> Drop for InRuntime<T> {
    fn drop(&mut self) {
        let _entered = self.runtime.enter();
        drop(self.value.take());
    }
}

pub struct AshpdSession {
    runtime: &'static Runtime,
    remote: InRuntime<RemoteDesktop>,
    session: InRuntime<Arc<Session<RemoteDesktop>>>,
    clipboard: Option<&'static Clipboard>,
    state: Arc<ClipboardState>,
    tasks: Vec<JoinHandle<()>>,
}

impl PortalConnector for AshpdConnector {
    type Session = AshpdSession;

    fn connect(&mut self, restore_token: Option<&str>, on_closed: Closed) -> Result<Connected<AshpdSession>, ConnectError> {
        let runtime = runtime()?;
        runtime.block_on(open(runtime, restore_token, on_closed))
    }
}

async fn open(
    runtime: &'static Runtime,
    restore_token: Option<&str>,
    on_closed: Closed,
) -> Result<Connected<AshpdSession>, ConnectError> {
    let remote = setup(RemoteDesktop::new()).await?;
    let session = setup(remote.create_session(Default::default())).await?;
    let mut devices = SelectDevicesOptions::default()
        .set_devices(DeviceType::Keyboard | DeviceType::Pointer)
        .set_persist_mode(PersistMode::ExplicitlyRevoked);
    if let Some(token) = restore_token {
        devices = devices.set_restore_token(token);
    }
    setup(remote.select_devices(&session, devices)).await?;

    // The clipboard has to be requested before the session starts.
    let state = Arc::new(ClipboardState::default());
    let session = Arc::new(session);
    let mut tasks = Vec::new();
    // The portal ends the session from the outside when the user stops sharing or the portal restarts. The signal stream
    // borrows the session, so the task owns a share of it.
    let watched = session.clone();
    tasks.push(tokio::spawn(async move {
        if let Ok(closed) = watched.receive_closed().await {
            if Box::pin(closed).next().await.is_some() {
                on_closed();
            }
        }
    }));
    let mut clipboard = None;
    if let Ok(Ok(proxy)) = tokio::time::timeout(SETUP_TIMEOUT, clipboard_proxy()).await {
        let requested = tokio::time::timeout(SETUP_TIMEOUT, proxy.request(&session, RequestClipboardOptions::default())).await;
        if matches!(requested, Ok(Ok(_))) {
            if let Ok(mut spawned) = spawn_clipboard_tasks(proxy, state.clone()).await {
                tasks.append(&mut spawned);
                clipboard = Some(proxy);
            }
        }
    }

    let started = remote.start(&session, None, Default::default()).await.map_err(connect_error)?;
    let response = started.response().map_err(connect_error)?;
    if !response.devices().contains(DeviceType::Keyboard) {
        return Err(ConnectError::Denied);
    }
    let restore_token = response.restore_token().map(str::to_string);
    if !response.is_clipboard_enabled() {
        clipboard = None;
    }
    Ok(Connected {
        session: AshpdSession {
            runtime,
            remote: InRuntime::new(remote, runtime),
            session: InRuntime::new(session, runtime),
            clipboard,
            state,
            tasks,
        },
        restore_token,
    })
}

/// Serves the clipboard payload to pasting applications and tracks who owns the clipboard.
async fn spawn_clipboard_tasks(clipboard: &'static Clipboard, state: Arc<ClipboardState>) -> ashpd::Result<Vec<JoinHandle<()>>> {
    let transfers = clipboard.receive_selection_transfer::<RemoteDesktop>().await?;
    let serve_state = state.clone();
    let serve = tokio::spawn(async move {
        let mut transfers = Box::pin(transfers);
        while let Some((session, _mime, serial)) = transfers.next().await {
            let data = lock(&serve_state.payload).clone();
            let ok = match clipboard.selection_write(&session, serial).await {
                Ok(fd) => {
                    let fd: std::os::fd::OwnedFd = fd.into();
                    tokio::task::spawn_blocking(move || std::fs::File::from(fd).write_all(data.as_bytes()).is_ok())
                        .await
                        .unwrap_or(false)
                }
                Err(_) => false,
            };
            let _ = clipboard.selection_write_done(&session, serial, ok).await;
        }
    });

    let changes = clipboard.receive_selection_owner_changed::<RemoteDesktop>().await?;
    let watch = tokio::spawn(async move {
        let mut changes = Box::pin(changes);
        while let Some((_session, info)) = changes.next().await {
            let is_owner = info.session_is_owner().unwrap_or(false);
            *lock(&state.owner) = Some((info.mime_types().to_vec(), is_owner));
        }
    });
    Ok(vec![serve, watch])
}

impl AshpdSession {
    /// Runs one portal call to the end, but not longer than `CALL_TIMEOUT`.
    fn call<T>(&self, call: impl Future<Output = Result<T, ashpd::Error>>) -> Result<T, InjectError> {
        self.runtime.block_on(async {
            match tokio::time::timeout(CALL_TIMEOUT, call).await {
                Ok(result) => result.map_err(failed),
                Err(_) => Err(InjectError::Failed(TIMED_OUT.to_string())),
            }
        })
    }

    fn announced_owner(&self) -> Option<(Vec<String>, bool)> {
        let mut waited = Duration::ZERO;
        loop {
            if let Some(owner) = lock(&self.state.owner).clone() {
                return Some(owner);
            }
            if waited >= OWNER_WAIT {
                return None;
            }
            let step = Duration::from_millis(25);
            std::thread::sleep(step);
            waited += step;
        }
    }
}

impl PortalSession for AshpdSession {
    fn keysym(&mut self, sym: i32, pressed: bool) -> Result<(), InjectError> {
        let state = if pressed { KeyState::Pressed } else { KeyState::Released };
        self.call(self.remote.notify_keyboard_keysym(&self.session, sym, state, NotifyKeyboardKeysymOptions::default()))
    }

    fn pointer_motion(&mut self, dx: f64, dy: f64) -> Result<(), InjectError> {
        self.call(self.remote.notify_pointer_motion(&self.session, dx, dy, NotifyPointerMotionOptions::default()))
    }

    fn pointer_button(&mut self, code: i32, pressed: bool) -> Result<(), InjectError> {
        let state = if pressed { KeyState::Pressed } else { KeyState::Released };
        self.call(self.remote.notify_pointer_button(&self.session, code, state, NotifyPointerButtonOptions::default()))
    }

    fn pointer_axis(&mut self, dx: f64, dy: f64, finish: bool) -> Result<(), InjectError> {
        self.call(self.remote.notify_pointer_axis(&self.session, dx, dy, NotifyPointerAxisOptions::default().set_finish(finish)))
    }

    fn has_clipboard(&self) -> bool {
        self.clipboard.is_some()
    }

    fn clipboard_read(&mut self) -> Result<Option<String>, InjectError> {
        let Some(clipboard) = self.clipboard else {
            return Ok(None);
        };
        let Some((mimes, session_is_owner)) = self.announced_owner() else {
            return Ok(None);
        };
        if session_is_owner {
            let payload = lock(&self.state.payload).clone();
            return Ok((!payload.is_empty()).then_some(payload));
        }
        let Some(mime) = pick_text_mime(&mimes) else {
            return Ok(None);
        };
        let session = &self.session;
        // Anything that stops the text from being read in full is an error: it could not be given back afterwards.
        self.runtime.block_on(async {
            let read = async {
                let fd = clipboard.selection_read(session, &mime).await.map_err(failed)?;
                let fd: std::os::fd::OwnedFd = fd.into();
                let data = tokio::task::spawn_blocking(move || {
                    read_fd_limited(fd, MAX_ORIGINAL_BYTES, READ_TIMEOUT)
                })
                .await
                .map_err(failed)?
                .map_err(|e| match e.kind() {
                    std::io::ErrorKind::InvalidData => InjectError::Failed("clipboard too large to give back".to_string()),
                    std::io::ErrorKind::TimedOut => InjectError::Failed(TIMED_OUT.to_string()),
                    _ => failed(e),
                })?;
                String::from_utf8(data).map(Some).map_err(|_| InjectError::Failed("clipboard is not UTF-8 text".to_string()))
            };
            tokio::time::timeout(READ_TIMEOUT, read).await.unwrap_or_else(|_| Err(InjectError::Failed(TIMED_OUT.to_string())))
        })
    }

    /// The payload is only kept when the portal took the selection; a refused set leaves what was served before.
    fn clipboard_set(&mut self, text: &str) -> Result<(), InjectError> {
        let Some(clipboard) = self.clipboard else {
            return Err(InjectError::Failed("clipboard portal not available".to_string()));
        };
        let previous = std::mem::replace(&mut *lock(&self.state.payload), text.to_string());
        let set = self.call(clipboard.set_selection(&self.session, SetSelectionOptions::default().set_mime_types(&TEXT_MIMES)));
        if let Err(error) = set {
            *lock(&self.state.payload) = previous;
            return Err(error);
        }
        *lock(&self.state.owner) = Some((TEXT_MIMES.iter().map(|m| (*m).to_string()).collect(), true));
        Ok(())
    }

    /// What was served is dropped before the portal is asked, so a failing call cannot leave text behind that could still be
    /// pasted. The selection is then served with an empty payload instead of being unset: the compositor keeps the content of
    /// an unset selection around, so unsetting would leave the typed run on the clipboard.
    fn clipboard_clear(&mut self) -> Result<(), InjectError> {
        let Some(clipboard) = self.clipboard else {
            return Ok(());
        };
        lock(&self.state.payload).clear();
        self.call(clipboard.set_selection(&self.session, SetSelectionOptions::default().set_mime_types(&TEXT_MIMES)))?;
        *lock(&self.state.owner) = Some((TEXT_MIMES.iter().map(|m| (*m).to_string()).collect(), true));
        Ok(())
    }

    fn sleep(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

impl Drop for AshpdSession {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let session = &self.session;
        let _ = self.runtime.block_on(async { tokio::time::timeout(CLOSE_TIMEOUT, session.close()).await });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;

    /// Answers `WouldBlock` a few times, then hands out its data in two pieces.
    struct Slow {
        would_block: u32,
        pieces: Vec<Vec<u8>>,
    }

    impl Read for Slow {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if self.would_block > 0 {
                self.would_block -= 1;
                return Err(ErrorKind::WouldBlock.into());
            }
            if self.pieces.is_empty() {
                return Ok(0);
            }
            let piece = self.pieces.remove(0);
            buffer[..piece.len()].copy_from_slice(&piece);
            Ok(piece.len())
        }
    }

    #[test]
    fn a_silent_blocking_pipe_times_out_instead_of_blocking_forever() {
        let (reader, writer) = std::io::pipe().unwrap();
        let (done, result) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = done.send(read_fd_limited(reader.into(), 100, Duration::from_millis(100)));
        });
        let outcome = result.recv_timeout(Duration::from_secs(2)).expect("the read is stuck on a blocking pipe");
        assert_eq!(outcome.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
        drop(writer);
    }

    #[test]
    fn read_limited_waits_out_would_block() {
        let mut reader = Slow { would_block: 3, pieces: vec![b"ab".to_vec(), b"cd".to_vec()] };
        assert_eq!(read_limited(&mut reader, 100, Duration::from_secs(2)).unwrap(), b"abcd");
    }

    #[test]
    fn read_limited_refuses_more_than_the_limit() {
        let mut reader = Slow { would_block: 0, pieces: vec![vec![b'x'; 60], vec![b'y'; 60]] };
        let error = read_limited(&mut reader, 100, Duration::from_secs(2)).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);
    }

    #[test]
    fn read_limited_gives_up_at_the_deadline() {
        let mut reader = Slow { would_block: u32::MAX, pieces: Vec::new() };
        let error = read_limited(&mut reader, 100, Duration::from_millis(50)).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::TimedOut);
    }
}
