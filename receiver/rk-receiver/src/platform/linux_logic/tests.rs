use super::*;
use crate::i18n::Lang;
use crate::store::{PhoneBackend, StoreError};
use crate::ui::{IconState, NoticeKind, PhoneEntry, TrayState, UiCommand};
use rk_core::identity::{PairedPhone, PhoneIdentity, PhonePlatform};
use rk_core::secret::PairKey;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn phone(n: u8) -> PairedPhone {
    PairedPhone {
        identity: PhoneIdentity { id: [n; 16], name: format!("phone {n}"), platform: PhonePlatform::Ios },
        pair_key: PairKey::new([n; 32]),
    }
}

fn state() -> TrayState {
    TrayState {
        icon: IconState::Disconnected,
        connected_phone: None,
        pairing_open: false,
        receiving: true,
        host_name: "Linux".into(),
        phones: vec![PhoneEntry { id: [1; 16], name: "A".into() }, PhoneEntry { id: [2; 16], name: "B".into() }],
        trackpad: false,
        autostart: false,
        paste_non_ascii: true,
        needs_authorization: false,
    }
}

fn no_adapters() -> AdapterChoices {
    AdapterChoices::default()
}

fn flatten(entries: &[MenuEntry], out: &mut Vec<(String, String)>) {
    for entry in entries {
        match entry {
            MenuEntry::Item { id, label } | MenuEntry::Check { id, label, .. } => out.push((id.clone(), label.clone())),
            MenuEntry::Sub { entries, .. } => flatten(entries, out),
            MenuEntry::Info { .. } | MenuEntry::Separator => {}
        }
    }
}

fn ids(entries: &[MenuEntry]) -> Vec<String> {
    let mut all = Vec::new();
    flatten(entries, &mut all);
    all.into_iter().map(|(id, _)| id).collect()
}

fn find<'a>(entries: &'a [MenuEntry], wanted: &str) -> Option<&'a MenuEntry> {
    for entry in entries {
        match entry {
            MenuEntry::Item { id, .. } | MenuEntry::Check { id, .. } if id == wanted => return Some(entry),
            MenuEntry::Sub { entries, .. } => {
                if let Some(found) = find(entries, wanted) {
                    return Some(found);
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------- autostart

#[test]
fn autostart_desktop_file_contents() {
    let text = autostart_desktop_file(Path::new("/opt/rk/rk-receiver"));
    assert_eq!(
        text,
        "[Desktop Entry]\nType=Application\nName=Remote Keyboard\nExec=/opt/rk/rk-receiver\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
    );
}

#[test]
fn the_exec_line_quotes_what_the_desktop_entry_spec_wants_quoted() {
    assert_eq!(desktop_exec_quote(Path::new("/home/me/my apps/rk")), "\"/home/me/my apps/rk\"");
    assert_eq!(desktop_exec_quote(Path::new("/a/b\"c")), "\"/a/b\\\\\"c\"");
    // A backslash is escaped by a backslash for the Exec key, and each of those again for the file: four in all.
    assert_eq!(desktop_exec_quote(Path::new("/a/b\\c")), "\"/a/b\\\\\\\\c\"");
    assert_eq!(desktop_exec_quote(Path::new("/a/$b")), "\"/a/\\\\$b\"");
    assert_eq!(desktop_exec_quote(Path::new("/a/100%")), "/a/100%%");
    assert_eq!(desktop_exec_quote(Path::new("/plain/path")), "/plain/path");
}

#[test]
fn the_autostart_file_lives_in_the_xdg_config_home() {
    assert_eq!(autostart_file(Path::new("/home/a"), None), Path::new("/home/a/.config/autostart/remote-keyboard.desktop"));
    assert_eq!(autostart_file(Path::new("/home/a"), Some(Path::new("/c"))), Path::new("/c/autostart/remote-keyboard.desktop"));
}

#[test]
fn set_autostart_writes_and_removes_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("autostart").join("remote-keyboard.desktop");
    assert!(write_autostart(&file, Path::new("/opt/rk"), true));
    assert!(std::fs::read_to_string(&file).unwrap().contains("Exec=/opt/rk\n"));
    assert!(write_autostart(&file, Path::new("/opt/rk"), false));
    assert!(!file.exists());
    assert!(write_autostart(&file, Path::new("/opt/rk"), false), "removing what is not there is fine");
}

#[test]
fn autostart_file_is_rewritten_when_it_points_to_another_exe() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("remote-keyboard.desktop");
    std::fs::write(&file, autostart_desktop_file(Path::new("/home/x/.local/bin/rk-receiver"))).unwrap();
    assert!(ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), autostart_desktop_file(Path::new("/usr/bin/rk-receiver")));
}

#[test]
fn autostart_file_is_left_alone_when_disabled_or_already_ours() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("remote-keyboard.desktop");
    assert!(!ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")));
    assert!(!file.exists(), "a missing file means autostart is off and must stay missing");

    let ours = autostart_desktop_file(Path::new("/usr/bin/rk-receiver"));
    std::fs::write(&file, &ours).unwrap();
    assert!(!ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), ours);
}

