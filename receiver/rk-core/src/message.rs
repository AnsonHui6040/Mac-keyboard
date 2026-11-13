//! Message shapes and their canonical JSON (protocol v4 §3).

use crate::identity::{HostPlatform, PhonePlatform};
use crate::json::Json;
use std::collections::BTreeMap;
use std::fmt;
use thiserror::Error;
use uuid::Uuid;

/// The protocol version carried by every phone-to-host message (§3.3).
pub const PROTOCOL_VERSION: i64 = 4;

/// Why bytes are not a message (§3.1, §10).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CodecError {
    /// Not JSON, a missing or mistyped field, bad base64, or an unknown type or enum string.
    #[error("malformed message")]
    Malformed,
    /// A well-formed `protocolVersion` other than 4 (§10).
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(i64),
}

/// An `ack` result code (§3.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AckResult {
    Posted,
    NotAuthorized,
    NoFocus,
    StaleFocus,
    SwitchFailed,
    CompositionActive,
    InjectFailed,
    Malformed,
    Pong,
    OutOfOrder,
}

impl AckResult {
    /// The wire string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Posted => "posted",
            Self::NotAuthorized => "notAuthorized",
            Self::NoFocus => "noFocus",
            Self::StaleFocus => "staleFocus",
            Self::SwitchFailed => "switchFailed",
            Self::CompositionActive => "compositionActive",
            Self::InjectFailed => "injectFailed",
            Self::Malformed => "malformed",
            Self::Pong => "pong",
            Self::OutOfOrder => "outOfOrder",
        }
    }
    /// The code for a wire string.
    pub fn from_wire(s: &str) -> Option<Self> {
        Some(match s {
            "posted" => Self::Posted,
            "notAuthorized" => Self::NotAuthorized,
            "noFocus" => Self::NoFocus,
            "staleFocus" => Self::StaleFocus,
            "switchFailed" => Self::SwitchFailed,
            "compositionActive" => Self::CompositionActive,
            "injectFailed" => Self::InjectFailed,
            "malformed" => Self::Malformed,
            "pong" => Self::Pong,
            "outOfOrder" => Self::OutOfOrder,
            _ => return None,
        })
    }
}

/// The `eventId` an `ack` carries when the event could not be read far enough to know it (§3.5).
pub const UNKNOWN_EVENT_ID: Uuid = Uuid::nil();

/// The host's answer to one event (§3.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ack {
    pub event_id: Uuid,
    pub result: AckResult,
}

/// What the host tells the keyboard about itself (§9).
#[derive(Clone, PartialEq, Eq)]
pub struct ReceiverStatus {
    pub ready: bool,
    pub app_name: Option<String>,
    pub focus_epoch: u64,
    /// Written only when false (§9).
    pub trusted: bool,
    /// Written only when true (§9).
    pub measure: bool,
    pub pointer_grant: Option<u32>,
    /// Written only when true (§9).
    pub input_blocked: bool,
}

impl ReceiverStatus {
    /// A status with every optional field at its wire default (trusted, no measure, no grant, not blocked).
    pub fn new(ready: bool, focus_epoch: u64) -> Self {
        Self { ready, app_name: None, focus_epoch, trusted: true, measure: false, pointer_grant: None, input_blocked: false }
    }
}

impl fmt::Debug for ReceiverStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReceiverStatus")
            .field("ready", &self.ready)
            .field("app_name_len", &self.app_name.as_ref().map(|s| s.len()))
            .field("focus_epoch", &self.focus_epoch)
            .field("trusted", &self.trusted)
            .field("measure", &self.measure)
            .field("has_pointer_grant", &self.pointer_grant.is_some())
            .field("input_blocked", &self.input_blocked)
            .finish()
    }
}

/// What one key press means (§3.4).
#[derive(Clone, PartialEq, Eq)]
pub enum EventKind {
    Text(String),
    Backspace,
    ReturnKey,
    Ping { shown_at_ms: i64, connected_at_ms: i64 },
    Probe,
    PointerOpen { grant: u32 },
    PointerClose,
}

impl EventKind {
    /// Whether the event carries a `focusEpoch` (§3.4: not for `ping`, `probe`, `pointerOpen`, `pointerClose`).
    pub fn carries_focus_epoch(&self) -> bool {
        !matches!(self, Self::Ping { .. } | Self::Probe | Self::PointerOpen { .. } | Self::PointerClose)
    }
}

