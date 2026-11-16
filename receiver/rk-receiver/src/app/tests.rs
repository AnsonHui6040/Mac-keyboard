//! The application driven the way the radio and the tray drive it: a fake link, a recording injector, an in-memory store,
//! a clock the test moves and a phone built from `rk_core`.

use super::*;
use crate::clock::FakeClock;
use crate::config::Config;
use crate::log::{Level, MemorySink};
use crate::random::SequenceRandom;
use crate::store::{MemoryConfigStore, MemoryPhoneStore, StoreError};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rk_ble::fake::FakeLink;
use rk_ble::{DeviceKey, DisconnectReason, ScanFailure, ScanState};
use rk_core::channel::{derive_probe_key, ChannelSet, ProbeOpener};
use rk_core::frame::split_frames;
use rk_core::handshake::{PhoneHandshake, PhoneOutput};
use rk_core::identity::{HostPlatform, PairedPhone, PhoneIdentity, PhonePlatform};
use rk_core::message::{
    decode_control, encode_peripheral, Ack, AckResult, ControlMessage, EventKind, KeyboardEvent, PeripheralMessage,
    ReceiverStatus, WifiOffer,
};
use rk_core::pairing::{PhonePairing, PhonePairingOutput};
use rk_core::pointer::{Opcode, PointerPayload};
use rk_core::secret::PairKey;
use rk_inject::{Button, Call, RecordingInjector};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use uuid::Uuid;

const T0: u64 = 1_794_651_630_123;
const HOST_ID: [u8; 16] = [0x21; 16];
const DEVICE: DeviceKey = DeviceKey(0xA1);
const PHONE_NONCE: [u8; 16] = [0xB0; 16];

struct Rig {
    app: App,
    link: FakeLink,
    clock: Arc<FakeClock>,
    logs: MemorySink,
    injector: RecordingInjector,
    store: MemoryPhoneStore,
    configs: MemoryConfigStore,
    ui: Vec<UiEvent>,
    message_id: u16,
    nonce: u8,
    stash: Vec<ControlMessage>,
    /// What the application asked the runner to send on the network, in order.
    wifi: Vec<(Vec<SocketAddrV4>, Vec<u8>)>,
    /// The `hostNonce` of the last `hello` the host wrote.
    host_nonce: [u8; 16],
}

impl Rig {
    fn new() -> Self {
        Self::with_level(Level::Info)
    }

    fn with_level(level: Level) -> Self {
        Self::build(level, false)
    }

    /// A receiver started with `--pair`: the pairing window opens at start-up.
    fn with_pairing_at_start() -> Self {
        Self::build(Level::Info, true)
    }

    fn build(level: Level, pair_at_start: bool) -> Self {
        Self::build_with(level, pair_at_start, None)
    }

    /// A receiver whose key store is `store` (a stand-in for a keyring that can be locked).
    fn with_store(store: Box<dyn PhoneStore>) -> Self {
        Self::build_with(Level::Info, false, Some(store))
    }

    fn build_with(level: Level, pair_at_start: bool, custom_store: Option<Box<dyn PhoneStore>>) -> Self {
        let clock = Arc::new(FakeClock::new(T0));
        let logs = MemorySink::new();
        let logger = Logger::new(Box::new(logs.clone()), clock.clone(), level);
        let injector = RecordingInjector::new();
        let store = MemoryPhoneStore::new();
        let configs = MemoryConfigStore::new();
        let app = App::new(AppDeps {
            config: Config::new(HOST_ID, HostPlatform::Windows),
            platform: HostPlatform::Windows,
            store: custom_store.unwrap_or_else(|| Box::new(store.clone())),
            config_store: Box::new(configs.clone()),
            injector: Box::new(injector.clone()),
            clock: clock.clone(),
            random: Box::new(SequenceRandom::default()),
            logger,
            pair_at_start,
        });
        let mut rig = Self {
            app,
            link: FakeLink::new(),
            clock,
            logs,
            injector,
            store,
            configs,
            ui: Vec::new(),
            message_id: 0,
            nonce: 0,
            stash: Vec::new(),
            wifi: Vec::new(),
            host_nonce: [0; 16],
        };
        let effects = rig.app.start();
        rig.run(effects);
        rig
    }

    fn run(&mut self, effects: Vec<Effect>) {
        let mut pending: Vec<LinkEvent> = Vec::new();
        for effect in effects {
            match effect {
                Effect::Link(command) => pending.extend(self.link.apply(command)),
                Effect::Ui(event) => self.ui.push(event),
                Effect::Wifi(WifiCommand::Send { to, bytes }) => self.wifi.push((to, bytes)),
            }
        }
        for event in pending {
            self.deliver(event);
        }
    }

    fn link_drops(&mut self, reason: DisconnectReason) {
        if let Some(event) = self.link.drop_link(reason) {
            self.deliver(event);
        }
    }

    fn deliver(&mut self, event: LinkEvent) {
        let effects = self.app.on_link(event);
        self.run(effects);
    }

    fn command(&mut self, command: UiCommand) {
        let effects = self.app.on_ui(command);
        self.run(effects);
    }

    fn advance(&mut self, ms: u64) {
        self.clock.advance(ms);
        let effects = self.app.on_tick();
        self.run(effects);
    }

    fn connect(&mut self, route: Route) {
        for event in self.link.connect(DEVICE, route, 185) {
            self.deliver(event);
        }
    }

    fn phone_sends(&mut self, message: &PeripheralMessage) {
        self.send_raw(&encode_peripheral(message));
    }

    fn send_raw(&mut self, bytes: &[u8]) {
        self.message_id = self.message_id.wrapping_add(1);
        for frame in split_frames(bytes, self.message_id, 185).unwrap() {
            let event = self.link.notify(frame);
            self.deliver(event);
        }
    }

    /// The user answers the pairing question that was asked last.
    fn confirm(&mut self, accepted: bool) {
        let attempt = self.last_attempt();
        self.command(UiCommand::ConfirmPairing(attempt, accepted));
    }

    fn last_attempt(&self) -> u64 {
        self.ui
            .iter()
            .rev()
            .find_map(|e| if let UiEvent::PairingRequest { attempt, .. } = e { Some(*attempt) } else { None })
            .expect("a pairing question was asked")
    }

    fn notify(&mut self, bytes: Vec<u8>) {
        let event = self.link.notify(bytes);
        self.deliver(event);
    }

    fn writes(&mut self) -> Vec<ControlMessage> {
        let writes = self.link.take_writes();
        writes.iter().map(|w| decode_control(w).expect("the host wrote a control message")).collect()
    }

    fn next_nonce(&mut self) -> [u8; 12] {
        self.nonce += 1;
        [self.nonce; 12]
    }

    fn pair_phone(&self, n: u8) -> PairedPhone {
        let phone = PairedPhone {
            identity: PhoneIdentity { id: [n; 16], name: format!("Phone {n}"), platform: PhonePlatform::Ios },
            pair_key: PairKey::new([n; 32]),
        };
        self.store.clone().save(phone.clone()).unwrap();
        phone
    }

    /// A stored phone connects through the selected UUID and authenticates; returns the phone's side.
    fn authenticate(&mut self, key: &PairKey) -> PhoneHandshake {
        self.connect(Route::Selected);
        let mut phone = PhoneHandshake::new(Some((HOST_ID, key.clone())), PHONE_NONCE);
        let hello = self.writes().remove(0);
        if let ControlMessage::Hello { host_nonce, .. } = &hello {
            self.host_nonce = host_nonce.as_slice().try_into().expect("a 16-byte nonce");
        }
        let PhoneOutput::Send(reply) = phone.receive(&hello) else { panic!("helloReply expected") };
        self.phone_sends(&reply);
        for message in self.writes() {
            match phone.receive(&message) {
                PhoneOutput::Authenticated => {}
                PhoneOutput::Deliver(inner) => self.stash.push(inner),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert!(phone.can_send_events());
        phone
    }

    fn send_event(&mut self, phone: &PhoneHandshake, seq: u64, kind: EventKind) -> KeyboardEvent {
        let event = event(seq, kind);
        self.send_existing_event(phone, &event);
        event
    }

    fn send_existing_event(&mut self, phone: &PhoneHandshake, event: &KeyboardEvent) {
        let nonce = self.next_nonce();
        self.phone_sends(&phone.seal_event(event, &nonce).unwrap());
    }

    /// The inner messages the host sealed for the phone since last asked.
    fn inner_messages(&mut self, phone: &mut PhoneHandshake) -> Vec<ControlMessage> {
        let mut inner = std::mem::take(&mut self.stash);
        inner.extend(self.writes().iter().filter_map(|m| match phone.receive(m) {
            PhoneOutput::Deliver(inner) => Some(inner),
            _ => None,
        }));
        inner
    }

    fn acks(&mut self, phone: &mut PhoneHandshake) -> Vec<Ack> {
        self.inner_messages(phone).into_iter().filter_map(|m| if let ControlMessage::Ack(a) = m { Some(a) } else { None }).collect()
    }

    fn last_status(&mut self, phone: &mut PhoneHandshake) -> ReceiverStatus {
        self.inner_messages(phone)
            .into_iter()
            .rev()
            .find_map(|m| if let ControlMessage::Status(s) = m { Some(s) } else { None })
            .expect("a status was sent")
    }

    /// Runs the phone's side of a pairing up to the host asking for confirmation; returns the pairing code.
    fn pair_up_to_confirmation(&mut self, phone_name: &str) -> (PhonePairing, String) {
        self.command(UiCommand::StartPairing);
        self.connect(Route::Pairing);
        let identity = PhoneIdentity { id: [0x77; 16], name: phone_name.into(), platform: PhonePlatform::Ios };
        let mut pairing = PhonePairing::new([0x42; 32], identity).unwrap();
        self.phone_sends(&pairing.offer());
        let accept = self.writes().remove(0);
        let PhonePairingOutput::Send(reveal) = pairing.receive(&accept) else { panic!("pairReveal expected") };
        self.phone_sends(&reveal);
        let sas = self
            .ui
            .iter()
            .rev()
            .find_map(|e| if let UiEvent::PairingRequest { sas, .. } = e { Some(sas.clone()) } else { None })
            .expect("the host asks for confirmation");
        assert_eq!(Some(sas.as_str()), pairing.sas());
        (pairing, sas)
    }

    fn notices(&self) -> Vec<NoticeKind> {
        self.ui.iter().filter_map(|e| if let UiEvent::Notice(k) = e { Some(*k) } else { None }).collect()
    }

    fn last_tray(&self) -> TrayState {
        self.ui.iter().rev().find_map(|e| if let UiEvent::State(s) = e { Some(s.clone()) } else { None }).expect("a tray state")
    }

    fn log_text(&self) -> String {
        self.logs.lines().join("\n")
    }
}

fn event(seq: u64, kind: EventKind) -> KeyboardEvent {
    KeyboardEvent { event_id: Uuid::from_u128(0xE000 + u128::from(seq)), session_id: Uuid::from_u128(0x5E55), seq, focus_epoch: Some(1), kind }
}

fn is_auth_failed(m: &ControlMessage) -> bool {
    matches!(m, ControlMessage::AuthFailed)
}

// ---------------------------------------------------------------- identity and configuration

#[test]
fn rename_keeps_host_id_and_phones() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.command(UiCommand::Rename("書房的電腦".into()));
    let saved = rig.configs.last().expect("the configuration was saved");
    assert_eq!(saved.host_name, "書房的電腦");
    assert_eq!(saved.host_id, HOST_ID);
    assert_eq!(rig.store.phones().len(), 1);
    assert_eq!(rig.last_tray().host_name, "書房的電腦");
    // The name is cut to 32 bytes and an empty one falls back to the default.
    rig.command(UiCommand::Rename("測".repeat(11)));
    assert_eq!(rig.configs.last().unwrap().host_name, "測".repeat(10));
    rig.command(UiCommand::Rename("  ".into()));
    assert_eq!(rig.configs.last().unwrap().host_name, "Windows");
}

#[test]
fn choosing_a_bluetooth_controller_is_saved_and_the_link_config_follows() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetAdapter(Some("hci1".into())));
    assert_eq!(rig.configs.last().unwrap().adapter.as_deref(), Some("hci1"));
    assert_eq!(rig.app.link_config().adapter.as_deref(), Some("hci1"));
    rig.command(UiCommand::SetAdapter(None));
    assert_eq!(rig.configs.last().unwrap().adapter, None);
}