fn old_exec_file(dir: &Path, extra_before: &str, exec: &str, extra_after: &str) -> PathBuf {
    let file = dir.join("remote-keyboard.desktop");
    std::fs::write(&file, format!("[Desktop Entry]\n{extra_before}Exec={exec}\n{extra_after}")).unwrap();
    file
}

#[test]
fn a_disabled_autostart_file_stays_disabled_when_repointed() {
    let dir = tempfile::tempdir().unwrap();
    let file = old_exec_file(dir.path(), "Type=Application\n", "/gone/rk-receiver", "Hidden=true\nX-GNOME-Autostart-enabled=false\n");
    assert!(ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")));
    let text = std::fs::read_to_string(&file).unwrap();
    assert!(text.contains("Exec=/usr/bin/rk-receiver\n"));
    assert!(text.contains("Hidden=true\n"));
    assert!(text.contains("X-GNOME-Autostart-enabled=false\n"));
    assert!(!text.contains("enabled=true"));
}

#[test]
fn extra_keys_and_arguments_survive_a_repoint() {
    let dir = tempfile::tempdir().unwrap();
    let file = old_exec_file(dir.path(), "X-Custom=1\n", "\"/gone/my apps/rk\" --adapter hci1", "Comment=mine\n");
    assert!(ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")));
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        "[Desktop Entry]\nX-Custom=1\nExec=/usr/bin/rk-receiver --adapter hci1\nComment=mine\n"
    );
}

#[test]
fn a_quoted_old_program_with_a_space_is_recognised_as_the_same_exe() {
    let dir = tempfile::tempdir().unwrap();
    let exe = Path::new("/usr/my apps/rk");
    let file = old_exec_file(dir.path(), "", &format!("{} --x", desktop_exec_quote(exe)), "");
    assert!(!ensure_autostart_points_to(&file, exe));
}

#[test]
fn a_dev_build_does_not_steal_an_autostart_that_names_a_program_that_exists() {
    let dir = tempfile::tempdir().unwrap();
    let old = dir.path().join("rk-old");
    std::fs::write(&old, "x").unwrap();
    let file = old_exec_file(dir.path(), "", old.to_str().unwrap(), "");
    let before = std::fs::read_to_string(&file).unwrap();
    assert!(!ensure_autostart_points_to(&file, Path::new("/home/x/src/target/debug/rk-receiver")));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), before);
    assert!(ensure_autostart_points_to(&file, Path::new("/usr/bin/rk-receiver")), "the package takes over");
}

#[test]
fn should_repoint_decides_on_the_old_program_and_the_running_exe() {
    let dev = Path::new("/home/x/src/target/debug/rk-receiver");
    let old = Path::new("/home/x/.local/bin/rk-receiver");
    assert!(!should_repoint(old, true, dev));
    assert!(should_repoint(old, true, Path::new("/usr/bin/rk-receiver")));
    assert!(should_repoint(old, false, dev));
}

#[test]
fn running_exe_path_drops_the_deleted_suffix() {
    assert_eq!(running_exe_path(PathBuf::from("/usr/bin/rk-receiver (deleted)")), Path::new("/usr/bin/rk-receiver"));
    assert_eq!(running_exe_path(PathBuf::from("/usr/bin/rk-receiver")), Path::new("/usr/bin/rk-receiver"));
}

// ---------------------------------------------------------------- paths