impl fmt::Debug for EventKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text(s) => write!(f, "Text(utf8_len={})", s.len()),
            Self::Backspace => f.write_str("Backspace"),
            Self::ReturnKey => f.write_str("ReturnKey"),
            Self::Ping { .. } => f.write_str("Ping"),
            Self::Probe => f.write_str("Probe"),
            Self::PointerOpen { .. } => f.write_str("PointerOpen"),
            Self::PointerClose => f.write_str("PointerClose"),
        }
    }
}

/// One keyboard event (§3.4). `protocolVersion` is always 4 on the wire and is not stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyboardEvent {
    pub event_id: Uuid,
    pub session_id: Uuid,
    pub seq: u64,
    pub focus_epoch: Option<u64>,
    pub kind: EventKind,
}

impl KeyboardEvent {
    /// `false` for a text event whose text is empty (§3.4): the host answers `malformed` and types nothing (§3.5).
    pub fn is_well_formed(&self) -> bool {
        !matches!(&self.kind, EventKind::Text(text) if text.is_empty())
    }
}

/// Host to phone, written to `control` (§3.2).
#[derive(Clone, PartialEq, Eq)]
pub enum ControlMessage {
    Ack(Ack),
    Status(ReceiverStatus),
    PairAccept { public_key: Vec<u8>, host_id: Vec<u8>, host_name: String, platform: HostPlatform },
    Hello { host_id: Vec<u8>, host_nonce: Vec<u8> },
    Auth { proof: Vec<u8> },
    AuthFailed,
    Bye,
    Sealed(Vec<u8>),
}

/// Phone to host, notified on `event` (§3.3).
#[derive(Clone, PartialEq, Eq)]
pub enum PeripheralMessage {
    Event(KeyboardEvent),
    PairOffer { commitment: Vec<u8> },
    PairReveal { public_key: Vec<u8>, phone_id: Vec<u8>, phone_name: String, phone_platform: PhonePlatform },
    HelloReply { phone_nonce: Vec<u8>, proof: Vec<u8> },
    NotSelected,
    Sealed(Vec<u8>),
}

impl fmt::Debug for ControlMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ack(a) => write!(f, "Ack({a:?})"),
            Self::Status(s) => write!(f, "Status({s:?})"),
            Self::PairAccept { public_key, host_id, host_name, platform } => write!(
                f,
                "PairAccept {{ public_key_len: {}, host_id_len: {}, host_name_len: {}, platform: {platform:?} }}",
                public_key.len(),
                host_id.len(),
                host_name.len()
            ),
            Self::Hello { host_id, host_nonce } => {
                write!(f, "Hello {{ host_id_len: {}, host_nonce_len: {} }}", host_id.len(), host_nonce.len())
            }
            Self::Auth { proof } => write!(f, "Auth {{ proof_len: {} }}", proof.len()),
            Self::AuthFailed => f.write_str("AuthFailed"),
            Self::Bye => f.write_str("Bye"),
            Self::Sealed(p) => write!(f, "Sealed {{ len: {} }}", p.len()),
        }
    }
}

impl fmt::Debug for PeripheralMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Event(e) => write!(f, "Event({e:?})"),
            Self::PairOffer { commitment } => write!(f, "PairOffer {{ commitment_len: {} }}", commitment.len()),
            Self::PairReveal { public_key, phone_id, phone_name, phone_platform } => write!(
                f,
                "PairReveal {{ public_key_len: {}, phone_id_len: {}, phone_name_len: {}, phone_platform: {phone_platform:?} }}",
                public_key.len(),
                phone_id.len(),
                phone_name.len()
            ),
            Self::HelloReply { phone_nonce, proof } => {
                write!(f, "HelloReply {{ phone_nonce_len: {}, proof_len: {} }}", phone_nonce.len(), proof.len())
            }
            Self::NotSelected => f.write_str("NotSelected"),
            Self::Sealed(p) => write!(f, "Sealed {{ len: {} }}", p.len()),
        }
    }
}

type Object = BTreeMap<String, Json>;

fn single(name: &str, content: Json) -> Json {
    Json::object([(name, content)])
}

fn nested(value: Json) -> Json {
    Json::object([("_0", value)])
}

impl Ack {
    fn to_json(self) -> Json {
        Json::object([("eventId", Json::uuid(&self.event_id)), ("result", Json::string(self.result.as_str()))])
    }
}

