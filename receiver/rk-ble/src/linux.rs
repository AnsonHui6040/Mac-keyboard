//! The Linux backend: BlueZ for finding the phone, a raw L2CAP socket for talking to it (WL1 debugging, "L3",
//! docs/superpowers/verification/2026-11-10-windows-linux-receiver.md, "WL1 除錯").
//!
//! 1. Discovery through `bluer` on the configured controller. While no link exists it is restarted every 1.5 s, and the
//!    devices BlueZ knows only from scanning are removed first, so a phone that changed its advertised UUID shows up as
//!    new. Each device's `UUIDs` are matched against the selected and the pairing UUID.
//! 2. Discovery is stopped before connecting. The link is an `L2CAP SOCK_SEQPACKET` on the fixed ATT channel (CID 4),
//!    bound to the controller's address, connecting to the phone's LE address. `ENOSYS` and an aborted link are retried
//!    at once, up to three times.
//! 3. [`crate::att`] speaks ATT over that socket: no BlueZ GATT client, which needs 46 round trips for the phone's ten
//!    services. The handles of the last good link are checked with one request and reused.
//! 4. Reading and writing share one task: notifications of `event` become [`LinkEvent::Notification`], a write of
//!    `control` is a Write Request that waits for its response.
//!
//! No root and no change to the system: only the sockets and D-Bus calls above. Nothing here touches another controller
//! than the one chosen.

use crate::att::{establish, AttClient, AttError, AttTransport, HandleSet, Phase, ServiceUuids};
use crate::connect::{choose_adapter, device_key, hci_index, fail_kind, fail_kind_of_errno, match_route, with_retries, AdapterChoice, Holds, CONNECT_RETRIES};
use crate::diag::{Diag, FailKind, Value};
use crate::flow::ScanBackoff;
use crate::{DeviceKey, DisconnectReason, LinkCommand, LinkConfig, LinkEvent, Route, ScanFailure, ScanState};
use bluer::l2cap::{SeqPacket, Socket, SocketAddr};
use bluer::{Adapter, AdapterEvent, Address, AddressType, DeviceEvent, DeviceProperty, DiscoveryFilter, DiscoveryTransport, Session};
use futures_util::stream::{SelectAll, Stream, StreamExt};
use std::collections::HashSet;
use std::pin::Pin;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::time::{interval, sleep, timeout, MissedTickBehavior};
use uuid::Uuid;

const SERVICE: Uuid = Uuid::from_u128(0x706AA642_68A3_41FA_889D_24E30709B0D0);
const EVENT_CHARACTERISTIC: Uuid = Uuid::from_u128(0xC7FC0313_53E7_4DCD_B75F_2AE66FE9C586);
const CONTROL_CHARACTERISTIC: Uuid = Uuid::from_u128(0x320468E2_53B6_4B6A_88EC_AE2752415818);
const UUIDS: ServiceUuids = ServiceUuids { service: SERVICE, event: EVENT_CHARACTERISTIC, control: CONTROL_CHARACTERISTIC };

/// The ATT fixed channel.
const ATT_CID: u16 = 4;
/// How long the kernel gets to bring a link up.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
/// A write of `control` that is not answered by now means the link is gone.
const WRITE_TIMEOUT: Duration = Duration::from_secs(3);
/// §1.5 of the plan: while no link exists, discovery is restarted this often.
const RESTART_EVERY: Duration = Duration::from_millis(1500);
/// How long to wait for BlueZ to have stopped discovery.
const IDLE_WAIT: Duration = Duration::from_secs(1);
/// The wait before scanning again after a connection failed before it became ready (ms), 2 s at most.
const RETRY_WAITS_MS: [u64; 4] = [0, 500, 1000, 2000];

fn millis(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn route_word(route: Route) -> &'static str {
    match route {
        Route::Selected => "selected",
        Route::Pairing => "pairing",
    }
}

// ---------------------------------------------------------------- the socket

struct Seq(SeqPacket);