#[test]
fn config_paths_follow_xdg() {
    let home = Path::new("/home/a");
    assert_eq!(data_file(home, None), Path::new("/home/a/.local/share/remote-keyboard/phones.json"));
    assert_eq!(data_file(home, Some(Path::new("/d"))), Path::new("/d/remote-keyboard/phones.json"));
    assert_eq!(lock_file(Some(Path::new("/run/user/1000")), Path::new("/tmp")), Path::new("/run/user/1000/remote-keyboard.lock"));
    assert_eq!(lock_file(None, Path::new("/home/a/.local/state")), Path::new("/home/a/.local/state/remote-keyboard.lock"));
}

#[test]
fn the_portal_token_sits_next_to_the_config_file() {
    assert_eq!(portal_token_file(Path::new("/home/a/.config/remote-keyboard/config.json")), Path::new("/home/a/.config/remote-keyboard/portal-token"));
    assert_eq!(portal_token_file(Path::new("config.json")), Path::new("portal-token"));
}

#[test]
fn the_diagnostics_zip_goes_to_the_desktop_when_there_is_one() {
    let home = Path::new("/home/a");
    assert_eq!(export_dir(home, true, Path::new("/logs")), Path::new("/home/a/Desktop"));
    assert_eq!(export_dir(home, false, Path::new("/logs")), Path::new("/logs"));
}

#[test]
fn os_release_gives_the_pretty_name() {
    assert_eq!(pretty_name("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 26.04 LTS\"\nID=ubuntu\n").as_deref(), Some("Ubuntu 26.04 LTS"));
    assert_eq!(pretty_name("ID=x\n"), None);
}

#[test]
fn the_language_comes_from_the_first_locale_variable_that_is_set() {
    assert_eq!(lang_from_env(Some("zh_TW.UTF-8"), None, Some("en_US.UTF-8")), Lang::ZhTw);
    assert_eq!(lang_from_env(None, Some("en_US"), Some("zh_TW")), Lang::En);
    assert_eq!(lang_from_env(Some(""), None, Some("zh_TW.UTF-8")), Lang::ZhTw);
    assert_eq!(lang_from_env(None, None, None), Lang::En);
}

// ---------------------------------------------------------------- tray menu

#[test]
fn the_menu_has_the_windows_items_and_the_two_linux_ones() {
    let entries = menu_entries(&state(), Lang::ZhTw, &no_adapters());
    let all = ids(&entries);
    for wanted in ["rename", "pair", "trackpad", "autostart", "export", "quit", "paste", "reauthorize", "delete:01010101010101010101010101010101"] {
        assert!(all.iter().any(|id| id == wanted), "{wanted} is missing from {all:?}");
    }
    let mut labelled = Vec::new();
    flatten(&entries, &mut labelled);
    let label = |id: &str| labelled.iter().find(|(i, _)| i == id).unwrap().1.clone();
    assert_eq!(label("paste"), "非 ASCII 文字改用貼上");
    assert_eq!(label("reauthorize"), "重新授權");
    assert_eq!(label("pair"), "配對新手機");
}

#[test]
fn checked_items_follow_the_state() {
    let mut s = state();
    s.trackpad = true;
    s.autostart = false;
    s.paste_non_ascii = true;
    let entries = menu_entries(&s, Lang::En, &no_adapters());
    let checked = |id: &str| matches!(find(&entries, id), Some(MenuEntry::Check { checked: true, .. }));
    assert!(checked("trackpad") && checked("paste") && !checked("autostart"));
}

#[test]
fn the_status_line_names_the_connected_phone_or_the_state() {
    let mut s = state();
    assert_eq!(status_label(&s, Lang::ZhTw), "接收中，等待手機連線");
    s.pairing_open = true;
    assert_eq!(status_label(&s, Lang::En), "Pairing: open the pairing screen on the phone");
    s.connected_phone = Some("我的 iPhone".into());
    assert_eq!(status_label(&s, Lang::ZhTw), "已連線：我的 iPhone");
}

#[test]
fn the_status_line_asks_for_authorization_until_the_computer_allows_typing() {
    let mut s = state();
    s.needs_authorization = true;
    assert_eq!(status_label(&s, Lang::ZhTw), "電腦未授權，請選「重新授權」");
    s.connected_phone = Some("我的 iPhone".into());
    assert_eq!(status_label(&s, Lang::ZhTw), "已連線：我的 iPhone", "a connected phone is the more useful thing to say");
}

