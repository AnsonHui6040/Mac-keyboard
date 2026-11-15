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
    /// 接收中 (`true`) or 已停止 (`false`): the user's switch, see `UiCommand::SetReceiving`.
    pub receiving: bool,
    pub host_name: String,
    pub phones: Vec<PhoneEntry>,
    pub trackpad: bool,
    pub autostart: bool,
    pub paste_non_ascii: bool,
    /// The computer has not (yet) allowed this program to type: the tray offers 「重新授權」 (Linux portal).
    pub needs_authorization: bool,
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
    /// The Bluetooth radio is off or scanning cannot run.
    BluetoothOff,
    /// The paired phones cannot be read from the key store (a locked keyring); they are read again later.
    KeyStoreUnavailable,
    /// `config.json` is unreadable and could not be moved aside: this run's settings are not saved, the file is left alone.
    ConfigNotSaved,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiEvent {
    State(TrayState),
    /// Ask the user whether the code on the phone shows the same. `attempt` names the pairing attempt; only an answer that
    /// carries it counts.
    PairingRequest { attempt: u64, phone_name: String, sas: String },
    /// The pairing window closed.
    PairingClosed,
    /// The attempt's question is moot (its connection ended, the window closed): take the dialog away.
    PairingDialogClose(u64),
    Notice(NoticeKind),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiCommand {
    StartPairing,
    /// 開始 (`true`) or 停止 (`false`) receiving. Never saved: every start of the receiver receives.
    SetReceiving(bool),
    /// The answer to the question of the given attempt.
    ConfirmPairing(u64, bool),
    Rename(String),
    DeletePhone([u8; 16]),
    SetTrackpad(bool),
    SetAutostart(bool),
    SetPasteNonAscii(bool),
    /// The Bluetooth controller to use from the next start on (Linux); `None` takes the system default.
    SetAdapter(Option<String>),
    Reauthorize,
    Quit,
}