impl AttTransport for Seq {
    async fn send(&mut self, pdu: &[u8]) -> std::io::Result<()> {
        self.0.send(pdu).await.map(|_| ())
    }

    async fn recv(&mut self) -> std::io::Result<Vec<u8>> {
        // 517 is the largest ATT MTU we ask for; the buffer is generous.
        let mut buffer = [0u8; 1024];
        let length = self.0.recv(&mut buffer).await?;
        Ok(buffer[..length].to_vec())
    }
}

// ---------------------------------------------------------------- what the scan found

struct Sighting {
    /// The controller that saw it; the socket binds to it.
    local: Address,
    address: Address,
    address_type: AddressType,
    route: Route,
}

/// How one scan ended.
enum Watched {
    Found(Sighting),
    Failed(ScanFailure),
    /// The application is gone.
    Gone,
}

type Merged = SelectAll<Pin<Box<dyn Stream<Item = (Address, HashSet<Uuid>)> + Send>>>;
type AdapterEvents = Pin<Box<dyn Stream<Item = AdapterEvent> + Send>>;

/// The things that live as long as scanning keeps working.
struct Scanner {
    adapter: Adapter,
    local: Address,
}

// ---------------------------------------------------------------- an open link

struct Live {
    att: AttClient<Seq>,
    handles: HandleSet,
    mtu: usize,
}

struct Worker {
    events: mpsc::Sender<LinkEvent>,
    cfg: LinkConfig,
    pairing_on: bool,
    holds: Holds,
    next_conn: u64,
    failures: usize,
    scan_backoff: ScanBackoff,
    reported_scan: Option<ScanFailure>,
    /// The handles of the last link that worked, checked before every use.
    cache: Option<HandleSet>,
    session: Option<Session>,
    /// The controller last announced in the log.
    announced_adapter: Option<String>,
}

async fn emit_diag(events: &mpsc::Sender<LinkEvent>, diag: Diag) -> bool {
    events.send(LinkEvent::Diag(diag)).await.is_ok()
}

impl Worker {
    fn new(cfg: LinkConfig, events: mpsc::Sender<LinkEvent>) -> Self {
        Self {
            events,
            cfg,
            pairing_on: false,
            holds: Holds::default(),
            next_conn: 1,
            failures: 0,
            scan_backoff: ScanBackoff::new(),
            reported_scan: None,
            cache: None,
            session: None,
            announced_adapter: None,
        }
    }

    /// What can be applied while no link is open. `false` when the application is gone (the channel closed).
    fn apply(&mut self, command: Option<LinkCommand>) -> bool {
        match command {
            None => return false,
            Some(LinkCommand::SetPairingScan(on)) => self.pairing_on = on,
            Some(LinkCommand::Hold { device, for_ }) => self.holds.hold(device, for_, Instant::now()),
            Some(LinkCommand::Write(_) | LinkCommand::Disconnect) => {}
        }
        true
    }

    async fn run(mut self, rx: &mut mpsc::Receiver<LinkCommand>) {
        loop {
            let Some(sighting) = self.scan_until_found(rx).await else { return };
            let conn = self.next_conn;
            self.next_conn += 1;
            if !self.connect_and_serve(rx, conn, sighting).await {
                return;
            }
        }
    }

    async fn wait(&mut self, rx: &mut mpsc::Receiver<LinkCommand>, duration: Duration) -> bool {
        let until = tokio::time::Instant::now() + duration;
        loop {
            tokio::select! {
                command = rx.recv() => if !self.apply(command) { return false },
                () = tokio::time::sleep_until(until) => return true,
            }
        }
    }

    // ------------------------------------------------------------ scanning