#[test]
fn no_phones_shows_a_disabled_note_and_the_host_name_is_on_the_rename_item() {
    let mut s = state();
    s.phones.clear();
    let entries = menu_entries(&s, Lang::En, &no_adapters());
    assert!(!ids(&entries).iter().any(|id| id.starts_with("delete:")));
    assert!(entries.iter().any(|e| matches!(e, MenuEntry::Item { id, label } if id == "rename" && label.starts_with("Linux"))));
}

#[test]
fn the_controller_submenu_appears_only_with_more_than_one_controller() {
    let one = AdapterChoices { names: vec!["hci1".into()], current: Some("hci1".into()) };
    assert!(!ids(&menu_entries(&state(), Lang::En, &one)).iter().any(|id| id.starts_with("adapter:")));
    assert!(!ids(&menu_entries(&state(), Lang::En, &no_adapters())).iter().any(|id| id.starts_with("adapter:")));
    let two = AdapterChoices { names: vec!["hci0".into(), "hci1".into()], current: Some("hci1".into()) };
    let entries = menu_entries(&state(), Lang::ZhTw, &two);
    assert_eq!(ids(&entries).iter().filter(|id| id.starts_with("adapter:")).count(), 2);
    assert!(matches!(find(&entries, "adapter:hci1"), Some(MenuEntry::Check { checked: true, .. })));
    assert!(matches!(find(&entries, "adapter:hci0"), Some(MenuEntry::Check { checked: false, .. })));
}

#[test]
fn without_a_choice_the_system_default_controller_is_the_checked_one() {
    let two = AdapterChoices { names: vec!["hci1".into(), "hci0".into()], current: None };
    let entries = menu_entries(&state(), Lang::En, &two);
    assert!(matches!(find(&entries, "adapter:hci0"), Some(MenuEntry::Check { checked: true, .. })));
}

#[test]
fn the_effective_controller_is_the_choice_or_the_default() {
    let names = vec!["hci1".to_string(), "hci0".to_string()];
    assert_eq!(AdapterChoices { names: names.clone(), current: Some("hci1".into()) }.effective(), Some("hci1".into()));
    assert_eq!(AdapterChoices { names, current: None }.effective(), Some("hci0".into()));
    assert_eq!(AdapterChoices { names: vec!["hci2".into(), "hci1".into()], current: None }.effective(), Some("hci1".into()));
    assert_eq!(AdapterChoices::default().effective(), None);
}

#[test]
fn clicks_become_commands_with_the_state_flipped() {
    let s = state();
    assert_eq!(action_for("pair", &s), Some(Action::Command(UiCommand::StartPairing)));
    assert_eq!(action_for("trackpad", &s), Some(Action::Command(UiCommand::SetTrackpad(true))));
    assert_eq!(action_for("paste", &s), Some(Action::Command(UiCommand::SetPasteNonAscii(false))));
    assert_eq!(action_for("autostart", &s), Some(Action::SetAutostart(true)));
    assert_eq!(action_for("reauthorize", &s), Some(Action::Command(UiCommand::Reauthorize)));
    assert_eq!(action_for("quit", &s), Some(Action::Command(UiCommand::Quit)));
    assert_eq!(action_for("rename", &s), Some(Action::AskName));
    assert_eq!(action_for("export", &s), Some(Action::Export));
    assert_eq!(action_for("delete:02020202020202020202020202020202", &s), Some(Action::Command(UiCommand::DeletePhone([2; 16]))));
    assert_eq!(action_for("adapter:hci1", &s), Some(Action::ChooseAdapter("hci1".into())));
    assert_eq!(action_for("delete:zz", &s), None);
    assert_eq!(action_for("nonsense", &s), None);
}

#[test]
fn the_tooltip_shows_a_notice_before_the_state() {
    let s = state();
    assert_eq!(tooltip_text(&s, Lang::En, None), "Remote Keyboard - Receiving, waiting for a phone");
    assert_eq!(tooltip_text(&s, Lang::En, Some(NoticeKind::UpdatePhone)), "Remote Keyboard - Please update the iPhone app");
}

