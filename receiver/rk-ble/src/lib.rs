//! The BLE link of a receiver: scan for the keyboard, connect, subscribe, write, disconnect.
//!
//! Backends (`windows.rs` here, Linux in WL10) speak one interface to the application: [`LinkEvent`]s up, [`LinkCommand`]s
//! down. The contract the application relies on:
//!
//! - While no connection exists the backend scans for `LinkConfig::select` (and, after `SetPairingScan(true)`, for
//!   `LinkConfig::pairing`); while a connection exists it does not scan.
//! - A device under `Hold` is not connected to until the hold has run out.
//! - Every connection has a serial (`conn`), unique for the life of the process, and a `Diag` event for each phase.

#![cfg_attr(not(windows), forbid(unsafe_code))]
#![cfg_attr(windows, deny(unsafe_op_in_unsafe_fn))]

use std::time::Duration;
use uuid::Uuid;

pub mod diag;
pub mod fake;
pub mod flow;
#[cfg(windows)]
pub mod windows;

pub use diag::{Diag, FailKind, ShortId, Value};
pub use rk_core::handshake::Route;
#[cfg(windows)]
pub use windows::run;

/// A remote device as the backend knows it. The numeric value is the Bluetooth address on Windows and an opaque id on
/// other backends; it never reaches a log, only [`DeviceKey::short`] does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DeviceKey(pub u64);

impl DeviceKey {
    /// The hashed form that may be logged.
    pub fn short(self) -> ShortId {
        ShortId::of(self)
    }
}

/// Why a connection ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisconnectReason {
    /// The application asked for it.
    Local,
    /// The phone closed the link.
    Remote,
    /// The link dropped without either side asking (supervision timeout, out of range).
    LinkLost,
    /// The connection never became usable.
    Failed(FailKind),
}

impl DisconnectReason {
    /// The word written to the log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Remote => "remote",
            Self::LinkLost => "link_lost",
            Self::Failed(kind) => kind.as_str(),
        }
    }
}

/// Why scanning is not running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanFailure {
    /// The Bluetooth radio is off or disabled.
    RadioOff,
    /// The system stopped the scan on its own.
    Aborted,
    /// The scan could not be started for another reason.
    Unavailable,
}

impl ScanFailure {
    /// The word written to the log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RadioOff => "radio_off",
            Self::Aborted => "aborted",
            Self::Unavailable => "unavailable",
        }
    }
}

/// Whether the backend is scanning. Reported when it changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanState {
    Running,
    Failed(ScanFailure),
}

/// From a backend to the application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkEvent {
    /// The `event` characteristic is subscribed: the connection is usable. `route` tells which advertised UUID led here.
    Connected { conn: u64, device: DeviceKey, route: Route, mtu: usize },
    /// One notification of `event` (one frame, or one pointer packet) of connection `conn`. The backend delivers it after
    /// `Connected`; the application ignores one that belongs to a connection it no longer has.
    Notification { conn: u64, bytes: Vec<u8> },
    /// Scanning started, or stopped working.
    Scan(ScanState),
    Disconnected { conn: u64, device: DeviceKey, reason: DisconnectReason },
    /// A phase of a connection, for the diagnostic log.
    Diag(Diag),
}

/// From the application to a backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkCommand {
    /// Write `control`, always as a Write Request (with response).
    Write(Vec<u8>),
    /// Release the connection now.
    Disconnect,
    /// Do not connect to this device for this long.
    Hold { device: DeviceKey, for_: Duration },
    /// Scan for the pairing UUID as well, or stop doing so.
    SetPairingScan(bool),
}

/// What a backend scans for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkConfig {
    pub select: Uuid,
    pub pairing: Uuid,
    /// A specific Bluetooth controller; `None` takes the system default.
    pub adapter: Option<String>,
}