    /// Scans until a target advertises. A scan that cannot start or stops is reported, waited out with a growing pause and
    /// started again. `None` when the application has gone away.
    async fn scan_until_found(&mut self, rx: &mut mpsc::Receiver<LinkCommand>) -> Option<Sighting> {
        loop {
            let failure = match self.watch(rx).await {
                Watched::Found(sighting) => return Some(sighting),
                Watched::Gone => return None,
                Watched::Failed(failure) => failure,
            };
            // A broken session (bluetoothd restarted) is made again next time.
            self.session = None;
            let wait = self.scan_backoff.next_wait();
            self.report_scan_failure(failure, wait).await;
            if !self.wait(rx, wait).await {
                return None;
            }
        }
    }

    async fn report_scan_failure(&mut self, failure: ScanFailure, wait: Duration) {
        let diag = Diag::new(0, "scan_error").with("kind", Value::S(failure.as_str())).with("retry_ms", Value::U(u64::try_from(wait.as_millis()).unwrap_or(u64::MAX)));
        emit_diag(&self.events, diag).await;
        if self.reported_scan != Some(failure) {
            self.reported_scan = Some(failure);
            let _ = self.events.send(LinkEvent::Scan(ScanState::Failed(failure))).await;
        }
    }

    /// Scanning really runs: the backoff starts over, and an outage that was reported is over.
    async fn confirm_scan(&mut self, confirmed: &mut bool) {
        if std::mem::replace(confirmed, true) {
            return;
        }
        self.scan_backoff.reset();
        if self.reported_scan.take().is_some() {
            let _ = self.events.send(LinkEvent::Scan(ScanState::Running)).await;
        }
    }

    /// The session and the chosen controller, made when needed.
    async fn scanner(&mut self) -> Result<Scanner, ScanFailure> {
        if self.session.is_none() {
            self.session = Some(Session::new().await.map_err(|_| ScanFailure::Unavailable)?);
        }
        let session = self.session.as_ref().ok_or(ScanFailure::Unavailable)?;
        let names = session.adapter_names().await.map_err(|_| ScanFailure::Unavailable)?;
        let name = choose_adapter(&names, self.cfg.adapter.as_deref()).map_err(|_: AdapterChoice| ScanFailure::Unavailable)?;
        let adapter = session.adapter(&name).map_err(|_| ScanFailure::Unavailable)?;
        if self.announced_adapter.as_deref() != Some(name.as_str()) {
            if let Some(index) = hci_index(&name) {
                emit_diag(&self.events, Diag::new(0, "adapter").with("hci", Value::U(index))).await;
            }
            self.announced_adapter = Some(name);
        }
        if !adapter.is_powered().await.map_err(|_| ScanFailure::Unavailable)? {
            return Err(ScanFailure::RadioOff);
        }
        let local = adapter.address().await.map_err(|_| ScanFailure::Unavailable)?;
        // Set while nothing runs; kept for every later restart.
        let filter = DiscoveryFilter { transport: DiscoveryTransport::Le, duplicate_data: true, ..DiscoveryFilter::default() };
        let _ = adapter.set_discovery_filter(filter).await;
        Ok(Scanner { adapter, local })
    }

    async fn watch(&mut self, rx: &mut mpsc::Receiver<LinkCommand>) -> Watched {
        let scanner = match self.scanner().await {
            Ok(scanner) => scanner,
            Err(failure) => return Watched::Failed(failure),
        };
        let mut confirmed = false;
        let mut restart = interval(RESTART_EVERY);
        restart.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut stream: Option<AdapterEvents> = None;
        let mut changes: Merged = SelectAll::new();
        loop {
            tokio::select! {
                command = rx.recv() => if !self.apply(command) { return Watched::Gone },
                _ = restart.tick() => {
                    // Let go of the old discovery first, wait until BlueZ has stopped it, then start a new one.
                    drop(stream.take());
                    changes = SelectAll::new();
                    wait_until_idle(&scanner.adapter).await;
                    purge(&scanner.adapter).await;
                    match scanner.adapter.discover_devices().await {
                        Ok(events) => stream = Some(events.boxed()),
                        Err(_) => return Watched::Failed(ScanFailure::Unavailable),
                    }
                    self.confirm_scan(&mut confirmed).await;
                }
                added = next_event(&mut stream) => match added {
                    Some(AdapterEvent::DeviceAdded(address)) => {
                        if let Some(uuids) = watch_device(&scanner.adapter, address, &mut changes).await {
                            if let Some(found) = self.sighting(&scanner, address, &uuids).await {
                                stop_discovery(stream.take(), changes, &scanner.adapter).await;
                                return Watched::Found(found);
                            }
                        }
                    }
                    Some(_) => {}
                    None => return Watched::Failed(ScanFailure::Aborted),
                },
                Some((address, uuids)) = changes.next(), if !changes.is_empty() => {
                    if let Some(found) = self.sighting(&scanner, address, &uuids).await {
                        stop_discovery(stream.take(), changes, &scanner.adapter).await;
                        return Watched::Found(found);
                    }
                }
            }
        }
    }

