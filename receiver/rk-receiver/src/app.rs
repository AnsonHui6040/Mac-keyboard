//! The receiver as a state machine: link events, tray commands and the clock go in, link commands and tray updates come out.
//!
//! Nothing here touches a radio, a file, a window or a clock of its own, so every rule of the connection lifecycle (handshake
//! timeout, back-off, hold-off, pairing window, status) is exercised by the tests with a fake link and a fake clock.

use crate::clock::Clock;
use crate::config::Config;
use crate::inject_log::LoggingInjector;
use crate::log::Logger;
use crate::random::{RandomSource, SharedRandom};
use crate::store::{ConfigStore, PhoneStore, StoreError};
use crate::ui::{IconState, NoticeKind, PhoneEntry, TrayState, UiCommand, UiEvent};
use rk_ble::{DeviceKey, DisconnectReason, FailKind, LinkCommand, LinkConfig, LinkEvent, Route, Value};
use rk_core::dedup::{DedupDecision, EventDeduplicator};
use rk_core::frame::{FrameReassembler, Reassembly};
use rk_core::handshake::{HostHandshake, HostOutput};
use rk_core::identity::{HostPlatform, PairedPhone, PhonePlatform, MAX_PHONES};
use rk_core::message::{encode_control, Ack, AckResult, ControlMessage, EventKind, KeyboardEvent, ReceiverStatus, UNKNOWN_EVENT_ID};
use rk_core::pairing::{HostPairing, HostPairingOutput};
use rk_core::pointer::{PointerAction, PointerEffects, PointerReceiver, PointerRejection, ScrollPhase};
use rk_core::select_uuid::{select_uuid, PAIRING_ADVERT_UUID};
use rk_inject::{Button, InjectError, Injector};
use std::sync::Arc;
use std::time::Duration;

#[cfg(test)]
mod tests;

/// §6.2: a connection that has not authenticated within this time is dropped.
const HANDSHAKE_TIMEOUT_MS: u64 = 5_000;
/// §5.1
const PAIRING_WINDOW_MS: u64 = 120_000;
/// §6.4 (Provisional)
const BACKOFF: Duration = Duration::from_secs(10);
/// §6.2, §10 (Provisional)
const HOLD_AFTER_FAILURE: Duration = Duration::from_secs(60);
/// While a pointer is playing out, how often the application wants a tick.
const FRAME_TICK_MS: u64 = 8;
const WATCHDOG_TICK_MS: u64 = 25;
/// While authenticated, how often the injector's readiness is looked at.
const STATUS_POLL_MS: u64 = 500;
const POINTER_PACKET_MAGIC: u8 = 0x03;
const FRAME_MAGIC: u8 = 0x02;

pub struct AppDeps {
    pub config: Config,
    pub platform: HostPlatform,
    pub store: Box<dyn PhoneStore>,
    pub config_store: Box<dyn ConfigStore>,
    pub injector: Box<dyn Injector>,
    pub clock: Arc<dyn Clock>,
    pub random: Box<dyn RandomSource>,
    pub logger: Logger,
}

/// What the application wants done.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Link(LinkCommand),
    Ui(UiEvent),
}

/// What the phone was last told, to know when a new `status` is due.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StatusKey {
    ready: bool,
    trusted: bool,
    grant: Option<u32>,
}

/// A pairing attempt on a connection that came through the pairing UUID.
struct Attempt {
    pairing: HostPairing,
    /// Completed and waiting for the user's yes or no.
    pending: Option<PairedPhone>,
    /// The user said yes; the phone may stay connected.
    confirmed: bool,
}

struct Conn {
    id: u64,
    device: DeviceKey,
    route: Route,
    adv_base_ms: u64,
    handshake: HostHandshake,
    reassembler: FrameReassembler,
    deadline_ms: Option<u64>,
    attempt: Option<Attempt>,
    phone: Option<([u8; 16], String)>,
    last_status: Option<StatusKey>,
}