/// A key store that cannot be read while `locked` is set.
#[derive(Clone)]
struct LockableStore {
    inner: MemoryPhoneStore,
    locked: Arc<AtomicBool>,
    unlocks: Arc<std::sync::atomic::AtomicU32>,
}

impl PhoneStore for LockableStore {
    fn phones(&self) -> Vec<PairedPhone> {
        if self.locked.load(Ordering::SeqCst) { Vec::new() } else { self.inner.phones() }
    }
    fn unavailable(&self) -> bool {
        self.locked.load(Ordering::SeqCst)
    }
    fn unlock_keys(&self) {
        self.unlocks.fetch_add(1, Ordering::SeqCst);
    }
    fn save(&mut self, p: PairedPhone) -> Result<(), StoreError> {
        self.inner.save(p)
    }
    fn delete(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        self.inner.delete(id)
    }
}

#[test]
fn a_stale_link_that_the_backend_replaces_hands_over_to_the_new_connection_without_a_hold() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let _phone = rig.authenticate(&stored.pair_key);
    assert_eq!(rig.last_tray().connected_phone.as_deref(), Some("Phone 1"));
    // The keyboard was dismissed: the phone advertises its selected UUID again while the old link is still held.
    for event in rig.link.advert_while_connected(DEVICE, Some(Route::Selected), Duration::from_secs(5), 185) {
        rig.deliver(event);
    }
    assert!(rig.link.holds().is_empty(), "the phone is not held off: it is the one to connect to");
    assert!(rig.last_tray().connected_phone.is_none(), "the old link is gone until the new one authenticates");
    let lines = rig.logs.lines().join("\n");
    assert!(lines.contains("reason=stale_advert"), "{lines}");
    // The new connection is greeted like any other, with a hello and no authFailed.
    let writes = rig.writes();
    assert!(!writes.is_empty() && !writes.iter().any(is_auth_failed));
}

#[test]
fn reauthorize_asks_the_injector_for_a_new_grant() {
    let mut rig = Rig::new();
    rig.command(UiCommand::Reauthorize);
    assert_eq!(rig.injector.calls(), vec![Call::Reauthorize]);
}

#[test]
fn the_paste_option_is_saved_and_handed_to_the_injector() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetPasteNonAscii(true));
    rig.command(UiCommand::SetPasteNonAscii(false));
    assert_eq!(rig.injector.calls(), vec![Call::SetPasteNonAscii(true), Call::SetPasteNonAscii(false)]);
    assert!(!rig.configs.last().unwrap().paste_non_ascii);
    assert!(!rig.last_tray().paste_non_ascii);
}

#[test]
fn the_tray_asks_for_authorization_while_the_injector_is_not_trusted() {
    let mut rig = Rig::new();
    assert!(!rig.last_tray().needs_authorization);
    rig.injector.set_ready(false);
    rig.injector.set_trusted(false);
    rig.advance(10);
    let tray = rig.last_tray();
    assert!(tray.needs_authorization);
    assert_eq!(tray.icon, IconState::Attention);
    rig.injector.set_ready(true);
    rig.injector.set_trusted(true);
    rig.advance(10);
    let tray = rig.last_tray();
    assert!(!tray.needs_authorization);
    assert_eq!(tray.icon, IconState::Disconnected);
}

#[test]
fn an_idle_receiver_with_a_working_injector_plans_no_wake_up() {
    // Windows is always trusted: nothing to look at, so no timer runs while nobody is connected.
    let rig = Rig::new();
    assert_eq!(rig.app.next_wake_ms(), None);
}

#[test]
fn while_the_injector_is_not_trusted_the_receiver_looks_at_it_twice_a_second() {
    let rig = Rig::new();
    rig.injector.set_trusted(false);
    let wake = rig.app.next_wake_ms().expect("a wake-up is planned");
    assert!(wake <= rig.app.now() + 500, "{wake}");
}

#[test]
fn while_the_keyring_is_down_the_receiver_wakes_to_see_it_come_back() {
    let locked = Arc::new(AtomicBool::new(true));
    let mut rig = Rig::with_store(Box::new(LockableStore { inner: MemoryPhoneStore::new(), locked: locked.clone(), unlocks: Arc::default() }));
    let wake = rig.app.next_wake_ms().expect("a wake-up is planned while the keyring is down");
    assert!(wake <= rig.app.now() + 1_000, "{wake}");
    locked.store(false, Ordering::SeqCst);
    rig.advance(1_000);
    assert_eq!(rig.last_tray().icon, IconState::Disconnected);
    assert_eq!(rig.app.next_wake_ms(), None, "nothing left to wait for");
}

#[test]
fn starting_to_pair_asks_the_key_store_to_unlock() {
    let locked = Arc::new(AtomicBool::new(true));
    let store = LockableStore { inner: MemoryPhoneStore::new(), locked, unlocks: Arc::default() };
    let unlocks = store.unlocks.clone();
    let mut rig = Rig::with_store(Box::new(store));
    assert_eq!(unlocks.load(Ordering::SeqCst), 0, "nothing asks the user until they ask for something");
    rig.command(UiCommand::StartPairing);
    assert_eq!(unlocks.load(Ordering::SeqCst), 1);
}

#[test]
fn a_keyring_that_cannot_be_read_gives_one_notice_and_the_phones_return_when_it_opens() {
    let inner = MemoryPhoneStore::new();
    let locked = Arc::new(AtomicBool::new(true));
    let mut rig = Rig::with_store(Box::new(LockableStore { inner: inner.clone(), locked: locked.clone(), unlocks: Arc::default() }));
    inner.clone().save(PairedPhone {
        identity: PhoneIdentity { id: [1; 16], name: "Phone 1".into(), platform: PhonePlatform::Ios },
        pair_key: PairKey::new([1; 32]),
    })
    .unwrap();
    assert_eq!(rig.notices(), vec![NoticeKind::KeyStoreUnavailable]);
    rig.advance(10);
    rig.advance(10);
    assert_eq!(rig.notices(), vec![NoticeKind::KeyStoreUnavailable], "one outage, one notice");
    assert!(rig.last_tray().phones.is_empty());
    // The tray keeps showing the notice for as long as the outage lasts: it clears a notice once the icon is no longer
    // the attention one.
    assert_eq!(rig.last_tray().icon, IconState::Attention);
    locked.store(false, Ordering::SeqCst);
    rig.advance(10);
    assert_eq!(rig.last_tray().icon, IconState::Disconnected);
    assert_eq!(rig.last_tray().phones.len(), 1, "the phones are listed again without a restart");
    let lines = rig.logs.lines().join("\n");
    assert!(lines.contains("ev=keystore_unavailable") && lines.contains("ev=keystore_ok"), "{lines}");
    assert!(!lines.contains("Phone 1"));
}

#[test]
fn a_connection_while_the_keyring_cannot_be_read_is_dropped_without_auth_failed() {
    let locked = Arc::new(AtomicBool::new(true));
    let mut rig = Rig::with_store(Box::new(LockableStore { inner: MemoryPhoneStore::new(), locked, unlocks: Arc::default() }));
    rig.connect(Route::Selected);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.link.holds(), &[(DEVICE, Duration::from_secs(10))]);
    assert!(rig.link.writes().is_empty(), "no hello and no authFailed: the phone's key is not known to be wrong");
}

// ---------------------------------------------------------------- pairing

#[test]
fn pairing_window_closes_after_120_s() {
    let mut rig = Rig::new();
    rig.command(UiCommand::StartPairing);
    assert!(rig.link.pairing_scan());
    assert!(rig.last_tray().pairing_open);
    rig.advance(119_999);
    assert!(rig.link.pairing_scan(), "still open one millisecond before the end");
    rig.advance(1);
    assert!(!rig.link.pairing_scan());
    assert!(!rig.last_tray().pairing_open);
    assert!(rig.ui.contains(&UiEvent::PairingClosed));
}

#[test]
fn confirmed_pairing_saves_phone() {
    let mut rig = Rig::new();
    let (pairing, _) = rig.pair_up_to_confirmation("Anson 的 iPhone");
    assert!(rig.store.phones().is_empty(), "nothing is stored before the user confirms");
    rig.confirm(true);
    let stored = rig.store.phones();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].identity.name, "Anson 的 iPhone");
    assert_eq!(Some(&stored[0].pair_key), pairing.pair_key());
    assert_eq!(rig.last_tray().phones.len(), 1);
}

