# 01 Before you start

This chapter explains what to prepare before installing, the limits of a free Apple Account, the safety rules, and the whole installation process.

## What you need

| Item | Details |
|---|---|
| iPhone | iOS 18 or later, with a screen lock passcode set |
| Mac | macOS 15 or later, Apple silicon |
| USB cable | Connects the iPhone to the Mac. Needed only for the first SideStore install |
| Wi-Fi | The iPhone and the Mac are both online. Cellular data does not work when you install or refresh the iPhone app |
| Apple Account | Your own free Apple Account. You can also create a separate one just for sideloading |
| Files from the developer | One IPA file (the iPhone app) and one zip file (the Mac Receiver), each with its SHA-256 value |

SideStore and LocalDevVPN are third-party tools. They are not Apple services and not products of this project. The first install can take some time to troubleshoot, so back up your iPhone before you start.

## Limits of a free Apple Account

| Limit | Details |
|---|---|
| Validity | An app signed with a free account is valid for only 7 days. Refresh it before it expires |
| Number of apps | At most 3 sideloaded apps at the same time. SideStore itself takes 1, so only 2 slots are left |
| App IDs | At most 10 can be registered every 7 days, and you cannot delete them by hand |
| This app's usage | The main app and the keyboard each use 1 App ID, so every fresh install uses 2 |
| Network | Installing and refreshing both need Wi-Fi plus LocalDevVPN |

The "3 sideloaded apps" include any app you installed on this iPhone yourself with Xcode. Anything signed by the same Apple Account counts. When the slots are full, iOS refuses to install and shows the message "This app cannot be installed because its integrity could not be verified."

## Safety rules

| Rule | Details |
|---|---|
| Never hand over account details | Do not give your Apple Account password or two-factor code to anyone, including the developer |
| Never send files | When you report a problem, do not send the Pairing File, certificate files or pairing keys |
| Never type passwords | Do not use this keyboard to type passwords. Ordinary password fields are blocked, but some terminal password prompts, fields inside remote desktop sessions and similar cases cannot be detected |
| Install only from trusted sources | Install only the IPA and zip provided by the developer, and check the SHA-256 before installing |

## The whole process

| Step | Where | Chapter |
|---|---|---|
| 1 | iPhone and Mac: install LocalDevVPN and iloader, then use iloader to put SideStore on the iPhone | [02 Install SideStore](02-install-sidestore.md) |
| 2 | iPhone: trust the developer, turn on Developer Mode, sign in to SideStore, finish the first refresh | [02 Install SideStore](02-install-sidestore.md) |
| 3 | iPhone: import the IPA with SideStore, add the keyboard, allow Full Access and Bluetooth | [03 Install the iPhone app](03-install-iphone-app.md) |
| 4 | Mac: install the Mac Receiver, allow Bluetooth and Accessibility | [04 Install the Mac Receiver](04-install-mac-receiver.md) |
| 5 | iPhone and Mac: pair | [05 Pairing](05-pairing.md) |
| 6 | iPhone: start using it | [06 Using the keyboard](06-using-the-keyboard.md), [07 Trackpad](07-trackpad.md) |

Do not install any other app until the first SideStore refresh is finished.

Next chapter: [02 Install SideStore](02-install-sidestore.md)