#[test]
fn the_tray_pixmap_is_argb_in_network_order() {
    assert_eq!(argb_from_rgba(&[1, 2, 3, 4, 5, 6, 7, 8]), vec![4, 1, 2, 3, 8, 5, 6, 7]);
    assert!(argb_from_rgba(&[]).is_empty());
}

// ---------------------------------------------------------------- dialogs

#[test]
fn zenity_gets_each_text_as_one_argument_and_never_reads_markup() {
    let args = question_args("標題", "手機「<b>&</b>」要求配對", "相符", "不相符");
    assert_eq!(args[0], "--question");
    assert!(args.contains(&"--no-markup".to_string()));
    assert!(args.contains(&"--title=標題".to_string()));
    assert!(args.contains(&"--text=手機「<b>&</b>」要求配對".to_string()));
    assert!(args.contains(&"--ok-label=相符".to_string()) && args.contains(&"--cancel-label=不相符".to_string()));
    let entry = entry_args("改名", "名稱", "Linux; rm -rf ~");
    assert_eq!(entry[0], "--entry");
    assert!(entry.contains(&"--entry-text=Linux; rm -rf ~".to_string()));
    assert!(entry.contains(&"--no-markup".to_string()));
    assert_eq!(info_args("Remote Keyboard", "text")[0], "--info");
}

#[test]
fn only_exit_code_zero_is_yes_and_an_entry_is_cancelled_by_anything_else() {
    assert!(answered_yes(Some(0)));
    assert!(!answered_yes(Some(1)));
    assert!(!answered_yes(None), "killed by a signal");
    assert_eq!(entered_name(Some(0), "新名稱\n"), Some("新名稱".to_string()));
    assert_eq!(entered_name(Some(0), "  \n"), None);
    assert_eq!(entered_name(Some(1), "x\n"), None);
    assert_eq!(entered_name(None, "x\n"), None);
}

// ---------------------------------------------------------------- restart

#[test]
fn a_restart_drops_the_arguments_that_only_belong_to_the_first_start() {
    let args: Vec<String> = ["--pair", "--adapter", "hci1", "--log-level", "debug"].iter().map(|s| (*s).to_string()).collect();
    let strings = |list: &[&str]| list.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
    // The controller that was chosen is named outright, so the new start never falls back to the system default.
    assert_eq!(restart_args(&args, "hci0"), strings(&["--log-level", "debug", "--adapter", "hci0"]));
    assert_eq!(restart_args(&[], "hci1"), strings(&["--adapter", "hci1"]));
}

// ---------------------------------------------------------------- the key store without Secret Service

#[test]
fn the_phones_file_round_trips_and_is_private() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("share").join("phones.json");
    let mut file = FilePhoneBackend::new(path.clone());
    assert!(file.load().unwrap().is_empty());
    file.put(&phone(1)).unwrap();
    file.put(&phone(2)).unwrap();
    let mut renamed = phone(1);
    renamed.identity.name = "renamed".into();
    file.put(&renamed).unwrap();
    let loaded = FilePhoneBackend::new(path.clone()).load().unwrap();
    assert_eq!(loaded.iter().map(|p| p.identity.name.as_str()).collect::<Vec<_>>(), vec!["renamed", "phone 2"]);
    assert_eq!(loaded[1], phone(2));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
    file.remove(&[1; 16]).unwrap();
    assert_eq!(FilePhoneBackend::new(path).load().unwrap().len(), 1);
}