#[test]
fn rejected_pairing_saves_nothing() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    rig.confirm(false);
    assert!(rig.store.phones().is_empty());
    assert!(!rig.link.is_connected(), "the attempt is dropped with its connection");
}

#[test]
fn pairing_window_expiring_before_confirmation_saves_nothing() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    rig.advance(120_000);
    rig.confirm(true);
    assert!(rig.store.phones().is_empty());
    assert!(rig.ui.contains(&UiEvent::PairingClosed));
}

#[test]
fn pairing_advert_connection_sends_no_hello() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.command(UiCommand::StartPairing);
    rig.connect(Route::Pairing);
    assert!(rig.writes().is_empty(), "a connection found through the pairing UUID only waits for pairOffer");
}

#[test]
fn pair_offer_outside_the_pairing_window_disconnects() {
    let mut rig = Rig::new();
    rig.connect(Route::Pairing);
    let identity = PhoneIdentity { id: [0x77; 16], name: "P".into(), platform: PhonePlatform::Ios };
    let pairing = PhonePairing::new([0x42; 32], identity).unwrap();
    rig.phone_sends(&pairing.offer());
    assert!(rig.writes().is_empty(), "no reply");
    assert!(!rig.link.is_connected());
}

#[test]
fn ninth_phone_is_refused_with_a_notice() {
    let mut rig = Rig::new();
    for n in 1..=8 {
        rig.pair_phone(n);
    }
    rig.command(UiCommand::StartPairing);
    rig.connect(Route::Pairing);
    let identity = PhoneIdentity { id: [0x77; 16], name: "Ninth".into(), platform: PhonePlatform::Ios };
    let mut pairing = PhonePairing::new([0x42; 32], identity).unwrap();
    rig.phone_sends(&pairing.offer());
    let accept = rig.writes().remove(0);
    let PhonePairingOutput::Send(reveal) = pairing.receive(&accept) else { panic!("reveal") };
    rig.phone_sends(&reveal);
    assert!(rig.notices().contains(&NoticeKind::PairingStoreFull));
    assert!(!rig.ui.iter().any(|e| matches!(e, UiEvent::PairingRequest { .. })));
}

#[test]
fn stale_confirmation_is_ignored() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    let attempt = rig.last_attempt();
    // An answer that belongs to some other attempt must not confirm this one.
    rig.command(UiCommand::ConfirmPairing(attempt + 1, true));
    assert!(rig.store.phones().is_empty());
    // The attempt is still waiting for its own answer.
    rig.command(UiCommand::ConfirmPairing(attempt, true));
    assert_eq!(rig.store.phones().len(), 1);
}

#[test]
fn confirmation_of_a_finished_attempt_cannot_confirm_the_next_one() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("First");
    let first = rig.last_attempt();
    rig.link_drops(DisconnectReason::Remote);
    rig.pair_up_to_confirmation("Second");
    let second = rig.last_attempt();
    assert_ne!(first, second);
    rig.command(UiCommand::ConfirmPairing(first, true));
    assert!(rig.store.phones().is_empty(), "the dialog of the first attempt answered yes, the second is not confirmed");
    rig.command(UiCommand::ConfirmPairing(second, true));
    assert_eq!(rig.store.phones()[0].identity.name, "Second");
}

#[test]
fn the_question_is_withdrawn_when_its_attempt_ends() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    let attempt = rig.last_attempt();
    rig.link_drops(DisconnectReason::Remote);
    assert!(rig.ui.contains(&UiEvent::PairingDialogClose(attempt)), "the open dialog is closed");
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    let attempt = rig.last_attempt();
    rig.advance(120_000);
    assert!(rig.ui.contains(&UiEvent::PairingDialogClose(attempt)));
}

// ---------------------------------------------------------------- connection lifecycle

#[test]
fn handshake_timeout_backs_off_10_s_without_auth_failed() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.connect(Route::Selected);
    assert!(matches!(rig.writes()[0], ControlMessage::Hello { .. }));
    rig.advance(4_999);
    assert!(rig.link.is_connected());
    rig.advance(1);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.link.holds(), &[(DEVICE, Duration::from_secs(10))]);
    assert!(!rig.writes().iter().any(is_auth_failed), "a timeout never writes authFailed");
    assert!(rig.notices().is_empty());
}

#[test]
fn not_selected_backs_off_10_s_without_error() {
    let mut rig = Rig::new();
    let phone = rig.pair_phone(1);
    rig.connect(Route::Selected);
    let hello = rig.writes().remove(0);
    // A phone whose current host is another one answers every hello with notSelected.
    let mut other = PhoneHandshake::new(Some(([0x99; 16], phone.pair_key)), PHONE_NONCE);
    let PhoneOutput::Send(reply) = other.receive(&hello) else { panic!("notSelected expected") };
    assert_eq!(reply, PeripheralMessage::NotSelected);
    rig.phone_sends(&reply);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.link.holds(), &[(DEVICE, Duration::from_secs(10))]);
    assert!(!rig.writes().iter().any(is_auth_failed));
    assert!(rig.notices().is_empty());
    assert_ne!(rig.last_tray().icon, IconState::Attention);
}

#[test]
fn auth_failed_holds_device_60_s_and_shows_repair_note() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.connect(Route::Selected);
    let hello = rig.writes().remove(0);
    let mut stranger = PhoneHandshake::new(Some((HOST_ID, PairKey::new([0x55; 32]))), PHONE_NONCE);
    let PhoneOutput::Send(reply) = stranger.receive(&hello) else { panic!("helloReply expected") };
    rig.phone_sends(&reply);
    assert!(rig.writes().iter().any(is_auth_failed), "authFailed is written");
    assert!(!rig.link.is_connected());
    assert_eq!(rig.link.holds(), &[(DEVICE, Duration::from_secs(60))]);
    assert_eq!(rig.notices(), vec![NoticeKind::NeedsRepair]);
    assert_eq!(rig.last_tray().icon, IconState::Attention);
}

#[test]
fn auth_failure_while_the_pairing_window_is_open_is_not_held() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.command(UiCommand::StartPairing);
    rig.connect(Route::Selected);
    let hello = rig.writes().remove(0);
    let mut stranger = PhoneHandshake::new(Some((HOST_ID, PairKey::new([0x55; 32]))), PHONE_NONCE);
    let PhoneOutput::Send(reply) = stranger.receive(&hello) else { panic!("helloReply expected") };
    rig.phone_sends(&reply);
    assert!(rig.link.holds().is_empty(), "it may be the very phone the user is pairing");
}

#[test]
fn unsupported_version_shows_update_phone_note() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.connect(Route::Selected);
    rig.send_raw(br#"{"phoneNonce":"AAAAAAAAAAAAAAAAAAAAAA==","proof":"AAAA","protocolVersion":3,"type":"helloReply"}"#);
    assert_eq!(rig.notices(), vec![NoticeKind::UpdatePhone]);
    assert_eq!(rig.last_tray().icon, IconState::Attention);
}

#[test]
fn unsupported_version_disconnects_and_holds_device_60_s() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.connect(Route::Selected);
    rig.send_raw(br#"{"protocolVersion":3,"type":"notSelected"}"#);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.link.holds(), &[(DEVICE, Duration::from_secs(60))]);
}

#[test]
fn scanning_stops_while_connected() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    assert!(rig.link.is_scanning());
    rig.connect(Route::Selected);
    assert!(!rig.link.is_scanning());
    rig.link_drops(DisconnectReason::Remote);
    assert!(rig.link.is_scanning());
    let log = rig.log_text();
    let stop = log.find("ev=scan_stop").expect("scan_stop is logged");
    let restart = log.rfind("ev=scan_start").expect("scan_start is logged");
    assert!(log.contains("ev=scan_start") && stop < restart, "{log}");
}

#[test]
fn notification_for_old_conn_is_ignored() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.connect(Route::Selected);
    rig.writes();
    rig.link_drops(DisconnectReason::Remote);
    // The next connection is under way; a late notification of the first one must not touch it.
    rig.connect(Route::Selected);
    let old = 1;
    let mut stale = Vec::new();
    for frame in split_frames(&encode_peripheral(&PeripheralMessage::NotSelected), 9, 185).unwrap() {
        stale.push(frame);
    }
    for frame in stale {
        rig.deliver(LinkEvent::Notification { conn: old, bytes: frame });
    }
    assert!(rig.link.is_connected(), "a notSelected of the old connection ends nothing");
    assert!(rig.link.holds().is_empty());
}

#[test]
fn scan_failure_shows_bluetooth_notice_and_recovery_clears_it() {
    let mut rig = Rig::new();
    rig.deliver(LinkEvent::Scan(ScanState::Failed(ScanFailure::RadioOff)));
    assert_eq!(rig.notices(), vec![NoticeKind::BluetoothOff]);
    assert_eq!(rig.last_tray().icon, IconState::Attention);
    assert!(rig.log_text().contains("ev=scan_error kind=radio_off"));
    // The same failure again is not announced twice.
    rig.deliver(LinkEvent::Scan(ScanState::Failed(ScanFailure::RadioOff)));
    assert_eq!(rig.notices().len(), 1);
    rig.deliver(LinkEvent::Scan(ScanState::Running));
    assert_eq!(rig.last_tray().icon, IconState::Disconnected);
    assert!(rig.log_text().contains("ev=scan_ok"));
}

#[test]
fn repeated_scan_failures_without_a_real_recovery_raise_one_notice() {
    let mut rig = Rig::new();
    // The radio is off: every backoff round fails again, the kind may even change, and none of them ran in between.
    for failure in [ScanFailure::RadioOff, ScanFailure::Aborted, ScanFailure::RadioOff, ScanFailure::Unavailable] {
        rig.deliver(LinkEvent::Scan(ScanState::Failed(failure)));
    }
    assert_eq!(rig.notices(), vec![NoticeKind::BluetoothOff], "one notice per outage");
    assert!(!rig.log_text().contains("ev=scan_ok"), "no recovery was reported");
    // A real recovery ends the outage; the next outage is announced again.
    rig.deliver(LinkEvent::Scan(ScanState::Running));
    rig.deliver(LinkEvent::Scan(ScanState::Failed(ScanFailure::RadioOff)));
    assert_eq!(rig.notices(), vec![NoticeKind::BluetoothOff, NoticeKind::BluetoothOff]);
}

