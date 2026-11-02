# 01 開始之前

本章說明安裝前需要準備的東西、免費 Apple 帳號的限制、安全原則，以及整個安裝流程。

## 需要準備的東西

| 項目 | 說明 |
|---|---|
| iPhone | iOS 18 以上，已設定螢幕鎖定密碼 |
| Mac | macOS 15 以上，Apple 晶片 |
| USB 線 | 連接 iPhone 與 Mac，只有首次安裝 SideStore 時需要 |
| Wi-Fi | iPhone 與 Mac 連上網路。安裝與續簽 iPhone App 時，行動網路不能使用 |
| Apple 帳號 | 你自己的免費 Apple 帳號，也可以另外申請一個專門用來側載的帳號 |
| 開發者提供的檔案 | 一個 IPA 檔（iPhone App）與一個 zip 檔（Mac Receiver），以及各自的 SHA-256 值 |

SideStore 與 LocalDevVPN 是第三方工具，不是 Apple 的服務，也不是本專案的產品。首次安裝可能要花一些時間排解問題，安裝前請先備份 iPhone。

## 免費 Apple 帳號的限制

| 限制 | 說明 |
|---|---|
| 有效期 | 免費帳號簽署的 App 只有 7 天有效，到期前要續簽 |
| App 數量 | 同時最多 3 個側載 App，SideStore 自己佔 1 個，所以只剩 2 個名額 |
| App ID | 每 7 天最多註冊 10 個，無法手動刪除 |
| 本 App 的用量 | 主 App 與鍵盤各佔 1 個 App ID，每次全新安裝用掉 2 個 |
| 網路 | 安裝與續簽都需要 Wi-Fi 加上 LocalDevVPN |

「3 個側載 App」包含你自己用 Xcode 裝到這支 iPhone 的 App，只要是同一個 Apple 帳號簽署的都算。名額已滿時，iOS 會拒絕安裝，訊息為無法驗證其完整性。

## 安全原則

| 原則 | 說明 |
|---|---|
| 不交出帳號資料 | 不要把 Apple 帳號密碼或雙重驗證碼交給任何人，包括開發者 |
| 不傳送檔案 | 回報問題時，不要傳送配對檔（Pairing File）、憑證檔或配對金鑰 |
| 不輸入密碼 | 不要用這個鍵盤輸入密碼。一般密碼欄會被擋下，但部分終端機的密碼提示、遠端桌面內的欄位等偵測不到 |
| 只從可信來源安裝 | 只安裝開發者提供的 IPA 與 zip，安裝前先核對 SHA-256 |

## 整體流程

| 步驟 | 在哪裡做 | 章節 |
|---|---|---|
| 1 | iPhone 與 Mac：安裝 LocalDevVPN 與 iloader，用 iloader 把 SideStore 裝進 iPhone | [02 安裝 SideStore](02-install-sidestore.md) |
| 2 | iPhone：信任開發者、開啟開發者模式、登入 SideStore、完成第一次續簽 | [02 安裝 SideStore](02-install-sidestore.md) |
| 3 | iPhone：用 SideStore 匯入 IPA，加入鍵盤，允許完整取用與藍牙 | [03 安裝 iPhone App](03-install-iphone-app.md) |
| 4 | Mac：安裝 Mac Receiver，允許藍牙與輔助使用 | [04 安裝 Mac Receiver](04-install-mac-receiver.md) |
| 5 | iPhone 與 Mac：配對 | [05 配對](05-pairing.md) |
| 6 | iPhone：開始使用 | [06 使用鍵盤](06-using-the-keyboard.md)、[07 觸控板](07-trackpad.md) |

完成 SideStore 的第一次續簽之前，不要安裝其他 App。

下一章：[02 安裝 SideStore](02-install-sidestore.md)
