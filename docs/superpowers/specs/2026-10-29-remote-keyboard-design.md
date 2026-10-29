# iPhone → Mac Remote Keyboard — 設計規格（待批准）

**版本**：v1.1 | **日期**：2026-10-29 | **狀態**：APPROVED（使用者於 2026-10-29 批准 v1.1）；非已實作產品

**v1.1 變更**：納入 2026-10-29 設計審問的決定，涵蓋 Remote 模式行為、草稿列、配對備案、Mac 輸入法、語音流程、BLE 備案與開發環境。決定總表見 §12。

## 1. 產品意圖

在 Mac 使用者點選可編輯文字框之後，Mac Receiver 顯示「準備接收」。使用者於 iPhone 任一**容許第三方鍵盤**的 App 打開文字欄位、切換到 Remote Keyboard，即可透過自製鍵盤將英文、數字／符號或繁體中文手寫的已提交文字遠端送往 Mac 的**目前有效焦點**。iPhone 不需每次打開主 App。此流程不會令 iPhone 自動從鎖屏／其他 App 彈出鍵盤。

## 2. 已定義功能

- iOS 第三方 Keyboard Extension：英文 QWERTY，Shift／Caps Lock／長按、刪除、Space、Return；數字 `123` 和特殊符號 `#+=` 兩層；繁體中文手寫頁、候選字；系統 globe／語言切換；語音輸入入口。
- 英文外觀及使用習慣參考 Apple 原生鍵盤，但不複製 Apple 私有資產、預測字詞引擎或私有系統鍵盤 View。關鍵動作應原生風格而非假裝能重用 Apple keyboard。
- Mac 具 menu-bar Receiver、首次配對、連線狀態、焦點狀態、接收暫停／解除配對。
- 預設 Local Mode：iPhone 本地正常輸入，毋須 Full Access；Remote Mode 必須由使用者明確啟用並授權，且有持續可見狀態；不能暗地將其他 App 的文字複製到 Mac。
- Remote Mode 行為：按鍵只送往 Mac，iPhone 目前欄位不出字；鍵盤收起或切換 App 後重新開啟，沿用上次模式；鍵盤頂部常駐狀態列顯示「Mac → 目前 App 名稱」，點一下即切回 Local。
- 未就緒時的草稿列：Remote Mode 開啟但 BLE 未連線、或 Mac 沒有可編輯焦點時，按鍵寫入鍵盤頂部草稿列，「傳送」為灰色不可按。就緒後「傳送」轉為可用，由使用者手動送出，不自動送出；送出後恢復逐字即時傳送。草稿送出時使用當下的 `focusEpoch`。草稿只存在記憶體，Extension 被終止或切換 App 即消失，不寫入磁碟。
- 優先 BLE 自訂 GATT：Mac Peripheral/Server，iPhone Keyboard Extension Central/Client；Mac 使用 AX 聚焦與 CGEvent Unicode 注入；純 Wi-Fi fallback 留到核心 BLE 路徑驗證後才評估。**不以 BLE HID 作主路徑**。
- iPhone 主 App：安裝教學、Full Access 提示、初次配對、管理配對 Mac、顯示診斷及語音方案說明。主 App **不假設**能長期代 Extension 維持 BLE 連線。

## 3. 最重要的平台限制

