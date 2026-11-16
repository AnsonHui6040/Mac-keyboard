//! A minimal ATT client for the Linux backend (WL1 debugging, "L3"): the L2CAP fixed channel 4 is opened directly, so
//! BlueZ's own GATT client (46 round trips for ten services) is not involved. Only what the keyboard needs is spoken:
//! Exchange MTU, Find By Type Value, Read By Type, Find Information, Write Request, and the notifications of `event`.
//!
//! Everything here is plain bytes and a transport trait, so it is tested on every host; the socket sits in `linux.rs`.
//!
//! The iPhone is a GATT client of the Mac or PC as well: it sends its own ATT requests over the same link and waits for
//! the answers. They are answered here (an empty database), or the iPhone's transaction times out.

use std::collections::VecDeque;
use std::io;
use std::time::Duration;
use uuid::Uuid;

pub const OP_ERROR: u8 = 0x01;
pub const OP_MTU_REQUEST: u8 = 0x02;
pub const OP_MTU_RESPONSE: u8 = 0x03;
pub const OP_FIND_INFO_REQUEST: u8 = 0x04;
pub const OP_FIND_INFO_RESPONSE: u8 = 0x05;
pub const OP_FIND_BY_TYPE_VALUE_REQUEST: u8 = 0x06;
pub const OP_FIND_BY_TYPE_VALUE_RESPONSE: u8 = 0x07;
pub const OP_READ_BY_TYPE_REQUEST: u8 = 0x08;
pub const OP_READ_BY_TYPE_RESPONSE: u8 = 0x09;
pub const OP_READ_REQUEST: u8 = 0x0A;
pub const OP_READ_RESPONSE: u8 = 0x0B;
pub const OP_WRITE_REQUEST: u8 = 0x12;
pub const OP_WRITE_RESPONSE: u8 = 0x13;
pub const OP_NOTIFICATION: u8 = 0x1B;
pub const OP_INDICATION: u8 = 0x1D;
pub const OP_CONFIRMATION: u8 = 0x1E;

pub const ERR_INVALID_HANDLE: u8 = 0x01;
pub const ERR_REQUEST_NOT_SUPPORTED: u8 = 0x06;
pub const ERR_ATTRIBUTE_NOT_FOUND: u8 = 0x0A;

pub const UUID16_PRIMARY_SERVICE: u16 = 0x2800;
pub const UUID16_CHARACTERISTIC: u16 = 0x2803;
pub const UUID16_CCCD: u16 = 0x2902;

/// The MTU asked for (the largest ATT allows for the iPhone to answer with).
pub const OUR_MTU: u16 = 517;
pub const DEFAULT_MTU: u16 = 23;
/// How long one request waits for its response.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(6);
/// A discovery that does not end after this many pages is not going to.
const MAX_PAGES: usize = 16;

/// The Bluetooth base UUID with a 16-bit value in it.
pub fn uuid_from_16(short: u16) -> Uuid {
    Uuid::from_u128((u128::from(short) << 96) | 0x0000_0000_0000_1000_8000_0080_5F9B_34FB)
}

/// Why an ATT exchange did not work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttError {
    /// No response within the time.
    Timeout,
    /// The peer closed the channel (a read of length 0).
    Closed,
    /// The socket failed; the OS error number when there is one.
    Io(Option<i32>),
    /// The peer answered with an Error Response.
    Protocol { request: u8, code: u8 },
    /// A response that could not be read.
    Malformed,
    /// A write longer than the MTU allows.
    TooLong,
}

/// One channel of ATT PDUs. A read of a closed channel is `Ok(empty)`.
#[allow(async_fn_in_trait)]
pub trait AttTransport {
    async fn send(&mut self, pdu: &[u8]) -> io::Result<()>;
    async fn recv(&mut self) -> io::Result<Vec<u8>>;
}

fn io_error(error: &io::Error) -> AttError {
    AttError::Io(error.raw_os_error())
}

// ---------------------------------------------------------------- requests

fn pdu(opcode: u8, parts: &[&[u8]]) -> Vec<u8> {
    let mut out = vec![opcode];
    for part in parts {
        out.extend_from_slice(part);
    }
    out
}

pub fn exchange_mtu_request(mtu: u16) -> Vec<u8> {
    pdu(OP_MTU_REQUEST, &[&mtu.to_le_bytes()])
}

pub fn mtu_response(mtu: u16) -> Vec<u8> {
    pdu(OP_MTU_RESPONSE, &[&mtu.to_le_bytes()])
}

pub fn find_by_type_value_request(start: u16, end: u16, attribute_type: u16, value: Uuid) -> Vec<u8> {
    pdu(
        OP_FIND_BY_TYPE_VALUE_REQUEST,
        &[&start.to_le_bytes(), &end.to_le_bytes(), &attribute_type.to_le_bytes(), &value.as_u128().to_le_bytes()],
    )
}

pub fn read_by_type_request(start: u16, end: u16, attribute_type: u16) -> Vec<u8> {
    pdu(OP_READ_BY_TYPE_REQUEST, &[&start.to_le_bytes(), &end.to_le_bytes(), &attribute_type.to_le_bytes()])
}

pub fn find_information_request(start: u16, end: u16) -> Vec<u8> {
    pdu(OP_FIND_INFO_REQUEST, &[&start.to_le_bytes(), &end.to_le_bytes()])
}

pub fn write_request(handle: u16, value: &[u8]) -> Vec<u8> {
    pdu(OP_WRITE_REQUEST, &[&handle.to_le_bytes(), value])
}

pub fn read_request(handle: u16) -> Vec<u8> {
    pdu(OP_READ_REQUEST, &[&handle.to_le_bytes()])
}

pub fn error_response(request: u8, handle: u16, code: u8) -> Vec<u8> {
    pdu(OP_ERROR, &[&[request], &handle.to_le_bytes(), &[code]])
}

// ---------------------------------------------------------------- responses

/// One characteristic declaration (Read By Type on 0x2803).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CharacteristicDeclaration {
    pub declaration: u16,
    pub properties: u8,
    pub value: u16,
    pub uuid: Uuid,
}

fn u16_at(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes([*bytes.get(at)?, *bytes.get(at + 1)?]))
}

/// A UUID of 2 or 16 bytes in ATT (little-endian) order.
fn uuid_from_att(bytes: &[u8]) -> Option<Uuid> {
    match bytes.len() {
        2 => Some(uuid_from_16(u16::from_le_bytes([bytes[0], bytes[1]]))),
        16 => Some(Uuid::from_u128(u128::from_le_bytes(bytes.try_into().ok()?))),
        _ => None,
    }
}

