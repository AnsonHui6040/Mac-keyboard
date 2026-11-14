//! The tray's words in Taiwanese Traditional Chinese and in English.

use crate::ui::NoticeKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    ZhTw,
    En,
}

impl Lang {
    /// From a Windows language id (`GetUserDefaultUILanguage`): the primary language Chinese (0x04) reads Traditional
    /// Chinese, anything else English.
    pub fn from_langid(langid: u16) -> Self {
        if langid & 0x3FF == 0x04 {
            Self::ZhTw
        } else {
            Self::En
        }
    }

    /// From a POSIX locale such as `zh_TW.UTF-8` or `en_US`.
    pub fn from_locale(locale: &str) -> Self {
        if locale.starts_with("zh") {
            Self::ZhTw
        } else {
            Self::En
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Text {
    AppName,
    StatusIdle,
    StatusPairing,
    Rename,
    RenamePrompt,
    PairNewPhone,
    PairedPhones,
    NoPairedPhones,
    Delete,
    AllowTrackpad,
    Autostart,
    PasteNonAscii,
    Reauthorize,
    ExportDiagnostics,
    Quit,
    PairingTitle,
    DiagnosticsExported,
    DiagnosticsFailed,
}

impl Text {
    pub const ALL: [Text; 18] = [
        Text::AppName,
        Text::StatusIdle,
        Text::StatusPairing,
        Text::Rename,
        Text::RenamePrompt,
        Text::PairNewPhone,
        Text::PairedPhones,
        Text::NoPairedPhones,
        Text::Delete,
        Text::AllowTrackpad,
        Text::Autostart,
        Text::PasteNonAscii,
        Text::Reauthorize,
        Text::ExportDiagnostics,
        Text::Quit,
        Text::PairingTitle,
        Text::DiagnosticsExported,
        Text::DiagnosticsFailed,
    ];
}

pub fn text(lang: Lang, key: Text) -> &'static str {
    use Lang::{En, ZhTw};
    match (key, lang) {
        (Text::AppName, _) => "Remote Keyboard",
        (Text::StatusIdle, ZhTw) => "等待手機連線",
        (Text::StatusIdle, En) => "Waiting for a phone",
        (Text::StatusPairing, ZhTw) => "配對中，請在手機上開啟配對畫面",
        (Text::StatusPairing, En) => "Pairing: open the pairing screen on the phone",
        (Text::Rename, ZhTw) => "改名…",
        (Text::Rename, En) => "Rename…",
        (Text::RenamePrompt, ZhTw) => "這台電腦在手機上顯示的名稱（最多 32 個位元組）",
        (Text::RenamePrompt, En) => "Name shown on the phone (32 bytes at most)",
        (Text::PairNewPhone, ZhTw) => "配對新手機",
        (Text::PairNewPhone, En) => "Pair a new phone",
        (Text::PairedPhones, ZhTw) => "已配對的手機",
        (Text::PairedPhones, En) => "Paired phones",
        (Text::NoPairedPhones, ZhTw) => "尚未配對任何手機",
        (Text::NoPairedPhones, En) => "No phone paired yet",
        (Text::Delete, ZhTw) => "刪除",
        (Text::Delete, En) => "Delete",
        (Text::AllowTrackpad, ZhTw) => "允許觸控板控制",
        (Text::AllowTrackpad, En) => "Allow trackpad control",
        (Text::Autostart, ZhTw) => "開機自動啟動",
        (Text::Autostart, En) => "Start at sign-in",
        (Text::PasteNonAscii, ZhTw) => "非 ASCII 文字改用貼上",
        (Text::PasteNonAscii, En) => "Paste non-ASCII text",
        (Text::Reauthorize, ZhTw) => "重新授權",
        (Text::Reauthorize, En) => "Authorize again",
        (Text::ExportDiagnostics, ZhTw) => "匯出診斷資料",
        (Text::ExportDiagnostics, En) => "Export diagnostics",
        (Text::Quit, ZhTw) => "結束",
        (Text::Quit, En) => "Quit",
        (Text::PairingTitle, ZhTw) => "配對新手機",
        (Text::PairingTitle, En) => "Pair a new phone",
        (Text::DiagnosticsExported, ZhTw) => "診斷資料已匯出",
        (Text::DiagnosticsExported, En) => "Diagnostics exported",
        (Text::DiagnosticsFailed, ZhTw) => "診斷資料匯出失敗",
        (Text::DiagnosticsFailed, En) => "Diagnostics export failed",
    }
}

/// `已連線：<phone>` / `Connected: <phone>`.
pub fn status_connected(lang: Lang, phone: &str) -> String {
    match lang {
        Lang::ZhTw => format!("已連線：{phone}"),
        Lang::En => format!("Connected: {phone}"),
    }
}

pub fn notice(lang: Lang, kind: NoticeKind) -> &'static str {
    use Lang::{En, ZhTw};
    match (kind, lang) {
        (NoticeKind::NeedsRepair, ZhTw) => "這支手機需要重新配對",
        (NoticeKind::NeedsRepair, En) => "This phone needs to be paired again",
        (NoticeKind::UpdatePhone, ZhTw) => "請更新 iPhone App",
        (NoticeKind::UpdatePhone, En) => "Please update the iPhone app",
        (NoticeKind::PairingFailed, ZhTw) => "配對失敗，請再試一次",
        (NoticeKind::PairingFailed, En) => "Pairing failed, please try again",
        (NoticeKind::PairingStoreFull, ZhTw) => "已配對 8 支手機，請先刪除一支",
        (NoticeKind::PairingStoreFull, En) => "Eight phones are paired already, delete one first",
        (NoticeKind::StoreError, ZhTw) => "無法儲存配對資料",
        (NoticeKind::StoreError, En) => "Could not store the pairing",
        (NoticeKind::BluetoothOff, ZhTw) => "藍牙未開啟，無法掃描",
        (NoticeKind::BluetoothOff, En) => "Bluetooth is off, scanning is not running",
        (NoticeKind::ConfigNotSaved, ZhTw) => "設定檔無法讀取，也無法備份；這次的設定不會儲存，原檔保持不動",
        (NoticeKind::ConfigNotSaved, En) => "The settings file cannot be read or backed up; this run's settings are not saved and the file is left alone",
    }
}

/// The pairing question: the phone's name and the code to compare.
pub fn pairing_question(lang: Lang, phone: &str, sas: &str) -> String {
    match lang {
        Lang::ZhTw => format!("手機「{phone}」要求配對。\n\n配對碼：{sas}\n\n手機上顯示的配對碼相同嗎？"),
        Lang::En => format!("Phone \"{phone}\" wants to pair.\n\nPairing code: {sas}\n\nDoes the phone show the same code?"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_text_exists_in_both_languages_and_they_differ() {
        for key in Text::ALL {
            let (zh, en) = (text(Lang::ZhTw, key), text(Lang::En, key));
            assert!(!zh.is_empty() && !en.is_empty());
            if key != Text::AppName {
                assert_ne!(zh, en, "{key:?}");
            }
        }
    }

    #[test]
    fn chinese_windows_ui_language_reads_traditional_chinese() {
        assert_eq!(Lang::from_langid(0x0404), Lang::ZhTw);
        assert_eq!(Lang::from_langid(0x0804), Lang::ZhTw);
        assert_eq!(Lang::from_langid(0x0409), Lang::En);
        assert_eq!(Lang::from_locale("zh_TW.UTF-8"), Lang::ZhTw);
        assert_eq!(Lang::from_locale("en_US.UTF-8"), Lang::En);
    }

    #[test]
    fn traditional_chinese_uses_taiwan_wording() {
        for key in Text::ALL {
            let zh = text(Lang::ZhTw, key);
            assert!(!zh.contains("没") && !zh.contains("网络") && !zh.contains("设"), "{zh}");
        }
    }
}