#[test]
fn a_stale_temporary_file_is_replaced_and_the_result_is_private() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("phones.json");
    // A crash left a world-readable temporary file behind.
    let stale = path.with_extension("json.tmp");
    std::fs::write(&stale, "old").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stale, std::fs::Permissions::from_mode(0o644)).unwrap();
    }
    let mut file = FilePhoneBackend::new(path.clone());
    file.put(&phone(1)).unwrap();
    assert!(!stale.exists(), "the temporary file is gone after the rename");
    assert_eq!(FilePhoneBackend::new(path.clone()).load().unwrap(), vec![phone(1)]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn an_unreadable_phones_file_is_never_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("phones.json");
    std::fs::write(&path, "{ not json").unwrap();
    let mut file = FilePhoneBackend::new(path.clone());
    assert!(file.load().is_err(), "unreadable is not the same as empty");
    assert!(file.put(&phone(1)).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}

#[derive(Clone, Default)]
struct ListBackend(Arc<Mutex<Vec<PairedPhone>>>, bool);

impl PhoneBackend for ListBackend {
    fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
        if self.1 {
            return Err(StoreError::Backend("locked".into()));
        }
        Ok(self.0.lock().unwrap().clone())
    }
    fn put(&mut self, p: &PairedPhone) -> Result<(), StoreError> {
        if self.1 {
            return Err(StoreError::Backend("locked".into()));
        }
        crate::store::upsert(&mut self.0.lock().unwrap(), p.clone())
    }
    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        if self.1 {
            return Err(StoreError::Backend("locked".into()));
        }
        self.0.lock().unwrap().retain(|p| &p.identity.id != id);
        Ok(())
    }
}

#[test]
fn with_a_key_store_new_phones_go_there_and_old_file_phones_stay_visible() {
    let dir = tempfile::tempdir().unwrap();
    let mut file = FilePhoneBackend::new(dir.path().join("phones.json"));
    file.put(&phone(9)).unwrap();
    let keystore = ListBackend::default();
    let mut chain = ChainedBackend::new(Some(Box::new(keystore.clone())), file);
    chain.put(&phone(1)).unwrap();
    assert_eq!(keystore.0.lock().unwrap().len(), 1, "new phone in the key store");
    assert_eq!(chain.load().unwrap().iter().map(|p| p.identity.id[0]).collect::<Vec<_>>(), vec![1, 9]);
    chain.remove(&[9; 16]).unwrap();
    assert_eq!(chain.load().unwrap().len(), 1, "removed from the file too");
}

#[test]
fn without_a_key_store_the_file_is_used() {
    let dir = tempfile::tempdir().unwrap();
    let mut chain = ChainedBackend::new(None, FilePhoneBackend::new(dir.path().join("phones.json")));
    chain.put(&phone(3)).unwrap();
    assert_eq!(chain.load().unwrap(), vec![phone(3)]);
    chain.remove(&[3; 16]).unwrap();
    assert!(chain.load().unwrap().is_empty());
}

#[test]
fn a_key_store_that_cannot_be_read_makes_the_list_unknown_not_empty() {
    let dir = tempfile::tempdir().unwrap();
    let mut file = FilePhoneBackend::new(dir.path().join("phones.json"));
    file.put(&phone(9)).unwrap();
    let chain = ChainedBackend::new(Some(Box::new(ListBackend(Arc::default(), true))), file);
    assert!(chain.load().is_err(), "a locked keyring must not look like \"no phones\"");
}

#[test]
fn a_damaged_phones_file_does_not_hide_the_key_store() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("phones.json");
    std::fs::write(&path, "{ not json").unwrap();
    let keystore = ListBackend::default();
    keystore.0.lock().unwrap().push(phone(1));
    let chain = ChainedBackend::new(Some(Box::new(keystore)), FilePhoneBackend::new(path));
    assert_eq!(chain.load().unwrap(), vec![phone(1)]);
}

// ---------------------------------------------------------------- reading the keyring without waiting for it

#[test]
fn only_the_first_read_may_ask_the_user_to_unlock() {
    let slot = LoadSlot::new();
    assert!(matches!(slot.begin(), Begin::Start { interactive: true }));
    slot.finish(Err(StoreError::Backend("cancelled".into())));
    assert!(matches!(slot.begin(), Begin::Done(Err(_))), "the answer of the last read comes first");
    assert!(matches!(slot.begin(), Begin::Start { interactive: false }), "a retry never raises a prompt");
}

#[test]
fn a_read_that_is_still_going_is_never_started_a_second_time() {
    let slot = LoadSlot::new();
    assert!(matches!(slot.begin(), Begin::Start { .. }));
    for _ in 0..5 {
        assert!(matches!(slot.begin(), Begin::Busy), "a prompt that nobody answers must not pile up requests");
    }
    slot.finish(Ok(vec![phone(1)]));
    assert!(matches!(slot.begin(), Begin::Done(Ok(list)) if list == vec![phone(1)]));
}