/// `(first handle, last handle)` of each service in a Find By Type Value response.
pub fn parse_service_ranges(response: &[u8]) -> Result<Vec<(u16, u16)>, AttError> {
    if response.first() != Some(&OP_FIND_BY_TYPE_VALUE_RESPONSE) || response.len() < 5 || !(response.len() - 1).is_multiple_of(4) {
        return Err(AttError::Malformed);
    }
    Ok(response[1..].as_chunks::<4>().0.iter().map(|e| (u16::from_le_bytes([e[0], e[1]]), u16::from_le_bytes([e[2], e[3]]))).collect())
}

pub fn parse_characteristics(response: &[u8]) -> Result<Vec<CharacteristicDeclaration>, AttError> {
    if response.first() != Some(&OP_READ_BY_TYPE_RESPONSE) {
        return Err(AttError::Malformed);
    }
    let length = usize::from(*response.get(1).ok_or(AttError::Malformed)?);
    if (length != 7 && length != 21) || response.len() < 2 + length || !(response.len() - 2).is_multiple_of(length) {
        return Err(AttError::Malformed);
    }
    response[2..]
        .chunks_exact(length)
        .map(|e| {
            Some(CharacteristicDeclaration {
                declaration: u16_at(e, 0)?,
                properties: e[2],
                value: u16_at(e, 3)?,
                uuid: uuid_from_att(&e[5..])?,
            })
        })
        .collect::<Option<Vec<_>>>()
        .ok_or(AttError::Malformed)
}

/// `(handle, type UUID)` of each entry of a Find Information response.
pub fn parse_find_information(response: &[u8]) -> Result<Vec<(u16, Uuid)>, AttError> {
    if response.first() != Some(&OP_FIND_INFO_RESPONSE) {
        return Err(AttError::Malformed);
    }
    let width = match response.get(1) {
        Some(1) => 2,
        Some(2) => 16,
        _ => return Err(AttError::Malformed),
    };
    let entry = 2 + width;
    if response.len() < 2 + entry || !(response.len() - 2).is_multiple_of(entry) {
        return Err(AttError::Malformed);
    }
    response[2..]
        .chunks_exact(entry)
        .map(|e| Some((u16_at(e, 0)?, uuid_from_att(&e[2..])?)))
        .collect::<Option<Vec<_>>>()
        .ok_or(AttError::Malformed)
}

// ---------------------------------------------------------------- what the peer sends unasked

/// How the peer answered a Read Request: either way it is there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadReply {
    /// A Read Response, with the attribute value it carried.
    Answered(Vec<u8>),
    /// An Error Response to the read (a write-only characteristic says "Read Not Permitted").
    AttError,
}

/// A PDU that arrived, sorted by what the client must do with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    /// A response (or Error Response) that belongs to one of our requests.
    Response(Vec<u8>),
    /// A notification or indication of `handle`; an indication wants a confirmation.
    Notification { handle: u16, value: Vec<u8>, confirm: bool },
    /// The peer asks us something. `reply` is what to send back (`None` for a command, which gets no answer);
    /// `peer_mtu` is set when it was an Exchange MTU request.
    PeerRequest { reply: Option<Vec<u8>>, peer_mtu: Option<u16> },
    Ignored,
}

/// Opcodes of responses, the Error Response included.
const RESPONSE_OPCODES: [u8; 12] = [0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19];
/// Discovery requests: an empty database ends them with "attribute not found".
const DISCOVERY_REQUESTS: [u8; 4] = [OP_FIND_INFO_REQUEST, OP_FIND_BY_TYPE_VALUE_REQUEST, OP_READ_BY_TYPE_REQUEST, 0x10];
/// Requests that name a handle: an empty database has none.
const HANDLE_REQUESTS: [u8; 4] = [0x0A, 0x0C, OP_WRITE_REQUEST, 0x16];
/// Bit 6 of the opcode marks a command: no response is allowed.
const COMMAND_FLAG: u8 = 0x40;

pub fn classify(pdu: &[u8]) -> Incoming {
    let Some(&opcode) = pdu.first() else { return Incoming::Ignored };
    if opcode == OP_NOTIFICATION || opcode == OP_INDICATION {
        return match u16_at(pdu, 1) {
            Some(handle) => Incoming::Notification { handle, value: pdu[3..].to_vec(), confirm: opcode == OP_INDICATION },
            None => Incoming::Ignored,
        };
    }
    if opcode == OP_MTU_REQUEST {
        return match u16_at(pdu, 1) {
            Some(peer_mtu) => Incoming::PeerRequest { reply: Some(mtu_response(OUR_MTU)), peer_mtu: Some(peer_mtu) },
            None => Incoming::Ignored,
        };
    }
    if RESPONSE_OPCODES.contains(&opcode) {
        return Incoming::Response(pdu.to_vec());
    }
    if opcode == OP_CONFIRMATION {
        return Incoming::Ignored;
    }
    if opcode & COMMAND_FLAG != 0 {
        return Incoming::PeerRequest { reply: None, peer_mtu: None };
    }
    let code = if DISCOVERY_REQUESTS.contains(&opcode) {
        ERR_ATTRIBUTE_NOT_FOUND
    } else if HANDLE_REQUESTS.contains(&opcode) {
        ERR_INVALID_HANDLE
    } else {
        ERR_REQUEST_NOT_SUPPORTED
    };
    Incoming::PeerRequest { reply: Some(error_response(opcode, u16_at(pdu, 1).unwrap_or(0), code)), peer_mtu: None }
}

// ---------------------------------------------------------------- the client

pub struct AttClient<T> {
    transport: T,
    /// The MTU our own Exchange MTU request ended with (the phone's receive size).
    exchanged: Option<u16>,
    /// The MTU the phone asked for in its own request.
    peer: Option<u16>,
    pending: VecDeque<(u16, Vec<u8>)>,
    round_trips: u32,
}