#[test]
fn start_after_a_scan_failure_that_happened_while_stopped_repeats_the_bluetooth_notice() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetReceiving(false));
    // Bluetooth went off while stopped: recorded, but nobody is told (the user stopped receiving).
    rig.deliver(LinkEvent::Scan(ScanState::Failed(ScanFailure::RadioOff)));
    assert!(rig.notices().is_empty());
    // Starting again with the outage still on: the backend reports nothing new, so the app says it itself.
    rig.command(UiCommand::SetReceiving(true));
    assert_eq!(rig.notices(), vec![NoticeKind::BluetoothOff]);
    // No outage on record: starting says nothing.
    let mut clean = Rig::new();
    clean.command(UiCommand::SetReceiving(false));
    clean.command(UiCommand::SetReceiving(true));
    assert!(clean.notices().is_empty());
}

#[test]
fn pairing_window_opens_at_start_when_asked() {
    let rig = Rig::with_pairing_at_start();
    assert!(rig.link.pairing_scan(), "the backend is told to scan for the pairing UUID");
    assert!(rig.last_tray().pairing_open);
    assert!(rig.log_text().contains("ev=pairing_window state=open"));
    let plain = Rig::new();
    assert!(!plain.link.pairing_scan());
}

#[test]
fn the_receiver_starts_by_scanning_and_logs_it() {
    let rig = Rig::new();
    assert!(rig.log_text().contains("ev=start"));
    assert!(rig.log_text().contains("ev=scan_start"));
}

// ---------------------------------------------------------------- 接收開關

fn scanning_commands(rig: &Rig) -> Vec<bool> {
    rig.link.commands().iter().filter_map(|c| if let LinkCommand::SetScanning(on) = c { Some(*on) } else { None }).collect()
}

#[test]
fn receiving_on_at_start() {
    let rig = Rig::new();
    assert!(rig.last_tray().receiving, "a started receiver receives");
    assert!(rig.link.is_scanning());
    assert!(scanning_commands(&rig).is_empty(), "the backends scan from the start: nothing has to be switched on");
    assert!(!rig.log_text().contains("ev=receiving_stopped"));
    // `--pair` does not change it.
    assert!(Rig::with_pairing_at_start().last_tray().receiving);
}

#[test]
fn stop_disconnects_and_stops_scan() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    assert!(rig.last_tray().connected_phone.is_some());
    rig.command(UiCommand::SetReceiving(false));
    // The phone is told `bye` the normal way, the link is released, and nothing scans.
    assert_eq!(rig.inner_messages(&mut phone).last(), Some(&ControlMessage::Bye));
    assert!(!rig.link.is_connected());
    assert!(!rig.link.is_scanning());
    assert_eq!(scanning_commands(&rig), vec![false]);
    let commands = rig.link.commands().to_vec();
    let disconnect = commands.iter().rposition(|c| *c == LinkCommand::Disconnect).expect("Disconnect was sent");
    // The switch goes off first: a worker that ends its link on `Disconnect` and looks at the switch next must find it off.
    assert!(commands.iter().rposition(|c| *c == LinkCommand::SetScanning(false)).unwrap() < disconnect);
    let tray = rig.last_tray();
    assert!(!tray.receiving);
    assert!(tray.connected_phone.is_none());
    assert_eq!(tray.icon, IconState::Disconnected, "stopping is not a fault");
    // Not connected at all: the same.
    let mut idle = Rig::new();
    idle.command(UiCommand::SetReceiving(false));
    assert!(!idle.link.is_scanning());
    assert!(!idle.last_tray().receiving);
}

#[test]
fn stop_closes_the_pairing_window_and_pairing_scan() {
    let mut rig = Rig::with_pairing_at_start();
    assert!(rig.link.pairing_scan());
    rig.command(UiCommand::SetReceiving(false));
    assert!(!rig.link.pairing_scan());
    assert!(!rig.last_tray().pairing_open);
    assert!(rig.log_text().contains("ev=pairing_window state=closed"));
    // The tray item is greyed out, but a command that still arrives opens nothing.
    rig.command(UiCommand::StartPairing);
    assert!(!rig.link.pairing_scan());
    assert!(!rig.last_tray().pairing_open);
}

#[test]
fn stop_withdraws_a_pairing_question_that_is_open() {
    let mut rig = Rig::with_pairing_at_start();
    let (_phone, _sas) = rig.pair_up_to_confirmation("iPhone");
    let attempt = rig.last_attempt();
    rig.command(UiCommand::SetReceiving(false));
    assert!(rig.ui.contains(&UiEvent::PairingDialogClose(attempt)));
    assert!(rig.store.phones().is_empty(), "nothing is saved from a question nobody answered");
    assert!(!rig.link.is_connected());
}

#[test]
fn stop_persists_until_start() {
    let mut rig = Rig::new();
    rig.pair_phone(1);
    rig.command(UiCommand::SetReceiving(false));
    rig.link.clear_record();
    // Time passes: no timer, no back-off, no hold-off ends the stop.
    for _ in 0..40 {
        rig.advance(30_000);
    }
    assert_eq!(rig.app.next_wake_ms(), None, "a stopped receiver plans no wake-up");
    assert!(!rig.link.is_scanning());
    // The backend does not connect while it is off, so a new advert does nothing.
    assert!(rig.link.connect(DEVICE, Route::Selected, 185).is_empty());
    assert!(!rig.link.is_connected());
    // A scan failure and its recovery (the backend's own retry) neither raise a notice nor start anything.
    rig.deliver(LinkEvent::Scan(ScanState::Failed(ScanFailure::RadioOff)));
    rig.deliver(LinkEvent::Scan(ScanState::Running));
    assert!(rig.notices().is_empty());
    assert!(!rig.last_tray().receiving);
    // A connection that slipped in before the backend heard of the stop is let go at once.
    rig.deliver(LinkEvent::Connected { conn: 99, device: DEVICE, route: Route::Selected, mtu: 185 });
    assert_eq!(rig.link.commands().last(), Some(&LinkCommand::Disconnect));
    assert!(rig.link.writes().is_empty(), "no hello is sent to a connection nobody wanted");
    // Nothing the app did since the stop asked for scanning, pairing or a connection.
    assert!(scanning_commands(&rig).is_empty());
    assert!(!rig.link.commands().iter().any(|c| matches!(c, LinkCommand::SetPairingScan(true))));
    // Only 開始 ends it.
    rig.command(UiCommand::SetReceiving(true));
    assert_eq!(scanning_commands(&rig), vec![true]);
    assert!(rig.link.is_scanning());
    assert!(rig.last_tray().receiving);
    assert_eq!(rig.link.connect(DEVICE, Route::Selected, 185).len(), 2);
}

#[test]
fn start_while_receiving_changes_nothing() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetReceiving(true));
    assert!(scanning_commands(&rig).is_empty());
    assert!(!rig.log_text().contains("ev=receiving_started"));
    rig.command(UiCommand::SetReceiving(false));
    rig.command(UiCommand::SetReceiving(false));
    assert_eq!(scanning_commands(&rig), vec![false], "a second stop is not sent again");
}

#[test]
fn restart_resets_to_on() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetReceiving(false));
    assert!(!rig.last_tray().receiving);
    // Stopping is not a setting: nothing was written, and the configuration has no trace of it.
    assert!(rig.configs.last().is_none());
    let json = serde_json::to_string(rig.app.config()).unwrap().to_lowercase();
    assert!(!json.contains("receiv") && !json.contains("stop") && !json.contains("scanning"), "{json}");
    // A new application from the same saved configuration (a restart, the autostart at login) receives.
    let clock = Arc::new(FakeClock::new(T0));
    let logger = Logger::new(Box::new(MemorySink::new()), clock.clone(), Level::Info);
    let mut again = App::new(AppDeps {
        config: rig.app.config().clone(),
        platform: HostPlatform::Windows,
        store: Box::new(MemoryPhoneStore::new()),
        config_store: Box::new(MemoryConfigStore::new()),
        injector: Box::new(RecordingInjector::new()),
        clock,
        random: Box::new(SequenceRandom::default()),
        logger,
        pair_at_start: false,
    });
    let state = again.start().into_iter().find_map(|e| if let Effect::Ui(UiEvent::State(s)) = e { Some(s) } else { None }).expect("a tray state");
    assert!(state.receiving);
}

#[test]
fn stopping_and_starting_are_logged_as_events_only() {
    let mut rig = Rig::new();
    rig.command(UiCommand::SetReceiving(false));
    rig.command(UiCommand::SetReceiving(true));
    let log = rig.log_text();
    let stopped = log.lines().find(|l| l.contains("ev=receiving_stopped")).expect("receiving_stopped is logged");
    let started = log.lines().find(|l| l.contains("ev=receiving_started")).expect("receiving_started is logged");
    assert!(stopped.contains("by=user"), "{stopped}");
    assert!(started.contains("by=user"), "{started}");
    assert!(log.find("ev=receiving_stopped") < log.find("ev=receiving_started"));
    // The app starting is `start`, not `receiving_started`.
    assert!(!Rig::new().log_text().contains("ev=receiving_started"));
}

#[test]
fn bye_disconnects_immediately() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.command(UiCommand::DeletePhone(stored.identity.id));
    let commands = rig.link.commands().to_vec();
    assert!(matches!(commands[commands.len() - 2], LinkCommand::Write(_)), "the sealed bye comes first");
    assert_eq!(commands[commands.len() - 1], LinkCommand::Disconnect);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.inner_messages(&mut phone).last(), Some(&ControlMessage::Bye));
}

#[test]
fn quitting_says_bye_and_lets_go() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.command(UiCommand::Quit);
    assert!(!rig.link.is_connected());
    assert_eq!(rig.inner_messages(&mut phone).last(), Some(&ControlMessage::Bye));
}

#[test]
fn paired_phone_list_delete_removes_key() {
    let mut rig = Rig::new();
    let first = rig.pair_phone(1);
    let second = rig.pair_phone(2);
    rig.command(UiCommand::DeletePhone(first.identity.id));
    assert_eq!(rig.store.phones().len(), 1);
    assert_eq!(rig.last_tray().phones.iter().map(|p| p.id).collect::<Vec<_>>(), vec![second.identity.id]);
    // The deleted phone's key no longer authenticates.
    rig.connect(Route::Selected);
    let hello = rig.writes().remove(0);
    let mut deleted = PhoneHandshake::new(Some((HOST_ID, first.pair_key)), PHONE_NONCE);
    let PhoneOutput::Send(reply) = deleted.receive(&hello) else { panic!("reply") };
    rig.phone_sends(&reply);
    assert!(rig.writes().iter().any(is_auth_failed));
}

// ---------------------------------------------------------------- events

