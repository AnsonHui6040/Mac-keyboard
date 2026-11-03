# SideStore 可行性評估

檢查日期：2026-11-02。基礎：main `1415158`。SideStore 依據：官方文件，以及 GitHub `SideStore/SideStore` develop 分支與 `SideStore/SideSign` main 分支的原始碼。

**結論：可以產出 IPA，但實機是否可用尚未驗證。**

## 專案

| 項目 | 結果 |
|---|---|
| 環境 | macOS 27.2、Xcode 27.2、Swift 6.4.2、iPhoneOS SDK 27.2 |
| 專案形式 | XcodeGen `project.yml` 產生 xcodeproj，CocoaPods 產生 xcworkspace，加本地 Swift Package |
| 框架 | UIKit、SwiftUI、CoreBluetooth、Google ML Kit Digital Ink（靜態） |
| iOS Target | `RemoteKeyboardApp`（`com.ansonhui.remotekeyboard`）、`RemoteKeyboardExtension`（`.keyboard`） |
| 最低版本 | iOS 18.0 |
| 版本 | 0.1.0，build 1 |
| 既有流程 | 沒有 CI，只有 `scripts/install-mac-receiver.sh` |
| 憑證 | 只有 Apple Development，沒有 Distribution |

## 能力逐項評估

| 能力 | 專案使用 | 免費帳號重新簽署後 | 影響 |
|---|---|---|---|
| App Groups | 有 | 可註冊，但名稱改為 `<原名>.<TEAMID>` | 必須在執行時取得實際名稱 |
| Keychain Sharing | 以 App Group 當存取群組 | 依賴上一項；實機未驗證 | 配對金鑰存放的關鍵 |
| App Extension | 鍵盤 | 可保留，多用 1 個 App ID | 測試者不可選移除 |
| Full Access | `RequestsOpenAccess` | 屬於 Info.plist，不受簽署影響 | 測試者手動開啟 |
| 藍牙 | Info.plist 用途說明 | 不需特殊 entitlement | 實機未驗證 |
| Push、Associated Domains、iCloud、Sign in with Apple、Background Modes | 沒有 | 不適用 | 沒有影響 |

## 發現的阻礙與處理

1. **App Group 名稱寫死（已修改）**：`AppGroup.identifier` 原本固定，重新簽署後 Keychain 存取會失敗，主 App 和鍵盤也無法共用資料。改為執行時從 `embedded.mobileprovision` 讀取，找不到就用原名，所以現有簽署方式的結果不變。
2. **未簽署的執行檔沒有 entitlements（已處理）**：SideStore 從執行檔簽章讀取要申請的 entitlements，所以 `CODE_SIGNING_ALLOWED=NO` 建置後，打包腳本會用 ad-hoc 簽署寫入。檔名的 `unsigned` 指沒有發佈簽章。

## 限制

| 項目 | 內容 | 依據 |
|---|---|---|
| App 數量 | 免費帳號最多 3 個，含 SideStore | 官方 FAQ |
| App ID | 每 7 天 10 個；本 App 每次全新註冊用 2 個 | 官方 FAQ、原始碼 `requiredAppIDs` |
| Extension 是否佔 3 個名額 | 文件沒有說明，要實機確認 | 未驗證 |
| iOS 26.4 以上 | 錯誤 (27) 時官方要求改用 nightly；開發機是 iOS 27 系列（`24A446`） | 官方錯誤碼文件 |
| 換 Apple 帳號 | TEAMID 改變，App Group 也改變，配對和設定會遺失 | 由原始碼推論 |