impl ReceiverStatus {
    fn to_json(&self) -> Json {
        let mut o: Vec<(&str, Json)> = vec![("ready", Json::Bool(self.ready)), ("focusEpoch", Json::uint(self.focus_epoch))];
        if let Some(name) = &self.app_name {
            o.push(("appName", Json::string(name)));
        }
        if !self.trusted {
            o.push(("trusted", Json::Bool(false)));
        }
        if self.measure {
            o.push(("measure", Json::Bool(true)));
        }
        if let Some(grant) = self.pointer_grant {
            o.push(("pointerGrant", Json::uint(u64::from(grant))));
        }
        if self.input_blocked {
            o.push(("inputBlocked", Json::Bool(true)));
        }
        Json::object(o)
    }
}

impl EventKind {
    fn to_json(&self) -> Json {
        match self {
            Self::Text(s) => single("text", nested(Json::string(s))),
            Self::Backspace => single("backspace", Json::object([])),
            Self::ReturnKey => single("returnKey", Json::object([])),
            Self::Ping { shown_at_ms, connected_at_ms } => {
                single("ping", Json::object([("c", Json::int(*connected_at_ms)), ("s", Json::int(*shown_at_ms))]))
            }
            Self::Probe => single("probe", Json::object([])),
            Self::PointerOpen { grant } => single("pointerOpen", Json::object([("grant", Json::uint(u64::from(*grant)))])),
            Self::PointerClose => single("pointerClose", Json::object([])),
        }
    }
}

impl KeyboardEvent {
    fn fields(&self) -> Vec<(&'static str, Json)> {
        let mut o = vec![
            ("eventId", Json::uuid(&self.event_id)),
            ("sessionId", Json::uuid(&self.session_id)),
            ("seq", Json::uint(self.seq)),
            ("kind", self.kind.to_json()),
        ];
        if let Some(epoch) = self.focus_epoch {
            o.push(("focusEpoch", Json::uint(epoch)));
        }
        o
    }
}

/// Canonical bytes of a `ControlMessage` (§3.1, §3.2).
pub fn encode_control(m: &ControlMessage) -> Vec<u8> {
    let json = match m {
        ControlMessage::Ack(a) => single("ack", nested(a.to_json())),
        ControlMessage::Status(s) => single("status", nested(s.to_json())),
        ControlMessage::PairAccept { public_key, host_id, host_name, platform } => single(
            "pairAccept",
            Json::object([
                ("hostId", Json::bytes(host_id)),
                ("hostName", Json::string(host_name)),
                ("platform", Json::string(platform.as_str())),
                ("publicKey", Json::bytes(public_key)),
            ]),
        ),
        ControlMessage::Hello { host_id, host_nonce } => {
            single("hello", Json::object([("hostId", Json::bytes(host_id)), ("hostNonce", Json::bytes(host_nonce))]))
        }
        ControlMessage::Auth { proof } => single("auth", Json::object([("proof", Json::bytes(proof))])),
        ControlMessage::AuthFailed => single("authFailed", Json::object([])),
        ControlMessage::Bye => single("bye", Json::object([])),
        ControlMessage::Sealed(payload) => single("sealed", nested(Json::bytes(payload))),
    };
    json.to_bytes()
}

/// Canonical bytes of a `PeripheralMessage` (§3.1, §3.3).
pub fn encode_peripheral(m: &PeripheralMessage) -> Vec<u8> {
    let mut fields: Vec<(&str, Json)> = vec![("protocolVersion", Json::int(PROTOCOL_VERSION))];
    match m {
        PeripheralMessage::Event(e) => {
            fields.push(("type", Json::string("event")));
            fields.extend(e.fields());
        }
        PeripheralMessage::PairOffer { commitment } => {
            fields.push(("type", Json::string("pairOffer")));
            fields.push(("commitment", Json::bytes(commitment)));
        }
        PeripheralMessage::PairReveal { public_key, phone_id, phone_name, phone_platform } => {
            fields.push(("type", Json::string("pairReveal")));
            fields.push(("publicKey", Json::bytes(public_key)));
            fields.push(("phoneId", Json::bytes(phone_id)));
            fields.push(("phoneName", Json::string(phone_name)));
            fields.push(("phonePlatform", Json::string(phone_platform.as_str())));
        }
        PeripheralMessage::HelloReply { phone_nonce, proof } => {
            fields.push(("type", Json::string("helloReply")));
            fields.push(("phoneNonce", Json::bytes(phone_nonce)));
            fields.push(("proof", Json::bytes(proof)));
        }
        PeripheralMessage::NotSelected => fields.push(("type", Json::string("notSelected"))),
        PeripheralMessage::Sealed(payload) => {
            fields.push(("type", Json::string("sealed")));
            fields.push(("payload", Json::bytes(payload)));
        }
    }
    Json::object(fields).to_bytes()
}

