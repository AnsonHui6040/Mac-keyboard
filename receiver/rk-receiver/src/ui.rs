//! What the application tells the tray and what the tray asks of it.

/// Which of the three tray icons shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconState {
    Connected,
    Disconnected,
    /// Something needs the user: re-pair, update the phone.
    Attention,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhoneEntry {
    pub id: [u8; 16],
    pub name: String,
}

/// A snapshot of everything the tray menu shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayState {
    pub icon: IconState,
    pub connected_phone: Option<String>,
    pub pairing_open: bool,
    pub host_name: String,
    pub phones: Vec<PhoneEntry>,
    pub trackpad: bool,
    pub autostart: bool,
    pub paste_non_ascii: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoticeKind {
    /// The phone's key did not match: pair again.
    NeedsRepair,
    /// The phone speaks another protocol version.
    UpdatePhone,
    PairingFailed,
    /// Eight phones are stored; delete one first.
    PairingStoreFull,
    StoreError,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiEvent {
    State(TrayState),
    /// Ask the user whether the code on the phone shows the same.
    PairingRequest { phone_name: String, sas: String },
    PairingClosed,
    Notice(NoticeKind),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiCommand {
    StartPairing,
    ConfirmPairing(bool),
    Rename(String),
    DeletePhone([u8; 16]),
    SetTrackpad(bool),
    SetAutostart(bool),
    SetPasteNonAscii(bool),
    Reauthorize,
    Quit,
}