impl<T: AttTransport> AttClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport, exchanged: None, peer: None, pending: VecDeque::new(), round_trips: 0 }
    }

    /// The ATT MTU in force: the smaller of what the two sides asked for, at least 23.
    pub fn mtu(&self) -> u16 {
        let base = self.exchanged.unwrap_or(DEFAULT_MTU);
        self.peer.map_or(base, |peer| base.min(peer)).max(DEFAULT_MTU)
    }

    /// Requests made so far, for the diagnostic log.
    pub fn round_trips(&self) -> u32 {
        self.round_trips
    }

    async fn read_one(&mut self) -> Result<Incoming, AttError> {
        let pdu = self.transport.recv().await.map_err(|e| io_error(&e))?;
        if pdu.is_empty() {
            return Err(AttError::Closed);
        }
        Ok(classify(&pdu))
    }

    /// Handles what is not the response being waited for: keeps notifications, answers the peer.
    async fn absorb(&mut self, incoming: Incoming) -> Result<(), AttError> {
        match incoming {
            Incoming::Notification { handle, value, confirm } => {
                self.pending.push_back((handle, value));
                if confirm {
                    self.transport.send(&[OP_CONFIRMATION]).await.map_err(|e| io_error(&e))?;
                }
            }
            Incoming::PeerRequest { reply, peer_mtu } => {
                if let Some(mtu) = peer_mtu {
                    self.peer = Some(mtu);
                }
                if let Some(reply) = reply {
                    self.transport.send(&reply).await.map_err(|e| io_error(&e))?;
                }
            }
            Incoming::Response(_) | Incoming::Ignored => {}
        }
        Ok(())
    }

    /// Sends a request and waits for its response (or its Error Response, which is `Err(Protocol)`).
    pub async fn request(&mut self, request: Vec<u8>, timeout: Duration) -> Result<Vec<u8>, AttError> {
        let opcode = request.first().copied().ok_or(AttError::Malformed)?;
        self.transport.send(&request).await.map_err(|e| io_error(&e))?;
        self.round_trips += 1;
        let waiting = async {
            loop {
                match self.read_one().await? {
                    Incoming::Response(response) if response[0] == opcode.wrapping_add(1) => return Ok(response),
                    Incoming::Response(response) if response[0] == OP_ERROR && response.get(1) == Some(&opcode) => {
                        let code = response.get(4).copied().ok_or(AttError::Malformed)?;
                        return Err(AttError::Protocol { request: opcode, code });
                    }
                    other => self.absorb(other).await?,
                }
            }
        };
        tokio::time::timeout(timeout, waiting).await.map_err(|_| AttError::Timeout)?
    }

    /// Write Request to `handle`; waits for the Write Response.
    pub async fn write(&mut self, handle: u16, value: &[u8], timeout: Duration) -> Result<(), AttError> {
        if value.len() + 3 > usize::from(self.mtu()) {
            return Err(AttError::TooLong);
        }
        let response = self.request(write_request(handle, value), timeout).await?;
        if response == [OP_WRITE_RESPONSE] {
            Ok(())
        } else {
            Err(AttError::Malformed)
        }
    }

    /// Read Request to `handle`. Any answer, a value or an ATT error, is `Ok`;
    /// no answer, a closed channel or a socket failure is `Err`. Notifications that arrive meanwhile are kept for
    /// [`Self::next_notification`], in order, like during any other request.
    pub async fn read(&mut self, handle: u16, timeout: Duration) -> Result<ReadReply, AttError> {
        match self.request(read_request(handle), timeout).await {
            Ok(response) => Ok(ReadReply::Answered(response.get(1..).unwrap_or_default().to_vec())),
            Err(AttError::Protocol { request: OP_READ_REQUEST, .. }) => Ok(ReadReply::AttError),
            Err(other) => Err(other),
        }
    }

    /// The next notification, oldest first. Answers whatever the peer asks in the meantime. Cancelling it loses nothing.
    pub async fn next_notification(&mut self) -> Result<(u16, Vec<u8>), AttError> {
        loop {
            if let Some(next) = self.pending.pop_front() {
                return Ok(next);
            }
            let incoming = self.read_one().await?;
            self.absorb(incoming).await?;
        }
    }

    pub fn into_transport(self) -> T {
        self.transport
    }
}

// ---------------------------------------------------------------- establishing

/// Where the keyboard's attributes are on this peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HandleSet {
    pub service_start: u16,
    pub service_end: u16,
    pub event: u16,
    pub control: u16,
    pub cccd: u16,
}

/// What the keyboard service looks like.
#[derive(Debug, Clone, Copy)]
pub struct ServiceUuids {
    pub service: Uuid,
    pub event: Uuid,
    pub control: Uuid,
}

/// Steps of `establish`, for the diagnostic log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Mtu(u16),
    /// The handles are known; `cached` when they came from the previous connection.
    Discovered { cached: bool },
    Subscribed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Established {
    pub handles: HandleSet,
    pub mtu: u16,
}

fn not_found(request: u8) -> AttError {
    AttError::Protocol { request, code: ERR_ATTRIBUTE_NOT_FOUND }
}

fn is_not_found(error: &AttError) -> bool {
    matches!(error, AttError::Protocol { code: ERR_ATTRIBUTE_NOT_FOUND, .. })
}

async fn exchange_mtu<T: AttTransport>(att: &mut AttClient<T>) -> Result<(), AttError> {
    let response = att.request(exchange_mtu_request(OUR_MTU), REQUEST_TIMEOUT).await?;
    let server = u16_at(&response, 1).ok_or(AttError::Malformed)?;
    att.exchanged = Some(server.min(OUR_MTU));
    Ok(())
}

/// One Read By Type over the cached service range: are `event` and `control` still where they were?
async fn cached_handles_still_valid<T: AttTransport>(att: &mut AttClient<T>, cached: HandleSet, uuids: ServiceUuids) -> Result<bool, AttError> {
    let request = read_by_type_request(cached.service_start, cached.service_end, UUID16_CHARACTERISTIC);
    let declarations = match att.request(request, REQUEST_TIMEOUT).await {
        // An answer that cannot be read is no answer to "are they still there": discover instead.
        Ok(response) => match parse_characteristics(&response) {
            Ok(declarations) => declarations,
            Err(_) => return Ok(false),
        },
        Err(AttError::Protocol { .. }) => return Ok(false),
        Err(other) => return Err(other),
    };
    let at = |value: u16, uuid: Uuid| declarations.iter().any(|d| d.value == value && d.uuid == uuid);
    Ok(at(cached.event, uuids.event) && at(cached.control, uuids.control))
}