#[test]
fn text_event_is_injected_and_acked_posted() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    let typed = rig.send_event(&phone, 1, EventKind::Text("你好 🙂".into()));
    assert_eq!(rig.injector.calls(), vec![Call::Text("你好 🙂".into())]);
    assert_eq!(rig.acks(&mut phone), vec![Ack { event_id: typed.event_id, result: AckResult::Posted }]);
    rig.send_event(&phone, 2, EventKind::Backspace);
    rig.send_event(&phone, 3, EventKind::ReturnKey);
    assert_eq!(&rig.injector.calls()[1..], &[Call::Backspace, Call::Enter]);
}

#[test]
fn failed_injection_is_acked_inject_failed() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.injector.set_failing(true);
    rig.send_event(&phone, 1, EventKind::Text("x".into()));
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::InjectFailed);
}

#[test]
fn duplicate_event_is_not_injected_twice() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    let first = rig.send_event(&phone, 1, EventKind::Text("a".into()));
    rig.send_existing_event(&phone, &first);
    assert_eq!(rig.injector.calls().len(), 1);
    let acks = rig.acks(&mut phone);
    assert_eq!(acks.len(), 2);
    assert!(acks.iter().all(|a| a.result == AckResult::Posted && a.event_id == first.event_id));
}

#[test]
fn stale_sequence_number_is_acked_out_of_order() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.send_event(&phone, 5, EventKind::Text("a".into()));
    let late = KeyboardEvent { event_id: Uuid::from_u128(0xBEEF), ..event(3, EventKind::Text("b".into())) };
    rig.send_existing_event(&phone, &late);
    assert_eq!(rig.injector.calls().len(), 1);
    assert_eq!(rig.acks(&mut phone).last().unwrap().result, AckResult::OutOfOrder);
}

#[test]
fn empty_text_is_acked_malformed_and_types_nothing() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.send_event(&phone, 1, EventKind::Text(String::new()));
    assert!(rig.injector.calls().is_empty());
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::Malformed);
}

#[test]
fn ping_and_probe_are_answered_pong_without_input() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    rig.send_event(&phone, 1, EventKind::Ping { shown_at_ms: 1, connected_at_ms: 2 });
    rig.send_event(&phone, 2, EventKind::Probe);
    assert!(rig.injector.calls().is_empty());
    let results: Vec<_> = rig.acks(&mut phone).iter().map(|a| a.result).collect();
    assert_eq!(results, vec![AckResult::Pong, AckResult::Pong]);
}

#[test]
fn status_is_ready_only_when_injector_ready() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    rig.injector.set_ready(false);
    rig.injector.set_trusted(false);
    let mut phone = rig.authenticate(&stored.pair_key);
    // The first status went out while the authentication completed; ask for the state again by changing it.
    rig.injector.set_ready(true);
    rig.injector.set_trusted(true);
    rig.advance(100);
    let status = rig.last_status(&mut phone);
    assert!(status.ready && status.trusted);
    assert_eq!(status.focus_epoch, 1);
    assert_eq!(status.app_name, None);
    rig.injector.set_ready(false);
    rig.advance(100);
    assert!(!rig.last_status(&mut phone).ready);
}

#[test]
fn first_status_after_authentication_reports_an_unready_injector() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    rig.injector.set_ready(false);
    rig.injector.set_trusted(false);
    rig.connect(Route::Selected);
    let mut phone = PhoneHandshake::new(Some((HOST_ID, stored.pair_key.clone())), PHONE_NONCE);
    let hello = rig.writes().remove(0);
    let PhoneOutput::Send(reply) = phone.receive(&hello) else { panic!("reply") };
    rig.phone_sends(&reply);
    let writes = rig.writes();
    assert!(matches!(phone.receive(&writes[0]), PhoneOutput::Authenticated));
    let PhoneOutput::Deliver(ControlMessage::Status(status)) = phone.receive(&writes[1]) else { panic!("status expected") };
    assert!(!status.ready);
    assert!(!status.trusted);
}

// ---------------------------------------------------------------- pointer

fn pointer_rig() -> (Rig, PhoneHandshake, ChannelSet, u32) {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    rig.command(UiCommand::SetTrackpad(true));
    let mut phone = rig.authenticate(&stored.pair_key);
    let grant = rig.last_status(&mut phone).pointer_grant.expect("the switch is on, so the status carries a grant");
    let channels = phone.take_channel_set().unwrap();
    (rig, phone, channels, grant)
}

fn packet(channels: &mut ChannelSet, payload: PointerPayload) -> Vec<u8> {
    channels.sealer().seal(&payload.encode()).unwrap()
}

#[test]
fn pointer_open_needs_current_grant() {
    let (mut rig, mut phone, _channels, grant) = pointer_rig();
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant: grant.wrapping_add(1), wifi: None });
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::NotAuthorized);
    rig.send_event(&phone, 2, EventKind::PointerOpen { grant, wifi: None });
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::Posted);
    rig.send_event(&phone, 3, EventKind::PointerClose);
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::Posted);
}

#[test]
fn pointer_open_is_refused_when_the_switch_is_off() {
    let mut rig = Rig::new();
    let stored = rig.pair_phone(1);
    let mut phone = rig.authenticate(&stored.pair_key);
    assert_eq!(rig.last_status(&mut phone).pointer_grant, None);
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant: 7, wifi: None });
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::NotAuthorized);
}

#[test]
fn pointer_packets_reach_the_injector_once_the_channel_is_open() {
    let (mut rig, mut phone, mut channels, grant) = pointer_rig();
    // Not open yet: dropped.
    rig.notify(packet(&mut channels, PointerPayload::new(Opcode::Click, 0, 0, 0, 0, 1)));
    assert!(rig.injector.calls().is_empty());
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant, wifi: None });
    rig.acks(&mut phone);
    let mut click = PointerPayload::new(Opcode::Click, 0, 0, 0, 0, 2);
    click.arg = PointerPayload::click_arg(0, 1);
    rig.notify(packet(&mut channels, click));
    assert!(rig.injector.calls().contains(&Call::Click(Button::Left, 1)));
    // Movement is played out over the following frames.
    rig.notify(packet(&mut channels, PointerPayload::new(Opcode::Move, 0, 160, 0, 80, 2)));
    rig.advance(30);
    assert!(rig.injector.calls().iter().any(|c| matches!(c, Call::Move(dx, _) if *dx > 0.0)));
}

#[test]
fn turning_the_switch_off_sends_a_status_without_grant() {
    let (mut rig, mut phone, _channels, _grant) = pointer_rig();
    rig.command(UiCommand::SetTrackpad(false));
    assert_eq!(rig.last_status(&mut phone).pointer_grant, None);
    assert!(!rig.configs.last().unwrap().trackpad);
}

// ---------------------------------------------------------------- pointer timing

/// A pointer rig whose channel is already open.
fn open_pointer_rig() -> (Rig, ChannelSet) {
    let (mut rig, mut phone, channels, grant) = pointer_rig();
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant, wifi: None });
    rig.acks(&mut phone);
    (rig, channels)
}

fn move_packet(channels: &mut ChannelSet, dx: i16, dy: i16, dt: u16) -> Vec<u8> {
    packet(channels, PointerPayload::new(Opcode::Move, 0, dx, dy, dt, 0))
}

/// The log lines of one event kind, exactly (`pointer_timing` does not match `pointer_timing_arr`).
fn lines_of(rig: &Rig, ev: &str) -> Vec<String> {
    let key = format!("ev={ev} ");
    rig.logs.lines().into_iter().filter(|line| line.contains(&key)).collect()
}

fn field(line: &str, key: &str) -> u64 {
    let prefix = format!("{key}=");
    line.split(' ')
        .find_map(|token| token.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("{key} is missing in {line}"))
        .parse()
        .unwrap_or_else(|_| panic!("{key} is not a number in {line}"))
}

/// Five move packets 10 ms apart, each carrying a time of 8 ms.
fn five_moves(rig: &mut Rig, channels: &mut ChannelSet, dx: i16, dy: i16) {
    for i in 0..5 {
        if i > 0 {
            rig.advance(10);
        }
        rig.notify(move_packet(channels, dx, dy, 80));
    }
}

#[test]
fn a_stroke_writes_one_pointer_timing_summary_when_300_ms_pass_without_a_packet() {
    let (mut rig, mut channels) = open_pointer_rig();
    five_moves(&mut rig, &mut channels, 160, 32);
    rig.advance(250);
    assert!(lines_of(&rig, "pointer_timing").is_empty(), "the stroke is still open 250 ms after the last packet");
    rig.advance(50);
    let summary = lines_of(&rig, "pointer_timing");
    assert_eq!(summary.len(), 1, "exactly one summary, written by the tick alone: {}", rig.log_text());
    assert_eq!((field(&summary[0], "packets"), field(&summary[0], "moves")), (5, 5));
    assert_eq!(field(&summary[0], "lag_us"), 20_000, "a 10 ms stream keeps the plain 20 ms lag bound: {}", summary[0]);
    assert!(summary[0].contains("lvl=info") && summary[0].contains("conn="), "{}", summary[0]);
    for key in ["frames", "idle", "squeeze", "lag_us", "inj_max_us", "late_p99_us", "late_max_us"] {
        field(&summary[0], key);
    }
    let arr = lines_of(&rig, "pointer_timing_arr");
    assert_eq!(arr.len(), 1);
    assert_eq!((field(&arr[0], "n"), field(&arr[0], "p50_us"), field(&arr[0], "max_us"), field(&arr[0], "b10")), (4, 10_000, 10_000, 4));
    let dt = lines_of(&rig, "pointer_timing_dt");
    assert_eq!((field(&dt[0], "n"), field(&dt[0], "p50_us"), field(&dt[0], "b10")), (5, 8_000, 5));
    let out = lines_of(&rig, "pointer_timing_out");
    assert!(field(&out[0], "n") >= 3, "the frames played the moves out: {}", out[0]);
    rig.advance(5_000);
    assert_eq!(lines_of(&rig, "pointer_timing").len(), 1, "nothing more is written once the stroke is closed");
}

