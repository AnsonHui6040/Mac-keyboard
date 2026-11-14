//! The application driven the way the radio and the tray drive it: a fake link, a recording injector, an in-memory store,
//! a clock the test moves and a phone built from `rk_core`.

use super::*;
use crate::clock::FakeClock;
use crate::config::Config;
use crate::log::{Level, MemorySink};
use crate::random::SequenceRandom;
use crate::store::{MemoryConfigStore, MemoryPhoneStore};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rk_ble::fake::FakeLink;
use rk_ble::{DeviceKey, DisconnectReason};
use rk_core::channel::ChannelSet;
use rk_core::frame::split_frames;
use rk_core::handshake::{PhoneHandshake, PhoneOutput};
use rk_core::identity::{HostPlatform, PairedPhone, PhoneIdentity, PhonePlatform};
use rk_core::message::{
    decode_control, encode_peripheral, Ack, AckResult, ControlMessage, EventKind, KeyboardEvent, PeripheralMessage,
    ReceiverStatus,
};
use rk_core::pairing::{PhonePairing, PhonePairingOutput};
use rk_core::pointer::{Opcode, PointerPayload};
use rk_core::secret::PairKey;
use rk_inject::{Button, Call, RecordingInjector};
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
}

impl Rig {
    fn new() -> Self {
        Self::with_level(Level::Info)
    }

    fn with_level(level: Level) -> Self {
        let clock = Arc::new(FakeClock::new(T0));
        let logs = MemorySink::new();
        let logger = Logger::new(Box::new(logs.clone()), clock.clone(), level);
        let injector = RecordingInjector::new();
        let store = MemoryPhoneStore::new();
        let configs = MemoryConfigStore::new();
        let app = App::new(AppDeps {
            config: Config::new(HOST_ID, HostPlatform::Windows),
            platform: HostPlatform::Windows,
            store: Box::new(store.clone()),
            config_store: Box::new(configs.clone()),
            injector: Box::new(injector.clone()),
            clock: clock.clone(),
            random: Box::new(SequenceRandom::default()),
            logger,
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
    rig.command(UiCommand::ConfirmPairing(true));
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
    rig.command(UiCommand::ConfirmPairing(false));
    assert!(rig.store.phones().is_empty());
    assert!(!rig.link.is_connected(), "the attempt is dropped with its connection");
}

#[test]
fn pairing_window_expiring_before_confirmation_saves_nothing() {
    let mut rig = Rig::new();
    rig.pair_up_to_confirmation("Phone");
    rig.advance(120_000);
    rig.command(UiCommand::ConfirmPairing(true));
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
fn the_receiver_starts_by_scanning_and_logs_it() {
    let rig = Rig::new();
    assert!(rig.log_text().contains("ev=start"));
    assert!(rig.log_text().contains("ev=scan_start"));
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
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant: grant.wrapping_add(1) });
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::NotAuthorized);
    rig.send_event(&phone, 2, EventKind::PointerOpen { grant });
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
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant: 7 });
    assert_eq!(rig.acks(&mut phone)[0].result, AckResult::NotAuthorized);
}

#[test]
fn pointer_packets_reach_the_injector_once_the_channel_is_open() {
    let (mut rig, mut phone, mut channels, grant) = pointer_rig();
    // Not open yet: dropped.
    rig.notify(packet(&mut channels, PointerPayload::new(Opcode::Click, 0, 0, 0, 0, 1)));
    assert!(rig.injector.calls().is_empty());
    rig.send_event(&phone, 1, EventKind::PointerOpen { grant });
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

// ---------------------------------------------------------------- end to end and the log

#[test]
fn end_to_end_with_rust_phone() {
    let mut rig = Rig::new();
    // Pair.
    let (pairing, sas) = rig.pair_up_to_confirmation("Anson 的 iPhone");
    assert_eq!(sas.len(), 6);
    rig.command(UiCommand::ConfirmPairing(true));
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
    rig.command(UiCommand::ConfirmPairing(true));
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
    rig.send_event(&phone, 2, EventKind::PointerOpen { grant });
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
