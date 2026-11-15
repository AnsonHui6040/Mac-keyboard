# 04c Install the Linux receiver

The Linux receiver is the receiving program you install on an Ubuntu computer. It types the text and trackpad actions sent from your iPhone into the window that is in front on the computer. It has no main window. It only shows a tray icon at the right end of the top bar.

This chapter is for Ubuntu computers only. For a Mac, see [04 Install the Mac Receiver](04-install-mac-receiver.md). For Windows, see [04b Install the Windows receiver](04b-install-windows-receiver.md).

## Requirements

| Item | Requirement |
|---|---|
| Operating system | Ubuntu 26.04, x86_64, GNOME desktop, Wayland session |
| Bluetooth | The computer has Bluetooth (Bluetooth LE support) and it is turned on |
| Permissions | Installing needs `sudo`. Running the receiver does not |
| Network | The receiver does not need a network while it runs. Text travels over Bluetooth only |

The package also installs these dependencies: `zenity`, `xdg-desktop-portal`, `xdg-desktop-portal-gnome`, `gnome-keyring` and `bluez`.

## 1. Download, verify, and install

1. From the GitHub Release, get `remote-keyboard_0.2.0~alpha.1_amd64.deb` and `SHA256SUMS.txt` from the same page.
2. Open Terminal and run the command below. Replace the file path with the location of your `.deb`.

```bash
sha256sum remote-keyboard_0.2.0~alpha.1_amd64.deb
```

3. Compare the output with the value for that file in `SHA256SUMS.txt`. The two must be exactly the same. If they differ, download the file again and do not install.
4. In the folder that holds the `.deb`, run:

```bash
sudo apt install ./remote-keyboard_0.2.0~alpha.1_amd64.deb
```

After installing, `/usr/bin/rk-receiver` is the receiver, `/usr/bin/rk-diag` is the diagnostics tool, and the application menu has a new Remote Keyboard entry.

## 2. Run it for the first time

1. Open the application menu and run Remote Keyboard.
2. The first time, the system opens a window asking whether Remote Keyboard may use Remote Desktop (遠端桌面). Choose Allow.
3. A Remote Keyboard icon appears at the right end of the top bar.

The Remote Desktop permission lets the receiver send key presses and pointer movement to the desktop. Without it the receiver cannot type, and its status says "Not authorized to type: choose Authorize again" (電腦未授權，請選「重新授權」). In that case choose Authorize again (重新授權) in the tray menu and click Allow once more. The receiver remembers the permission, so it does not ask again.

When it works, the first line of the tray menu says "Receiving, waiting for a phone".

## 3. The tray menu

Click the Remote Keyboard icon in the top bar to open the menu. The menu language follows the system language. It shows Chinese when the system uses Chinese and English otherwise. The table gives both.

| Item (Chinese) | Item (English) | Description |
|---|---|---|
| First line (status): 接收中，等待手機連線; 已連線：phone name; 配對中，請在手機上開啟配對畫面; 已停止接收; 電腦未授權，請選「重新授權」 | Receiving, waiting for a phone; Connected: phone name; Pairing: open the pairing screen on the phone; Receiving stopped; Not authorized to type: choose Authorize again | The current state. You cannot click this line |
| 停止接收, 開始接收 | Stop receiving, Start receiving | Stop receiving ends the current connection and stops scanning, until you choose Start receiving or restart the receiver. The stopped state is not saved, so every start receives |
| 電腦名稱　改名… | Computer name　Rename… | This line starts with the current computer name, which is "Linux" by default. Clicking it opens an input box to change the name this computer shows on the phone, 32 bytes at most. After renaming, a paired iPhone has to pair again to show the new name |
| 配對新手機 | Pair a new phone | Starts pairing, see [05 Pairing](05-pairing.md). You cannot click it while receiving is stopped |
| 已配對的手機 | Paired phones | Lists the paired phones. Pick a phone, then click Delete (刪除) to remove its pairing. With no phone, the list shows 尚未配對任何手機 (No phone paired yet). You can pair up to 8 |
| 允許觸控板控制 | Allow trackpad control | When checked, the iPhone can control the pointer, see [07 Trackpad](07-trackpad.md) |
| 非 ASCII 文字改用貼上 | Paste non-ASCII text | Checked by default. See section 6 of this chapter |
| 開機自動啟動 | Start at sign-in | When checked, the receiver starts after you sign in to the desktop |
| 重新授權 | Authorize again | Asks for the Remote Desktop permission again |
| 藍牙控制器 | Bluetooth adapter | Only shown when the computer has more than one Bluetooth adapter. Pick another one and the receiver restarts to use it |
| 匯出診斷資料 | Export diagnostics | Writes a zip file of diagnostics and opens its folder. For its contents see [Receiver troubleshooting](../../troubleshooting-receiver.md) (in Chinese) |
| 結束 | Quit | Closes the receiver, and the iPhone can no longer reach this computer |

