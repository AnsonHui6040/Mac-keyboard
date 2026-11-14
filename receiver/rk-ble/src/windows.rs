//! The Windows backend: WinRT `BluetoothLEAdvertisementWatcher` and `BluetoothLEDevice`, connected the way the WL1 debugging
//! showed to be reliable (docs/superpowers/verification/2026-11-10-windows-linux-receiver.md, "WL1 除錯"):
//!
//! 1. an active watcher, matching the service UUIDs of each single advertisement;
//! 2. the device opened with the advertisement's address type;
//! 3. a GATT session that maintains the connection, and ThroughputOptimized connection parameters held for the whole link;
//! 4. service discovery repeated on the same device object every 50 ms for up to 8 s, Unreachable and "no service" included;
//! 5. `event` subscribed, `control` written with Write Request only;
//! 6. a new advertisement during discovery means the old link was stale: everything is closed and opened afresh.
//!
//! WinRT calls block (`.get()`), so one dedicated thread owns the whole state machine and talks to the application through
//! channels. All of it is invisible to the logic tests; it is exercised on a real Windows machine.

use crate::diag::{Diag, FailKind, Value};
use crate::{DeviceKey, DisconnectReason, LinkCommand, LinkConfig, LinkEvent, Route};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use uuid::Uuid;
use windows::core::{IInspectable, GUID};
use windows::Devices::Bluetooth::Advertisement::{
    BluetoothLEAdvertisementReceivedEventArgs, BluetoothLEAdvertisementWatcher, BluetoothLEScanningMode,
};
use windows::Devices::Bluetooth::GenericAttributeProfile::{
    GattCharacteristic, GattClientCharacteristicConfigurationDescriptorValue, GattCommunicationStatus, GattDeviceService, GattSession,
    GattValueChangedEventArgs, GattWriteOption,
};
use windows::Devices::Bluetooth::{
    BluetoothAddressType, BluetoothCacheMode, BluetoothConnectionStatus, BluetoothLEDevice, BluetoothLEPreferredConnectionParameters,
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
/// A fresh advertisement only counts as proof of a stale link after the device has had this long to settle.
const STALE_LINK_GRACE: Duration = Duration::from_millis(300);
/// §1.5: the wait before scanning again after a connection failed before it became ready (ms), 2 s at most.
const RETRY_WAITS_MS: [u64; 4] = [0, 500, 1000, 2000];

fn guid(uuid: Uuid) -> GUID {
    GUID::from_u128(uuid.as_u128())
}

fn millis(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The scan filter the watcher callback reads and the worker changes.
struct ScanState {
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

fn start_watcher(scan: Arc<Mutex<ScanState>>, found: std_mpsc::Sender<Sighting>) -> windows::core::Result<BluetoothLEAdvertisementWatcher> {
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
    watcher.Start()?;
    Ok(watcher)
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

enum Failure {
    /// Give up on this attempt for the given reason.
    Gave(FailKind),
    /// The caller asked to disconnect while the link was being set up.
    Cancelled,
}

struct Worker {
    events: mpsc::Sender<LinkEvent>,
    commands: std_mpsc::Receiver<LinkCommand>,
    scan: Arc<Mutex<ScanState>>,
    next_conn: u64,
    failures: usize,
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

    /// Scans until a target advertises. `None` when the application has gone away.
    fn scan_until_found(&mut self) -> Option<Sighting> {
        let (tx, rx) = std_mpsc::channel();
        let watcher = start_watcher(self.scan.clone(), tx).ok()?;
        let found = loop {
            if !self.drain_commands() {
                break None;
            }
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(sighting) => break Some(sighting),
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => break None,
            }
        };
        let _ = watcher.Stop();
        found
    }

    /// One attempt from advertisement to hang-up. `false` ends the worker.
    fn connect_and_serve(&mut self, conn: u64, sighting: Sighting) -> bool {
        let adv_at = Instant::now();
        let device_key = DeviceKey(sighting.address);
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

    /// Steps 2 to 5 of the module comment. Retries on the same device object; a fresh advertisement reopens everything.
    fn open_link(&mut self, conn: u64, sighting: &Sighting, adv_at: Instant) -> Result<Link, Failure> {
        // A second watcher only listens for the same device advertising again while this link is being built.
        let (stale_tx, stale_rx) = std_mpsc::channel();
        let watcher = start_watcher(self.scan.clone(), stale_tx).map_err(|_| Failure::Gave(FailKind::Unreachable))?;
        let result = self.open_link_inner(conn, sighting, adv_at, &stale_rx);
        let _ = watcher.Stop();
        result
    }

    fn open_link_inner(&mut self, conn: u64, sighting: &Sighting, adv_at: Instant, stale: &std_mpsc::Receiver<Sighting>) -> Result<Link, Failure> {
        let deadline = Instant::now() + DISCOVERY_DEADLINE;
        let mut attempt: u64 = 0;
        let mut last_kind = FailKind::Timeout;
        'reopen: loop {
            if attempt > 0 {
                self.diag(Diag::new(conn, "retry").at(millis(adv_at)).with("attempt", Value::U(attempt)).with("kind", Value::S(last_kind.as_str())));
            }
            attempt += 1;
            let opened = self.open_device(sighting).map_err(|_| Failure::Gave(FailKind::Unreachable))?;
            let opened_at = Instant::now();
            let mut announced = false;
            let mut tries: u64 = 0;
            while Instant::now() < deadline {
                if !self.drain_commands() {
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
                if stale.try_iter().any(|s| s.address == sighting.address) && opened_at.elapsed() > STALE_LINK_GRACE {
                    // The phone advertises again, so Windows is holding a link the phone no longer has.
                    last_kind = FailKind::LinkLost;
                    close_opened(opened);
                    continue 'reopen;
                }
                std::thread::sleep(DISCOVERY_RETRY);
            }
            close_opened(opened);
            return Err(Failure::Gave(last_kind));
        }
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
        let value_token = match event
            .ValueChanged(&TypedEventHandler::new(move |_, args: windows::core::Ref<'_, GattValueChangedEventArgs>| {
                let buffer = args.ok()?.CharacteristicValue()?;
                let reader = DataReader::FromBuffer(&buffer)?;
                let mut bytes = vec![0u8; reader.UnconsumedBufferLength()? as usize];
                reader.ReadBytes(&mut bytes)?;
                let _ = sender.blocking_send(LinkEvent::Notification(bytes));
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
        Ok(Link { device: opened.device, session: opened.session, service, event, control, _preferred: opened.preferred, value_token, lost })
    }

    /// Runs one open link until it ends. `false` ends the worker.
    fn serve(&mut self, conn: u64, device: DeviceKey, route: Route, adv_at: Instant, link: Link) -> bool {
        let mtu = link.session.MaxPduSize().map_or(23, usize::from);
        if !self.emit(LinkEvent::Connected { conn, device, route, mtu }) {
            link.release();
            return false;
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
                        self.diag(Diag::new(conn, "write_failed").at(millis(adv_at)).with("kind", Value::S(kind.as_str())));
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

/// Runs the backend until the application drops its end of the channels. `cfg.adapter` is not used on Windows: WinRT takes
/// the default radio.
pub async fn run(cfg: LinkConfig, tx: mpsc::Sender<LinkEvent>, mut rx: mpsc::Receiver<LinkCommand>) {
    let (command_tx, command_rx) = std_mpsc::channel();
    let scan = Arc::new(Mutex::new(ScanState { select: guid(cfg.select), pairing: guid(cfg.pairing), pairing_on: false, holds: HashMap::new() }));
    let alive = Arc::new(AtomicBool::new(true));
    let worker_alive = alive.clone();
    let thread = std::thread::Builder::new().name("rk-ble".into()).spawn(move || {
        // The thread owns WinRT: multi-threaded apartment, initialised once.
        // SAFETY: RoInitialize has no preconditions beyond being called on the thread that will use WinRT.
        let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        Worker { events: tx, commands: command_rx, scan, next_conn: 1, failures: 0 }.run();
        worker_alive.store(false, Ordering::SeqCst);
    });
    if thread.is_err() {
        return;
    }
    while let Some(command) = rx.recv().await {
        if command_tx.send(command).is_err() || !alive.load(Ordering::SeqCst) {
            break;
        }
    }
}