#[test]
fn the_timing_lines_hold_counts_and_times_but_no_displacement() {
    let (mut rig, mut channels) = open_pointer_rig();
    five_moves(&mut rig, &mut channels, 1234, -777);
    rig.advance(400);
    let text = lines_of(&rig, "pointer_timing")
        .into_iter()
        .chain(lines_of(&rig, "pointer_timing_arr"))
        .chain(lines_of(&rig, "pointer_timing_dt"))
        .chain(lines_of(&rig, "pointer_timing_out"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(text.contains("ev=pointer_timing "), "the summary was written");
    for forbidden in ["1234", "777", "dx", "dy"] {
        assert!(!text.contains(forbidden), "{forbidden} must not appear in the timing lines: {text}");
    }
    let moved = rig.injector.calls().iter().filter(|c| matches!(c, Call::Move(..))).count();
    assert!(moved > 0, "the moves really were injected");
}

#[test]
fn the_wake_up_for_the_stroke_end_is_asked_for_once_the_frames_are_done() {
    let (mut rig, mut channels) = open_pointer_rig();
    let at = rig.clock.mono_ms();
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    rig.advance(30);
    assert_eq!(rig.app.next_wake_ms(), Some(at + 300), "the status poll is 500 ms away, the stroke ends first");
}

#[test]
fn a_packet_after_a_quiet_gap_closes_the_old_stroke_and_starts_a_new_one() {
    let (mut rig, mut channels) = open_pointer_rig();
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    rig.advance(10);
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    rig.clock.advance(400);
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    let first = lines_of(&rig, "pointer_timing");
    assert_eq!(first.len(), 1, "the packet itself flushed the earlier stroke");
    assert_eq!(field(&first[0], "packets"), 2);
    rig.advance(300);
    let all = lines_of(&rig, "pointer_timing");
    assert_eq!(all.len(), 2);
    assert_eq!(field(&all[1], "packets"), 1, "the new stroke started fresh");
    let arr = lines_of(&rig, "pointer_timing_arr");
    assert_eq!((field(&arr[0], "n"), field(&arr[1], "n")), (1, 0), "the 400 ms gap is no interval of either stroke");
}

#[test]
fn bursts_of_three_every_45_ms_raise_the_reported_lag_bound_to_50_ms() {
    let (mut rig, mut channels) = open_pointer_rig();
    for _ in 0..6 {
        rig.notify(move_packet(&mut channels, 160, 0, 166));
        rig.advance(1);
        rig.notify(move_packet(&mut channels, 160, 0, 166));
        rig.advance(1);
        rig.notify(move_packet(&mut channels, 160, 0, 166));
        rig.advance(43);
    }
    rig.advance(400);
    let summary = lines_of(&rig, "pointer_timing");
    assert_eq!(field(&summary[0], "lag_us"), 50_000, "{}", summary[0]);
}

#[test]
fn starved_frames_and_squeezes_are_counted_per_stroke() {
    let (mut rig, mut channels) = open_pointer_rig();
    for _ in 0..8 {
        rig.notify(move_packet(&mut channels, 160, 0, 100));
    }
    // A frame at the very instant of the packets has nothing due yet.
    let effects = rig.app.on_tick();
    rig.run(effects);
    rig.advance(400);
    let summary = lines_of(&rig, "pointer_timing");
    assert_eq!(summary.len(), 1);
    assert!(field(&summary[0], "squeeze") > 0, "eight 10 ms moves at one instant exceed the lag bound: {}", summary[0]);
    assert!(field(&summary[0], "idle") >= 1, "{}", summary[0]);
    // The next stroke starts counting from where this one ended.
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    rig.advance(400);
    let second = lines_of(&rig, "pointer_timing");
    assert_eq!(field(&second[1], "squeeze"), 0, "{}", second[1]);
}

#[test]
fn a_tick_that_comes_late_is_measured_against_the_wake_up_that_was_asked_for() {
    let (mut rig, mut channels) = open_pointer_rig();
    rig.notify(move_packet(&mut channels, 160, 0, 80));
    let asked = rig.app.next_wake_ms().expect("the frame tick is wanted");
    let late_by = 42;
    rig.advance(asked - rig.clock.mono_ms() + late_by);
    rig.advance(400);
    let summary = lines_of(&rig, "pointer_timing");
    assert_eq!(field(&summary[0], "late_max_us"), late_by * 1_000, "{}", summary[0]);
}

// ---------------------------------------------------------------- end to end and the log

#[test]
fn end_to_end_with_rust_phone() {
    let mut rig = Rig::new();
    // Pair.
    let (pairing, sas) = rig.pair_up_to_confirmation("Anson 的 iPhone");
    assert_eq!(sas.len(), 6);
    rig.confirm(true);
    // The phone goes away; the keyboard now advertises the selected UUID.
    rig.link_drops(DisconnectReason::Remote);
    // Connect through the selected UUID and type.
    let key = pairing.pair_key().unwrap().clone();
    let mut phone = rig.authenticate(&key);
    assert_eq!(rig.last_tray().connected_phone.as_deref(), Some("Anson 的 iPhone"));
    assert_eq!(rig.last_tray().icon, IconState::Connected);
    rig.send_event(&phone, 1, EventKind::Text("Hello 世界 🙂".into()));
    rig.send_event(&phone, 2, EventKind::Backspace);
    rig.send_event(&phone, 3, EventKind::ReturnKey);
    assert_eq!(rig.injector.calls(), vec![Call::Text("Hello 世界 🙂".into()), Call::Backspace, Call::Enter]);
    let results: Vec<_> = rig.acks(&mut phone).iter().map(|a| a.result).collect();
    assert_eq!(results, vec![AckResult::Posted; 3]);
    // The phone drops the link: the tray goes back to waiting.
    rig.link_drops(DisconnectReason::Remote);
    assert_eq!(rig.last_tray().icon, IconState::Disconnected);
    assert_eq!(rig.last_tray().connected_phone, None);
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn log_lines_never_contain_text() {
    let mut rig = Rig::with_level(Level::Debug);
    let secret = "機密文字-Secret-🙂";
    let phone_name = "Zelda-Phone-名稱";
    let (pairing, sas) = rig.pair_up_to_confirmation(phone_name);
    let pair_key = pairing.pair_key().unwrap().clone();
    rig.confirm(true);
    rig.command(UiCommand::SetTrackpad(true));
    rig.link_drops(DisconnectReason::Remote);

    rig.connect(Route::Selected);
    let writes = rig.writes();
    let ControlMessage::Hello { host_nonce, .. } = writes[0].clone() else { panic!("hello expected") };
    let mut phone = PhoneHandshake::new(Some((HOST_ID, pair_key.clone())), PHONE_NONCE);
    let PhoneOutput::Send(reply) = phone.receive(&writes[0]) else { panic!("reply") };
    rig.phone_sends(&reply);
    for message in rig.writes() {
        phone.receive(&message);
    }
    rig.send_event(&phone, 1, EventKind::Text(secret.into()));
    let mut channels = phone.take_channel_set().unwrap();
    let grant = 0; // wrong on purpose: the refusal is logged too
    rig.send_event(&phone, 2, EventKind::PointerOpen { grant, wifi: None });
    rig.notify(packet(&mut channels, PointerPayload::new(Opcode::Move, 0, 160, 32, 80, 2)));
    rig.advance(50);
    rig.send_event(&phone, 3, EventKind::Backspace);

    let host_nonce: [u8; 16] = host_nonce.try_into().unwrap();
    let secrets: Vec<(&str, Vec<u8>)> = vec![
        ("text", secret.as_bytes().to_vec()),
        ("phone name", phone_name.as_bytes().to_vec()),
        ("pairing code", sas.as_bytes().to_vec()),
        ("pair key", pair_key.expose().to_vec()),
        ("host nonce", host_nonce.to_vec()),
        ("phone nonce", PHONE_NONCE.to_vec()),
        ("phone proof", rk_core::pairing::phone_proof(&pair_key, &host_nonce, &PHONE_NONCE).to_vec()),
        ("host proof", rk_core::pairing::host_proof(&pair_key, &host_nonce, &PHONE_NONCE).to_vec()),
    ];
    let text = rig.log_text();
    assert!(text.contains("ev=inject op=text"), "the batch is logged: {text}");
    for (what, bytes) in secrets {
        let forms = [String::from_utf8_lossy(&bytes).into_owned(), hex(&bytes), hex(&bytes).to_uppercase(), STANDARD.encode(&bytes)];
        for form in forms {
            assert!(!text.contains(&form), "the log must not contain the {what} ({form})");
        }
    }
    // No long run of hex digits at all: only the 8-character device hash is allowed.
    for line in rig.logs.lines() {
        for token in line.split(|c: char| !c.is_ascii_hexdigit()) {
            assert!(token.len() < 16, "suspicious hex run in {line}");
        }
    }
}

// ---------------------------------------------------------------- Wi-Fi assist (D30, WF2)

fn target(a: [u8; 4], port: u16) -> SocketAddrV4 {
    SocketAddrV4::new(Ipv4Addr::from(a), port)
}

fn wifi_offer() -> WifiOffer {
    WifiOffer::new(vec![Ipv4Addr::new(192, 168, 1, 23), Ipv4Addr::new(10, 0, 0, 5)], 50_123).expect("a valid offer")
}

fn wifi_targets() -> Vec<SocketAddrV4> {
    vec![target([192, 168, 1, 23], 50_123), target([10, 0, 0, 5], 50_123)]
}

/// A pointer rig, as the phone sees it, plus the phone's side of the probe channel of this connection.
struct WifiRig {
    rig: Rig,
    phone: PhoneHandshake,
    channels: ChannelSet,
    probes: ProbeOpener,
    grant: u32,
    next_seq: u64,
}

fn wifi_rig() -> WifiRig {
    wifi_rig_at(Level::Info)
}

fn wifi_rig_at(level: Level) -> WifiRig {
    let mut rig = Rig::with_level(level);
    let stored = rig.pair_phone(1);
    rig.command(UiCommand::SetTrackpad(true));
    let mut phone = rig.authenticate(&stored.pair_key);
    let grant = rig.last_status(&mut phone).pointer_grant.expect("the switch is on, so the status carries a grant");
    let channels = phone.take_channel_set().unwrap();
    let probes = ProbeOpener::new(derive_probe_key(&stored.pair_key, &rig.host_nonce, &PHONE_NONCE));
    WifiRig { rig, phone, channels, probes, grant, next_seq: 1 }
}

impl WifiRig {
    /// The phone sends `pointerOpen` with this offer and the current grant; returns the ack.
    fn open(&mut self, wifi: Option<WifiOffer>) -> AckResult {
        let grant = self.grant;
        self.open_with(grant, wifi)
    }

    fn open_with(&mut self, grant: u32, wifi: Option<WifiOffer>) -> AckResult {
        let seq = self.next_seq;
        self.next_seq += 1;
        self.rig.send_event(&self.phone, seq, EventKind::PointerOpen { grant, wifi });
        self.rig.acks(&mut self.phone).last().expect("an ack").result
    }

    fn close(&mut self) {
        let seq = self.next_seq;
        self.next_seq += 1;
        self.rig.send_event(&self.phone, seq, EventKind::PointerClose);
        self.rig.acks(&mut self.phone);
    }

    /// The probes sent since last asked.
    fn take_probes(&mut self) -> Vec<(Vec<SocketAddrV4>, Vec<u8>)> {
        std::mem::take(&mut self.rig.wifi)
    }

    /// Nothing is sent however long the application runs on.
    fn assert_silent_for(&mut self, ms: u64) {
        for _ in 0..(ms / 50) {
            self.rig.advance(50);
        }
        assert_eq!(self.take_probes(), vec![], "no probe may be sent");
    }

    fn click_packet(&mut self) -> Vec<u8> {
        let mut click = PointerPayload::new(Opcode::Click, 0, 0, 0, 0, 1);
        click.arg = PointerPayload::click_arg(0, 1);
        packet(&mut self.channels, click)
    }
}

#[test]
fn a_granted_pointer_open_with_wifi_probes_every_target_at_once_and_then_every_250_ms() {
    let mut w = wifi_rig();
    assert_eq!(w.open(Some(wifi_offer())), AckResult::Posted);
    let first = w.take_probes();
    assert_eq!(first.len(), 1, "one probe, sent to all targets, the moment the channel opens");
    assert_eq!(first[0].0, wifi_targets());
    assert_eq!(first[0].1.len(), 41);
    w.probes.open(&first[0].1).expect("the probe opens under this connection's probe key");
    assert_eq!(w.probes.last_opened_counter(), 1);

    let asked = w.rig.app.next_wake_ms().expect("a wake-up is wanted");
    assert_eq!(asked, w.rig.clock.mono_ms() + 250, "the application asks to be woken for the next probe");

    w.rig.advance(249);
    assert_eq!(w.take_probes(), vec![], "not before 250 ms");
    w.rig.advance(1);
    let second = w.take_probes();
    assert_eq!(second.len(), 1);
    assert_eq!(second[0].0, wifi_targets());
    w.probes.open(&second[0].1).unwrap();
    assert_eq!(w.probes.last_opened_counter(), 2);
    w.rig.advance(250);
    let third = w.take_probes();
    assert_eq!(third.len(), 1);
    w.probes.open(&third[0].1).unwrap();
    assert_eq!(w.probes.last_opened_counter(), 3);
    w.rig.advance(100);
    assert_eq!(w.take_probes(), vec![]);
}

#[test]
fn the_log_says_when_probing_starts_with_a_count_of_targets_and_never_an_address() {
    let mut w = wifi_rig();
    w.open(Some(wifi_offer()));
    assert_eq!(lines_of(&w.rig, "wifi_probe_start").len(), 1);
    assert_eq!(field(&lines_of(&w.rig, "wifi_probe_start")[0], "targets"), 2);
    w.rig.advance(1000);
    let text = w.rig.log_text();
    for forbidden in ["192.168", "10.0.0.5", "50123"] {
        assert!(!text.contains(forbidden), "the log must not name an address or port: {forbidden}");
    }
}

#[test]
fn a_pointer_open_without_wifi_never_probes() {
    let mut w = wifi_rig();
    assert_eq!(w.open(None), AckResult::Posted);
    w.assert_silent_for(1_000);
    assert!(lines_of(&w.rig, "wifi_probe_start").is_empty());
}

#[test]
fn a_refused_pointer_open_with_wifi_never_probes() {
    let mut w = wifi_rig();
    let wrong = w.grant.wrapping_add(1);
    assert_eq!(w.open_with(wrong, Some(wifi_offer())), AckResult::NotAuthorized);
    w.assert_silent_for(1_000);
}

#[test]
fn a_pointer_open_with_wifi_while_the_switch_is_off_never_probes() {
    let mut w = wifi_rig();
    w.rig.command(UiCommand::SetTrackpad(false));
    assert_eq!(w.open(Some(wifi_offer())), AckResult::NotAuthorized);
    w.assert_silent_for(1_000);
}

/// A rig whose channel is open with a Wi-Fi offer and whose first probe has been taken.
fn probing_rig() -> WifiRig {
    probing_rig_at(Level::Info)
}

fn probing_rig_at(level: Level) -> WifiRig {
    let mut w = wifi_rig_at(level);
    assert_eq!(w.open(Some(wifi_offer())), AckResult::Posted);
    assert_eq!(w.take_probes().len(), 1);
    w.rig.advance(250);
    assert_eq!(w.take_probes().len(), 1, "probing is running before the thing under test happens");
    w
}

fn stop_word(rig: &Rig) -> String {
    let lines = lines_of(rig, "wifi_probe_stop");
    assert_eq!(lines.len(), 1, "one stop line: {lines:?}");
    lines[0].split(' ').find_map(|t| t.strip_prefix("why=")).expect("a reason").to_string()
}

#[test]
fn pointer_close_stops_the_probes() {
    let mut w = probing_rig();
    w.close();
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "close");
}

#[test]
fn the_connection_ending_stops_the_probes() {
    let mut w = probing_rig();
    w.rig.link_drops(DisconnectReason::Remote);
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "disconnect");
}

#[test]
fn a_new_connection_that_replaces_the_old_one_ends_its_probes_and_a_failed_handshake_probes_nothing() {
    let mut w = probing_rig();
    w.rig.connect(Route::Selected); // the backend hands over without a disconnect in between
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "disconnect");
}

