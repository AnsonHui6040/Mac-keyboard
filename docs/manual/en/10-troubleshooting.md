# 10 Troubleshooting

Find the situation that matches yours, then follow the steps in the last column. The problems are in four groups: install and refresh, keyboard and app installation, Mac Receiver, and keyboard connection and typing.

Messages shown by Remote Keyboard and Mac Receiver appear in Chinese on your screen, so this chapter keeps them in Chinese, with the English meaning in brackets after each one. Match the Chinese text to what you see.

When you report a problem, include the full error code and your iOS version. Do not send passwords, Apple Account details, two-factor codes, pairing files or certificates.

## Install and refresh

| Problem | How to check | What to do |
|---|---|---|
| You cannot sign in to your Apple Account, or the screen freezes | SideStore freezes during sign-in or shows an error code | Check that the capitalization of your account name is correct. If you see -80045, follow the Anisette setup in [02 Install SideStore](02-install-sidestore.md). In SideStore settings, switch to a different Anisette server. If it still fails, use a separate Apple Account just for this |
| You do not receive the two-factor code | SideStore asks for a code but none arrives | iOS 18.1 or later: turn off Wi-Fi and cellular data first, go to Settings > your name > Sign-In & Security > Get Verification Code, then enter the code in SideStore |
| LocalDevVPN will not connect, or you see (1414) or (27) | Check that both Wi-Fi and LocalDevVPN show as connected | Turn off DNS-blocking tools and any other VPN. Reopen SideStore and LocalDevVPN. If it still fails, replace the pairing file |
| The pairing file is no longer valid, and you see (1006) or (1414) | Both connections are fine but it still fails | On the Mac, use iloader: choose Delete Stored Pairing, pick your device, tap Trust on the iPhone, then go to Manage Pairing File and click Place next to SideStore. It is done only when you see a success message |
| The IPA is the wrong format, and you see (1007) | Compare the SHA-256 using `shasum -a 256` | Download the IPA again. If the value is still different, report it to the developer |
| Signing fails, and you see ldid, (3007), (3008) or (3017) | Write down the full error code | Refresh again in SideStore and retry. If it still fails, report the error code to the developer. Do not send certificates |
| The app will not open after installing | The app icon closes as soon as you tap it | First check that you trusted the developer and turned on Developer Mode (see [02 Install SideStore](02-install-sidestore.md)). Then check that the app has not expired, and refresh. Report your iOS version to the developer |
| You are over the App ID limit, and you see (1009) or (3013) | Check the remaining App IDs in My Apps | App IDs cannot be deleted by hand. You have to wait until the oldest one reaches 7 days. Do not delete and reinstall repeatedly |
| More than 3 apps | The install says the limit is reached, or iOS says "This app cannot be installed because its integrity could not be verified." | A free account allows at most 3 sideloaded apps at a time, and SideStore uses 1 of them. Turn off or remove other apps signed with the same Apple Account, including apps you installed yourself with Xcode |
| The app has expired | Tapping the icon does nothing | Connect to Wi-Fi and LocalDevVPN, then refresh. Do not delete the app |
| Data is gone after an update | Pairing or settings have disappeared | Check whether you changed accounts or deleted the old version. Pair again, and report what happened |
| iOS 26.4 or later, and Refresh shows (27) | The Stable version cannot refresh | Report your iOS version to the developer. SideStore's official documentation says you may need to switch to the nightly version |

