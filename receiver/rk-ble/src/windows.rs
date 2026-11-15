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
//! 7. while a link made through the selected UUID is open a second watcher keeps running, and an advertisement of the
//!    selected UUID from the same phone, more than a second after `subscribed`, makes the link stale: it is released at
//!    once and that advertiser is connected to (`stale.rs`).
//!
//! WinRT calls block (`.get()`), so one dedicated thread owns the whole state machine and talks to the application through
//! channels. All of it is invisible to the logic tests; it is exercised on a real Windows machine.

use crate::diag::{Diag, FailKind, Value};
use crate::flow::{drain_then_admit, pump_commands, settle_attempt, NotificationGate, Offer, ScanBackoff, ScanSwitch, Settled};
use crate::stale::{age_at, is_stale_link, Advert, HeldLink, WatchRestart};
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
/// A scan counts as running once the watcher has stayed in `Started` this long without being stopped (with the radio off
/// it starts and is aborted straight away) or once it has seen an advertisement.
const SCAN_CONFIRM_AFTER: Duration = Duration::from_millis(500);
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
    /// When the advertisement arrived (the stale-link grace counts to here, not to when it is looked at).
    seen_at: Instant,
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
        let _ = found.send(Sighting { address, address_type: args.BluetoothAddressType()?, route, seen_at: Instant::now() });
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
    /// When `event` was subscribed: the stale-link rule counts from here.
    subscribed_at: Instant,
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
    /// The application switched scanning off (`SetScanning(false)`).
    Paused,
    /// The application is gone.
    Gone,
}

/// How one link ended, for the loop that runs them.
enum Served {
    /// Back to scanning.
    Ended,
    /// The application is gone.
    Quit,
    /// The link was stale: connect to the phone that advertised, at once.
    Reconnect(Sighting),
}

impl Served {
    fn of(keep_going: bool) -> Self {
        if keep_going {
            Self::Ended
        } else {
            Self::Quit
        }
    }
}

enum Failure {
    /// Give up on this attempt for the given reason.
    Gave(FailKind),
    /// The caller asked to disconnect while the link was being set up.
    Cancelled,
    /// Receiving was switched off while the link was being set up: given up without a trace of failure.
    Stopped,
}