#[test]
fn stopping_the_receiver_stops_the_probes() {
    let mut w = probing_rig();
    w.rig.command(UiCommand::SetReceiving(false));
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "disconnect");
}

#[test]
fn turning_the_pointer_switch_off_stops_the_probes() {
    let mut w = probing_rig();
    w.rig.command(UiCommand::SetTrackpad(false));
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "switch_off");
}

#[test]
fn eight_failed_bluetooth_packets_renew_the_grant_and_stop_the_probes() {
    let mut w = probing_rig();
    let good = w.click_packet();
    w.rig.notify(good.clone());
    for _ in 0..8 {
        w.rig.notify(good.clone()); // the same bytes again: a replay
    }
    assert_ne!(w.rig.last_status(&mut w.phone).pointer_grant, Some(w.grant), "the grant was renewed");
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "grant_changed");
}

#[test]
fn a_refused_pointer_open_stops_the_probes_that_were_running() {
    let mut w = probing_rig();
    let wrong = w.grant.wrapping_add(1);
    assert_eq!(w.open_with(wrong, Some(wifi_offer())), AckResult::NotAuthorized);
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "refused");
}

#[test]
fn a_new_pointer_open_without_wifi_stops_the_probes() {
    let mut w = probing_rig();
    assert_eq!(w.open(None), AckResult::Posted);
    w.assert_silent_for(1_000);
    assert_eq!(stop_word(&w.rig), "no_wifi");
}

#[test]
fn a_new_pointer_open_with_wifi_replaces_the_targets_at_once() {
    let mut w = probing_rig();
    let other = WifiOffer::new(vec![Ipv4Addr::new(172, 16, 4, 2)], 4_000).unwrap();
    assert_eq!(w.open(Some(other)), AckResult::Posted);
    let sent = w.take_probes();
    assert_eq!(sent.len(), 1, "the first probe to the new target goes out at once");
    assert_eq!(sent[0].0, vec![target([172, 16, 4, 2], 4_000)]);
    w.rig.advance(250);
    let sent = w.take_probes();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].0, vec![target([172, 16, 4, 2], 4_000)], "the old targets are gone");
    assert!(lines_of(&w.rig, "wifi_probe_stop").is_empty(), "replacing is not stopping");
}

#[test]
fn a_repeated_pointer_open_event_is_a_restart_and_never_a_second_stream_of_probes() {
    let mut w = probing_rig();
    // Pointer events are exempt from the duplicate check (§7.5), so a retransmission is performed again.
    let open = event(1, EventKind::PointerOpen { grant: w.grant, wifi: Some(wifi_offer()) });
    w.rig.send_existing_event(&w.phone, &open);
    w.rig.send_existing_event(&w.phone, &open);
    assert_eq!(w.take_probes().len(), 2, "one probe at once for each open");
    w.rig.advance(250);
    assert_eq!(w.take_probes().len(), 1, "then a single probe every 250 ms");
    w.rig.advance(250);
    assert_eq!(w.take_probes().len(), 1);
}

#[test]
fn probes_that_stopped_and_start_again_go_on_counting_from_where_the_connection_was() {
    let mut w = probing_rig();
    assert_eq!(w.probes.last_opened_counter(), 0, "nothing opened by the test so far");
    w.close();
    assert_eq!(w.open(Some(wifi_offer())), AckResult::Posted);
    let sent = w.take_probes();
    let counter_before_reopen = 2; // the first two probes of probing_rig
    // The opener was never fed the first two probes, so any counter above them proves the sealer was not recreated.
    w.probes.open(&sent.last().unwrap().1).expect("opens");
    assert!(w.probes.last_opened_counter() > counter_before_reopen, "got {}", w.probes.last_opened_counter());
}

// ---- datagrams from the phone

impl WifiRig {
    /// A datagram arrives on the Wi-Fi socket from `from`.
    fn udp(&mut self, from: SocketAddrV4, bytes: &[u8]) {
        let effects = self.rig.app.on_wifi_datagram(SocketAddr::V4(from), bytes);
        self.rig.run(effects);
    }

    fn move_packet(&mut self, dx: i16) -> Vec<u8> {
        packet(&mut self.channels, PointerPayload::new(Opcode::Move, 0, dx, 0, 80, 0))
    }
}

fn moves(rig: &Rig) -> Vec<Call> {
    rig.injector.calls().into_iter().filter(|c| matches!(c, Call::Move(..))).collect()
}

fn clicks(rig: &Rig) -> usize {
    rig.injector.calls().iter().filter(|c| matches!(c, Call::Click(..))).count()
}