Official resources: [Prerequisites](https://docs.sidestore.io/docs/installation/prerequisites), [Install steps](https://docs.sidestore.io/docs/installation/install), [FAQ](https://docs.sidestore.io/docs/faq), [Troubleshooting](https://docs.sidestore.io/docs/troubleshooting).

## Keyboard and app installation

| Problem | How to check | What to do |
|---|---|---|
| Remote Keyboard is not in the keyboard list | Go to Settings > General > Keyboard > Keyboards > Add New Keyboard and look | The extension may have been removed during installation. Install the IPA again, and for the extension choose "Keep App Extensions (Register App ID for Each Extension)" |
| Pairing does not work, or settings are not shared | The app shows not paired, or the keyboard cannot read the settings | Check that Allow Full Access is turned on. Report it to the developer, because this is one of the things being tested |
| The handwriting page cannot recognize writing | The handwriting page shows no candidate characters, or the Chinese page turns into Quick | In the app, open 「中文輸入與手寫」 (Chinese Input and Handwriting) and check that the handwriting model status is 「已下載」 (Downloaded). Also check that Allow Full Access is turned on |

## Mac Receiver

| Problem | How to check | What to do |
|---|---|---|
| It is blocked when you open it | A message says Apple cannot verify the app | Click Done, go to System Settings > Privacy & Security, and in the Security section click Open Anyway. For the steps, see [04 Install the Mac Receiver](04-install-mac-receiver.md) |
| The panel shows 「尚未授權輔助使用，無法輸入文字」 (Accessibility is not authorized, cannot type text) | Red text at the top of the panel | Go to System Settings > Privacy & Security > Accessibility and turn on Remote Keyboard Receiver. If it is not in the list, click "+" to add it. If the switch is already on and the message still shows, remove it and add it again |
| The panel shows red text about Bluetooth | Red text about Bluetooth at the top of the panel | Turn on Bluetooth on the Mac. Or click 「打開藍牙設定」 (Open Bluetooth Settings) and turn on the switch for Remote Keyboard Receiver |
| Accessibility is asked for again after an update | The panel shows 「尚未授權輔助使用，無法輸入文字」 (Accessibility is not authorized, cannot type text) | This is normal. You have to allow it once more after an update. Your pairing is kept |

## Keyboard connection and typing

| Problem | How to check | What to do |
|---|---|---|
| The keyboard stays at 「未連接」 (Not connected) | The status line is red and says not connected, and the Trackpad key is gray | First click 「開始接收」 (Start receiving) in the Mac panel, or click a text field on the Mac. The Receiver stops receiving after 30 minutes of inactivity. If it still does not work, close any browser tab or other app that is stuck on a password field, because it may have secure input turned on. If that does not help, hide the keyboard and bring it up again, or quit the Receiver and reopen it |
| The keyboard shows 「手寫模型匯入失敗」 (Handwriting model import failed) | In the app, under 「中文輸入與手寫」 (Chinese Input and Handwriting) | Under 「手寫模型」 (Handwriting model) in 「中文輸入與手寫」, tap 「刪除手寫模型」 (Delete handwriting model), then tap 「下載手寫模型」 (Download handwriting model) to download it again, then go back to the keyboard |
| The app's main screen shows 「連線有問題」 (Connection problem) | The first line under 「設定進度」 (Setup progress) once it is expanded | Tap that line and follow the screen. It disappears by itself the next time the keyboard connects |
| The keyboard shows 「配對驗證失敗」 (Pairing verification failed) | The pairing status in the Mac Receiver panel | Pair again on both devices: click 「配對新 iPhone」 (Pair new iPhone) on the Mac, tap 「配對 Mac」 (Pair Mac) on the iPhone, check the pairing code, click or tap 「確認」 (Confirm) on both, then finish with 「完成」 (Done). See [05 Pairing](05-pairing.md) |
| The keyboard shows 「尚未配對」 (Not paired) | The status line is red and says not paired | Pair by following [05 Pairing](05-pairing.md) |
| 「密碼不能輸入」 (Password entry blocked) shows in an ordinary text field | The Mac cursor is clearly in an ordinary text field | Another app has secure input turned on. Turn off Secure Keyboard Entry in Terminal, close any browser tab or other app that is stuck on a password field, then click a text field on the Mac |
| It shows 「Mac 沒有輸入欄位，未輸入」 (The Mac has no text field, nothing was entered) | A red message appears after you type | Click the text field you want to type in on the Mac, then type again |
| It shows 「Mac 未授權輔助使用」 (The Mac has not allowed Accessibility) | The status line is red | Allow Accessibility on the Mac, see [04 Install the Mac Receiver](04-install-mac-receiver.md) |
| It shows 「N 個按鍵未確認是否送達」 (N keys not confirmed as delivered) | It appears after the connection drops | Check the text on the Mac. Add anything that is missing and delete anything that was typed twice |
| The trackpad shows 「Mac 未允許觸控板控制」 (The Mac has not allowed trackpad control) | Gray text in the middle of the trackpad page | Select 「允許觸控板控制」 (Allow trackpad control) in the Mac panel |
| The trackpad key is gray | 「觸控板」 (Trackpad) at the top cannot be tapped | The keyboard is not connected to the Mac yet, or is not paired. Fix the problem shown in the status line first |

Back to the manual: [Manual home](README.md)
