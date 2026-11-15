# 04b Install the Windows receiver

The Windows receiver is the receiving program you install on a Windows computer. It types the text and trackpad actions sent from your iPhone into the window that is in front on the computer. It has no main window. It only shows an icon in the notification area at the right end of the taskbar.

This chapter is for Windows computers only. For a Mac, see [04 Install the Mac Receiver](04-install-mac-receiver.md). For Ubuntu, see [04c Install the Linux receiver](04c-install-linux-receiver.md).

## Requirements

| Item | Requirement |
|---|---|
| Operating system | Windows 11, x64 |
| Bluetooth | The computer has Bluetooth (Bluetooth LE support) and it is turned on |
| Permissions | A standard user account is enough. Installing does not need an administrator |
| Network | The receiver does not need a network while it runs. Text travels over Bluetooth only |

This version has no digital signature, so Windows shows a SmartScreen warning the first time you run it, and you need to allow it by hand.

## 1. Download, verify, and install

1. From the GitHub Release, get the installer `RemoteKeyboard-Setup-0.2.0-alpha.1.exe` and `SHA256SUMS.txt` from the same page.
2. Open PowerShell and run the command below. Replace the file path with the location of your installer.

```powershell
Get-FileHash .\RemoteKeyboard-Setup-0.2.0-alpha.1.exe -Algorithm SHA256
```

3. Compare the hash in the output with the value for that file in `SHA256SUMS.txt`. The two must be exactly the same. If they differ, download the file again and do not install.
4. Double-click the installer and follow the screens.

The installer puts the receiver in `%LOCALAPPDATA%\Programs\RemoteKeyboard` and does not ask for administrator permission. The installer option Start when I sign in (開機時自動啟動) is checked by default. If you do not want the receiver to start after you sign in, clear it during installation. You can also change it later with Start at sign-in (開機自動啟動) in the tray menu. The last page lets you start the receiver right away.

## 2. Run it for the first time

The first time you run the installer, Windows shows "Windows protected your PC".

1. Click More info (其他資訊).
2. Click Run anyway (仍要執行), which appears below.

When it works, the installer opens, and after it finishes the receiver starts and a Remote Keyboard icon appears at the right end of the taskbar. If the icon is hidden under the "^" button, click "^" and drag the icon onto the taskbar. It stays visible from then on.

## 3. Turn on Bluetooth

1. Open Settings > Bluetooth & devices and check that Bluetooth is on.
2. If the tray icon's tooltip says "Bluetooth is off, scanning is not running", Bluetooth is off. Turn it on, and the receiver starts scanning again by itself.

The receiver connects to your iPhone over Bluetooth. You do not need to add the iPhone to the Windows Bluetooth list first.

When it works, the tray icon's tooltip says "Receiving, waiting for a phone".

## 4. The tray menu

Click the Remote Keyboard icon in the tray to open the menu. The menu language follows the Windows display language. It shows Chinese when Windows uses Chinese and English otherwise. The table gives both.

| Item (Chinese) | Item (English) | Description |
|---|---|---|
| First line (status): 接收中，等待手機連線; 已連線：phone name; 配對中，請在手機上開啟配對畫面; 已停止接收 | Receiving, waiting for a phone; Connected: phone name; Pairing: open the pairing screen on the phone; Receiving stopped | The current state. You cannot click this line |
| 停止接收, 開始接收 | Stop receiving, Start receiving | Stop receiving ends the current connection and stops scanning, until you choose Start receiving or restart the receiver. The stopped state is not saved, so every start receives |
| 電腦名稱　改名… | Computer name　Rename… | This line starts with the current computer name, which is "Windows" by default. Clicking it opens an input box to change the name this computer shows on the phone, 32 bytes at most. After renaming, a paired iPhone has to pair again to show the new name |
| 配對新手機 | Pair a new phone | Starts pairing, see [05 Pairing](05-pairing.md). You cannot click it while receiving is stopped |
| 已配對的手機 | Paired phones | Lists the paired phones. Pick a phone, then click Delete (刪除) to remove its pairing. With no phone, the list shows 尚未配對任何手機 (No phone paired yet). You can pair up to 8 |
| 允許觸控板控制 | Allow trackpad control | When checked, the iPhone can control the pointer, see [07 Trackpad](07-trackpad.md) |
| 開機自動啟動 | Start at sign-in | When checked, the receiver starts after you sign in to Windows |
| 匯出診斷資料 | Export diagnostics | Writes a zip file of diagnostics to the desktop. For its contents see [Receiver troubleshooting](../../troubleshooting-receiver.md) (in Chinese) |
| 結束 | Quit | Closes the receiver, and the iPhone can no longer reach this computer |

When the receiver needs you to act, the icon's tooltip shows one of these messages, in Chinese or English by display language:

| Tooltip | What to do |
|---|---|
| 這支手機需要重新配對 (This phone needs to be paired again) | Pair again on both the phone and the computer |
| 請更新 iPhone App (Please update the iPhone app) | Update the iPhone app to the same version |
| 配對失敗，請再試一次 (Pairing failed, please try again) | Choose Pair a new phone again |
| 已配對 8 支手機，請先刪除一支 (Eight phones are paired already, delete one first) | Delete a phone you no longer use from Paired phones |
| 無法儲存配對資料 (Could not store the pairing) | Pair again. If it still fails, export diagnostics |
| 藍牙未開啟，無法掃描 (Bluetooth is off, scanning is not running) | Turn on Bluetooth in Windows |
| 設定檔無法讀取，也無法備份；這次的設定不會儲存，原檔保持不動 (The settings file cannot be read or backed up; this run's settings are not saved and the file is left alone) | Export diagnostics, see [Receiver troubleshooting](../../troubleshooting-receiver.md) (in Chinese) |

## 5. Upgrade and uninstall

| Situation | What to do |
|---|---|
| Upgrade | Run the new installer. It closes the running receiver first and starts it again when it finishes. Settings and pairing are kept |
| Upgrading from v0.1 | This version uses protocol v4, which does not work with v0.1. Update the iPhone app and the Mac Receiver too, and pair every computer again |
| Uninstall | Open Settings > Apps, find Remote Keyboard and choose Uninstall. The start-at-sign-in entry is removed with it |

Settings are in `%APPDATA%\RemoteKeyboard` and logs are in `%LOCALAPPDATA%\RemoteKeyboard\logs`. Uninstalling does not delete either place, so you do not need to pair again after reinstalling. To remove everything, delete both folders yourself.

## 6. Good to know

| Item | Description |
|---|---|
| No focus safety gate | The Windows receiver does not check what kind of field is active. Text goes to the window that is in front, password fields included. Before you type, make sure the cursor is in the field you want, and do not use this keyboard for passwords |
| Administrator windows | Windows that run as administrator, UAC prompts and the lock screen do not receive input. The receiver itself does not run as administrator, so open such a window with normal permissions instead |
| When it will not connect | The Remote Keyboard keyboard has to be on screen on the iPhone before the receiver connects. First check whether the first status line in the tray menu says Receiving stopped (已停止接收) |

When it works, the status cell of the iPhone keyboard shows this computer's name and Connected (已連接).

After this, the receiver is ready to pair with your iPhone.

Next chapter: [05 Pairing](05-pairing.md)