    /// `Some` when the device offers a route we are looking for and is not on hold.
    async fn sighting(&self, scanner: &Scanner, address: Address, uuids: &HashSet<Uuid>) -> Option<Sighting> {
        let advertised: Vec<Uuid> = uuids.iter().copied().collect();
        let route = match_route(&advertised, self.cfg.select, self.cfg.pairing, self.pairing_on)?;
        let key = device_key(address.0);
        if self.holds.is_held(key, Instant::now()) {
            emit_diag(&self.events, Diag::new(0, "held_skip").debug().with("device", Value::Id(key.short()))).await;
            return None;
        }
        let address_type = scanner.adapter.device(address).ok()?.address_type().await.ok()?;
        Some(Sighting { local: scanner.local, address, address_type, route })
    }

    // ------------------------------------------------------------ connecting

    /// One attempt from advertisement to hang-up. `false` ends the worker.
    async fn connect_and_serve(&mut self, rx: &mut mpsc::Receiver<LinkCommand>, conn: u64, sighting: Sighting) -> bool {
        let adv_at = Instant::now();
        let key = device_key(sighting.address.0);
        let events = self.events.clone();
        emit_diag(&events, Diag::new(conn, "adv_seen").at(0).with("device", Value::Id(key.short())).with("route", Value::S(route_word(sighting.route)))).await;
        emit_diag(&events, Diag::new(conn, "connect_start").at(millis(adv_at))).await;
        let cached = self.cache;
        let opened = {
            let attempt = open_link(&events, cached, conn, adv_at, &sighting);
            tokio::pin!(attempt);
            loop {
                tokio::select! {
                    result = &mut attempt => break Some(result),
                    command = rx.recv() => match command {
                        None => return false,
                        Some(LinkCommand::Disconnect) => break None,
                        other => { self.apply(other); }
                    },
                }
            }
        };
        match opened {
            None => self.emit(LinkEvent::Disconnected { conn, device: key, reason: DisconnectReason::Local }).await,
            Some(Err(kind)) => self.failed_connect(rx, conn, key, adv_at, kind).await,
            Some(Ok(live)) => {
                self.failures = 0;
                self.cache = Some(live.handles);
                self.serve(rx, conn, key, sighting.route, adv_at, live).await
            }
        }
    }

    async fn failed_connect(&mut self, rx: &mut mpsc::Receiver<LinkCommand>, conn: u64, device: DeviceKey, adv_at: Instant, kind: FailKind) -> bool {
        emit_diag(&self.events, Diag::new(conn, "connect_failed").at(millis(adv_at)).with("kind", Value::S(kind.as_str()))).await;
        let wait = RETRY_WAITS_MS[self.failures.min(RETRY_WAITS_MS.len() - 1)];
        self.failures += 1;
        self.emit(LinkEvent::Disconnected { conn, device, reason: DisconnectReason::Failed(kind) }).await && self.wait(rx, Duration::from_millis(wait)).await
    }

    async fn emit(&self, event: LinkEvent) -> bool {
        self.events.send(event).await.is_ok()
    }

    // ------------------------------------------------------------ serving