pub struct App {
    cfg: Config,
    platform: HostPlatform,
    store: Box<dyn PhoneStore>,
    config_store: Box<dyn ConfigStore>,
    injector: LoggingInjector,
    clock: Arc<dyn Clock>,
    random: SharedRandom,
    log: Logger,
    conn: Option<Conn>,
    dedup: EventDeduplicator,
    pointer: PointerReceiver,
    pairing_until_ms: Option<u64>,
    attention: bool,
    last_adv: Option<(u64, u64)>,
    last_tray: Option<TrayState>,
}

fn kind_word(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::Text(_) => "text",
        EventKind::Backspace => "backspace",
        EventKind::ReturnKey => "enter",
        EventKind::Ping { .. } => "ping",
        EventKind::Probe => "probe",
        EventKind::PointerOpen { .. } => "pointer_open",
        EventKind::PointerClose => "pointer_close",
    }
}

fn ack_word(result: AckResult) -> &'static str {
    result.as_str()
}

fn inject_result(result: Result<(), InjectError>) -> AckResult {
    if result.is_ok() {
        AckResult::Posted
    } else {
        AckResult::InjectFailed
    }
}

impl App {
    pub fn new(deps: AppDeps) -> Self {
        let random = SharedRandom::new(deps.random);
        let grants = random.clone();
        let injector = LoggingInjector::new(deps.injector, deps.logger.clone(), deps.clock.clone());
        let pointer = PointerReceiver::new(deps.config.trackpad, Box::new(move || grants.u32()));
        Self {
            cfg: deps.config,
            platform: deps.platform,
            store: deps.store,
            config_store: deps.config_store,
            injector,
            clock: deps.clock,
            random,
            log: deps.logger,
            conn: None,
            dedup: EventDeduplicator::new(),
            pointer,
            pairing_until_ms: None,
            attention: false,
            last_adv: None,
            last_tray: None,
        }
    }

    /// What the backend scans for.
    pub fn link_config(&self) -> LinkConfig {
        LinkConfig { select: select_uuid(&self.cfg.host_id), pairing: PAIRING_ADVERT_UUID, adapter: self.cfg.adapter.clone() }
    }

    /// The configuration as it stands, for the shell.
    pub fn config(&self) -> &Config {
        &self.cfg
    }

    fn now(&self) -> u64 {
        self.clock.mono_ms()
    }

    fn now_micros(&self) -> u64 {
        self.now().saturating_mul(1000)
    }

    pub fn start(&mut self) -> Vec<Effect> {
        let mut fx = Vec::new();
        self.log.info("start", None, &[("version", Value::S(env!("CARGO_PKG_VERSION"))), ("phones", Value::U(self.store.phones().len() as u64))]);
        self.log.info("scan_start", None, &[("pairing", Value::B(false))]);
        self.flush_state(&mut fx);
        fx
    }

    // ------------------------------------------------------------ link events

