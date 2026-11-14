//! The Windows backend: WinRT `BluetoothLEAdvertisementWatcher` and `BluetoothLEDevice`, connected the way the WL1 debugging
//! showed to be reliable (docs/superpowers/verification/2026-11-10-windows-linux-receiver.md, "WL1 除錯"):
//!
//! 1. an active watcher, matching the service UUIDs of each single advertisement;
//! 2. the device opened with the advertisement's address type;
//! 3. a GATT session that maintains the connection, and ThroughputOptimized connection parameters held for the whole link;
//! 4. service discovery repeated on the same device object every 50 ms for up to 8 s, Unreachable and "no service" included;
//! 5. `event` subscribed, `control` written with Write Request only;
//! 6. when the 8 s run out the objects are closed, so the next advertisement opens everything afresh. The phone keeps
//!    advertising until it is subscribed, so a new advertisement during discovery is normal and is not looked at.
//!
//! WinRT calls block (`.get()`), so one dedicated thread owns the whole state machine and talks to the application through
//! channels. All of it is invisible to the logic tests; it is exercised on a real Windows machine.

use crate::diag::{Diag, FailKind, Value};
use crate::flow::{pump_commands, NotificationGate, Offer, ScanBackoff};
use crate::{DeviceKey, DisconnectReason, LinkCommand, LinkConfig, LinkEvent, Route, ScanFailure, ScanState};
use std::collections::HashMap;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;
use windows::core::{IInspectable, GUID};
use windows::Devices::Bluetooth::Advertisement::{
    BluetoothLEAdvertisementReceivedEventArgs, BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementWatcherStatus,
    BluetoothLEAdvertisementWatcherStoppedEventArgs, BluetoothLEScanningMode,
};
use windows::Devices::Bluetooth::GenericAttributeProfile::{
    GattCharacteristic, GattClientCharacteristicConfigurationDescriptorValue, GattCommunicationStatus, GattDeviceService, GattSession,
    GattValueChangedEventArgs, GattWriteOption,
};
use windows::Devices::Bluetooth::{
    BluetoothAddressType, BluetoothCacheMode, BluetoothError, BluetoothConnectionStatus, BluetoothLEDevice, BluetoothLEPreferredConnectionParameters,
    BluetoothLEPreferredConnectionParametersRequest,
};
use windows::Foundation::TypedEventHandler;
use windows::Storage::Streams::{DataReader, DataWriter};
use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

const SERVICE: GUID = GUID::from_u128(rk_service());
const EVENT_CHARACTERISTIC: GUID = GUID::from_u128(0xC7FC0313_53E7_4DCD_B75F_2AE66FE9C586);
const CONTROL_CHARACTERISTIC: GUID = GUID::from_u128(0x320468E2_53B6_4B6A_88EC_AE2752415818);

const fn rk_service() -> u128 {
    0x706AA642_68A3_41FA_889D_24E30709B0D0
}

/// §1.5: how long service discovery may take before the attempt is given up.
const DISCOVERY_DEADLINE: Duration = Duration::from_secs(8);
const DISCOVERY_RETRY: Duration = Duration::from_millis(50);
/// §1.5 and the plan: on `Disconnect` or exit the queued commands (the `bye`) get this long to reach the radio.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
/// §1.5: the wait before scanning again after a connection failed before it became ready (ms), 2 s at most.
const RETRY_WAITS_MS: [u64; 4] = [0, 500, 1000, 2000];

fn guid(uuid: Uuid) -> GUID {
    GUID::from_u128(uuid.as_u128())
}