/// Discovery of this service only: its range, its characteristics, the CCCD behind `event`.
async fn discover<T: AttTransport>(att: &mut AttClient<T>, uuids: ServiceUuids) -> Result<HandleSet, AttError> {
    let request = find_by_type_value_request(0x0001, 0xFFFF, UUID16_PRIMARY_SERVICE, uuids.service);
    let ranges = parse_service_ranges(&att.request(request, REQUEST_TIMEOUT).await?)?;
    let &(start, end) = ranges.first().ok_or(AttError::Malformed)?;
    let (mut event, mut control) = (None, None);
    let mut from = start;
    for _ in 0..MAX_PAGES {
        if (event.is_some() && control.is_some()) || from > end {
            break;
        }
        let response = match att.request(read_by_type_request(from, end, UUID16_CHARACTERISTIC), REQUEST_TIMEOUT).await {
            Ok(response) => response,
            Err(error) if is_not_found(&error) => break,
            Err(error) => return Err(error),
        };
        let declarations = parse_characteristics(&response)?;
        for d in &declarations {
            if d.uuid == uuids.event {
                event = Some(d.value);
            } else if d.uuid == uuids.control {
                control = Some(d.value);
            }
        }
        match declarations.last().and_then(|d| d.declaration.checked_add(1)) {
            Some(next) if next > from => from = next,
            _ => break,
        }
    }
    let (Some(event), Some(control)) = (event, control) else { return Err(not_found(OP_READ_BY_TYPE_REQUEST)) };
    let cccd = find_cccd(att, event, end).await?;
    Ok(HandleSet { service_start: start, service_end: end, event, control, cccd })
}

async fn find_cccd<T: AttTransport>(att: &mut AttClient<T>, event: u16, end: u16) -> Result<u16, AttError> {
    let mut from = event.saturating_add(1);
    for _ in 0..MAX_PAGES {
        if from > end {
            break;
        }
        let response = match att.request(find_information_request(from, end), REQUEST_TIMEOUT).await {
            Ok(response) => response,
            Err(error) if is_not_found(&error) => break,
            Err(error) => return Err(error),
        };
        let entries = parse_find_information(&response)?;
        for (handle, uuid) in &entries {
            if *uuid == uuid_from_16(UUID16_CCCD) {
                return Ok(*handle);
            }
            // The next characteristic or service starts here: `event` has no CCCD.
            if *uuid == uuid_from_16(UUID16_CHARACTERISTIC) || *uuid == uuid_from_16(UUID16_PRIMARY_SERVICE) {
                return Err(not_found(OP_FIND_INFO_REQUEST));
            }
        }
        match entries.last().and_then(|(handle, _)| handle.checked_add(1)) {
            Some(next) if next > from => from = next,
            _ => break,
        }
    }
    Err(not_found(OP_FIND_INFO_REQUEST))
}

async fn subscribe<T: AttTransport>(att: &mut AttClient<T>, cccd: u16) -> Result<(), AttError> {
    att.write(cccd, &[0x01, 0x00], REQUEST_TIMEOUT).await
}