#[test]
fn a_datagram_from_a_probed_address_does_what_the_same_packet_over_bluetooth_does() {
    let (mut by_udp, mut by_ble) = (probing_rig(), probing_rig());
    // The two rigs are identical (same keys, same nonces), so the same packets can be made in each.
    let (click, mv) = (by_udp.click_packet(), by_udp.move_packet(160));
    by_udp.udp(wifi_targets()[0], &click);
    by_udp.udp(wifi_targets()[1], &mv);
    by_udp.rig.advance(30);
    let (click, mv) = (by_ble.click_packet(), by_ble.move_packet(160));
    by_ble.rig.notify(click);
    by_ble.rig.notify(mv);
    by_ble.rig.advance(30);
    assert_eq!(clicks(&by_udp.rig), 1, "the click arrived");
    assert!(!moves(&by_udp.rig).is_empty(), "the move was played out");
    assert_eq!(by_udp.rig.injector.calls(), by_ble.rig.injector.calls(), "the same calls, in the same order");
}

#[test]
fn a_datagram_from_any_other_address_or_port_is_ignored_and_does_not_use_up_its_counter() {
    let mut w = probing_rig();
    let mv = w.move_packet(160);
    w.udp(target([192, 168, 1, 23], 50_124), &mv); // right host, wrong port
    w.udp(target([192, 168, 1, 99], 50_123), &mv); // wrong host, right port
    w.udp(target([8, 8, 8, 8], 53), &mv);
    w.rig.advance(60);
    assert_eq!(moves(&w.rig), vec![], "the cursor did not move");
    // The packet was never opened, so it is still good when it comes from a target.
    w.udp(wifi_targets()[0], &mv);
    w.rig.advance(60);
    assert!(!moves(&w.rig).is_empty());
}

#[test]
fn a_datagram_of_the_wrong_shape_from_a_target_is_ignored() {
    let mut w = probing_rig();
    let mv = w.move_packet(160);
    w.udp(wifi_targets()[0], &mv[..40]);
    let mut longer = mv.clone();
    longer.push(0);
    w.udp(wifi_targets()[0], &longer);
    let mut probe_like = mv.clone();
    probe_like[0] = 0x05;
    w.udp(wifi_targets()[0], &probe_like);
    w.udp(wifi_targets()[0], &[]);
    w.rig.advance(60);
    assert_eq!(moves(&w.rig), vec![]);
    w.udp(wifi_targets()[0], &mv);
    w.rig.advance(60);
    assert!(!moves(&w.rig).is_empty(), "the good packet still opens");
}

#[test]
fn a_datagram_is_ignored_when_nothing_was_probed() {
    // The channel is open but the phone offered no Wi-Fi.
    let mut w = wifi_rig();
    assert_eq!(w.open(None), AckResult::Posted);
    let mv = w.move_packet(160);
    w.udp(wifi_targets()[0], &mv);
    w.rig.advance(60);
    assert_eq!(moves(&w.rig), vec![]);
    // And before there is any connection at all.
    let mut rig = Rig::new();
    let effects = rig.app.on_wifi_datagram(SocketAddr::V4(wifi_targets()[0]), &mv);
    assert_eq!(effects, vec![]);
}

#[test]
fn a_datagram_after_the_probes_stopped_is_ignored() {
    let mut w = probing_rig();
    let mv = w.move_packet(160);
    w.close();
    w.udp(wifi_targets()[0], &mv);
    w.rig.advance(60);
    assert_eq!(moves(&w.rig), vec![]);
}

#[test]
fn twenty_bad_datagrams_from_a_target_do_not_renew_the_grant_but_eight_bad_bluetooth_packets_do() {
    let mut w = probing_rig();
    let mut forged = vec![0x03; 41];
    for i in 0..20u8 {
        forged[1] = i; // a different counter each time; none of them authenticates
        w.udp(wifi_targets()[0], &forged);
    }
    let good = w.click_packet();
    w.udp(wifi_targets()[0], &good);
    for _ in 0..20 {
        w.udp(wifi_targets()[0], &good); // and replays of it
    }
    assert_eq!(clicks(&w.rig), 1, "only the good packet did anything");
    assert!(w.rig.app.pointer.is_open(), "the channel is still open");
    assert_eq!(w.rig.app.pointer.grant(), Some(w.grant), "no new grant");
    assert_eq!(lines_of(&w.rig, "wifi_probe_stop"), Vec::<String>::new(), "probing goes on");
    w.rig.advance(250);
    assert_eq!(w.take_probes().len(), 1);

    // Bluetooth keeps its rule.
    for _ in 0..8 {
        w.rig.notify(good.clone());
    }
    assert!(!w.rig.app.pointer.is_open());
    assert_ne!(w.rig.app.pointer.grant(), Some(w.grant), "eight failures over Bluetooth renew the grant");
}

#[test]
fn a_packet_replayed_across_transports_is_refused_by_the_shared_window() {
    let mut w = probing_rig();
    let click = w.click_packet();
    w.rig.notify(click.clone());
    w.udp(wifi_targets()[0], &click);
    assert_eq!(clicks(&w.rig), 1, "delivered over Bluetooth, then again over UDP: once");

    let mut w = probing_rig();
    let click = w.click_packet();
    w.udp(wifi_targets()[1], &click);
    w.rig.notify(click);
    assert_eq!(clicks(&w.rig), 1, "delivered over UDP, then again over Bluetooth: once");
}

#[test]
fn a_pointer_stroke_counts_its_packets_by_transport() {
    let mut w = probing_rig();
    for dx in [16, 32] {
        let mv = w.move_packet(dx);
        w.rig.notify(mv);
    }
    for dx in [48, 64, 80] {
        let mv = w.move_packet(dx);
        w.udp(wifi_targets()[0], &mv);
    }
    w.rig.advance(1_000);
    let summary = lines_of(&w.rig, "pointer_timing");
    assert_eq!(summary.len(), 1);
    assert_eq!((field(&summary[0], "packets"), field(&summary[0], "ble"), field(&summary[0], "udp")), (5, 2, 3));
}

#[test]
fn without_a_socket_the_phone_is_not_asked_to_expect_probes() {
    let mut w = wifi_rig();
    w.rig.app.on_wifi_unavailable(std::io::ErrorKind::PermissionDenied);
    assert_eq!(lines_of(&w.rig, "wifi_unavailable").len(), 1);
    assert!(lines_of(&w.rig, "wifi_unavailable")[0].contains("kind=permission_denied"));
    assert_eq!(w.open(Some(wifi_offer())), AckResult::Posted, "the channel opens all the same");
    w.assert_silent_for(1_000);
    assert!(lines_of(&w.rig, "wifi_probe_start").is_empty());
}

// ---- review fixes

#[test]
fn a_connection_without_a_probe_sealer_never_starts_probing_and_says_so() {
    let mut w = wifi_rig();
    w.rig.app.conn.as_mut().expect("connected").probe = None;
    assert_eq!(w.open(Some(wifi_offer())), AckResult::Posted);
    w.assert_silent_for(1_000);
    assert!(lines_of(&w.rig, "wifi_probe_start").is_empty());
    assert_eq!(stop_word(&w.rig), "no_sealer");
    assert!(w.rig.app.conn.as_ref().unwrap().probing.is_none());
}

#[test]
fn a_datagram_gets_the_tray_up_to_date_like_any_other_input() {
    let mut w = probing_rig();
    w.rig.injector.set_trusted(false);
    let mv = w.move_packet(16);
    w.udp(wifi_targets()[0], &mv);
    assert!(w.rig.last_tray().needs_authorization, "the state change was passed on with the datagram's effects");
    // The same when there is no connection to look at.
    let mut rig = Rig::new();
    rig.injector.set_trusted(false);
    let effects = rig.app.on_wifi_datagram(SocketAddr::V4(wifi_targets()[0]), &[0; 41]);
    rig.run(effects);
    assert!(rig.last_tray().needs_authorization);
}

#[test]
fn dropped_datagrams_write_at_most_one_debug_line_a_second_with_a_count_and_no_address() {
    let mut w = probing_rig_at(Level::Debug);
    let mv = w.move_packet(16);
    for _ in 0..50 {
        w.udp(target([8, 8, 8, 8], 53), &mv); // not a probed source
    }
    let lines = lines_of(&w.rig, "wifi_drop");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(field(&lines[0], "n"), 1);
    assert!(lines[0].contains("why=source"));
    w.rig.advance(1_000);
    w.udp(target([8, 8, 8, 8], 53), &mv);
    let lines = lines_of(&w.rig, "wifi_drop");
    assert_eq!(lines.len(), 2);
    assert_eq!(field(&lines[1], "n"), 50, "the 49 held back and this one");
    assert!(!w.rig.log_text().contains("8.8.8.8"));
}

#[test]
fn udp_packets_the_pointer_checks_refuse_write_at_most_one_pointer_drop_line_a_second_while_bluetooth_ones_all_do() {
    let mut w = probing_rig_at(Level::Debug);
    let mut forged = vec![0x03; 41];
    for i in 0..50u8 {
        forged[1] = i;
        w.udp(wifi_targets()[0], &forged);
    }
    let udp_lines: Vec<String> = lines_of(&w.rig, "pointer_drop").into_iter().filter(|l| l.contains("via=udp")).collect();
    assert_eq!(udp_lines.len(), 1, "{udp_lines:?}");
    assert_eq!(field(&udp_lines[0], "n"), 1);
    w.rig.advance(1_000);
    w.udp(wifi_targets()[0], &forged);
    let udp_lines: Vec<String> = lines_of(&w.rig, "pointer_drop").into_iter().filter(|l| l.contains("via=udp")).collect();
    assert_eq!(udp_lines.len(), 2);
    assert_eq!(field(&udp_lines[1], "n"), 50);
    // Bluetooth keeps one line for every packet it drops.
    let before = lines_of(&w.rig, "pointer_drop").iter().filter(|l| l.contains("via=ble")).count();
    for _ in 0..3 {
        w.rig.notify(forged.clone());
    }
    let after = lines_of(&w.rig, "pointer_drop").iter().filter(|l| l.contains("via=ble")).count();
    assert_eq!(after - before, 3);
}

#[test]
fn socket_errors_write_at_most_one_debug_line_a_second() {
    let mut w = wifi_rig_at(Level::Debug);
    for _ in 0..50 {
        w.rig.app.on_wifi_io("recv", std::io::ErrorKind::ConnectionReset);
    }
    let lines = lines_of(&w.rig, "wifi_io");
    assert_eq!(lines.len(), 1);
    w.rig.advance(1_000);
    w.rig.app.on_wifi_io("recv", std::io::ErrorKind::ConnectionReset);
    let lines = lines_of(&w.rig, "wifi_io");
    assert_eq!((lines.len(), field(&lines[1], "n")), (2, 50));
}