#[test]
fn waiting_gives_the_answer_when_it_comes_in_time_and_gives_up_otherwise() {
    let slot = Arc::new(LoadSlot::new());
    slot.begin();
    assert_eq!(slot.wait(Duration::from_millis(20)), None, "no answer, no waiting beyond the bound");
    assert!(matches!(slot.begin(), Begin::Busy), "the read is still going");
    let worker = slot.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(30));
        worker.finish(Ok(vec![phone(2)]));
    });
    assert_eq!(slot.wait(Duration::from_secs(5)), Some(Ok(vec![phone(2)])));
    thread.join().unwrap();
    assert!(matches!(slot.begin(), Begin::Start { .. }), "the answer was taken, the slot is free");
}

#[test]
fn the_slot_says_when_an_answer_is_waiting() {
    let slot = LoadSlot::new();
    assert!(!slot.has_answer());
    slot.begin();
    assert!(!slot.has_answer());
    slot.finish(Ok(Vec::new()));
    assert!(slot.has_answer());
    slot.begin();
    assert!(!slot.has_answer());
}

#[test]
fn the_user_asking_to_unlock_makes_the_next_read_interactive() {
    let slot = LoadSlot::new();
    slot.begin();
    slot.finish(Err(StoreError::Backend("locked".into())));
    slot.begin(); // takes the answer
    slot.want_interactive();
    assert!(matches!(slot.begin(), Begin::Start { interactive: true }));
    slot.finish(Err(StoreError::Backend("cancelled".into())));
    slot.begin();
    assert!(matches!(slot.begin(), Begin::Start { interactive: false }));
}

#[test]
fn a_key_store_that_refuses_is_an_error_not_a_quiet_fall_back_to_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let keystore = ListBackend(Arc::default(), true);
    let path = dir.path().join("phones.json");
    let mut chain = ChainedBackend::new(Some(Box::new(keystore)), FilePhoneBackend::new(path.clone()));
    assert!(chain.put(&phone(1)).is_err());
    assert!(!path.exists(), "no key was written in the clear");
    assert!(chain.remove(&[1; 16]).is_err());
}

#[test]
fn the_menu_toggles_between_stop_and_start_receiving() {
    let mut s = state();
    let entries = menu_entries(&s, Lang::ZhTw, &no_adapters());
    assert!(matches!(find(&entries, "receiving"), Some(MenuEntry::Item { label, .. }) if label == "停止接收"));
    assert_eq!(action_for("receiving", &s), Some(Action::Command(UiCommand::SetReceiving(false))));
    s.receiving = false;
    let entries = menu_entries(&s, Lang::ZhTw, &no_adapters());
    assert!(matches!(find(&entries, "receiving"), Some(MenuEntry::Item { label, .. }) if label == "開始接收"));
    assert_eq!(action_for("receiving", &s), Some(Action::Command(UiCommand::SetReceiving(true))));
    let english = menu_entries(&s, Lang::En, &no_adapters());
    assert!(matches!(find(&english, "receiving"), Some(MenuEntry::Item { label, .. }) if label == "Start receiving"));
}

#[test]
fn pairing_a_new_phone_is_greyed_out_while_stopped() {
    let mut s = state();
    assert!(find(&menu_entries(&s, Lang::ZhTw, &no_adapters()), "pair").is_some());
    s.receiving = false;
    let entries = menu_entries(&s, Lang::ZhTw, &no_adapters());
    assert!(find(&entries, "pair").is_none(), "no clickable item");
    assert!(entries.iter().any(|e| matches!(e, MenuEntry::Info { label } if label == "配對新手機")), "the label stays, disabled");
}

#[test]
fn the_status_line_and_the_tooltip_say_stopped() {
    let mut s = state();
    assert_eq!(status_label(&s, Lang::ZhTw), "接收中，等待手機連線");
    s.receiving = false;
    assert_eq!(status_label(&s, Lang::ZhTw), "已停止接收");
    assert_eq!(status_label(&s, Lang::En), "Receiving stopped");
    assert_eq!(tooltip_text(&s, Lang::ZhTw, None), "Remote Keyboard - 已停止接收");
    // Stopped outranks the other idle lines: nothing is waiting for anything.
    s.needs_authorization = true;
    s.pairing_open = true;
    assert_eq!(status_label(&s, Lang::ZhTw), "已停止接收");
}