1. Apple App Review 4.4.1：必須能在未開 Full Access 時正常作為鍵盤；須提供切換下一個鍵盤的控制；不能自行啟動 Settings 以外其他 App；鍵盤活動只能收集作合法鍵盤功能用途。
2. Apple `hasDictationKey` 是表示鍵盤有沒有自己的語音按鍵，不是一個可供 Extension 取得系統 Dictation 完整文字流的公開 callback；語音由獨立實機 Gate 驗證；失敗時不得以非公開 API／越權跳 App 方案作正式產品主線。
3. `UIInputViewController` 在獨立 Extension process 運作；會被殺死或重新建立，不能依賴常駐單例或無限制記憶體；部分 secure/password、phone keypad、禁止第三方鍵盤的 App 會回到 Apple 系統鍵盤。
4. Mac Accessibility 只能證明有可用的焦點與可發送事件，不等同文字已呈現在任意第三方 App；輸入框切換／睡眠／桌面切換需重新驗證。
5. BLE ACK 只能確認 Receiver 端協定狀態／注入動作，不保證目標軟體已經顯示文字。對無法觀察結果的 CGEvent，斷線重試可能出現語義不確定狀態；**不可宣稱任意 App 都具備端到端 exactly-once。**
6. 若 iPhone 用戶在其他 App 打開鍵盤，遠端模式只發送由本鍵盤**直接產生**並明確選擇發往 Mac 的事件；不收集 host App 既有文字或複製通用打字紀錄。
7. `PencilKit PKStrokeRecognizer` 支援與部署最低版本、繁體中文辨識語言及 Extension 記憶體佔用須實機查證；未通過則用 ML Kit Digital Ink `zh-Hani-TW` 或 `zh-Hani-HK` 評估回退。

## 4. 架構

```text
[iPhone host App: Notes, Safari, Messages...]
             │ iOS 揀選第三方鍵盤
             ▼
[Keyboard Extension, UIKit/UIInputViewController]
  ├─ Local mode (textDocumentProxy -> iPhone current field)
  └─ Remote mode (English / Symbols / Handwriting -> SemanticEvent queue)
             │ CoreBluetooth Central：scan/connect/write/notify
             ▼
[Mac Receiver CBPeripheralManager custom GATT service]
  ├─ Pairing + authentication, session/sequence, queue/ACK
  ├─ AX focus guard, remote-enabled status
  └─ CGEvent Unicode / limited AX fallback
             ▼
[Mac frontmost editable field: TextEdit/Word/Safari/VS Code]

[Host iOS App] --App Group settings/Keychain config--> [Keyboard Extension]
```

## 5. 協定、權限及事件

- Cross-platform Swift Package：`RemoteKeyboardCore`，定義 `KeyboardEvent`、`Handshake`、`Ack`、`ConnectionState`、二進位/JSON 編碼與 schema 版本；自訂 GATT UUID 於程式中產生並固定，不採用文獻中的示意 UUID。
- 事件：`TEXT(UTF-8 committed string)`、`BACKSPACE(1)`、`RETURN`、`MOVE_CURSOR`（非 MVP）、`PING`；每事件有 `sessionId`、`seq`、`focusEpoch`、`eventId`。握手要版本與 capability negotiation；驗證字節長度、chunk 重組、UTF-8 有效性及 framing。
- Mac AX 每次 commit 前查詢前台程序和 focused editable UI element；沒有焦點、失去權限、焦點世代更換時 fail closed；不把舊輸入重播至新 App。remote mode 有使用者明確開關，狀態標識清楚。
- 透過 BLE 加密權限及應用層 challenge-response/Keychain secret 雙重驗證；禁止僅以 device name/BLE identifier 認定已配對 Mac；敏感文字不寫入一般診斷 log。
- 配對路徑：首選由主 App 配對，經 App Group／Keychain sharing 交給 Extension。若 T01 實測 Personal Team 無法使用 App Group，改為在鍵盤內輸入 Mac 顯示的 6 位配對碼，配對秘密存於 Extension 自身的 Keychain，主 App 只負責教學與診斷。
- Mac 輸入法：注入前若目前輸入法不是 ABC，以 TIS API 切換至 ABC，注入後切回原輸入法。輸入法組字中的未完成文字可能因切換而被提交，此行為可接受。切換後再驗證一次，仍不是 ABC 則 fail closed 拒收。需測試切換未生效即注入、連續事件之間反覆切換的 race。
- `CGEventKeyboardSetUnicodeString` 單一事件有長度上限，Receiver 須自行切段注入；實際上限於 T04 實測後寫入本節。
- 連線路徑：同一 iCloud 的 iPhone 與 Mac 通常已有系統 LE 連線（T02 實測：第三方 App 對 Mac 廣播發起新連線不會完成）。Keyboard Extension 先以 `retrieveConnectedPeripherals(withServices:)` 接入已連線的 Mac，取不到才掃描。
- 先以 `writeWithResponse` 及 notify/indicate 的可驗證流程做 PoC；由實際 MTU/`maximumWriteValueLength` 分 chunk，勿寫死 20 bytes。
- 針對 ACK lost：Receiver 保留短期事件 ID 去重；若是否已發往目標 App 無法證明，回報 `AMBIGUOUS` 狀態，禁止無提示的跨焦點重播。