/// Exchange MTU, find the handles (the cached ones after one check, else a discovery of this service only), subscribe
/// to `event`.
pub async fn establish<T: AttTransport>(
    att: &mut AttClient<T>,
    cache: Option<HandleSet>,
    uuids: ServiceUuids,
    mut on_phase: impl FnMut(Phase),
) -> Result<Established, AttError> {
    exchange_mtu(att).await?;
    on_phase(Phase::Mtu(att.mtu()));
    if let Some(cached) = cache {
        if cached_handles_still_valid(att, cached, uuids).await? {
            on_phase(Phase::Discovered { cached: true });
            match subscribe(att, cached.cccd).await {
                Ok(()) => {
                    on_phase(Phase::Subscribed);
                    return Ok(Established { handles: cached, mtu: att.mtu() });
                }
                // The characteristics are where they were but the CCCD is not: discover afresh on this link.
                Err(AttError::Protocol { .. }) => {}
                Err(other) => return Err(other),
            }
        }
    }
    let handles = discover(att, uuids).await?;
    on_phase(Phase::Discovered { cached: false });
    subscribe(att, handles.cccd).await?;
    on_phase(Phase::Subscribed);
    Ok(Established { handles, mtu: att.mtu() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    const SERVICE: Uuid = Uuid::from_u128(0x706AA642_68A3_41FA_889D_24E30709B0D0);
    const EVENT: Uuid = Uuid::from_u128(0xC7FC0313_53E7_4DCD_B75F_2AE66FE9C586);
    const CONTROL: Uuid = Uuid::from_u128(0x320468E2_53B6_4B6A_88EC_AE2752415818);
    const UUIDS: ServiceUuids = ServiceUuids { service: SERVICE, event: EVENT, control: CONTROL };

    /// The phone's database: one service, `event` (notify, CCCD behind it), `control`.
    #[derive(Clone, Copy)]
    struct Layout {
        service: (u16, u16),
        event_value: u16,
        control_value: u16,
        cccd: u16,
    }

    const LAYOUT: Layout = Layout { service: (0x0020, 0x0028), event_value: 0x0022, control_value: 0x0026, cccd: 0x0023 };

    fn le(v: u16) -> [u8; 2] {
        v.to_le_bytes()
    }

    /// A phone that answers like the real one, and records what it was sent.
    struct Phone {
        layout: Layout,
        /// PDUs the phone pushes at the moment the CCCD is written.
        on_subscribe: Vec<Vec<u8>>,
        /// An Error Response to give to Write Requests to the CCCD.
        cccd_error: Option<u8>,
        inbox: VecDeque<Vec<u8>>,
        sent: Rc<RefCell<Vec<Vec<u8>>>>,
        mtu: u16,
        /// The next Read By Type is answered with something that is not a response.
        garble_next_read_by_type: bool,
    }

    impl Phone {
        fn new(layout: Layout) -> (Self, Rc<RefCell<Vec<Vec<u8>>>>) {
            let sent = Rc::new(RefCell::new(Vec::new()));
            (Self { layout, on_subscribe: Vec::new(), cccd_error: None, inbox: VecDeque::new(), sent: sent.clone(), mtu: 185, garble_next_read_by_type: false }, sent)
        }

        fn error(&self, request: &[u8], code: u8) -> Vec<u8> {
            let handle = if request.len() >= 3 { u16::from_le_bytes([request[1], request[2]]) } else { 0 };
            error_response(request[0], handle, code)
        }

        fn declaration(&self, handle: u16, properties: u8, value: u16, uuid: Uuid) -> Vec<u8> {
            let mut entry = Vec::new();
            entry.extend(le(handle));
            entry.push(properties);
            entry.extend(le(value));
            entry.extend(uuid.as_u128().to_le_bytes());
            entry
        }

        fn answer(&mut self, request: &[u8]) -> Vec<Vec<u8>> {
            let l = self.layout;
            match request[0] {
                OP_MTU_REQUEST => vec![mtu_response(self.mtu)],
                OP_FIND_BY_TYPE_VALUE_REQUEST => {
                    let wanted = Uuid::from_u128(u128::from_le_bytes(request[7..23].try_into().unwrap()));
                    if wanted == SERVICE {
                        let mut r = vec![OP_FIND_BY_TYPE_VALUE_RESPONSE];
                        r.extend(le(l.service.0));
                        r.extend(le(l.service.1));
                        vec![r]
                    } else {
                        vec![self.error(request, ERR_ATTRIBUTE_NOT_FOUND)]
                    }
                }
                OP_READ_BY_TYPE_REQUEST if std::mem::take(&mut self.garble_next_read_by_type) => vec![vec![OP_READ_BY_TYPE_RESPONSE, 0x00]],
                OP_READ_BY_TYPE_REQUEST => {
                    let from = u16::from_le_bytes([request[1], request[2]]);
                    let to = u16::from_le_bytes([request[3], request[4]]);
                    let mut entries = Vec::new();
                    for (decl, props, value, uuid) in
                        [(l.event_value - 1, 0x10, l.event_value, EVENT), (l.control_value - 1, 0x08, l.control_value, CONTROL)]
                    {
                        if decl >= from && decl <= to && decl >= l.service.0 && decl <= l.service.1 {
                            entries.push(self.declaration(decl, props, value, uuid));
                        }
                    }
                    if entries.is_empty() {
                        return vec![self.error(request, ERR_ATTRIBUTE_NOT_FOUND)];
                    }
                    let mut r = vec![OP_READ_BY_TYPE_RESPONSE, 21];
                    for e in entries {
                        r.extend(e);
                    }
                    vec![r]
                }
                OP_FIND_INFO_REQUEST => {
                    let from = u16::from_le_bytes([request[1], request[2]]);
                    let mut r = vec![OP_FIND_INFO_RESPONSE, 1];
                    let mut any = false;
                    // value of `event`, then its CCCD, then the next declaration
                    for (handle, short) in [(l.cccd, UUID16_CCCD), (l.control_value - 1, UUID16_CHARACTERISTIC)] {
                        if handle >= from {
                            r.extend(le(handle));
                            r.extend(le(short));
                            any = true;
                        }
                    }
                    if any { vec![r] } else { vec![self.error(request, ERR_ATTRIBUTE_NOT_FOUND)] }
                }
                OP_WRITE_REQUEST => {
                    let handle = u16::from_le_bytes([request[1], request[2]]);
                    if handle == l.cccd {
                        if let Some(code) = self.cccd_error {
                            return vec![self.error(request, code)];
                        }
                        let mut out = vec![vec![OP_WRITE_RESPONSE]];
                        out.extend(self.on_subscribe.clone());
                        out
                    } else if handle == l.control_value {
                        vec![vec![OP_WRITE_RESPONSE]]
                    } else {
                        vec![self.error(request, ERR_INVALID_HANDLE)]
                    }
                }
                _ => vec![self.error(request, ERR_REQUEST_NOT_SUPPORTED)],
            }
        }
    }

    impl AttTransport for Phone {
        async fn send(&mut self, pdu: &[u8]) -> io::Result<()> {
            self.sent.borrow_mut().push(pdu.to_vec());
            // Answers to our own answers (Error Response, MTU response, confirmations) are not requests.
            if matches!(pdu[0], OP_ERROR | OP_MTU_RESPONSE | OP_CONFIRMATION) {
                return Ok(());
            }
            let replies = self.answer(pdu);
            self.inbox.extend(replies);
            Ok(())
        }

        async fn recv(&mut self) -> io::Result<Vec<u8>> {
            match self.inbox.pop_front() {
                Some(pdu) => Ok(pdu),
                None => std::future::pending().await,
            }
        }
    }

    fn opcodes(sent: &Rc<RefCell<Vec<Vec<u8>>>>) -> Vec<u8> {
        sent.borrow().iter().map(|p| p[0]).collect()
    }

    // ------------------------------------------------------------ encoding

    #[test]
    fn att_find_by_type_value_request_bytes() {
        let pdu = find_by_type_value_request(0x0001, 0xFFFF, UUID16_PRIMARY_SERVICE, SERVICE);
        let mut expected = vec![0x06, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28];
        // the service UUID in ATT order: least significant byte first
        expected.extend(SERVICE.as_u128().to_le_bytes());
        assert_eq!(pdu, expected);
        assert_eq!(pdu.len(), 23);
        assert_eq!(&pdu[7..9], &[0xD0, 0xB0]);
    }

    #[test]
    fn requests_have_the_documented_layout() {
        assert_eq!(exchange_mtu_request(517), vec![0x02, 0x05, 0x02]);
        assert_eq!(mtu_response(517), vec![0x03, 0x05, 0x02]);
        assert_eq!(read_by_type_request(0x20, 0x28, UUID16_CHARACTERISTIC), vec![0x08, 0x20, 0x00, 0x28, 0x00, 0x03, 0x28]);
        assert_eq!(find_information_request(0x23, 0x28), vec![0x04, 0x23, 0x00, 0x28, 0x00]);
        assert_eq!(write_request(0x23, &[1, 0]), vec![0x12, 0x23, 0x00, 0x01, 0x00]);
        assert_eq!(error_response(0x08, 0x0020, ERR_REQUEST_NOT_SUPPORTED), vec![0x01, 0x08, 0x20, 0x00, 0x06]);
    }

    // ------------------------------------------------------------ decoding

    #[test]
    fn att_parses_read_by_type_characteristics() {
        let mut response = vec![OP_READ_BY_TYPE_RESPONSE, 21];
        response.extend([0x21, 0x00, 0x10, 0x22, 0x00]);
        response.extend(EVENT.as_u128().to_le_bytes());
        response.extend([0x25, 0x00, 0x08, 0x26, 0x00]);
        response.extend(CONTROL.as_u128().to_le_bytes());
        let found = parse_characteristics(&response).unwrap();
        assert_eq!(
            found,
            vec![
                CharacteristicDeclaration { declaration: 0x21, properties: 0x10, value: 0x22, uuid: EVENT },
                CharacteristicDeclaration { declaration: 0x25, properties: 0x08, value: 0x26, uuid: CONTROL },
            ]
        );
    }

    #[test]
    fn att_parses_sixteen_bit_characteristic_uuids_into_the_base_uuid() {
        let response = vec![OP_READ_BY_TYPE_RESPONSE, 7, 0x03, 0x00, 0x02, 0x04, 0x00, 0x00, 0x2A];
        let found = parse_characteristics(&response).unwrap();
        assert_eq!(found[0].uuid, uuid_from_16(0x2A00));
        assert_eq!(found[0].value, 0x0004);
    }

    #[test]
    fn att_finds_cccd_in_find_information() {
        let response = vec![OP_FIND_INFO_RESPONSE, 1, 0x23, 0x00, 0x02, 0x29, 0x24, 0x00, 0x03, 0x28];
        let entries = parse_find_information(&response).unwrap();
        assert_eq!(entries, vec![(0x23, uuid_from_16(UUID16_CCCD)), (0x24, uuid_from_16(UUID16_CHARACTERISTIC))]);
        let long = {
            let mut r = vec![OP_FIND_INFO_RESPONSE, 2, 0x30, 0x00];
            r.extend(EVENT.as_u128().to_le_bytes());
            r
        };
        assert_eq!(parse_find_information(&long).unwrap(), vec![(0x30, EVENT)]);
    }

    #[test]
    fn service_ranges_are_read_from_find_by_type_value() {
        let response = vec![OP_FIND_BY_TYPE_VALUE_RESPONSE, 0x20, 0x00, 0x28, 0x00];
        assert_eq!(parse_service_ranges(&response).unwrap(), vec![(0x20, 0x28)]);
    }

    #[test]
    fn truncated_or_wrong_responses_are_malformed_not_a_panic() {
        assert_eq!(parse_characteristics(&[OP_READ_BY_TYPE_RESPONSE, 21, 0x01]), Err(AttError::Malformed));
        assert_eq!(parse_characteristics(&[OP_READ_BY_TYPE_RESPONSE]), Err(AttError::Malformed));
        assert_eq!(parse_characteristics(&[OP_WRITE_RESPONSE]), Err(AttError::Malformed));
        assert_eq!(parse_find_information(&[OP_FIND_INFO_RESPONSE, 9, 0, 0, 0, 0]), Err(AttError::Malformed));
        assert_eq!(parse_service_ranges(&[OP_FIND_BY_TYPE_VALUE_RESPONSE, 1, 2, 3]), Err(AttError::Malformed));
        assert_eq!(parse_service_ranges(&[]), Err(AttError::Malformed));
    }

    // ------------------------------------------------------------ what the peer sends

    #[test]
    fn att_peer_request_gets_error_response() {
        // Discovery requests of the phone find an empty database; everything else is "not supported".
        let discovery = classify(&[0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28]);
        assert_eq!(discovery, Incoming::PeerRequest { reply: Some(vec![0x01, 0x10, 0x01, 0x00, ERR_ATTRIBUTE_NOT_FOUND]), peer_mtu: None });
        let read = classify(&[0x0A, 0x05, 0x00]);
        assert_eq!(read, Incoming::PeerRequest { reply: Some(vec![0x01, 0x0A, 0x05, 0x00, ERR_INVALID_HANDLE]), peer_mtu: None });
        let other = classify(&[0x0E, 0x05, 0x00, 0x06, 0x00]);
        assert_eq!(other, Incoming::PeerRequest { reply: Some(vec![0x01, 0x0E, 0x05, 0x00, ERR_REQUEST_NOT_SUPPORTED]), peer_mtu: None });
    }

    #[test]
    fn att_peer_mtu_request_gets_517() {
        assert_eq!(classify(&[OP_MTU_REQUEST, 0xB9, 0x00]), Incoming::PeerRequest { reply: Some(mtu_response(517)), peer_mtu: Some(185) });
    }

    #[test]
    fn commands_and_confirmations_from_the_peer_get_no_answer() {
        assert_eq!(classify(&[0x52, 0x05, 0x00, 0xAA]), Incoming::PeerRequest { reply: None, peer_mtu: None });
        assert_eq!(classify(&[0xD2, 0x05, 0x00, 0xAA]), Incoming::PeerRequest { reply: None, peer_mtu: None });
        assert_eq!(classify(&[OP_CONFIRMATION]), Incoming::Ignored);
        assert_eq!(classify(&[]), Incoming::Ignored);
    }

    #[test]
    fn notifications_and_indications_are_told_apart() {
        assert_eq!(classify(&[OP_NOTIFICATION, 0x22, 0x00, 7, 8]), Incoming::Notification { handle: 0x22, value: vec![7, 8], confirm: false });
        assert_eq!(classify(&[OP_INDICATION, 0x22, 0x00, 9]), Incoming::Notification { handle: 0x22, value: vec![9], confirm: true });
        assert_eq!(classify(&[OP_WRITE_RESPONSE]), Incoming::Response(vec![OP_WRITE_RESPONSE]));
        assert_eq!(classify(&[OP_ERROR, 0x12, 0, 0, 3]), Incoming::Response(vec![OP_ERROR, 0x12, 0, 0, 3]));
    }

    // ------------------------------------------------------------ the client

    #[tokio::test(start_paused = true)]
    async fn a_request_returns_its_response_and_answers_the_peer_in_between() {
        let (mut phone, sent) = Phone::new(LAYOUT);
        // The phone's own read request arrives before the response to ours.
        phone.inbox.push_back(vec![0x0A, 0x05, 0x00]);
        let mut att = AttClient::new(phone);
        let response = att.request(write_request(LAYOUT.control_value, b"x"), REQUEST_TIMEOUT).await.unwrap();
        assert_eq!(response, vec![OP_WRITE_RESPONSE]);
        let sent = sent.borrow();
        assert_eq!(sent[0][0], OP_WRITE_REQUEST);
        assert_eq!(sent[1], vec![0x01, 0x0A, 0x05, 0x00, ERR_INVALID_HANDLE], "the phone's request was answered");
    }

    #[tokio::test(start_paused = true)]
    async fn notifications_that_arrive_during_a_request_wait_for_the_reader_in_order() {
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.inbox.push_back(vec![OP_NOTIFICATION, 0x22, 0x00, 1]);
        phone.inbox.push_back(vec![OP_INDICATION, 0x22, 0x00, 2]);
        let mut att = AttClient::new(phone);
        att.request(write_request(LAYOUT.control_value, b"x"), REQUEST_TIMEOUT).await.unwrap();
        assert_eq!(att.next_notification().await.unwrap(), (0x22, vec![1]));
        assert_eq!(att.next_notification().await.unwrap(), (0x22, vec![2]));
    }

    #[tokio::test(start_paused = true)]
    async fn indications_are_confirmed() {
        let (mut phone, sent) = Phone::new(LAYOUT);
        phone.inbox.push_back(vec![OP_INDICATION, 0x22, 0x00, 2]);
        let mut att = AttClient::new(phone);
        att.next_notification().await.unwrap();
        assert_eq!(sent.borrow().as_slice(), &[vec![OP_CONFIRMATION]]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_request_without_a_response_times_out() {
        let (phone, _) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        // The test phone never answers a confirmation, so nothing comes back.
        let result = att.request(vec![OP_CONFIRMATION], Duration::from_secs(1)).await;
        assert_eq!(result, Err(AttError::Timeout));
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_channel_ends_the_wait() {
        struct Closed;
        impl AttTransport for Closed {
            async fn send(&mut self, _: &[u8]) -> io::Result<()> {
                Ok(())
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                Ok(Vec::new())
            }
        }
        let mut att = AttClient::new(Closed);
        assert_eq!(att.next_notification().await, Err(AttError::Closed));
        assert_eq!(att.request(vec![0x02, 0, 0], REQUEST_TIMEOUT).await, Err(AttError::Closed));
    }

    #[tokio::test(start_paused = true)]
    async fn an_os_error_carries_its_number() {
        struct Broken;
        impl AttTransport for Broken {
            async fn send(&mut self, _: &[u8]) -> io::Result<()> {
                Err(io::Error::from_raw_os_error(104))
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                Err(io::Error::from_raw_os_error(110))
            }
        }
        let mut att = AttClient::new(Broken);
        assert_eq!(att.request(vec![0x02, 0, 0], REQUEST_TIMEOUT).await, Err(AttError::Io(Some(104))));
        assert_eq!(att.next_notification().await, Err(AttError::Io(Some(110))));
    }

    #[tokio::test(start_paused = true)]
    async fn a_write_waits_for_the_response_and_reports_an_error_response() {
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        att.write(LAYOUT.control_value, b"hello", REQUEST_TIMEOUT).await.unwrap();
        assert_eq!(sent.borrow()[0], write_request(LAYOUT.control_value, b"hello"));
        let rejected = att.write(0x0999, b"x", REQUEST_TIMEOUT).await;
        assert_eq!(rejected, Err(AttError::Protocol { request: OP_WRITE_REQUEST, code: ERR_INVALID_HANDLE }));
    }

    #[tokio::test(start_paused = true)]
    async fn a_write_longer_than_the_mtu_allows_is_refused_before_it_is_sent() {
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        // MTU 23 until exchanged: 20 bytes fit, 21 do not.
        assert_eq!(att.write(LAYOUT.control_value, &[0; 21], REQUEST_TIMEOUT).await, Err(AttError::TooLong));
        assert!(sent.borrow().is_empty());
        att.write(LAYOUT.control_value, &[0; 20], REQUEST_TIMEOUT).await.unwrap();
    }

    #[test]
    fn a_read_request_names_the_handle() {
        assert_eq!(read_request(0x0026), vec![OP_READ_REQUEST, 0x26, 0x00]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_read_answered_with_a_value_returns_its_bytes() {
        struct Readable(VecDeque<Vec<u8>>);
        impl AttTransport for Readable {
            async fn send(&mut self, pdu: &[u8]) -> io::Result<()> {
                assert_eq!(pdu[0], OP_READ_REQUEST);
                self.0.push_back(vec![OP_READ_RESPONSE, 7]);
                Ok(())
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                match self.0.pop_front() {
                    Some(pdu) => Ok(pdu),
                    None => std::future::pending().await,
                }
            }
        }
        let mut att = AttClient::new(Readable(VecDeque::new()));
        assert_eq!(att.read(0x26, Duration::from_secs(1)).await, Ok(ReadReply::Answered(vec![7])));
    }

    #[tokio::test(start_paused = true)]
    async fn a_read_that_is_not_permitted_is_an_att_error_reply() {
        // The test phone answers an unknown request with an Error Response naming it, like iOS does for "Read Not Permitted".
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        assert_eq!(att.read(LAYOUT.control_value, Duration::from_secs(1)).await, Ok(ReadReply::AttError));
        assert_eq!(sent.borrow()[0], read_request(LAYOUT.control_value));
    }

    #[tokio::test(start_paused = true)]
    async fn a_read_without_any_reply_times_out() {
        struct Silent;
        impl AttTransport for Silent {
            async fn send(&mut self, _: &[u8]) -> io::Result<()> {
                Ok(())
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                std::future::pending().await
            }
        }
        let mut att = AttClient::new(Silent);
        assert_eq!(att.read(0x26, Duration::from_secs(1)).await, Err(AttError::Timeout));
    }

    #[tokio::test(start_paused = true)]
    async fn notifications_that_arrive_during_a_read_are_not_lost() {
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.inbox.push_back(vec![OP_NOTIFICATION, 0x22, 0x00, 1]);
        phone.inbox.push_back(vec![OP_INDICATION, 0x22, 0x00, 2]);
        let mut att = AttClient::new(phone);
        assert_eq!(att.read(LAYOUT.control_value, Duration::from_secs(1)).await, Ok(ReadReply::AttError));
        assert_eq!(att.next_notification().await.unwrap(), (0x22, vec![1]));
        assert_eq!(att.next_notification().await.unwrap(), (0x22, vec![2]));
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_channel_during_a_read_is_a_failure_not_a_reply() {
        struct Closed;
        impl AttTransport for Closed {
            async fn send(&mut self, _: &[u8]) -> io::Result<()> {
                Ok(())
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                Ok(Vec::new())
            }
        }
        let mut att = AttClient::new(Closed);
        assert_eq!(att.read(0x26, Duration::from_secs(1)).await, Err(AttError::Closed));
    }

    // ------------------------------------------------------------ establishing

    #[tokio::test(start_paused = true)]
    async fn establish_discovers_only_this_service_and_subscribes() {
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        let mut phases = Vec::new();
        let done = establish(&mut att, None, UUIDS, |p| phases.push(p)).await.unwrap();
        assert_eq!(
            done.handles,
            HandleSet { service_start: 0x20, service_end: 0x28, event: 0x22, control: 0x26, cccd: 0x23 }
        );
        assert_eq!(done.mtu, 185);
        assert_eq!(att.mtu(), 185);
        assert_eq!(phases, vec![Phase::Mtu(185), Phase::Discovered { cached: false }, Phase::Subscribed]);
        assert_eq!(
            opcodes(&sent),
            vec![OP_MTU_REQUEST, OP_FIND_BY_TYPE_VALUE_REQUEST, OP_READ_BY_TYPE_REQUEST, OP_FIND_INFO_REQUEST, OP_WRITE_REQUEST]
        );
        assert_eq!(sent.borrow()[4], write_request(0x23, &[1, 0]), "CCCD = 0x0001");
    }

    #[tokio::test(start_paused = true)]
    async fn att_cached_handles_are_checked_before_use() {
        let cached = HandleSet { service_start: 0x20, service_end: 0x28, event: 0x22, control: 0x26, cccd: 0x23 };
        // The phone still has the same layout: one Read By Type to check, then the CCCD write, no discovery.
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        let mut phases = Vec::new();
        let done = establish(&mut att, Some(cached), UUIDS, |p| phases.push(p)).await.unwrap();
        assert_eq!(done.handles, cached);
        assert_eq!(phases, vec![Phase::Mtu(185), Phase::Discovered { cached: true }, Phase::Subscribed]);
        assert_eq!(opcodes(&sent), vec![OP_MTU_REQUEST, OP_READ_BY_TYPE_REQUEST, OP_WRITE_REQUEST]);

        // The phone's database moved (an app update): the check fails, a full discovery follows, the old handles are not used.
        let moved = Layout { service: (0x0040, 0x0048), event_value: 0x0042, control_value: 0x0046, cccd: 0x0043 };
        let (phone, sent) = Phone::new(moved);
        let mut att = AttClient::new(phone);
        let mut phases = Vec::new();
        let done = establish(&mut att, Some(cached), UUIDS, |p| phases.push(p)).await.unwrap();
        assert_eq!(done.handles.event, 0x42);
        assert_eq!(phases, vec![Phase::Mtu(185), Phase::Discovered { cached: false }, Phase::Subscribed]);
        let ops = opcodes(&sent);
        assert_eq!(ops[..3], [OP_MTU_REQUEST, OP_READ_BY_TYPE_REQUEST, OP_FIND_BY_TYPE_VALUE_REQUEST]);
        let writes: Vec<_> = sent.borrow().iter().filter(|p| p[0] == OP_WRITE_REQUEST).cloned().collect();
        assert_eq!(writes, vec![write_request(0x43, &[1, 0])], "only the discovered CCCD is written");
    }

    #[tokio::test(start_paused = true)]
    async fn a_cache_check_answered_with_garbage_means_discover_again() {
        let cached = HandleSet { service_start: 0x20, service_end: 0x28, event: 0x22, control: 0x26, cccd: 0x23 };
        let (mut phone, sent) = Phone::new(LAYOUT);
        phone.garble_next_read_by_type = true;
        let mut att = AttClient::new(phone);
        let mut phases = Vec::new();
        let done = establish(&mut att, Some(cached), UUIDS, |p| phases.push(p)).await.unwrap();
        assert_eq!(done.handles, cached);
        assert_eq!(phases, vec![Phase::Mtu(185), Phase::Discovered { cached: false }, Phase::Subscribed]);
        assert!(opcodes(&sent).contains(&OP_FIND_BY_TYPE_VALUE_REQUEST), "the handles were looked for afresh");
    }

    #[tokio::test(start_paused = true)]
    async fn a_cached_cccd_that_is_refused_falls_back_to_discovery() {
        // The characteristics are where they were but the CCCD handle was not what the cache said.
        let cached = HandleSet { service_start: 0x20, service_end: 0x28, event: 0x22, control: 0x26, cccd: 0x24 };
        let (phone, sent) = Phone::new(LAYOUT);
        let mut att = AttClient::new(phone);
        let done = establish(&mut att, Some(cached), UUIDS, |_| {}).await.unwrap();
        assert_eq!(done.handles.cccd, 0x23);
        let writes: Vec<_> = sent.borrow().iter().filter(|p| p[0] == OP_WRITE_REQUEST).cloned().collect();
        assert_eq!(writes, vec![write_request(0x24, &[1, 0]), write_request(0x23, &[1, 0])]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_phone_without_the_service_fails_with_the_att_error() {
        struct Nothing(VecDeque<Vec<u8>>);
        impl AttTransport for Nothing {
            async fn send(&mut self, pdu: &[u8]) -> io::Result<()> {
                if pdu[0] == OP_MTU_REQUEST {
                    self.0.push_back(mtu_response(23));
                } else {
                    self.0.push_back(error_response(pdu[0], 0, ERR_ATTRIBUTE_NOT_FOUND));
                }
                Ok(())
            }
            async fn recv(&mut self) -> io::Result<Vec<u8>> {
                match self.0.pop_front() {
                    Some(p) => Ok(p),
                    None => std::future::pending().await,
                }
            }
        }
        let mut att = AttClient::new(Nothing(VecDeque::new()));
        let result = establish(&mut att, None, UUIDS, |_| {}).await;
        assert_eq!(result, Err(AttError::Protocol { request: OP_FIND_BY_TYPE_VALUE_REQUEST, code: ERR_ATTRIBUTE_NOT_FOUND }));
    }

    #[tokio::test(start_paused = true)]
    async fn notifications_sent_right_after_the_subscription_are_kept() {
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.on_subscribe = vec![vec![OP_NOTIFICATION, 0x22, 0x00, 0x7E]];
        let mut att = AttClient::new(phone);
        establish(&mut att, None, UUIDS, |_| {}).await.unwrap();
        assert_eq!(att.next_notification().await.unwrap(), (0x22, vec![0x7E]));
    }

    #[tokio::test(start_paused = true)]
    async fn the_negotiated_mtu_is_the_smaller_of_both_sides_and_never_below_23() {
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.mtu = 1000;
        let mut att = AttClient::new(phone);
        assert_eq!(establish(&mut att, None, UUIDS, |_| {}).await.unwrap().mtu, 517);
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.mtu = 5;
        let mut att = AttClient::new(phone);
        assert_eq!(establish(&mut att, None, UUIDS, |_| {}).await.unwrap().mtu, 23);
    }

    #[tokio::test(start_paused = true)]
    async fn the_phones_own_mtu_request_lowers_the_mtu() {
        let (mut phone, _) = Phone::new(LAYOUT);
        phone.inbox.push_back(vec![OP_MTU_REQUEST, 0x64, 0x00]); // the phone asks for 100
        let mut att = AttClient::new(phone);
        assert_eq!(establish(&mut att, None, UUIDS, |_| {}).await.unwrap().mtu, 100);
    }
}
