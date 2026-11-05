# Remote Keyboard

[中文](README.md) | English

Remote Keyboard turns your iPhone into a Bluetooth keyboard for your Mac. Switch to the Remote Keyboard keyboard on your iPhone, and what you type is encrypted, sent over Bluetooth, and entered into whatever text field has the cursor on your Mac. The keyboard also has a trackpad mode, so you can use your iPhone to move the Mac's pointer, click and scroll.

This is v0.1.0 Alpha. It is installed with SideStore, and it is not an App Store release.

The app and the install tutorial video are in Traditional Chinese. The whole user manual is in English, with the original Chinese screenshots. The app shows Chinese labels, so every label, message and setting name in this README and the manual is written in English first, with the Chinese as it appears on screen in parentheses after it. If this translation and the Chinese README differ, the Chinese README applies.

## Features

- Remote (遠端) mode: type on your iPhone, and the text appears in the field that is active on your Mac.
- Local (本機) mode: the same keyboard also types straight into apps on your iPhone.
- Live and draft: Live (即時) mode sends every key as you press it. Draft (草稿) mode lets you edit on the keyboard first, and sends everything at once when you press Send (傳送).
- Input methods: English, symbols, Chinese handwriting and Quick (速成), a simplified form of Cangjie.
- Trackpad (觸控板): move, click, double-click, right-click, drag and scroll.
- First-time guide and tutorial: the first time you open the app, a four-page introduction appears, which you can skip. After that, open Tutorial (使用教學) in the app. The panel in the Mac menu bar also has Tutorial (使用教學).
- Password protection: fields that the system marks as password fields, Secure Input and the Mac's lock screen receive no text. For other cases, see "Privacy and security" below.

## Requirements

| Item | Requirement |
|---|---|
| iPhone | iOS 18 or later |
| Mac | macOS 15 or later, Apple silicon |
| Connection | Bluetooth. Wi-Fi is needed to install and refresh the iPhone app |
| Apple Account | Your own free Apple Account. No paid developer program is needed |
| During installation | A USB cable to connect the iPhone and the Mac |

## How to get it

| Item | Details |
|---|---|
| iPhone app | Install the developer's IPA with SideStore. It is signed with your own free Apple Account |
| Mac Receiver | A zip file from the developer. Unzip it and move the app into the Applications folder |
| Notarization | Mac Receiver is not notarized by Apple. The first time you open it, you have to allow it manually in System Settings |
| Validity | An app signed with a free account is valid for 7 days only. Refresh it before it expires |
| App limit | A free account can have at most 3 sideloaded apps at a time, and SideStore uses 1 of them |

## Install tutorial video

The [Remote Keyboard install tutorial](https://youtu.be/dGhEuzRpAEg) (about 5 and a half minutes, in Traditional Chinese) takes you from scratch to typing your first character. The video matches v0.1.0 Alpha 1. Where it differs from the manual, follow the manual.

## User manual

On a first install, read the chapters in order. The whole manual is in English, with the original Chinese screenshots.

| Chapter | Contents |
|---|---|
| [Manual home](docs/manual/en/README.md) | List of chapters and suggested reading order |
| [01 Before you start](docs/manual/en/01-before-you-start.md) | What to prepare, the limits of a free account, safety rules, the overall process |
| [02 Install SideStore](docs/manual/en/02-install-sidestore.md) | LocalDevVPN, iloader, trusting the developer, Developer Mode, signing in and the first refresh |
| [03 Install the iPhone app](docs/manual/en/03-install-iphone-app.md) | Verifying and importing the IPA, adding the keyboard, allowing Full Access and Bluetooth |
| [04 Install Mac Receiver](docs/manual/en/04-install-mac-receiver.md) | Download, unzip, first launch, Bluetooth and Accessibility permissions, the menu bar panel |
| [05 Pairing](docs/manual/en/05-pairing.md) | Pairing the iPhone and the Mac with a six-digit pairing code |
| [06 Using the keyboard](docs/manual/en/06-using-the-keyboard.md) | Local and remote, live and draft, handwriting, Quick (速成), the keyboard's status line, how passwords are handled |
| [07 Trackpad](docs/manual/en/07-trackpad.md) | Trackpad gestures and settings |
| [08 App settings](docs/manual/en/08-app-settings.md) | Main screen, Keyboard feedback (鍵盤回饋), Trackpad (觸控板), Chinese input and handwriting (中文輸入與手寫), Dictation (聽寫), Tutorial (使用教學), legal notices |
| [09 Refresh and update](docs/manual/en/09-refresh-and-update.md) | The 7-day refresh, updating the IPA and Mac Receiver, when data can be lost |
| [10 Troubleshooting](docs/manual/en/10-troubleshooting.md) | Common problems with installing, pairing and typing |

## Privacy and security

- Your text goes only to the Mac you paired, encrypted over Bluetooth. It is never sent to the developer or to any server. The app's logs record only the type of event, the length, the time and the result, never the text itself.
- The keyboard needs Allow Full Access. Mac Receiver needs the Bluetooth and Accessibility permissions. What each one is used for is written in the privacy note.
- Handwriting recognition uses Google ML Kit. When you use handwriting, ML Kit connects to Google to download its model and sends usage and performance data.
- Do not use this keyboard to enter passwords. Some password prompts cannot be detected, for example in some terminals or in fields inside a remote desktop window. The text is still sent there.
- Never give your Apple Account password or two-factor authentication codes to anyone, including the developer.

For details, see the [privacy note](docs/distribution/privacy-note.md) and the [risk note](docs/distribution/risk-note.md), both in Traditional Chinese.

## For developers

For how to build, the project status and the release scripts, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Legal notice

This software is a test version provided as is, without any express or implied warranty. To the maximum extent permitted by law, the developer is not liable for any damage caused by using or being unable to use this software, including lost data, wrong input, or input into the wrong window. Do not use it where errors cannot be tolerated, such as medical use or financial transactions.

© 2026 AnsonHui6040. All rights reserved. You may not modify or redistribute this software or its source code without permission. Third-party components are provided under their own licenses.

Apple, iPhone, Mac, Google, ML Kit and SideStore belong to their respective owners. This project is not affiliated with or endorsed by any of these companies or projects.