// Decoding helpers. A missing key and a null read the same for a required field; for an optional field both mean absent.

fn field<'a>(o: &'a Object, key: &str) -> Result<&'a Json, CodecError> {
    match o.get(key) {
        Some(Json::Null) | None => Err(CodecError::Malformed),
        Some(v) => Ok(v),
    }
}

fn optional<'a>(o: &'a Object, key: &str) -> Option<&'a Json> {
    match o.get(key) {
        Some(Json::Null) | None => None,
        Some(v) => Some(v),
    }
}

fn object_field<'a>(o: &'a Object, key: &str) -> Result<&'a Object, CodecError> {
    field(o, key)?.as_object().ok_or(CodecError::Malformed)
}

fn bytes_field(o: &Object, key: &str) -> Result<Vec<u8>, CodecError> {
    field(o, key)?.as_bytes().ok_or(CodecError::Malformed)
}

fn string_field(o: &Object, key: &str) -> Result<String, CodecError> {
    field(o, key)?.as_str().map(str::to_string).ok_or(CodecError::Malformed)
}

fn uuid_field(o: &Object, key: &str) -> Result<Uuid, CodecError> {
    field(o, key)?.as_uuid().ok_or(CodecError::Malformed)
}

fn u64_field(o: &Object, key: &str) -> Result<u64, CodecError> {
    field(o, key)?.as_u64().ok_or(CodecError::Malformed)
}

fn i64_field(o: &Object, key: &str) -> Result<i64, CodecError> {
    field(o, key)?.as_i64().ok_or(CodecError::Malformed)
}

fn u32_field(o: &Object, key: &str) -> Result<u32, CodecError> {
    u32::try_from(u64_field(o, key)?).map_err(|_| CodecError::Malformed)
}

fn optional_u64(o: &Object, key: &str) -> Result<Option<u64>, CodecError> {
    optional(o, key).map(|v| v.as_u64().ok_or(CodecError::Malformed)).transpose()
}

fn optional_bool(o: &Object, key: &str, default: bool) -> Result<bool, CodecError> {
    optional(o, key).map_or(Ok(default), |v| v.as_bool().ok_or(CodecError::Malformed))
}