    pub fn on_link(&mut self, event: LinkEvent) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            LinkEvent::Diag(diag) => {
                if diag.ev == "adv_seen" {
                    self.last_adv = Some((diag.conn, self.now()));
                }
                self.log.diag(&diag);
            }
            LinkEvent::Connected { conn, device, route, mtu } => self.on_connected(conn, device, route, mtu, &mut fx),
            LinkEvent::Notification(bytes) => self.on_notification(&bytes, &mut fx),
            LinkEvent::Disconnected { conn, reason, .. } => {
                if self.conn.as_ref().is_some_and(|c| c.id == conn) {
                    if let Some(conn) = self.conn.take() {
                        self.end_connection(&conn, reason, &mut fx);
                    }
                }
            }
        }
        self.flush_state(&mut fx);
        fx
    }

    fn on_connected(&mut self, id: u64, device: DeviceKey, route: Route, mtu: usize, fx: &mut Vec<Effect>) {
        if let Some(old) = self.conn.take() {
            self.end_connection(&old, DisconnectReason::Local, fx);
        }
        let now = self.now();
        let adv_base_ms = self.last_adv.filter(|(conn, _)| *conn == id).map_or(now, |(_, at)| at);
        let route_word = if route == Route::Selected { "selected" } else { "pairing" };
        self.log.info("scan_stop", None, &[]);
        self.log.info("link_ready", Some(id), &[("route", Value::S(route_word)), ("mtu", Value::U(mtu as u64)), ("device", Value::Id(device.short()))]);
        let handshake = HostHandshake::new(self.cfg.host_id, self.store.phones(), self.random.bytes::<16>(), route);
        let mut conn = Conn {
            id,
            device,
            route,
            adv_base_ms,
            handshake,
            reassembler: FrameReassembler::new(),
            deadline_ms: Some(now + HANDSHAKE_TIMEOUT_MS),
            attempt: None,
            phone: None,
            last_status: None,
        };
        let output = conn.handshake.begin();
        if self.handle_output(&mut conn, output, fx) {
            self.conn = Some(conn);
        }
    }

    fn on_notification(&mut self, bytes: &[u8], fx: &mut Vec<Effect>) {
        let Some(mut conn) = self.conn.take() else { return };
        let keep = match bytes.first() {
            Some(&FRAME_MAGIC) => self.on_frame(&mut conn, bytes, fx),
            Some(&POINTER_PACKET_MAGIC) => {
                self.on_pointer_packet(&mut conn, bytes, fx);
                true
            }
            other => {
                self.log.debug("notify_ignored", Some(conn.id), &[("first", Value::U(u64::from(other.copied().unwrap_or(0)))), ("len", Value::U(bytes.len() as u64))]);
                true
            }
        };
        if keep {
            self.conn = Some(conn);
        }
    }

    fn on_frame(&mut self, conn: &mut Conn, frame: &[u8], fx: &mut Vec<Effect>) -> bool {
        match conn.reassembler.accept(frame) {
            Reassembly::Incomplete => true,
            Reassembly::Rejected(_) => {
                self.log.info("frame_rejected", Some(conn.id), &[("len", Value::U(frame.len() as u64))]);
                true
            }
            Reassembly::Complete(message) => {
                self.log.debug("message_in", Some(conn.id), &[("len", Value::U(message.len() as u64))]);
                let output = conn.handshake.receive_bytes(&message);
                self.handle_output(conn, output, fx)
            }
        }
    }

    fn on_pointer_packet(&mut self, conn: &mut Conn, packet: &[u8], fx: &mut Vec<Effect>) {
        if !conn.handshake.is_authenticated() {
            return;
        }
        let effects = self.pointer.handle_packet(packet, self.now_micros());
        if let Some(rejection) = effects.rejection {
            let why = match rejection {
                PointerRejection::NotOpen => "not_open",
                PointerRejection::Channel(_) => "channel",
                PointerRejection::Unreadable => "unreadable",
            };
            self.log.debug("pointer_drop", Some(conn.id), &[("why", Value::S(why))]);
        }
        self.apply_pointer(effects, Some(conn), fx);
    }

    /// Acts on one handshake result. `false` means the connection is over and must not be kept.
    fn handle_output(&mut self, conn: &mut Conn, output: HostOutput, fx: &mut Vec<Effect>) -> bool {
        match output {
            HostOutput::None => true,
            HostOutput::Send(message) => {
                if matches!(message, ControlMessage::Hello { .. }) {
                    self.log_phase("hello_sent", conn);
                }
                fx.push(Effect::Link(LinkCommand::Write(encode_control(&message))));
                true
            }
            HostOutput::Authenticated { reply, phone_id } => {
                self.on_authenticated(conn, reply, phone_id, fx);
                true
            }
            HostOutput::PairOffer { commitment } => self.on_pair_offer(conn, &commitment, fx),
            HostOutput::PairReveal { public_key, phone_id, phone_name, phone_platform } => {
                self.on_pair_reveal(conn, &public_key, &phone_id, &phone_name, phone_platform, fx)
            }
            HostOutput::Event(event) => {
                self.handle_event(conn, &event, fx);
                true
            }
            HostOutput::MalformedPayload => {
                self.log.info("event_in", Some(conn.id), &[("kind", Value::S("unreadable")), ("ack", Value::S(ack_word(AckResult::Malformed)))]);
                self.send_ack(conn, Ack { event_id: UNKNOWN_EVENT_ID, result: AckResult::Malformed }, fx);
                true
            }
            HostOutput::AuthFailed => {
                self.log_auth(conn, "fail");
                fx.push(Effect::Link(LinkCommand::Write(encode_control(&ControlMessage::AuthFailed))));
                self.notice(NoticeKind::NeedsRepair, fx);
                self.finish(conn, FailKind::AuthFailed, self.failure_hold(), fx)
            }
            HostOutput::NotSelected => {
                self.log_auth(conn, "not_selected");
                self.finish(conn, FailKind::NotSelected, Some(BACKOFF), fx)
            }
            HostOutput::TimedOut => {
                self.log_auth(conn, "timeout");
                self.finish(conn, FailKind::Timeout, Some(BACKOFF), fx)
            }
            HostOutput::UnsupportedVersion(version) => {
                self.log.info("version_mismatch", Some(conn.id), &[("seen", Value::U(u64::try_from(version).unwrap_or(0)))]);
                self.log_auth(conn, "unsupported_version");
                self.notice(NoticeKind::UpdatePhone, fx);
                self.finish(conn, FailKind::UnsupportedVersion, self.failure_hold(), fx)
            }
        }
    }

    /// 60 s without reconnecting, except while the pairing window is open: the device may be the one being paired (§6.2).
    fn failure_hold(&self) -> Option<Duration> {
        self.pairing_until_ms.is_none().then_some(HOLD_AFTER_FAILURE)
    }

    fn on_authenticated(&mut self, conn: &mut Conn, reply: ControlMessage, phone_id: [u8; 16], fx: &mut Vec<Effect>) {
        self.log_phase("hello_reply", conn);
        self.log_auth(conn, "ok");
        fx.push(Effect::Link(LinkCommand::Write(encode_control(&reply))));
        conn.deadline_ms = None;
        let name = self.store.phones().into_iter().find(|p| p.identity.id == phone_id).map(|p| p.identity.name);
        conn.phone = Some((phone_id, name.unwrap_or_default()));
        self.attention = false;
        if let Some(channels) = conn.handshake.take_channel_set() {
            let effects = self.pointer.attach(channels);
            self.apply_pointer(effects, None, fx);
        }
        self.send_status(conn, fx);
    }

    // ------------------------------------------------------------ pairing

    fn on_pair_offer(&mut self, conn: &mut Conn, commitment: &[u8], fx: &mut Vec<Effect>) -> bool {
        let window_open = self.pairing_until_ms.is_some();
        let pairing = window_open
            .then(|| HostPairing::new(self.random.bytes::<32>(), self.cfg.host_identity(self.platform)).ok())
            .flatten();
        let Some(mut pairing) = pairing.filter(|_| conn.attempt.is_none()) else {
            self.log.info("pair_refused", Some(conn.id), &[("window_open", Value::B(window_open))]);
            return self.finish(conn, FailKind::AuthFailed, None, fx);
        };
        match pairing.receive_offer(commitment) {
            HostPairingOutput::Send(accept) => {
                fx.push(Effect::Link(LinkCommand::Write(encode_control(&accept))));
                conn.attempt = Some(Attempt { pairing, pending: None, confirmed: false });
                self.log.info("pair_accept_sent", Some(conn.id), &[]);
                true
            }
            _ => self.fail_pairing(conn, fx),
        }
    }

    fn on_pair_reveal(
        &mut self,
        conn: &mut Conn,
        public_key: &[u8],
        phone_id: &[u8],
        phone_name: &str,
        phone_platform: PhonePlatform,
        fx: &mut Vec<Effect>,
    ) -> bool {
        let Some(attempt) = conn.attempt.as_mut() else { return self.fail_pairing(conn, fx) };
        if attempt.pairing.receive_reveal(public_key, phone_id, phone_name, phone_platform) != HostPairingOutput::Completed {
            return self.fail_pairing(conn, fx);
        }
        let (Some(identity), Some(key), Some(sas)) = (attempt.pairing.phone().cloned(), attempt.pairing.pair_key().cloned(), attempt.pairing.sas().map(str::to_string)) else {
            return self.fail_pairing(conn, fx);
        };
        let known = self.store.phones();
        if known.len() >= MAX_PHONES && !known.iter().any(|p| p.identity.id == identity.id) {
            self.notice(NoticeKind::PairingStoreFull, fx);
            return self.finish(conn, FailKind::AuthFailed, None, fx);
        }
        attempt.pending = Some(PairedPhone { identity: identity.clone(), pair_key: key });
        self.log.info("pair_confirm_shown", Some(conn.id), &[]);
        fx.push(Effect::Ui(UiEvent::PairingRequest { phone_name: identity.name, sas }));
        true
    }

    fn fail_pairing(&mut self, conn: &Conn, fx: &mut Vec<Effect>) -> bool {
        self.notice(NoticeKind::PairingFailed, fx);
        self.finish(conn, FailKind::AuthFailed, None, fx)
    }

    fn close_pairing_window(&mut self, fx: &mut Vec<Effect>) {
        if self.pairing_until_ms.take().is_none() {
            return;
        }
        self.log.info("pairing_window", None, &[("state", Value::S("closed"))]);
        fx.push(Effect::Link(LinkCommand::SetPairingScan(false)));
        fx.push(Effect::Ui(UiEvent::PairingClosed));
    }

    /// Drops a pairing attempt nobody confirmed (window over, user said no).
    fn discard_unconfirmed_attempt(&mut self, fx: &mut Vec<Effect>) {
        let unconfirmed = self.conn.as_ref().is_some_and(|c| c.attempt.as_ref().is_some_and(|a| !a.confirmed));
        if unconfirmed {
            if let Some(conn) = self.conn.take() {
                self.finish(&conn, FailKind::AuthFailed, None, fx);
            }
        }
    }

    fn confirm_pairing(&mut self, accepted: bool, fx: &mut Vec<Effect>) {
        let pending = self.conn.as_mut().and_then(|c| c.attempt.as_mut()).and_then(|a| a.pending.take());
        let Some(phone) = pending else { return };
        if !accepted {
            self.log.info("pair_rejected", None, &[]);
            fx.push(Effect::Ui(UiEvent::PairingClosed));
            self.discard_unconfirmed_attempt(fx);
            return;
        }
        match self.store.save(phone) {
            Ok(()) => {
                self.log.info("pair_saved", None, &[("phones", Value::U(self.store.phones().len() as u64))]);
                if let Some(attempt) = self.conn.as_mut().and_then(|c| c.attempt.as_mut()) {
                    attempt.confirmed = true;
                }
                self.close_pairing_window(fx);
            }
            Err(error) => {
                let kind = if error == StoreError::Full { NoticeKind::PairingStoreFull } else { NoticeKind::StoreError };
                self.log.info("pair_save_failed", None, &[]);
                self.notice(kind, fx);
                self.discard_unconfirmed_attempt(fx);
            }
        }
    }

    // ------------------------------------------------------------ events

    fn handle_event(&mut self, conn: &mut Conn, event: &KeyboardEvent, fx: &mut Vec<Effect>) {
        let (result, fresh) = match self.dedup.check(event) {
            DedupDecision::Duplicate(original) => (original, false),
            DedupDecision::OutOfOrder => (AckResult::OutOfOrder, false),
            DedupDecision::Fresh | DedupDecision::Exempt => (self.perform(conn, event, fx), true),
        };
        if fresh {
            self.dedup.record(event, result);
        }
        let len = if let EventKind::Text(text) = &event.kind { text.len() as u64 } else { 0 };
        self.log.info(
            "event_in",
            Some(conn.id),
            &[("kind", Value::S(kind_word(&event.kind))), ("len", Value::U(len)), ("dup", Value::B(!fresh)), ("ack", Value::S(ack_word(result)))],
        );
        self.send_ack(conn, Ack { event_id: event.event_id, result }, fx);
    }

    fn perform(&mut self, conn: &mut Conn, event: &KeyboardEvent, fx: &mut Vec<Effect>) -> AckResult {
        match &event.kind {
            _ if !event.is_well_formed() => AckResult::Malformed,
            EventKind::Text(text) => inject_result(self.injector.text(text)),
            EventKind::Backspace => inject_result(self.injector.backspace()),
            EventKind::ReturnKey => inject_result(self.injector.enter()),
            EventKind::Ping { .. } | EventKind::Probe => AckResult::Pong,
            EventKind::PointerOpen { grant } => {
                let effects = self.pointer.handle_open(*grant);
                self.finish_pointer_event(effects, conn, fx)
            }
            EventKind::PointerClose => {
                let effects = self.pointer.handle_close();
                self.finish_pointer_event(effects, conn, fx)
            }
        }
    }

    fn finish_pointer_event(&mut self, mut effects: PointerEffects, conn: &mut Conn, fx: &mut Vec<Effect>) -> AckResult {
        let ack = effects.ack.take().unwrap_or(AckResult::Posted);
        self.apply_pointer(effects, Some(conn), fx);
        ack
    }

    /// Performs what the pointer logic decided and sends a new `status` when its grant changed.
    fn apply_pointer(&mut self, effects: PointerEffects, conn: Option<&mut Conn>, fx: &mut Vec<Effect>) {
        for action in &effects.actions {
            // A failed injection is in the log already; the pointer has no ack to carry it.
            let _ = match *action {
                PointerAction::Move { dx, dy, .. } => self.injector.pointer_move(dx, dy),
                PointerAction::Click { count } => self.injector.click(Button::Left, count),
                PointerAction::RightClick => self.injector.click(Button::Right, 1),
                PointerAction::LeftButton { down } => self.injector.button(Button::Left, down),
                PointerAction::Scroll { phase: ScrollPhase::Ended | ScrollPhase::Cancelled, .. } => Ok(()),
                PointerAction::Scroll { dx, dy, .. } => self.injector.scroll(dx, dy),
            };
        }
        if effects.status_changed {
            if let Some(conn) = conn.filter(|c| c.handshake.is_authenticated()) {
                self.send_status(conn, fx);
            }
        }
    }

    // ------------------------------------------------------------ writing to the phone

    fn seal_and_write(&mut self, conn: &Conn, message: &ControlMessage, fx: &mut Vec<Effect>) {
        let nonce = self.random.bytes::<12>();
        match conn.handshake.seal_control(message, &nonce) {
            Ok(sealed) => fx.push(Effect::Link(LinkCommand::Write(encode_control(&sealed)))),
            Err(_) => self.log.info("seal_failed", Some(conn.id), &[]),
        }
    }

    fn send_ack(&mut self, conn: &Conn, ack: Ack, fx: &mut Vec<Effect>) {
        self.seal_and_write(conn, &ControlMessage::Ack(ack), fx);
    }

    fn status_key(&self) -> StatusKey {
        StatusKey { ready: self.injector.ready(), trusted: self.injector.trusted(), grant: self.pointer.grant() }
    }

    fn send_status(&mut self, conn: &mut Conn, fx: &mut Vec<Effect>) {
        let key = self.status_key();
        let mut status = ReceiverStatus::new(key.ready, 1);
        status.trusted = key.trusted;
        status.pointer_grant = key.grant;
        conn.last_status = Some(key);
        self.log.info(
            "status_sent",
            Some(conn.id),
            &[("ready", Value::B(key.ready)), ("trusted", Value::B(key.trusted)), ("grant", Value::B(key.grant.is_some()))],
        );
        self.seal_and_write(conn, &ControlMessage::Status(status), fx);
    }

    fn say_bye(&mut self, conn: &Conn, fx: &mut Vec<Effect>) {
        if conn.handshake.is_authenticated() {
            self.seal_and_write(conn, &ControlMessage::Bye, fx);
        }
    }

    // ------------------------------------------------------------ ending a connection

    /// The connection ends by our decision: release the link, hold the device off for a while, forget the connection.
    /// Always returns `false` so a handler can pass it on as "do not keep".
    fn finish(&mut self, conn: &Conn, kind: FailKind, hold: Option<Duration>, fx: &mut Vec<Effect>) -> bool {
        fx.push(Effect::Link(LinkCommand::Disconnect));
        if let Some(for_) = hold {
            self.log.info("hold", Some(conn.id), &[("secs", Value::U(for_.as_secs())), ("device", Value::Id(conn.device.short()))]);
            fx.push(Effect::Link(LinkCommand::Hold { device: conn.device, for_ }));
        }
        self.end_connection(conn, DisconnectReason::Failed(kind), fx);
        false
    }

    /// Ends a connection the application let go of without any failure.
    fn release(&mut self, conn: Conn, fx: &mut Vec<Effect>) {
        fx.push(Effect::Link(LinkCommand::Disconnect));
        self.end_connection(&conn, DisconnectReason::Local, fx);
    }

    /// Bookkeeping when a connection is over, whoever ended it.
    fn end_connection(&mut self, conn: &Conn, reason: DisconnectReason, fx: &mut Vec<Effect>) {
        let effects = self.pointer.detach();
        self.apply_pointer(effects, None, fx);
        let ms = self.now().saturating_sub(conn.adv_base_ms);
        self.log.info("disconnected", Some(conn.id), &[("ms", Value::U(ms)), ("reason", Value::S(reason.as_str()))]);
        if let Some(attempt) = &conn.attempt {
            if attempt.pending.is_some() {
                fx.push(Effect::Ui(UiEvent::PairingClosed));
            }
        }
        self.log.info("scan_start", None, &[("pairing", Value::B(self.pairing_until_ms.is_some()))]);
    }

    fn log_phase(&self, ev: &'static str, conn: &Conn) {
        self.log.info(ev, Some(conn.id), &[("ms", Value::U(self.now().saturating_sub(conn.adv_base_ms)))]);
    }

    fn log_auth(&self, conn: &Conn, result: &'static str) {
        self.log.info("auth", Some(conn.id), &[("ms", Value::U(self.now().saturating_sub(conn.adv_base_ms))), ("result", Value::S(result))]);
    }

    fn notice(&mut self, kind: NoticeKind, fx: &mut Vec<Effect>) {
        if matches!(kind, NoticeKind::NeedsRepair | NoticeKind::UpdatePhone) {
            self.attention = true;
        }
        fx.push(Effect::Ui(UiEvent::Notice(kind)));
    }

    // ------------------------------------------------------------ tray commands

    pub fn on_ui(&mut self, command: UiCommand) -> Vec<Effect> {
        let mut fx = Vec::new();
        match command {
            UiCommand::StartPairing => self.start_pairing(&mut fx),
            UiCommand::ConfirmPairing(accepted) => self.confirm_pairing(accepted, &mut fx),
            UiCommand::Rename(name) => {
                self.cfg.set_host_name(&name, self.platform);
                self.save_config("rename", &mut fx);
            }
            UiCommand::DeletePhone(id) => self.delete_phone(&id, &mut fx),
            UiCommand::SetTrackpad(on) => {
                self.cfg.trackpad = on;
                self.save_config("trackpad", &mut fx);
                let effects = self.pointer.set_enabled(on);
                let mut conn = self.conn.take();
                self.apply_pointer(effects, conn.as_mut(), &mut fx);
                self.conn = conn;
            }
            UiCommand::SetAutostart(on) => {
                self.cfg.autostart = on;
                self.save_config("autostart", &mut fx);
            }
            UiCommand::SetPasteNonAscii(on) => {
                self.cfg.paste_non_ascii = on;
                self.save_config("paste_non_ascii", &mut fx);
            }
            UiCommand::Reauthorize => {}
            UiCommand::Quit => self.quit(&mut fx),
        }
        self.flush_state(&mut fx);
        fx
    }

    fn start_pairing(&mut self, fx: &mut Vec<Effect>) {
        self.pairing_until_ms = Some(self.now() + PAIRING_WINDOW_MS);
        self.log.info("pairing_window", None, &[("state", Value::S("open"))]);
        fx.push(Effect::Link(LinkCommand::SetPairingScan(true)));
    }

    fn save_config(&mut self, what: &'static str, fx: &mut Vec<Effect>) {
        self.log.info("config_changed", None, &[("what", Value::S(what))]);
        if self.config_store.save(&self.cfg).is_err() {
            self.log.info("config_save_failed", None, &[]);
            self.notice(NoticeKind::StoreError, fx);
        }
    }

    fn delete_phone(&mut self, id: &[u8; 16], fx: &mut Vec<Effect>) {
        if self.store.delete(id).is_err() {
            self.notice(NoticeKind::StoreError, fx);
            return;
        }
        self.log.info("phone_deleted", None, &[("phones", Value::U(self.store.phones().len() as u64))]);
        let Some(conn) = self.conn.take() else { return };
        let is_that_phone = conn.phone.as_ref().is_some_and(|(phone, _)| phone == id);
        let still_handshaking = conn.route == Route::Selected && !conn.handshake.is_authenticated();
        if is_that_phone || still_handshaking {
            // A handshake in progress holds a copy of the key that was just deleted.
            self.say_bye(&conn, fx);
            self.release(conn, fx);
        } else {
            self.conn = Some(conn);
        }
    }

    fn quit(&mut self, fx: &mut Vec<Effect>) {
        self.close_pairing_window(fx);
        if let Some(conn) = self.conn.take() {
            self.say_bye(&conn, fx);
            self.release(conn, fx);
        }
    }

    // ------------------------------------------------------------ time

    pub fn on_tick(&mut self) -> Vec<Effect> {
        let mut fx = Vec::new();
        let now = self.now();
        if self.pairing_until_ms.is_some_and(|until| now >= until) {
            self.close_pairing_window(&mut fx);
            self.discard_unconfirmed_attempt(&mut fx);
        }
        self.tick_connection(now, &mut fx);
        self.tick_pointer(&mut fx);
        self.flush_state(&mut fx);
        fx
    }

    fn tick_connection(&mut self, now: u64, fx: &mut Vec<Effect>) {
        let Some(mut conn) = self.conn.take() else { return };
        if conn.deadline_ms.is_some_and(|deadline| now >= deadline) {
            conn.deadline_ms = None;
            let output = conn.handshake.on_timeout();
            if !self.handle_output(&mut conn, output, fx) {
                return;
            }
        }
        if conn.handshake.is_authenticated() && conn.last_status != Some(self.status_key()) {
            self.send_status(&mut conn, fx);
        }
        self.conn = Some(conn);
    }

    fn tick_pointer(&mut self, fx: &mut Vec<Effect>) {
        let now = self.now_micros();
        let mut conn = self.conn.take();
        if self.pointer.needs_frames() {
            let effects = self.pointer.frame_tick(now);
            self.apply_pointer(effects, conn.as_mut(), fx);
        }
        if self.pointer.needs_watchdog() {
            let effects = self.pointer.watchdog_tick(now);
            self.apply_pointer(effects, conn.as_mut(), fx);
        }
        self.conn = conn;
    }

    /// The monotonic time (ms) at which the application next wants `on_tick`, if it wants one.
    pub fn next_wake_ms(&self) -> Option<u64> {
        let now = self.now();
        let mut wakes: Vec<u64> = Vec::new();
        wakes.extend(self.pairing_until_ms);
        if let Some(conn) = &self.conn {
            wakes.extend(conn.deadline_ms);
            if conn.handshake.is_authenticated() {
                wakes.push(now + STATUS_POLL_MS);
            }
        }
        if self.pointer.needs_frames() {
            wakes.push(now + FRAME_TICK_MS);
        }
        if self.pointer.needs_watchdog() {
            wakes.push(now + WATCHDOG_TICK_MS);
        }
        wakes.into_iter().min()
    }

    // ------------------------------------------------------------ tray state

    fn tray_state(&self) -> TrayState {
        let authenticated = self.conn.as_ref().is_some_and(|c| c.handshake.is_authenticated());
        let icon = if authenticated {
            IconState::Connected
        } else if self.attention {
            IconState::Attention
        } else {
            IconState::Disconnected
        };
        TrayState {
            icon,
            connected_phone: self.conn.as_ref().filter(|c| c.handshake.is_authenticated()).and_then(|c| c.phone.as_ref()).map(|(_, name)| name.clone()),
            pairing_open: self.pairing_until_ms.is_some(),
            host_name: self.cfg.host_name.clone(),
            phones: self.store.phones().into_iter().map(|p: PairedPhone| PhoneEntry { id: p.identity.id, name: p.identity.name }).collect(),
            trackpad: self.cfg.trackpad,
            autostart: self.cfg.autostart,
            paste_non_ascii: self.cfg.paste_non_ascii,
        }
    }

    /// Tells the tray about the state when it differs from what it was last told.
    fn flush_state(&mut self, fx: &mut Vec<Effect>) {
        let state = self.tray_state();
        if self.last_tray.as_ref() != Some(&state) {
            self.last_tray = Some(state.clone());
            fx.push(Effect::Ui(UiEvent::State(state)));
        }
    }
}