struct Worker {
    events: mpsc::Sender<LinkEvent>,
    commands: std_mpsc::Receiver<LinkCommand>,
    scan: Arc<Mutex<ScanFilter>>,
    /// The application's receive switch; while it is off nothing here scans or connects.
    switch: ScanSwitch,
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
                Ok(LinkCommand::SetScanning(on)) => self.switch.apply(&LinkCommand::SetScanning(on)),
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
        let mut reconnect: Option<Sighting> = None;
        loop {
            if !self.drain_commands() {
                return;
            }
            // A stale link was replaced: its advertiser is the next target, no scan in between (unless receiving was
            // switched off meanwhile).
            let Ok(replacement) = drain_then_admit(&mut self, Worker::drain_commands, |worker| &worker.switch, reconnect.take()) else { return };
            let sighting = match replacement {
                Some(sighting) => sighting,
                None => match self.scan_until_found() {
                    Some(sighting) => sighting,
                    None => return,
                },
            };
            // Found just as scanning was switched off: let it go.
            let Ok(Some(sighting)) = drain_then_admit(&mut self, Worker::drain_commands, |worker| &worker.switch, Some(sighting)) else { continue };
            let conn = self.next_conn;
            self.next_conn += 1;
            match self.connect_and_serve(conn, sighting) {
                Served::Quit => return,
                Served::Reconnect(next) => reconnect = Some(next),
                Served::Ended => {}
            }
        }
    }

    /// Scans until a target advertises. A scan that cannot start or is stopped by the system is reported, waited out with a
    /// growing pause and started again. `None` when the application has gone away.
    fn scan_until_found(&mut self) -> Option<Sighting> {
        loop {
            if !self.park() {
                return None;
            }
            let (tx, rx) = std_mpsc::channel();
            let failure = match start_watcher(self.scan.clone(), tx) {
                Err(_) => ScanFailure::Unavailable,
                Ok((watcher, stopped_because)) => {
                    let outcome = self.watch(&watcher, &stopped_because, &rx);
                    let _ = watcher.Stop();
                    match outcome {
                        Watched::Found(sighting) => return Some(sighting),
                        Watched::Gone => return None,
                        // Back to the top: the switch is off, so `park` waits there and no new watcher starts.
                        Watched::Paused => continue,
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

    /// While the application has switched receiving off: no watcher, no retry timer; only commands are waited for. `false`
    /// when the application is gone.
    fn park(&mut self) -> bool {
        while !self.switch.is_on() {
            if !self.wait(Duration::from_millis(100)) {
                return false;
            }
        }
        true
    }

    fn watch(&mut self, watcher: &BluetoothLEAdvertisementWatcher, stopped_because: &StopReason, found: &std_mpsc::Receiver<Sighting>) -> Watched {
        let started = Instant::now();
        let mut confirmed = false;
        loop {
            if !self.drain_commands() {
                return Watched::Gone;
            }
            if !self.switch.is_on() {
                return Watched::Paused;
            }
            match found.recv_timeout(Duration::from_millis(100)) {
                Ok(sighting) => {
                    self.confirm_scan(&mut confirmed);
                    return Watched::Found(sighting);
                }
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => return Watched::Gone,
            }
            let status = watcher.Status().ok();
            let aborted = status == Some(BluetoothLEAdvertisementWatcherStatus::Aborted);
            let reason = stopped_because.lock().unwrap_or_else(|p| p.into_inner()).take();
            if let Some(failure) = reason.or(aborted.then_some(ScanFailure::Aborted)) {
                return Watched::Failed(failure);
            }
            if !confirmed && started.elapsed() >= SCAN_CONFIRM_AFTER && status == Some(BluetoothLEAdvertisementWatcherStatus::Started) {
                self.confirm_scan(&mut confirmed);
            }
        }
    }

    /// Scanning is really running: the backoff starts over, and an outage that was reported is over.
    fn confirm_scan(&mut self, confirmed: &mut bool) {
        if std::mem::replace(confirmed, true) {
            return;
        }
        self.scan_backoff.reset();
        if self.reported_scan.take().is_some() {
            self.emit(LinkEvent::Scan(ScanState::Running));
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
    fn connect_and_serve(&mut self, conn: u64, sighting: Sighting) -> Served {
        let adv_at = Instant::now();
        let device_key = DeviceKey(sighting.address);
        // A hold may have been set between the advertisement and now (the previous connection of this device just ended).
        let held = self.scan.lock().unwrap_or_else(|p| p.into_inner()).holds.get(&sighting.address).is_some_and(|until| *until > adv_at);
        if held {
            self.diag(Diag::new(conn, "held_skip").debug().with("device", Value::Id(device_key.short())));
            return Served::Ended;
        }
        self.diag(Diag::new(conn, "adv_seen").at(0).with("device", Value::Id(device_key.short())).with("route", Value::S(route_word(sighting.route))));
        self.diag(Diag::new(conn, "connect_start").at(millis(adv_at)));
        let result = self.open_link(conn, &sighting, adv_at);
        // Whatever was queued while the last step ran counts before `Connected` is announced.
        if !self.drain_commands() {
            if let Ok(link) = result {
                link.release();
            }
            return Served::Quit;
        }
        match settle_attempt(&self.switch, result) {
            Settled::Opened(link) => {
                self.failures = 0;
                self.serve(conn, device_key, sighting.route, adv_at, link)
            }
            Settled::Cancelled(link) => {
                if let Some(link) = link {
                    link.release();
                }
                self.cancelled(conn, adv_at)
            }
            // Stopped and started again while the attempt ran: the attempt was still given up.
            Settled::Failed(Failure::Stopped) => self.cancelled(conn, adv_at),
            Settled::Failed(Failure::Gave(kind)) => {
                self.diag(Diag::new(conn, "connect_failed").at(millis(adv_at)).with("kind", Value::S(kind.as_str())));
                let wait = RETRY_WAITS_MS[self.failures.min(RETRY_WAITS_MS.len() - 1)];
                self.failures += 1;
                Served::of(self.emit(LinkEvent::Disconnected { conn, device: device_key, reason: DisconnectReason::Failed(kind) }) && self.wait(Duration::from_millis(wait)))
            }
            Settled::Failed(Failure::Cancelled) => Served::of(self.emit(LinkEvent::Disconnected { conn, device: device_key, reason: DisconnectReason::Local })),
        }
    }

    /// The attempt was given up because receiving is off: no `Connected`, no failure count, no back-off.
    fn cancelled(&self, conn: u64, adv_at: Instant) -> Served {
        Served::of(self.diag(Diag::new(conn, "connect_cancelled").at(millis(adv_at)).with("why", Value::S("stopped"))))
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
        // Stopped while the device object was being made (this can take a while): let go at once.
        if !self.drain_commands() {
            close_opened(opened);
            return Err(Failure::Cancelled);
        }
        if !self.switch.is_on() {
            close_opened(opened);
            return Err(Failure::Stopped);
        }
        let mut announced = false;
        let mut tries: u64 = 0;
        let mut last_kind = FailKind::Timeout;
        while Instant::now() < deadline {
            if !self.drain_commands() {
                close_opened(opened);
                return Err(Failure::Cancelled);
            }
            if !self.switch.is_on() {
                close_opened(opened);
                return Err(Failure::Stopped);
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
        let subscribed_at = Instant::now();
        let (lost_tx, lost) = std_mpsc::channel();
        let lost_tx = Mutex::new(lost_tx);
        let _ = opened.device.ConnectionStatusChanged(&TypedEventHandler::<BluetoothLEDevice, IInspectable>::new(move |device, _| {
            if device.ok()?.ConnectionStatus()? == BluetoothConnectionStatus::Disconnected {
                let _ = lost_tx.lock().unwrap_or_else(|p| p.into_inner()).send(());
            }
            Ok(())
        }));
        Ok(Link { device: opened.device, session: opened.session, service, event, control, _preferred: opened.preferred, value_token, lost, gate, subscribed_at })
    }

    /// Runs one open link until it ends.
    fn serve(&mut self, conn: u64, device: DeviceKey, route: Route, adv_at: Instant, link: Link) -> Served {
        let mtu = link.session.MaxPduSize().map_or(23, usize::from);
        {
            let mut gate = link.gate.lock().unwrap_or_else(|p| p.into_inner());
            if !self.emit(LinkEvent::Connected { conn, device, route, mtu }) {
                drop(gate);
                link.release();
                return Served::Quit;
            }
            for bytes in gate.open() {
                self.emit(LinkEvent::Notification { conn, bytes });
            }
        }
        // The phone advertises its selected UUID only while no central is subscribed: seeing it again means it has let go of
        // this link, which Windows would keep for about ten more seconds. The scan runs next to the link for that.
        let (seen_tx, seen) = std_mpsc::channel();
        let mut watching = if route == Route::Selected { start_watcher(self.scan.clone(), seen_tx.clone()).ok() } else { None };
        let mut restart = WatchRestart::default();
        let mut replaced = None;
        let reason = loop {
            if link.lost.try_recv().is_ok() {
                break DisconnectReason::LinkLost;
            }
            // A watcher the system stopped is started again once, after a pause; a second stop turns stale detection off.
            if watching.as_ref().is_some_and(|(watcher, why)| watcher_stopped(watcher, why)) {
                stop_watching(watching.take());
                let state = if restart.stopped(Instant::now()) { "restarting" } else { "unavailable" };
                self.diag(Diag::new(conn, "stale_watch").at(millis(adv_at)).with("state", Value::S(state)));
            }
            if watching.is_none() && restart.due(Instant::now()) {
                watching = start_watcher(self.scan.clone(), seen_tx.clone()).ok();
                let state = if watching.is_some() { "restarted" } else { "unavailable" };
                self.diag(Diag::new(conn, "stale_watch").at(millis(adv_at)).with("state", Value::S(state)));
            }
            if let Some(sighting) = self.stale_advert(&seen, device, route, link.subscribed_at) {
                self.diag(Diag::new(conn, "stale_link").at(millis(adv_at)).with("ms", Value::U(millis(link.subscribed_at))));
                replaced = Some(sighting);
                break DisconnectReason::StaleAdvert;
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
                Ok(LinkCommand::SetScanning(on)) => self.switch.apply(&LinkCommand::SetScanning(on)),
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                    stop_watching(watching);
                    link.release();
                    return Served::Quit;
                }
            }
        };
        stop_watching(watching);
        link.release();
        if !self.emit(LinkEvent::Disconnected { conn, device, reason }) {
            return Served::Quit;
        }
        replaced.map_or(Served::Ended, Served::Reconnect)
    }

    /// The first advertisement of what the watcher has seen that makes the held link stale.
    fn stale_advert(&self, seen: &std_mpsc::Receiver<Sighting>, device: DeviceKey, route: Route, subscribed_at: Instant) -> Option<Sighting> {
        seen.try_iter().find(|s| {
            let link = HeldLink { route, device, subscribed_for: Some(age_at(subscribed_at, s.seen_at)) };
            is_stale_link(link, Advert { device: DeviceKey(s.address), route: Some(s.route) })
        })
    }
}

/// The system stopped the watcher (radio off, an error): it no longer reports anything.
fn watcher_stopped(watcher: &BluetoothLEAdvertisementWatcher, why: &StopReason) -> bool {
    why.lock().unwrap_or_else(|p| p.into_inner()).is_some() || watcher.Status().is_ok_and(|status| status == BluetoothLEAdvertisementWatcherStatus::Aborted)
}

fn stop_watching(watching: Option<(BluetoothLEAdvertisementWatcher, StopReason)>) {
    if let Some((watcher, _)) = watching {
        let _ = watcher.Stop();
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
        Worker { events: tx, commands: command_rx, scan, switch: ScanSwitch::new(), next_conn: 1, failures: 0, scan_backoff: ScanBackoff::new(), reported_scan: None }.run();
        let _ = done_tx.send(());
    });
    if thread.is_err() {
        return;
    }
    pump_commands(rx, move |command| command_tx.send(command).is_ok(), done_rx, SHUTDOWN_GRACE).await;
}