fn millis(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The scan filter the watcher callback reads and the worker changes.
struct ScanFilter {
    select: GUID,
    pairing: GUID,
    pairing_on: bool,
    holds: HashMap<u64, Instant>,
}

struct Sighting {
    address: u64,
    address_type: BluetoothAddressType,
    route: Route,
}

/// Why a stopped watcher stopped, as seen by the `Stopped` event; filled in by the handler, read by the scan loop.
type StopReason = Arc<Mutex<Option<ScanFailure>>>;

fn failure_of(error: BluetoothError) -> Option<ScanFailure> {
    match error {
        BluetoothError::Success => None,
        BluetoothError::RadioNotAvailable | BluetoothError::DisabledByUser | BluetoothError::DisabledByPolicy => Some(ScanFailure::RadioOff),
        _ => Some(ScanFailure::Aborted),
    }
}

fn start_watcher(scan: Arc<Mutex<ScanFilter>>, found: std_mpsc::Sender<Sighting>) -> windows::core::Result<(BluetoothLEAdvertisementWatcher, StopReason)> {
    let watcher = BluetoothLEAdvertisementWatcher::new()?;
    watcher.SetScanningMode(BluetoothLEScanningMode::Active)?;
    watcher.Received(&TypedEventHandler::<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs>::new(move |_, args| {
        let args = args.ok()?;
        let address = args.BluetoothAddress()?;
        let uuids = args.Advertisement()?.ServiceUuids()?;
        let (mut selected, mut pairing) = (false, false);
        for i in 0..uuids.Size()? {
            let id = uuids.GetAt(i)?;
            let state = scan.lock().unwrap_or_else(|p| p.into_inner());
            selected |= id == state.select;
            pairing |= id == state.pairing && state.pairing_on;
        }
        let held = scan.lock().unwrap_or_else(|p| p.into_inner()).holds.get(&address).is_some_and(|until| *until > Instant::now());
        if held || !(selected || pairing) {
            return Ok(());
        }
        let route = if selected { Route::Selected } else { Route::Pairing };
        let _ = found.send(Sighting { address, address_type: args.BluetoothAddressType()?, route });
        Ok(())
    }))?;
    let stopped_because: StopReason = Arc::new(Mutex::new(None));
    let reason = stopped_because.clone();
    watcher.Stopped(&TypedEventHandler::<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementWatcherStoppedEventArgs>::new(move |_, args| {
        if let Some(failure) = failure_of(args.ok()?.Error()?) {
            *reason.lock().unwrap_or_else(|p| p.into_inner()) = Some(failure);
        }
        Ok(())
    }))?;
    watcher.Start()?;
    Ok((watcher, stopped_because))
}

/// Everything WinRT hands out for one open link; dropped (closed) as a whole.
struct Link {
    device: BluetoothLEDevice,
    session: GattSession,
    service: GattDeviceService,
    event: GattCharacteristic,
    control: GattCharacteristic,
    _preferred: BluetoothLEPreferredConnectionParametersRequest,
    value_token: i64,
    lost: std_mpsc::Receiver<()>,
    gate: Arc<Mutex<NotificationGate>>,
}

impl Link {
    /// Unsubscribes and releases every object. Windows drops the radio link shortly after `Close`.
    fn release(self) {
        let _ = self.event.RemoveValueChanged(self.value_token);
        let _ = self.session.SetMaintainConnection(false);
        let _ = self.session.Close();
        let _ = self.service.Close();
        let _ = self.device.Close();
    }
}

struct Opened {
    device: BluetoothLEDevice,
    session: GattSession,
    preferred: BluetoothLEPreferredConnectionParametersRequest,
}

/// How one scan ended.
enum Watched {
    Found(Sighting),
    Failed(ScanFailure),
    /// The application is gone.
    Gone,
}

enum Failure {
    /// Give up on this attempt for the given reason.
    Gave(FailKind),
    /// The caller asked to disconnect while the link was being set up.
    Cancelled,
}

struct Worker {
    events: mpsc::Sender<LinkEvent>,
    commands: std_mpsc::Receiver<LinkCommand>,
    scan: Arc<Mutex<ScanFilter>>,
    next_conn: u64,
    failures: usize,
    scan_backoff: ScanBackoff,
    reported_scan: Option<ScanFailure>,
}

impl Worker {
    fn emit(&self, event: LinkEvent) -> bool {
        self.events.blocking_send(event).is_ok()
    }

    fn diag(&self, d: Diag) -> bool {
        self.emit(LinkEvent::Diag(d))
    }

    /// Applies what can be applied while no link is open. `false` when the application is gone.
    fn drain_commands(&mut self) -> bool {
        loop {
            match self.commands.try_recv() {
                Ok(LinkCommand::SetPairingScan(on)) => self.scan.lock().unwrap_or_else(|p| p.into_inner()).pairing_on = on,
                Ok(LinkCommand::Hold { device, for_ }) => {
                    self.scan.lock().unwrap_or_else(|p| p.into_inner()).holds.insert(device.0, Instant::now() + for_);
                }
                Ok(LinkCommand::Write(_) | LinkCommand::Disconnect) => {}
                Err(std_mpsc::TryRecvError::Empty) => return true,
                Err(std_mpsc::TryRecvError::Disconnected) => return false,
            }
        }
    }

    fn run(mut self) {
        loop {
            if !self.drain_commands() {
                return;
            }
            let Some(sighting) = self.scan_until_found() else { return };
            let conn = self.next_conn;
            self.next_conn += 1;
            if !self.connect_and_serve(conn, sighting) {
                return;
            }
        }
    }

    /// Scans until a target advertises. A scan that cannot start or is stopped by the system is reported, waited out with a
    /// growing pause and started again. `None` when the application has gone away.
    fn scan_until_found(&mut self) -> Option<Sighting> {
        loop {
            let (tx, rx) = std_mpsc::channel();
            let failure = match start_watcher(self.scan.clone(), tx) {
                Err(_) => ScanFailure::Unavailable,
                Ok((watcher, stopped_because)) => {
                    if self.reported_scan.take().is_some() {
                        self.emit(LinkEvent::Scan(ScanState::Running));
                    }
                    let outcome = self.watch(&watcher, &stopped_because, &rx);
                    let _ = watcher.Stop();
                    match outcome {
                        Watched::Found(sighting) => {
                            self.scan_backoff.reset();
                            return Some(sighting);
                        }
                        Watched::Gone => return None,
                        Watched::Failed(failure) => failure,
                    }
                }
            };
            let wait = self.scan_backoff.next_wait();
            self.report_scan_failure(failure, wait);
            if !self.wait(wait) {
                return None;
            }
        }
    }

    fn watch(&mut self, watcher: &BluetoothLEAdvertisementWatcher, stopped_because: &StopReason, found: &std_mpsc::Receiver<Sighting>) -> Watched {
        loop {
            if !self.drain_commands() {
                return Watched::Gone;
            }
            match found.recv_timeout(Duration::from_millis(100)) {
                Ok(sighting) => return Watched::Found(sighting),
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => return Watched::Gone,
            }
            let aborted = watcher.Status().is_ok_and(|s| s == BluetoothLEAdvertisementWatcherStatus::Aborted);
            let reason = stopped_because.lock().unwrap_or_else(|p| p.into_inner()).take();
            if let Some(failure) = reason.or(aborted.then_some(ScanFailure::Aborted)) {
                return Watched::Failed(failure);
            }
        }
    }

    fn report_scan_failure(&mut self, failure: ScanFailure, wait: Duration) {
        self.diag(Diag::new(0, "scan_error").with("kind", Value::S(failure.as_str())).with("retry_ms", Value::U(u64::try_from(wait.as_millis()).unwrap_or(u64::MAX))));
        if self.reported_scan != Some(failure) {
            self.reported_scan = Some(failure);
            self.emit(LinkEvent::Scan(ScanState::Failed(failure)));
        }
    }

    /// One attempt from advertisement to hang-up. `false` ends the worker.
    fn connect_and_serve(&mut self, conn: u64, sighting: Sighting) -> bool {
        let adv_at = Instant::now();
        let device_key = DeviceKey(sighting.address);
        // A hold may have been set between the advertisement and now (the previous connection of this device just ended).
        let held = self.scan.lock().unwrap_or_else(|p| p.into_inner()).holds.get(&sighting.address).is_some_and(|until| *until > adv_at);
        if held {
            self.diag(Diag::new(conn, "held_skip").debug().with("device", Value::Id(device_key.short())));
            return true;
        }
        self.diag(Diag::new(conn, "adv_seen").at(0).with("device", Value::Id(device_key.short())).with("route", Value::S(route_word(sighting.route))));
        self.diag(Diag::new(conn, "connect_start").at(millis(adv_at)));
        match self.open_link(conn, &sighting, adv_at) {
            Ok(link) => {
                self.failures = 0;
                self.serve(conn, device_key, sighting.route, adv_at, link)
            }
            Err(Failure::Gave(kind)) => {
                self.diag(Diag::new(conn, "connect_failed").at(millis(adv_at)).with("kind", Value::S(kind.as_str())));
                let wait = RETRY_WAITS_MS[self.failures.min(RETRY_WAITS_MS.len() - 1)];
                self.failures += 1;
                self.emit(LinkEvent::Disconnected { conn, device: device_key, reason: DisconnectReason::Failed(kind) }) && self.wait(Duration::from_millis(wait))
            }
            Err(Failure::Cancelled) => self.emit(LinkEvent::Disconnected { conn, device: device_key, reason: DisconnectReason::Local }),
        }
    }

    fn wait(&mut self, duration: Duration) -> bool {
        let until = Instant::now() + duration;
        while Instant::now() < until {
            if !self.drain_commands() {
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        true
    }

    fn open_device(&self, sighting: &Sighting) -> windows::core::Result<Opened> {
        let device = BluetoothLEDevice::FromBluetoothAddressWithBluetoothAddressTypeAsync(sighting.address, sighting.address_type)?.get()?;
        let preferred = device.RequestPreferredConnectionParameters(&BluetoothLEPreferredConnectionParameters::ThroughputOptimized()?)?;
        let session = GattSession::FromDeviceIdAsync(&device.BluetoothDeviceId()?)?.get()?;
        session.SetMaintainConnection(true)?;
        Ok(Opened { device, session, preferred })
    }

    /// Steps 2 to 5 of the module comment: one device object, service discovery repeated on it until it works or 8 s are up.
    fn open_link(&mut self, conn: u64, sighting: &Sighting, adv_at: Instant) -> Result<Link, Failure> {
        let deadline = Instant::now() + DISCOVERY_DEADLINE;
        let opened = self.open_device(sighting).map_err(|_| Failure::Gave(FailKind::Unreachable))?;
        let mut announced = false;
        let mut tries: u64 = 0;
        let mut last_kind = FailKind::Timeout;
        while Instant::now() < deadline {
            if !self.drain_commands() {
                close_opened(opened);
                return Err(Failure::Cancelled);
            }
            let connected = opened.device.ConnectionStatus().is_ok_and(|s| s == BluetoothConnectionStatus::Connected);
            if connected && !announced {
                announced = true;
                self.diag(Diag::new(conn, "connected").at(millis(adv_at)));
                if let Ok(mtu) = opened.session.MaxPduSize() {
                    self.diag(Diag::new(conn, "mtu").at(millis(adv_at)).with("value", Value::U(u64::from(mtu))));
                }
            }
            tries += 1;
            let call_started = Instant::now();
            let discovery = find_service(&opened.device);
            let outcome = match &discovery {
                Ok(Some(_)) => "service",
                Ok(None) => "no_service",
                Err(kind) => kind.as_str(),
            };
            self.diag(
                Diag::new(conn, "gatt_discover")
                    .at(millis(adv_at))
                    .debug()
                    .with("try", Value::U(tries))
                    .with("took_ms", Value::U(millis(call_started)))
                    .with("result", Value::S(outcome)),
            );
            match discovery {
                Ok(Some(service)) => {
                    self.diag(Diag::new(conn, "discovered").at(millis(adv_at)).with("tries", Value::U(tries)));
                    return self.subscribe(conn, adv_at, opened, service);
                }
                Ok(None) => last_kind = FailKind::Unreachable,
                Err(kind) => last_kind = kind,
            }
            // Retry on the same object: Windows reconnects by itself but does not rerun a discovery call in progress.
            self.diag(Diag::new(conn, "retry").at(millis(adv_at)).debug().with("attempt", Value::U(tries)).with("kind", Value::S(last_kind.as_str())));
            std::thread::sleep(DISCOVERY_RETRY);
        }
        // Eight seconds and no service: the link is probably a stale one Windows kept. Let go of everything, so the next
        // advertisement opens it afresh.
        close_opened(opened);
        Err(Failure::Gave(last_kind))
    }

    fn subscribe(&mut self, conn: u64, adv_at: Instant, opened: Opened, service: GattDeviceService) -> Result<Link, Failure> {
        let fail = |opened: Opened, service: GattDeviceService, kind| {
            let _ = service.Close();
            close_opened(opened);
            Failure::Gave(kind)
        };
        let characteristic = |id: GUID| -> Option<GattCharacteristic> {
            let found = service.GetCharacteristicsForUuidWithCacheModeAsync(id, BluetoothCacheMode::Uncached).ok()?.get().ok()?;
            found.Characteristics().ok()?.GetAt(0).ok()
        };
        let (Some(event), Some(control)) = (characteristic(EVENT_CHARACTERISTIC), characteristic(CONTROL_CHARACTERISTIC)) else {
            return Err(fail(opened, service, FailKind::AttError));
        };
        let sender = self.events.clone();
        let gate = Arc::new(Mutex::new(NotificationGate::new()));
        let handler_gate = gate.clone();
        let value_token = match event
            .ValueChanged(&TypedEventHandler::new(move |_, args: windows::core::Ref<'_, GattValueChangedEventArgs>| {
                let buffer = args.ok()?.CharacteristicValue()?;
                let reader = DataReader::FromBuffer(&buffer)?;
                let mut bytes = vec![0u8; reader.UnconsumedBufferLength()? as usize];
                reader.ReadBytes(&mut bytes)?;
                // Anything that arrives before `Connected` has been announced waits in the gate. The lock is held while
                // sending, so the order the phone sent is the order the application sees.
                let mut gate = handler_gate.lock().unwrap_or_else(|p| p.into_inner());
                if let Offer::Deliver(bytes) = gate.offer(bytes) {
                    let _ = sender.blocking_send(LinkEvent::Notification { conn, bytes });
                }
                Ok(())
            })) {
            Ok(token) => token,
            Err(_) => return Err(fail(opened, service, FailKind::AttError)),
        };
        let subscribed = event
            .WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue::Notify)
            .and_then(|op| op.get());
        if subscribed.ok() != Some(GattCommunicationStatus::Success) {
            let _ = event.RemoveValueChanged(value_token);
            return Err(fail(opened, service, FailKind::AttError));
        }
        self.diag(Diag::new(conn, "subscribed").at(millis(adv_at)));
        let (lost_tx, lost) = std_mpsc::channel();
        let lost_tx = Mutex::new(lost_tx);
        let _ = opened.device.ConnectionStatusChanged(&TypedEventHandler::<BluetoothLEDevice, IInspectable>::new(move |device, _| {
            if device.ok()?.ConnectionStatus()? == BluetoothConnectionStatus::Disconnected {
                let _ = lost_tx.lock().unwrap_or_else(|p| p.into_inner()).send(());
            }
            Ok(())
        }));
        Ok(Link { device: opened.device, session: opened.session, service, event, control, _preferred: opened.preferred, value_token, lost, gate })
    }

    /// Runs one open link until it ends. `false` ends the worker.
    fn serve(&mut self, conn: u64, device: DeviceKey, route: Route, adv_at: Instant, link: Link) -> bool {
        let mtu = link.session.MaxPduSize().map_or(23, usize::from);
        {
            let mut gate = link.gate.lock().unwrap_or_else(|p| p.into_inner());
            if !self.emit(LinkEvent::Connected { conn, device, route, mtu }) {
                drop(gate);
                link.release();
                return false;
            }
            for bytes in gate.open() {
                self.emit(LinkEvent::Notification { conn, bytes });
            }
        }
        let reason = loop {
            if link.lost.try_recv().is_ok() {
                break DisconnectReason::LinkLost;
            }
            match self.commands.recv_timeout(Duration::from_millis(50)) {
                Ok(LinkCommand::Write(bytes)) => {
                    let started = Instant::now();
                    let result = write_control(&link.control, &bytes);
                    self.diag(
                        Diag::new(conn, "att_write")
                            .at(millis(adv_at))
                            .debug()
                            .with("len", Value::U(bytes.len() as u64))
                            .with("took_ms", Value::U(millis(started)))
                            .with("result", Value::S(result.as_ref().map_or_else(|kind| kind.as_str(), |()| "ok"))),
                    );
                    if let Err(kind) = result {
                        // A write that does not get through means the link is no longer there: end it, go back to scanning.
                        self.diag(Diag::new(conn, "write_failed").at(millis(adv_at)).with("kind", Value::S(kind.as_str())));
                        break DisconnectReason::LinkLost;
                    }
                }
                Ok(LinkCommand::Disconnect) => break DisconnectReason::Local,
                Ok(LinkCommand::Hold { device, for_ }) => {
                    self.scan.lock().unwrap_or_else(|p| p.into_inner()).holds.insert(device.0, Instant::now() + for_);
                }
                Ok(LinkCommand::SetPairingScan(on)) => self.scan.lock().unwrap_or_else(|p| p.into_inner()).pairing_on = on,
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                    link.release();
                    return false;
                }
            }
        };
        link.release();
        self.emit(LinkEvent::Disconnected { conn, device, reason })
    }
}