When the receiver needs you to act, it shows one of these messages, in Chinese or English by system language. Tooltip means the text that appears when the pointer rests on the tray icon. Window means a dialog box, which you close with OK.

| Message | Shown as | What to do |
|---|---|---|
| 這支手機需要重新配對 (This phone needs to be paired again) | Tooltip | Pair again on both the phone and the computer |
| 請更新 iPhone App (Please update the iPhone app) | Tooltip | Update the iPhone app to the same version |
| 配對失敗，請再試一次 (Pairing failed, please try again) | Window | Choose Pair a new phone again |
| 已配對 8 支手機，請先刪除一支 (Eight phones are paired already, delete one first) | Window | Delete a phone you no longer use from Paired phones |
| 無法儲存配對資料 (Could not store the pairing) | Window | Pair again. If it still fails, export diagnostics |
| 藍牙未開啟，無法掃描 (Bluetooth is off, scanning is not running) | Tooltip | Turn on Bluetooth on the computer |
| 讀不到已配對手機的金鑰，鑰匙圈可能還沒解鎖 (The pairing keys cannot be read: the keyring may be locked) | Tooltip | Unlock the GNOME keyring. The receiver reads the keys again a little later |
| 設定檔無法讀取，也無法備份；這次的設定不會儲存，原檔保持不動 (The settings file cannot be read or backed up; this run's settings are not saved and the file is left alone) | Window | Export diagnostics, see [Receiver troubleshooting](../../troubleshooting-receiver.md) (in Chinese) |

## 4. Start at sign-in, and upgrading from a manual copy

When you check Start at sign-in in the tray menu, the receiver writes an autostart entry at `~/.config/autostart/remote-keyboard.desktop` that points to `/usr/bin/rk-receiver`.

If you used to copy the receiver into `~/.local/bin` by hand, upgrade like this:

1. Quit the running receiver.
2. Delete `~/.local/bin/rk-receiver` and `~/.local/bin/rk-diag`, so the terminal does not run the old copy.
3. Install the `.deb` and start Remote Keyboard from the application menu.

When the receiver starts and autostart is on but the entry points to a different program, it rewrites the entry to `/usr/bin/rk-receiver`, so you do not need to check the box again.

## 5. Upgrade and uninstall

| Situation | What to do |
|---|---|
| Upgrade | Run `sudo apt install ./FILENAME.deb` again with the new `.deb`. Settings and pairing are kept |
| Upgrading from v0.1 | This version uses protocol v4, which does not work with v0.1. Update the iPhone app and the Mac Receiver too, and pair every computer again |
| Uninstall | `sudo apt remove remote-keyboard` |

Settings are in `~/.config/remote-keyboard/config.json` and logs are in `~/.local/state/remote-keyboard/logs/`. Uninstalling does not delete either place. To remove everything, delete them yourself.

## 6. Good to know

| Item | Description |
|---|---|
| No focus safety gate | The Linux receiver does not check what kind of field is active. Text goes to the window that is in front, password fields included. Before you type, make sure the cursor is in the field you want, and do not use this keyboard for passwords |
| Non-ASCII text is pasted | Chinese, emoji and other non-ASCII text goes through the clipboard by default, so every such input overwrites what is on the computer's clipboard. If you clear Paste non-ASCII text, the clipboard stays alone, but the receiver can then only type characters in the Latin-1 range directly |
| Bluetooth adapter | If the computer has several Bluetooth adapters, choose the one to use under Bluetooth adapter |
| When it will not connect | The Remote Keyboard keyboard has to be on screen on the iPhone before the receiver connects. First check whether the first status line in the tray menu says Receiving stopped (已停止接收) or Not authorized (電腦未授權) |

When it works, the status cell of the iPhone keyboard shows this computer's name and Connected (已連接).

## 7. Optional: shorten the connection interval for a smoother trackpad

By default Linux uses a longer Bluetooth connection interval, so the trackpad can feel laggy. The two commands below shorten the connection interval of one Bluetooth adapter to 7.5 to 15 milliseconds. This is optional and needs root. The receiver never runs it for you, so you decide whether to do it.

First find the name of the Bluetooth adapter the receiver uses, such as `hci0` or `hci1` (run `ls /sys/class/bluetooth` to list them), and replace `hciN` below with it:

```bash
echo 6 | sudo tee /sys/kernel/debug/bluetooth/hciN/conn_min_interval
echo 12 | sudo tee /sys/kernel/debug/bluetooth/hciN/conn_max_interval
```

| Item | Description |
|---|---|
| What it affects | Only the adapter you name. It does not change `/etc/bluetooth/main.conf` and does not restart `bluetoothd` |
| Reboot | It resets when you reboot, so run it again after a restart |
| Values | The unit is 1.25 milliseconds, so 6 and 12 mean 7.5 and 15 milliseconds |

After this, the receiver is ready to pair with your iPhone.

Next chapter: [05 Pairing](05-pairing.md)