/// The one recognised key of an object that carries a name (`ControlMessage`, `EventKind`); zero or several is an error.
fn the_one_name(o: &Object, names: &[&'static str]) -> Result<&'static str, CodecError> {
    let mut found = names.iter().copied().filter(|n| o.contains_key(*n));
    match (found.next(), found.next()) {
        (Some(name), None) => Ok(name),
        _ => Err(CodecError::Malformed),
    }
}

fn parse_ack(o: &Object) -> Result<Ack, CodecError> {
    let result = AckResult::from_wire(field(o, "result")?.as_str().ok_or(CodecError::Malformed)?).ok_or(CodecError::Malformed)?;
    Ok(Ack { event_id: uuid_field(o, "eventId")?, result })
}

fn parse_status(o: &Object) -> Result<ReceiverStatus, CodecError> {
    Ok(ReceiverStatus {
        ready: field(o, "ready")?.as_bool().ok_or(CodecError::Malformed)?,
        app_name: optional(o, "appName").map(|v| v.as_str().map(str::to_string).ok_or(CodecError::Malformed)).transpose()?,
        focus_epoch: u64_field(o, "focusEpoch")?,
        trusted: optional_bool(o, "trusted", true)?,
        measure: optional_bool(o, "measure", false)?,
        pointer_grant: optional_u64(o, "pointerGrant")?.map(|g| u32::try_from(g).map_err(|_| CodecError::Malformed)).transpose()?,
        input_blocked: optional_bool(o, "inputBlocked", false)?,
    })
}

fn parse_kind(o: &Object) -> Result<EventKind, CodecError> {
    const NAMES: [&str; 7] = ["text", "backspace", "returnKey", "ping", "probe", "pointerOpen", "pointerClose"];
    let name = the_one_name(o, &NAMES)?;
    let body = object_field(o, name)?;
    Ok(match name {
        "text" => EventKind::Text(string_field(object_field(o, "text")?, "_0")?),
        "backspace" => EventKind::Backspace,
        "returnKey" => EventKind::ReturnKey,
        "ping" => EventKind::Ping { shown_at_ms: i64_field(body, "s")?, connected_at_ms: i64_field(body, "c")? },
        "probe" => EventKind::Probe,
        "pointerOpen" => EventKind::PointerOpen { grant: u32_field(body, "grant")? },
        _ => EventKind::PointerClose,
    })
}

fn parse_event(o: &Object) -> Result<KeyboardEvent, CodecError> {
    Ok(KeyboardEvent {
        event_id: uuid_field(o, "eventId")?,
        session_id: uuid_field(o, "sessionId")?,
        seq: u64_field(o, "seq")?,
        focus_epoch: optional_u64(o, "focusEpoch")?,
        kind: parse_kind(object_field(o, "kind")?)?,
    })
}

fn platform_field<T>(o: &Object, key: &str, from_wire: fn(&str) -> Option<T>) -> Result<T, CodecError> {
    from_wire(field(o, key)?.as_str().ok_or(CodecError::Malformed)?).ok_or(CodecError::Malformed)
}

/// Reads a `ControlMessage`; exactly one recognised name is required (§3.2).
pub fn decode_control(bytes: &[u8]) -> Result<ControlMessage, CodecError> {
    const NAMES: [&str; 8] = ["ack", "status", "pairAccept", "hello", "auth", "authFailed", "bye", "sealed"];
    let json = Json::parse(bytes).map_err(|_| CodecError::Malformed)?;
    let outer = json.as_object().ok_or(CodecError::Malformed)?;
    let name = the_one_name(outer, &NAMES)?;
    let body = object_field(outer, name)?;
    Ok(match name {
        "ack" => ControlMessage::Ack(parse_ack(object_field(body, "_0")?)?),
        "status" => ControlMessage::Status(parse_status(object_field(body, "_0")?)?),
        "pairAccept" => ControlMessage::PairAccept {
            public_key: bytes_field(body, "publicKey")?,
            host_id: bytes_field(body, "hostId")?,
            host_name: string_field(body, "hostName")?,
            platform: platform_field(body, "platform", HostPlatform::from_wire)?,
        },
        "hello" => ControlMessage::Hello { host_id: bytes_field(body, "hostId")?, host_nonce: bytes_field(body, "hostNonce")? },
        "auth" => ControlMessage::Auth { proof: bytes_field(body, "proof")? },
        "authFailed" => ControlMessage::AuthFailed,
        "bye" => ControlMessage::Bye,
        _ => ControlMessage::Sealed(bytes_field(body, "_0")?),
    })
}

/// Reads a `PeripheralMessage`; the version is checked before anything else (§10).
pub fn decode_peripheral(bytes: &[u8]) -> Result<PeripheralMessage, CodecError> {
    let json = Json::parse(bytes).map_err(|_| CodecError::Malformed)?;
    let o = json.as_object().ok_or(CodecError::Malformed)?;
    let version = field(o, "protocolVersion")?.as_i64().ok_or(CodecError::Malformed)?;
    if version != PROTOCOL_VERSION {
        return Err(CodecError::UnsupportedVersion(version));
    }
    Ok(match field(o, "type")?.as_str().ok_or(CodecError::Malformed)? {
        "event" => PeripheralMessage::Event(parse_event(o)?),
        "pairOffer" => PeripheralMessage::PairOffer { commitment: bytes_field(o, "commitment")? },
        "pairReveal" => PeripheralMessage::PairReveal {
            public_key: bytes_field(o, "publicKey")?,
            phone_id: bytes_field(o, "phoneId")?,
            phone_name: string_field(o, "phoneName")?,
            phone_platform: platform_field(o, "phonePlatform", PhonePlatform::from_wire)?,
        },
        "helloReply" => PeripheralMessage::HelloReply { phone_nonce: bytes_field(o, "phoneNonce")?, proof: bytes_field(o, "proof")? },
        "notSelected" => PeripheralMessage::NotSelected,
        "sealed" => PeripheralMessage::Sealed(bytes_field(o, "payload")?),
        _ => return Err(CodecError::Malformed),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event_json(kind: &str) -> String {
        format!(
            r#"{{"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","kind":{kind},"protocolVersion":4,"seq":1,"sessionId":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","type":"event"}}"#
        )
    }

    fn peripheral(json: &str) -> Result<PeripheralMessage, CodecError> {
        decode_peripheral(json.as_bytes())
    }

    fn control(json: &str) -> Result<ControlMessage, CodecError> {
        decode_control(json.as_bytes())
    }

    #[test]
    fn every_event_kind_round_trips() {
        let id = Uuid::from_u128(1);
        let kinds = [
            EventKind::Text("a/b 書 🙂 \n\"".into()),
            EventKind::Backspace,
            EventKind::ReturnKey,
            EventKind::Ping { shown_at_ms: -5, connected_at_ms: i64::MAX },
            EventKind::Probe,
            EventKind::PointerOpen { grant: u32::MAX },
            EventKind::PointerClose,
        ];
        for kind in kinds {
            let event = KeyboardEvent { event_id: id, session_id: id, seq: u64::MAX, focus_epoch: Some(u64::MAX), kind };
            let wire = encode_peripheral(&PeripheralMessage::Event(event.clone()));
            assert_eq!(decode_peripheral(&wire), Ok(PeripheralMessage::Event(event)));
        }
    }

    #[test]
    fn seq_and_epoch_use_the_whole_u64_range() {
        let json = event_json(r#"{"backspace":{}}"#).replace(r#""seq":1"#, r#""seq":18446744073709551615,"focusEpoch":18446744073709551614"#);
        let Ok(PeripheralMessage::Event(e)) = peripheral(&json) else { panic!("event expected") };
        assert_eq!(e.seq, u64::MAX);
        assert_eq!(e.focus_epoch, Some(u64::MAX - 1));
    }

    #[test]
    fn an_integer_written_with_a_fraction_is_refused() {
        let json = event_json(r#"{"backspace":{}}"#).replace(r#""seq":1"#, r#""seq":5.0"#);
        assert_eq!(peripheral(&json), Err(CodecError::Malformed));
        let json = event_json(r#"{"backspace":{}}"#).replace(r#""seq":1"#, r#""seq":1e0"#);
        assert_eq!(peripheral(&json), Err(CodecError::Malformed));
        let json = event_json(r#"{"backspace":{}}"#).replace(r#""seq":1"#, r#""seq":-1"#);
        assert_eq!(peripheral(&json), Err(CodecError::Malformed));
    }

    #[test]
    fn unknown_keys_are_ignored_at_every_level() {
        let json = r#"{"x":[1.5],"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","extra":{"a":1},"kind":{"backspace":{"y":1},"zzz":5},"protocolVersion":4,"seq":1,"sessionId":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","type":"event"}"#;
        assert!(matches!(peripheral(json), Ok(PeripheralMessage::Event(_))));
        assert_eq!(control(r#"{"bye":{"future":true},"other":1}"#), Ok(ControlMessage::Bye));
    }

    #[test]
    fn key_order_and_json_escapes_do_not_matter_on_input() {
        let json = r#"{ "type":"notSelected", "protocolVersion" : 4 }"#;
        assert_eq!(peripheral(json), Ok(PeripheralMessage::NotSelected));
        let json = r#"{"sealed":{"_0":"AQ=="}}"#;
        assert_eq!(control(json), Ok(ControlMessage::Sealed(vec![1])));
        let json = r#"{"sealed":{"_0":"AQ=="}}"#;
        assert_eq!(control(json), Ok(ControlMessage::Sealed(vec![1])));
        let json = event_json(r#"{"text":{"_0":"é\/🙂"}}"#);
        let Ok(PeripheralMessage::Event(e)) = peripheral(&json) else { panic!("event expected") };
        assert_eq!(e.kind, EventKind::Text("é/🙂".into()));
    }

    #[test]
    fn a_lowercase_uuid_is_accepted_and_written_back_in_capitals() {
        let json = event_json(r#"{"probe":{}}"#).replace("0F8FAD5B-D9CB-469F-A165-70867728950E", "0f8fad5b-d9cb-469f-a165-70867728950e");
        let decoded = peripheral(&json).unwrap();
        assert_eq!(String::from_utf8(encode_peripheral(&decoded)).unwrap(), event_json(r#"{"probe":{}}"#));
    }

    #[test]
    fn missing_or_mistyped_fields_are_malformed() {
        let ok = r#"{"hello":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostNonce":"oKGio6SlpqeoqaqrrK2urw=="}}"#;
        assert!(control(ok).is_ok());
        for bad in [
            r#"{"hello":{"hostId":"AAECAwQFBgcICQoLDA0ODw=="}}"#,
            r#"{"hello":{"hostId":5,"hostNonce":"oKGio6SlpqeoqaqrrK2urw=="}}"#,
            r#"{"hello":{"hostId":null,"hostNonce":"oKGio6SlpqeoqaqrrK2urw=="}}"#,
            r#"{"hello":[]}"#,
            r#"{"hello":"x"}"#,
            r#"[]"#,
            r#""hello""#,
            r#"{}"#,
            r#"{"hello":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostNonce":"oKGio6SlpqeoqaqrrK2urw=="},"bye":{}}"#,
            r#"{"ack":{"_0":{"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","result":"unknownResult"}}}"#,
            r#"{"ack":{"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","result":"posted"}}"#,
            r#"{"pairAccept":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"x","platform":"macos","publicKey":"AA=="}}"#,
            r#"{"sealed":{"_0":"AQ"}}"#,
        ] {
            assert_eq!(control(bad), Err(CodecError::Malformed), "{bad}");
        }
    }

    #[test]
    fn base64_without_padding_or_with_foreign_characters_is_malformed() {
        for payload in ["AQ", "AQ=", "A*==", "AQ==\n", "-_-_", "A Q=="] {
            let json = format!(r#"{{"payload":"{payload}","protocolVersion":4,"type":"sealed"}}"#);
            assert_eq!(peripheral(&json), Err(CodecError::Malformed), "{payload:?}");
        }
    }

    #[test]
    fn an_unknown_type_or_kind_is_malformed() {
        assert_eq!(peripheral(r#"{"protocolVersion":4,"type":"somethingNew"}"#), Err(CodecError::Malformed));
        assert_eq!(peripheral(&event_json(r#"{"somethingNew":{}}"#)), Err(CodecError::Malformed));
        assert_eq!(peripheral(&event_json(r#"{"backspace":{},"probe":{}}"#)), Err(CodecError::Malformed));
        assert_eq!(peripheral(&event_json(r#"{}"#)), Err(CodecError::Malformed));
        assert_eq!(peripheral(&event_json(r#"{"pointerOpen":{"grant":4294967296}}"#)), Err(CodecError::Malformed), "grant is 32 bit");
        assert_eq!(peripheral(&event_json(r#"{"text":{}}"#)), Err(CodecError::Malformed));
    }

    #[test]
    fn the_version_is_read_before_anything_else() {
        assert_eq!(peripheral(r#"{"protocolVersion":3,"type":"zzz"}"#), Err(CodecError::UnsupportedVersion(3)));
        assert_eq!(peripheral(r#"{"protocolVersion":5}"#), Err(CodecError::UnsupportedVersion(5)));
        assert_eq!(peripheral(r#"{"protocolVersion":-1}"#), Err(CodecError::UnsupportedVersion(-1)));
        assert_eq!(peripheral(r#"{"type":"notSelected"}"#), Err(CodecError::Malformed), "no version at all");
        assert_eq!(peripheral(r#"{"protocolVersion":"4","type":"notSelected"}"#), Err(CodecError::Malformed));
        assert_eq!(peripheral(r#"{"protocolVersion":4.0,"type":"notSelected"}"#), Err(CodecError::Malformed));
        assert_eq!(peripheral(r#"{"protocolVersion":18446744073709551615}"#), Err(CodecError::Malformed));
        assert_eq!(peripheral("not json"), Err(CodecError::Malformed));
    }

    #[test]
    fn status_omits_default_values_and_reads_missing_keys_as_defaults() {
        let plain = ControlMessage::Status(ReceiverStatus::new(true, 1));
        assert_eq!(String::from_utf8(encode_control(&plain)).unwrap(), r#"{"status":{"_0":{"focusEpoch":1,"ready":true}}}"#);
        assert_eq!(control(r#"{"status":{"_0":{"focusEpoch":1,"ready":true}}}"#), Ok(plain));
        let mut full = ReceiverStatus::new(false, 9);
        full.app_name = Some("a".into());
        full.trusted = false;
        full.measure = true;
        full.pointer_grant = Some(7);
        full.input_blocked = true;
        let wire = encode_control(&ControlMessage::Status(full.clone()));
        assert_eq!(
            String::from_utf8(wire.clone()).unwrap(),
            r#"{"status":{"_0":{"appName":"a","focusEpoch":9,"inputBlocked":true,"measure":true,"pointerGrant":7,"ready":false,"trusted":false}}}"#
        );
        assert_eq!(decode_control(&wire), Ok(ControlMessage::Status(full)));
        // `trusted: true` and `measure: false` on input are read, though a sender never writes them.
        let Ok(ControlMessage::Status(s)) = control(r#"{"status":{"_0":{"focusEpoch":1,"ready":true,"trusted":true,"measure":false}}}"#) else {
            panic!("status expected")
        };
        assert!(s.trusted && !s.measure);
    }

    #[test]
    fn a_focus_epoch_is_left_out_when_the_event_has_none() {
        let e = KeyboardEvent { event_id: Uuid::nil(), session_id: Uuid::nil(), seq: 1, focus_epoch: None, kind: EventKind::Probe };
        let wire = String::from_utf8(encode_peripheral(&PeripheralMessage::Event(e))).unwrap();
        assert!(!wire.contains("focusEpoch"));
        assert!(!wire.contains("null"));
    }

    #[test]
    fn debug_output_carries_no_text_nonce_or_proof() {
        let secret = "機密密碼";
        let event = KeyboardEvent {
            event_id: Uuid::nil(),
            session_id: Uuid::nil(),
            seq: 1,
            focus_epoch: None,
            kind: EventKind::Text(secret.into()),
        };
        let shown = format!("{:?} {:?}", event, PeripheralMessage::Event(event.clone()));
        assert!(!shown.contains(secret));
        let hello = format!("{:?}", ControlMessage::Hello { host_id: vec![0x42; 16], host_nonce: vec![0x43; 16] });
        assert!(!hello.contains("66") && !hello.contains("67"), "no byte values: {hello}");
        let mut status = ReceiverStatus::new(true, 1);
        status.app_name = Some(secret.into());
        assert!(!format!("{status:?}").contains(secret));
        let sealed = format!("{:?}", ControlMessage::Sealed(vec![0xDE, 0xAD]));
        assert!(!sealed.contains("222") && !sealed.contains("DE"));
    }

    #[test]
    fn an_empty_text_event_is_not_well_formed_but_still_decodes() {
        let json = event_json(r#"{"text":{"_0":""}}"#);
        let Ok(PeripheralMessage::Event(e)) = peripheral(&json) else { panic!("event expected") };
        assert!(!e.is_well_formed(), "the host answers malformed");
        let ok = KeyboardEvent { kind: EventKind::Text("a".into()), ..e.clone() };
        assert!(ok.is_well_formed());
        assert!(KeyboardEvent { kind: EventKind::Backspace, ..e }.is_well_formed());
    }

    #[test]
    fn carries_focus_epoch_is_false_for_probes_and_pointer_events() {
        assert!(EventKind::Text("a".into()).carries_focus_epoch());
        assert!(EventKind::Backspace.carries_focus_epoch());
        assert!(EventKind::ReturnKey.carries_focus_epoch());
        assert!(!EventKind::Probe.carries_focus_epoch());
        assert!(!EventKind::Ping { shown_at_ms: 0, connected_at_ms: 0 }.carries_focus_epoch());
        assert!(!EventKind::PointerOpen { grant: 1 }.carries_focus_epoch());
        assert!(!EventKind::PointerClose.carries_focus_epoch());
    }

    #[test]
    fn ack_codes_round_trip_and_the_unknown_event_id_is_all_zero() {
        for code in [
            AckResult::Posted,
            AckResult::NotAuthorized,
            AckResult::NoFocus,
            AckResult::StaleFocus,
            AckResult::SwitchFailed,
            AckResult::CompositionActive,
            AckResult::InjectFailed,
            AckResult::Malformed,
            AckResult::Pong,
            AckResult::OutOfOrder,
        ] {
            assert_eq!(AckResult::from_wire(code.as_str()), Some(code));
        }
        assert_eq!(AckResult::from_wire("Posted"), None);
        assert_eq!(UNKNOWN_EVENT_ID.to_string(), "00000000-0000-0000-0000-000000000000");
    }
}