fn route_word(route: Route) -> &'static str {
    match route {
        Route::Selected => "selected",
        Route::Pairing => "pairing",
    }
}

fn close_opened(opened: Opened) {
    let _ = opened.session.SetMaintainConnection(false);
    let _ = opened.session.Close();
    let _ = opened.device.Close();
}

/// One discovery call. `Ok(None)` is "reachable but no service yet" and an error is Windows saying Unreachable.
fn find_service(device: &BluetoothLEDevice) -> Result<Option<GattDeviceService>, FailKind> {
    let result = device
        .GetGattServicesForUuidWithCacheModeAsync(SERVICE, BluetoothCacheMode::Uncached)
        .and_then(|op| op.get())
        .map_err(|_| FailKind::Unreachable)?;
    let status = result.Status().map_err(|_| FailKind::Unreachable)?;
    if status == GattCommunicationStatus::Unreachable {
        return Err(FailKind::Unreachable);
    }
    if status != GattCommunicationStatus::Success {
        return Err(FailKind::AttError);
    }
    let services = result.Services().map_err(|_| FailKind::AttError)?;
    if services.Size().unwrap_or(0) == 0 {
        return Ok(None);
    }
    Ok(services.GetAt(0).ok())
}

/// `control` takes Write Requests only (§1.1).
fn write_control(control: &GattCharacteristic, bytes: &[u8]) -> Result<(), FailKind> {
    let writer = DataWriter::new().map_err(|_| FailKind::AttError)?;
    writer.WriteBytes(bytes).map_err(|_| FailKind::AttError)?;
    let buffer = writer.DetachBuffer().map_err(|_| FailKind::AttError)?;
    let result = control
        .WriteValueWithResultAndOptionAsync(&buffer, GattWriteOption::WriteWithResponse)
        .and_then(|op| op.get())
        .map_err(|_| FailKind::LinkLost)?;
    match result.Status() {
        Ok(GattCommunicationStatus::Success) => Ok(()),
        Ok(GattCommunicationStatus::Unreachable) => Err(FailKind::LinkLost),
        _ => Err(FailKind::AttError),
    }
}