## 6. 語音的預定設計決策

- 目標流程：使用 iOS 系統的麥克風按鍵（`hasDictationKey = false`，由系統在鍵盤下方顯示）。聽寫文字由 iOS 直接寫入 host App 欄位，因此**文字會留在 iPhone 欄位**；Extension 觀察 `documentContextBeforeInput` 的變化計算差分，同步到草稿列與 Mac。Apple 修正詞語時，Mac 端以 `BACKSPACE × n` 加新文字對應。
- 首先測 `system dictation visible / actually commits to host App / extension sees textDidChange / extension can know exact diff / remote receives exact diff`，**每項需獨立記錄**。
- 若僅能見到按鈕或有限 context diff，不能宣稱語音支援 Mac 同步。T13 未通過時，改為主 App 手動語音頁：使用者自行開啟主 App，以 iPhone 麥克風辨識後經主 App 的 BLE 送往 Mac。不走自動跳 App hack。

## 7. 不做的事（v1.0）

- 不製作觸控板、鍵盤 HID 配對、Mac 無 Receiver 模式、通用鍵盤事件側錄、跨 App 靜默同步、遠端任意系統快捷鍵、雲端中繼、強制喚醒 iPhone 鍵盤。
- 不保證模仿 Apple 私有自動修正、滑動輸入、iOS 系統語音 API 的內部操作。

## 8. 接受標準／非功能需求

- 工程 PoC：在真 iPhone 的第三方 Keyboard Extension 按 `A`，Mac TextEdit 同一焦點顯示 `A`；Notes→Safari 跨 App 能重開 Extension 並送達 Mac；不開 Full Access 時 Local Mode 仍可打字。
- Transport release gate：100 次鍵盤重開/連線 >=99 成功；首次可用時間 P95 <=2 秒（awake/已配對/同房環境；記錄測試環境）；在控制式 TextEdit 測 10,000 事件，0 遺漏/0 重複/0 亂序；這些是**預設驗收目標**，未做實測。
- Unicode：英文、符號、繁體中文、emoji（含 ZWJ）、accent、Return/Delete 在 TextEdit 試驗可重現預期結果；Word/Safari/VS Code 支援為個別矩陣結果，不由 TextEdit 推導。
- 重要安全測試：未配對/未授權/沒有 Mac 文字焦點/焦點切換/鎖屏/secure field/藍牙關閉，絕不把文字偷偷送往新位置；原則上 fail closed。
- 語音：Gate 結果必須明文寫為 `PASS / FAIL / INCONCLUSIVE`；若 FAIL，不可把語音當成已交付功能。
- 軟件可分發：Xcode target build+test、真機證據、手動驗收、版本化文檔、隱私權限說明；App Store 上架另設獨立審查。

## 9. 技術方案比較

| 方案 | 優點 | 限制 | 決策 |
|---|---|---|---|
| Extension -> BLE GATT -> Mac Receiver | 離線、Unicode 語義文字、不依賴 HID；易控 ACK | Extension 生命周期與授權待實測 | **首選（PoC 後方確立）** |
| Extension -> LAN WebSocket -> Mac Receiver | 協定傳輸可靠、debug 簡單 | Full Access + local-network permission、網段限制 | T03/T05 證實 Extension 無法使用 BLE 後才做限時 PoC（Bonjour + TLS WebSocket）；校園 Wi-Fi 隔離裝置時改用 iPhone 個人熱點測試 |
| Main iOS App -> BLE/LAN | 易處理 Native TextInput、語音 | 不符合任何 App 中直接開鍵盤的目標 | 診斷與語音降級方案 |
| iPhone Bluetooth HID | Mac 免安裝 Receiver | 既有配對體驗差，Unicode/CJK 問題 | 不採納主線 |