    /// Runs one open link until it ends. `false` ends the worker.
    async fn serve(&mut self, rx: &mut mpsc::Receiver<LinkCommand>, conn: u64, device: DeviceKey, route: Route, adv_at: Instant, live: Live) -> bool {
        let Live { mut att, handles, mtu } = live;
        if !self.emit(LinkEvent::Connected { conn, device, route, mtu }).await {
            return false;
        }
        let mut gone = false;
        let reason = loop {
            tokio::select! {
                incoming = att.next_notification() => match incoming {
                    Ok((handle, bytes)) => {
                        if handle == handles.event {
                            let _ = self.events.send(LinkEvent::Notification { conn, bytes }).await;
                        }
                    }
                    Err(error) => break reason_of(&error),
                },
                command = rx.recv() => match command {
                    None => {
                        gone = true;
                        break DisconnectReason::Local;
                    }
                    Some(LinkCommand::Write(bytes)) => {
                        let started = Instant::now();
                        let result = att.write(handles.control, &bytes, WRITE_TIMEOUT).await;
                        let word = result.as_ref().map_or_else(|error| fail_kind(error).as_str(), |()| "ok");
                        let diag = Diag::new(conn, "att_write").at(millis(adv_at)).debug().with("len", Value::U(bytes.len() as u64)).with("took_ms", Value::U(millis(started))).with("result", Value::S(word));
                        emit_diag(&self.events, diag).await;
                        if let Err(error) = result {
                            // A write that does not get through means the link is no longer there: end it, go back to scanning.
                            emit_diag(&self.events, Diag::new(conn, "write_failed").at(millis(adv_at)).with("kind", Value::S(fail_kind(&error).as_str()))).await;
                            break DisconnectReason::LinkLost;
                        }
                    }
                    Some(LinkCommand::Disconnect) => break DisconnectReason::Local,
                    other => { self.apply(other); }
                },
            }
        };
        // Closing the socket is what hangs up.
        drop(att);
        self.emit(LinkEvent::Disconnected { conn, device, reason }).await && !gone
    }
}

fn reason_of(error: &AttError) -> DisconnectReason {
    match error {
        // ECONNRESET: the phone terminated the connection.
        AttError::Io(Some(104)) => DisconnectReason::Remote,
        _ => DisconnectReason::LinkLost,
    }
}

// ---------------------------------------------------------------- BlueZ helpers

async fn next_event(stream: &mut Option<AdapterEvents>) -> Option<AdapterEvent> {
    match stream {
        Some(events) => events.next().await,
        None => std::future::pending().await,
    }
}

/// Waits until BlueZ reports discovery stopped (bluer stops it a moment after its last stream is dropped).
async fn wait_until_idle(adapter: &Adapter) {
    let deadline = tokio::time::Instant::now() + IDLE_WAIT;
    while adapter.is_discovering().await.unwrap_or(false) && tokio::time::Instant::now() < deadline {
        sleep(Duration::from_millis(20)).await;
    }
}

/// Removes the devices BlueZ only knows from scanning, so that a changed advertisement is a new device. Paired and
/// connected devices stay.
async fn purge(adapter: &Adapter) {
    let Ok(addresses) = adapter.device_addresses().await else { return };
    for address in addresses {
        let Ok(device) = adapter.device(address) else { continue };
        if device.is_paired().await.unwrap_or(true) || device.is_connected().await.unwrap_or(true) {
            continue;
        }
        let _ = adapter.remove_device(address).await;
    }
}

/// Starts following the `UUIDs` of a device and returns what they are now.
async fn watch_device(adapter: &Adapter, address: Address, changes: &mut Merged) -> Option<HashSet<Uuid>> {
    let device = adapter.device(address).ok()?;
    if let Ok(events) = device.events().await {
        let followed = events.filter_map(move |event| {
            std::future::ready(match event {
                DeviceEvent::PropertyChanged(DeviceProperty::Uuids(uuids)) => Some((address, uuids)),
                _ => None,
            })
        });
        changes.push(followed.boxed());
    }
    // Read after subscribing, so a change in between is not lost.
    device.uuids().await.ok().flatten()
}