/// Runs the backend until the application drops its end of the channels. Commands still queued then (the `bye`, the
/// `Disconnect`) are carried out first, and the link is released before this returns, but for at most two seconds.
/// `cfg.adapter` is not used on Windows: WinRT takes the default radio.
pub async fn run(cfg: LinkConfig, tx: mpsc::Sender<LinkEvent>, rx: mpsc::Receiver<LinkCommand>) {
    let (command_tx, command_rx) = std_mpsc::channel();
    let (done_tx, done_rx) = oneshot::channel();
    let scan = Arc::new(Mutex::new(ScanFilter { select: guid(cfg.select), pairing: guid(cfg.pairing), pairing_on: false, holds: HashMap::new() }));
    let thread = std::thread::Builder::new().name("rk-ble".into()).spawn(move || {
        // The thread owns WinRT: multi-threaded apartment, initialised once.
        // SAFETY: RoInitialize has no preconditions beyond being called on the thread that will use WinRT.
        let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        Worker { events: tx, commands: command_rx, scan, next_conn: 1, failures: 0, scan_backoff: ScanBackoff::new(), reported_scan: None }.run();
        let _ = done_tx.send(());
    });
    if thread.is_err() {
        return;
    }
    pump_commands(rx, move |command| command_tx.send(command).is_ok(), done_rx, SHUTDOWN_GRACE).await;
}