## 10. 設計文件狀態

本設計 v1.1 已於 2026-10-29 獲使用者批准。未宣稱任何真機測試已通過。下一文件 `docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md` 是對應的執行計劃，須依 v1.1 修訂後才開始執行。

## 11. 核心證據鏈（Apple 官方）

- Custom Keyboard: https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- Open Access: https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- Text input: https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
- Dictation: https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey
- App Review 4.4.1: https://developer.apple.com/app-store/review/guidelines/
- BLE: https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices
- AX: https://developer.apple.com/documentation/applicationservices/axuielement_h
- Unicode injection: https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)
- Handwriting: https://developer.apple.com/documentation/pencilkit/recognizing-handwriting-and-converting-to-text
- ML Kit Digital Ink: https://developers.google.com/ml-kit/vision/digital-ink-recognition/ios

## 12. 設計決定總表（v1.1，2026-10-29）

| # | 範疇 | 決定 | 影響任務 |
|---|---|---|---|
| D1 | 受眾 | 自用與專題／比賽展示；M1–M4 只用開發簽名，App Store、TestFlight、Developer ID 公證留到 T16；App Review 4.4.1 規則照常遵守 | T16 |
| D2 | 簽名 | 免費 Personal Team；build 7 天到期需重裝；App Group 可用性於 T01 實測並記錄 | T01、T09 |
| D3 | 配對備案 | App Group 不可用時，鍵盤內輸入 6 位配對碼，秘密存於 Extension 自身 Keychain（§5） | T09 |
| D4 | Mac 輸入法 | 注入前自動切換至 ABC、注入後切回；接受組字中文字被提交；切換後驗證失敗則 fail closed（§5） | T04、T14 |
| D5 | Remote 行為 | 只送 Mac；重開沿用上次模式；常駐狀態列，一點切回 Local（§2） | T05、T09、T10 |
| D6 | 未就緒輸入 | 寫入草稿列，「傳送」灰色；就緒後由使用者手動送出；草稿只存記憶體（§2） | T06、T08、T10 |
| D7 | 語音 | 系統麥克風加 context diff 同步；T13 未通過改用主 App 手動語音頁（§6） | T13 |
| D8 | BLE 備案 | 接受 LAN WebSocket 備案，僅在 BLE 證實不可行後做限時 PoC（§9） | T03、T05、T15 |
| D9 | 重連測試 | T06 的 100 次以 XCUITest 在真機自動執行，使用者親手抽查 10 次並錄影；XCUITest 無法切換第三方鍵盤時，改由使用者親手完成 100 次 | T06 |
| D10 | Xcode project | 使用 XcodeGen：`project.yml` 納入 git，`*.xcodeproj` 不納入；每次以 `xcodegen generate` 產生 | 全部 |
| D11 | 傳輸角色（2026-10-29 批准） | 角色對調：iPhone Keyboard Extension 為 GATT Peripheral、Mac Receiver 為 Central。原因：同一 iCloud 的 iPhone 主動連 Mac 在實機失敗（T03），Mac 主動連 iPhone 成功（spike）。§2、§4、§5 待 v1.2 改寫；D8 LAN 保留為後備 | T03–T06 |

## 13. 開發環境（2026-10-29 實測）

| 項目 | 狀態 |
|---|---|
| Xcode／Swift | 27.1／6.4 |
| macOS | 27.2，Bluetooth 已開啟 |
| iOS 模擬器 | iPhone 18 Pro（iOS 27.0）；模擬器沒有 CoreBluetooth，只能用於 T01 的 UI 與 Local Mode |
| 實體 iPhone | 尚未連接；T03、T05、T06 必須使用實機 |
| 簽名身分 | 0 個；需在 Xcode → Settings → Accounts 登入 Apple ID 取得 Personal Team |
| XcodeGen | 2.46.0 已安裝；三個 target 的空殼已於暫存資料夾驗證 iOS Simulator 與 macOS build 成功，Extension 的 `CFBundleVersion` 需與 host App 一致 |