async fn stop_discovery(stream: Option<AdapterEvents>, changes: Merged, adapter: &Adapter) {
    drop(stream);
    drop(changes);
    wait_until_idle(adapter).await;
}

// ---------------------------------------------------------------- connecting

/// Connect with the retries, then speak ATT up to the subscription. The diagnostic events of each step go out as they
/// happen.
async fn open_link(events: &mpsc::Sender<LinkEvent>, cache: Option<HandleSet>, conn: u64, adv_at: Instant, sighting: &Sighting) -> Result<Live, FailKind> {
    with_retries(
        CONNECT_RETRIES,
        |_| try_once(events, cache, conn, adv_at, sighting),
        |attempt, kind| {
            let diag = Diag::new(conn, "retry").at(millis(adv_at)).with("attempt", Value::U(u64::from(attempt))).with("kind", Value::S(kind.as_str()));
            let _ = events.try_send(LinkEvent::Diag(diag));
        },
    )
    .await
}

async fn try_once(events: &mpsc::Sender<LinkEvent>, cache: Option<HandleSet>, conn: u64, adv_at: Instant, sighting: &Sighting) -> Result<Live, FailKind> {
    let errno_kind = |e: &std::io::Error| fail_kind_of_errno(e.raw_os_error());
    let socket = Socket::<SeqPacket>::new_seq_packet().map_err(|e| errno_kind(&e))?;
    socket.bind(SocketAddr { addr: sighting.local, addr_type: AddressType::LePublic, psm: 0, cid: ATT_CID }).map_err(|e| errno_kind(&e))?;
    let target = SocketAddr { addr: sighting.address, addr_type: sighting.address_type, psm: 0, cid: ATT_CID };
    let seq = timeout(CONNECT_TIMEOUT, socket.connect(target)).await.map_err(|_| FailKind::Timeout)?.map_err(|e| errno_kind(&e))?;
    emit_diag(events, Diag::new(conn, "connected").at(millis(adv_at))).await;
    let mut att = AttClient::new(Seq(seq));
    let established = establish(&mut att, cache, UUIDS, |phase| {
        let diag = match phase {
            Phase::Mtu(mtu) => Diag::new(conn, "mtu").at(millis(adv_at)).with("value", Value::U(u64::from(mtu))),
            Phase::Discovered { cached } => Diag::new(conn, "discovered").at(millis(adv_at)).with("cached", Value::B(cached)),
            Phase::Subscribed => Diag::new(conn, "subscribed").at(millis(adv_at)),
        };
        let _ = events.try_send(LinkEvent::Diag(diag));
    })
    .await
    .map_err(|e| fail_kind(&e))?;
    Ok(Live { att, handles: established.handles, mtu: usize::from(established.mtu) })
}

// ---------------------------------------------------------------- entry points

/// A Bluetooth controller as BlueZ lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterInfo {
    pub name: String,
    pub address: String,
}

/// The controllers BlueZ knows, by name. Empty when bluetoothd is not reachable.
pub async fn adapters() -> Vec<AdapterInfo> {
    let Ok(session) = Session::new().await else { return Vec::new() };
    let Ok(mut names) = session.adapter_names().await else { return Vec::new() };
    names.sort();
    let mut found = Vec::new();
    for name in names {
        let Ok(adapter) = session.adapter(&name) else { continue };
        let address = adapter.address().await.map(|a| a.to_string()).unwrap_or_default();
        found.push(AdapterInfo { name, address });
    }
    found
}

/// Runs the backend until the application drops its end of the channels. Commands still queued then (the `bye`, the
/// `Disconnect`) are carried out first, in order, and the socket is closed before this returns.
pub async fn run(cfg: LinkConfig, tx: mpsc::Sender<LinkEvent>, mut rx: mpsc::Receiver<LinkCommand>) {
    Worker::new(cfg, tx).run(&mut rx).await;
}
