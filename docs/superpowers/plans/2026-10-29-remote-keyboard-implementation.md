# Remote Keyboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 開發 iPhone 跨 App Custom Keyboard Extension，經 BLE GATT 將英文、符號、繁中手寫和經驗證的語音輸入送至 Mac 當前可編輯焦點。

**Architecture:** Swift/UIKit Keyboard Extension + CoreBluetooth Central；macOS menu-bar CoreBluetooth Peripheral + AX/CGEvent；跨平台 Swift Package 統一語義事件、序列、權限與狀態。iOS host App 負責初始化、配對和配置，Local Mode 始終可用。先驗證真機 extension→Mac 最短鏈路，再擴功能。

**Tech Stack:** Xcode、Swift 6（以實際 Xcode toolchain 相容性為準）、UIKit、SwiftUI（host/setup）、CoreBluetooth、ApplicationServices AXUIElement、CoreGraphics CGEvent、Keychain/CryptoKit、App Groups、PencilKit（候選）、ML Kit（fallback）、XCTest/XCUITest、OSLog、Git、`xcodebuild`/`swift test`。

**Spec:** `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（DRAFT，待批准）；Research: `docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md`。

## Global Constraints

- 必須具備 iPhone 第三方鍵盤：英文／手寫／符號、語言切換、語音入口、Mac Remote Mode。
- Mac 點選輸入框僅令 Receiver 準備接收；不保證 iOS 鎖屏或其他 App 自動彈鍵盤。
- 第一階段以真實 iPhone + Mac 實機開發；模擬器不得替代 BLE E2E 驗證。
- 第三方鍵盤無 Full Access 時 Local Mode 仍要能打字和切換 globe；Remote Mode 僅在明確啟用和授權時操作。
- App Review 4.4.1 不容許鍵盤啟動 Settings 以外其他 App，不使用 Private API 跳 App 作語音依賴。
- 不採用 Bluetooth HID；優先 Custom BLE GATT，Mac 安裝 Receiver。
- 不使用 Apple 私有 keyboard assets/IME；手寫引擎先驗版本、語言與 Extension memory。
- Mac 要每次注入前驗有效前台焦點；斷線及未授權一律 fail closed，不盲目 replay 到新的 app。
- 僅編輯用戶明確產生之輸入事件；log 必須 redacted，不寫入明文打字內容。
- 每項任務須提交測試證據、Review、Git commit；不得以推論代替實測 PASS。
- 分發方式暫採 Developer ID/notarized Mac installer + iOS dev/TestFlight；Mac App Store sandbox 另外做 feasibility test。

## Review Focus

1. **被動切換 Mac 焦點**：在 100ms 內 Cmd-Tab 到另一 App 後收到 late event，不得向新 App 注入（Task 14）。
2. **emoji grapheme/分包**：👨‍👩‍👧‍👦、👍🏻、合成重音被 BLE 拆包，重組需與原文完全相同（Task 7）。
3. **ACK lost/reconnect**：event 已 post 但 ACK 丟失；不可無提示重播造成重複字元（Task 8）。
4. **Permission revoked**：iOS Full Access、macOS AX 或 BLE 權限在 session 中途被撤銷，Remote Mode 應停止而 Local Mode 保留（Task 9、15）。
5. **Host app restricted text**：密碼、phone-pad、禁止 third-party keyboard 的 App 須正常 fallback，不能透過旁路攔截（Task 14）。

---

## 執行方式與狀態規則

- 狀態：`NOT_STARTED`（未開始）、`RED`（先寫失敗測試）、`IMPLEMENTING`、`READY_FOR_VERIFY`、`PASS`、`FAIL`、`BLOCKED`、`INCONCLUSIVE`、`NOT_APPLICABLE`。
- 禁止把 `RESEARCHED`（文獻支持）標記成 `PASS`（實機測試支持）。
- 一次僅開一個 task 的主要 PR；核心 task 必須經獨立 reviewer 及實機驗收後才 merge。
- 每個任務以 feature branch 或 worktree 執行；只有測試指令 fresh pass 後才 commit。外部 AI 若執行此計劃，須按 TDD 紅→綠流程。
- 當下**全部 task 狀態為 `NOT_STARTED`**；研究完成不是產品功能驗收。
- 假定新 repo 結構；若已有 repo，先做 `tree/git status/xcodebuild -list`，以現有佈局為準並在 PR 說明偏差，勿直接套用不存在路徑。

## 預定 repo map

```text
RemoteKeyboard.xcodeproj
Packages/RemoteKeyboardCore/
  Package.swift
  Sources/RemoteKeyboardCore/{Protocol,Security}/...
  Tests/CoreTests/...
iOS/
  RemoteKeyboardApp/{Pairing,Dictation}/...
  MacKeyboardExtension/{Bluetooth,Input,State,Keyboard,Handwriting,Dictation,Transport}/...
  MacKeyboardExtensionTests/...
  MacKeyboardExtensionUITests/...
macOS/
  MacReceiver/{Bluetooth,Focus,Input,Security,Transport,Diagnostics}/...
  MacReceiverTests/...
e2e/
docs/superpowers/{specs,plans,verification,research}/
```

## 指令及環境注意

- Swift Package 純邏輯：`swift test --package-path Packages/RemoteKeyboardCore`
- Xcode schemes：`xcodebuild -list -project RemoteKeyboard.xcodeproj` 確認實際 scheme 後才使用 `xcodebuild test -project RemoteKeyboard.xcodeproj -scheme <real-scheme> -destination 'platform=macOS'`。
- iOS 真機：`xcrun xctrace list devices` 取得裝置；以自己的 `IOS_DEVICE_ID` 執行 `xcodebuild build -project RemoteKeyboard.xcodeproj -scheme <real-scheme> -destination "platform=iOS,id=$IOS_DEVICE_ID"`。切換 iOS host app／BLE/注入結果為**手動 E2E 真機測試**，不可假定 `xcodebuild build` 代表功能 PASS。
- 測試證據每 case 必須紀錄：UTC+local timestamp、iOS/macOS/Xcode 版本、commit SHA、scheme/device、操作腳本、預期/實際、結果、相關 console log（不含文字內容）、影片/截圖/缺陷 issue。

## 16 項任務與 Gate

### Task 01: 工程基礎與離線 Local Mode — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/RemoteKeyboardApp/RemoteKeyboardApp.swift`
- Create/Modify: `iOS/MacKeyboardExtension/KeyboardViewController.swift`
- Create/Modify: `Packages/RemoteKeyboardCore/Package.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/SmokeTests.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/LocalModeTests.swift`

**Interfaces / 技術實作：** App Group、Extension Info.plist、`RequestsOpenAccess`、`textDocumentProxy.insertText()`、`advanceToNextInputMode()`。

**交付範圍：** Extension 在 Notes 可輸入 A，globe 可切下一鍵盤，未開 Full Access 仍可輸入；Xcode build 和 CoreTests 綠燈。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T01`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：建立 `TextSink.insert(_ text: String)`、`TextSink.deleteBackward()`、`RemoteEventSink.enqueue(_ kind: EventKind)`，`KeyboardMode.local/remote`；`KeyboardActionRouter.route(_:,mode:)` 在 Local Mode **只**呼叫 local sink。
- **測試**：`testLocalModeInsertsAWithoutFullAccess` → localCalls=`["A"]`、remoteCalls=`[]`；`testGlobeSwitchIsAvailable` → 觸發 input-mode switch 而非插入字符。
- **真機**：iOS 設定開啟本鍵盤但**關閉** Allow Full Access；Notes 輸入 `Hello World`，每字一致；長按 🌐 可切回其他鍵盤。

**驗收結果判準：** PASS：真機 Notes 輸入 20 字正確且在無 Full Access 照常；FAIL：無法加入鍵盤/Crash。

**若失敗：** 保留純 Local 鍵盤 target，先修權限/Extension entitlements，不增加 BLE。

### Task 02: Mac Receiver Shell、BLE GATT Advertiser — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `macOS/MacReceiver/MacReceiverApp.swift`
- Create/Modify: `macOS/MacReceiver/Bluetooth/GATTPeripheralServer.swift`
- Test/Evidence: `macOS/MacReceiverTests/GATTServiceTests.swift`

**Interfaces / 技術實作：** `CBPeripheralManager`、`CBMutableService`、`CBMutableCharacteristic`、`addService`、`startAdvertising`。

**交付範圍：** Mac 可以 advertise 固定 service UUID、Input write + Ack notify；iPhone Bluetooth 掃描工具在實機看見正確 UUID。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T02`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`GATTPeripheralServer.start() -> Void`、`stop()`、`state: GATTServerState`；常量 `GATTServiceSpec.serviceUUID/inputUUID/ackUUID` 定義於 shared package，Input=`writeWithResponse`，Ack=`notify`/`indicate`。
- **測試**：`testUniqueUUIDsAndCharacteristicPermissions` → service、input、ack UUID 互不相同；`testAdvertiseWaitsForPoweredOnAndServiceReady` → 非 poweredOn 狀態不 broadcast。
- **真機**：以 BLE scanner 紀錄 service UUID、characteristic properties 與 Mac permission 的實際截圖；不可單靠 Xcode build。

**驗收結果判準：** PASS：macOS GATT service 完整可發現，service publish 成功；FAIL：無 UUID/Manager 非 poweredOn。

**若失敗：** 依 delegate 紀錄 Mac 藍牙權限/廣播狀態，Apple BLE sample 對照。

### Task 03: Extension BLE Central 冷連線 — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Bluetooth/KeyboardBLECentral.swift`
- Create/Modify: `iOS/MacKeyboardExtension/KeyboardViewController.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/BLEConnectionStateTests.swift`

**Interfaces / 技術實作：** `CBCentralManager`、`CBPeripheral` delegates、scanForPeripherals、discoverServices、`CoreBluetooth` 權限。

**交付範圍：** 真機 Extension 按 Connect 可 scan/發現/連接/Discover service；不依賴 iOS 主 App 前景。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T03`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`KeyboardBLECentral.startConnect(serviceUUID: CBUUID)`、`disconnect()`、`state: ConnectionState`；狀態 `.idle/.scanning/.connecting/.discovering/.ready/.failed`。
- **測試**：`testKeyboardAppearStartsScan`、`testBluetoothOffTransitionsToUnavailable`、`testReappearDoesNotReuseStalePeripheral`，用 fake transport 驗 transition。
- **真機**：在 Notes/ Safari Extension process 中獨立貼出 `scan -> connect -> discovered` 狀態時間線，必須證明不需要開主 App。

**驗收結果判準：** PASS：在 Notes 與 Safari Extension 中都可連線；FAIL：只有 main App 可以或 Extension 被終止。

**若失敗：** 先確認 Full Access/entitlements/extension 診斷，再比較 Wi-Fi fallback PoC。

### Task 04: Mac 焦點感知與 Unicode 注入 — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `macOS/MacReceiver/Focus/FocusMonitor.swift`
- Create/Modify: `macOS/MacReceiver/Input/TextInjector.swift`
- Test/Evidence: `macOS/MacReceiverTests/FocusGuardTests.swift`
- Test/Evidence: `macOS/MacReceiverTests/TextInjectorTests.swift`

**Interfaces / 技術實作：** `AXIsProcessTrustedWithOptions`、`AXUIElementCreateSystemWide`、`kAXFocusedUIElementAttribute`、`CGEventKeyboardSetUnicodeString`。

**交付範圍：** Mac 點 TextEdit 的文字框，Receiver Test Insert 顯示 Hello、香港及 😀；未授予 AX 時不發送。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T04`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`FocusMonitor.snapshot() -> FocusSnapshot?`（含 `frontmostPID`、`editable`、`focusEpoch`）；`TextInjector.insert(_ text:String, onlyIf snapshot:FocusSnapshot)->InjectionResult`。
- **測試**：`testAXUntrustedRejectsInsertion` → `.notAuthorized`；`testNoEditableFocusRejectsInsertion` → `.noFocus`；`testEpochChangedRejectsInsertion` → `.staleFocus`。
- **真機**：TextEdit 依次插入 `Hello`、`香港`、`👨‍👩‍👧‍👦`；另測 Spotlight/桌面/關文件等情境 0 誤注入；`InjectionResult.posted` 僅代表事件已 post，不代表顯示成功。

**驗收結果判準：** PASS：TextEdit 5 組字串逐一完全一致；切換至非可編輯焦點時 0 誤注入；FAIL：字亂碼/輸入錯位。

**若失敗：** 測 AXValue 支援；無法可靠注入時停用而不是貼到其他欄位。

### Task 05: 最小端到端 A 鍵輸入 PoC — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/KeyboardEvent.swift`
- Create/Modify: `iOS/MacKeyboardExtension/Input/RemoteKeyRouter.swift`
- Create/Modify: `macOS/MacReceiver/Bluetooth/GATTPeripheralServer.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/EventCodecTests.swift`
- Test/Evidence: `e2e/E2E-A-KEY.md`

**Interfaces / 技術實作：** `KeyboardEvent.text("A")`、BLE characteristic write、Mac input service。

**交付範圍：** iPhone Notes 中 extension 按 A -> Mac TextEdit 當前焦點出現 A；再於 Safari 切換回鍵盤重試。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T05`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`RemoteKeyRouter.tap("A")` → queue `EventKind.text("A")`，`GATTPeripheralServer` 收到同一 `eventId` 後呼叫 `TextInjector.insert("A", snapshot:)`。
- **測試**：`testTapAProducesOneRemoteSemanticEvent` → exactly one `text("A")`，local sink 0 calls；`testNoFocusMeansNoPost` → `.noFocus`。
- **真機**：T05-E2E-A-01 Notes→Mac TextEdit 和 T05-E2E-A-02 Safari→Mac TextEdit，各 20 次，逐次錄影/結果、不得使用主 App 代打。

**驗收結果判準：** PASS：Notes→TextEdit、Safari→TextEdit 各 20 次成功，0 錯誤焦點；FAIL：只可主 App 輸入。

**若失敗：** **停止完整鍵盤 UI 開發**，改驗 Wi-Fi extension transport；若任何 extension transport 都失敗則重新確認產品方向。

**Gate 1：** 如 Task 05 失敗，暫停 Task 10–12 的完整 UI 開發；僅做連線替代 PoC。

### Task 06: BLE Lifecycle／冷啟動 Gate — M1 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Bluetooth/KeyboardBLECentral.swift`
- Create/Modify: `macOS/MacReceiver/Bluetooth/GATTPeripheralServer.swift`
- Test/Evidence: `e2e/E2E-RECONNECT.md`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/BLEConnectionStateTests.swift`

**Interfaces / 技術實作：** Extension 顯示/隱藏 lifecycle；state restoration 不作 correctness 假設；macOS BLE state callbacks。

**交付範圍：** 鍵盤收起/重開、Notes↔Safari、Mac sleep/wake、iPhone 藍牙關閉後再開。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T06`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`ConnectionPolicy.onKeyboardAppeared()` 由任何 `.idle/.failed` 都能啟動可重入連線流程；`onDisappeared` 不宣稱 background persistence。
- **測試**：`testRepeatedAppearRestartsFromIdle`、`testNoDuplicateConnectOnRapidAppear`、`testBluetoothStateReset`，fake manager 校驗 connect 次數和狀態。
- **真機**：100 次 keyboard dismiss/reopen，每次紀錄 `keyboardShownAt/readyAt`；成功率>=99%、P95<=2s（Mac awake、同位置、既有配對），無任何機械假造成功。

**驗收結果判準：** PASS：100 次鍵盤重開連線 >=99 成功；已配對且 Mac awake 的 P95 <=2 秒；FAIL：連線長期不可靠。

**若失敗：** 先調整連線重試與 timeout；必要時在 M4 評估 LAN WebSocket fallback。

**Gate 2：** 如 Task 06 不達重連門檻，不能宣稱「任何 App 叫出鍵盤即連得上」。

### Task 07: 協定分幀、UTF-8 與事件流 — M2 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Protocol/FrameCodec.swift`
- Create/Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Protocol/KeyboardEvent.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/FrameCodecTests.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/UnicodeTests.swift`

**Interfaces / 技術實作：** `FrameCodec.encode/decode`, `ChunkAssembler.append`；version/length/session/sequence/CRC或MAC、分包。

**交付範圍：** 中英文、emoji、ZWJ、超過 ATT write limit 的輸入可分 chunk 組回，invalid UTF-8 拒絕。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T07`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`FrameCodec.encode(event: KeyboardEvent, maxValueBytes:Int)->[Data]`；`FrameDecoder.feed(chunk:Data)->DecodeResult`；event 包含 `protocolVersion, eventId, sessionId, seq, focusEpoch, kind`。
- **測試**：`testMultichunkRoundTripZWJEmoji`、`testRejectTruncatedFrame`、`testRejectInvalidUTF8`、`testRejectOversizedDeclaredLength`，assert `decode(encode(x)) == x`。
- **真機**：Mac TextEdit 比對 `繁體中文，標點：「你好嗎？」👨‍👩‍👧‍👦 café` 的逐字一致性，驗最小/最大 ATT chunk。

**驗收結果判準：** PASS：1000 組 fuzz/邊界 frames，0 誤解析；FAIL：截斷 emoji 或長包丟失。

**若失敗：** 限制單次 event payload 上限、超長分塊、加入明確 error status。

### Task 08: ACK、去重、排序、失敗語義 — M2 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Protocol/EventQueue.swift`
- Create/Modify: `macOS/MacReceiver/Bluetooth/ReceiverLedger.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/EventQueueTests.swift`
- Test/Evidence: `macOS/MacReceiverTests/ReceiverLedgerTests.swift`

**Interfaces / 技術實作：** `EventQueue.enqueue/ack/reconnect`；`ReceiverLedger.accept`；`ACK/REJECT/AMBIGUOUS`。

**交付範圍：** 同 eventId 重發不重複注入、亂序先緩衝、ACK lost 不能無提示重播到新焦點。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T08`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`ReceiverLedger.decide(event:KeyboardEvent, activeFocus:FocusSnapshot)->LedgerDecision`；`.accept/.duplicate/.wrongSession/.staleFocus/.pendingGap/.ambiguous`。
- **測試**：`testSameEventIdAcceptedOnce`；`testSeq102WaitsFor101`；`testStaleFocusCannotReplay`；`testLostAckAfterPostReportsAmbiguousWithoutBlindReplay`。
- **真機**：主動注入掉 ACK／多送 seq 並在 TestEdit 比對結果；10,000 events 0 missing/dup/reordered 限於受控 TextEdit 測試，不聲稱任意 App exactly-once。

**驗收結果判準：** PASS：重複100次 seq 單次 commit、亂序安全、10000 events 受控 TextEdit 0 遺漏/重複/亂序；FAIL：多發一次或錯焦點補送。

**若失敗：** 發送後無法確知結果回 AMBIGUOUS，由使用者決定，不能宣稱 exactly-once 任意 App。

### Task 09: 配對身份認證、隱私與 Local/Remote 模式 — M2 / P0

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/RemoteKeyboardApp/Pairing/PairingView.swift`
- Create/Modify: `iOS/MacKeyboardExtension/State/KeyboardModeStore.swift`
- Create/Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Security/SessionAuth.swift`
- Create/Modify: `macOS/MacReceiver/Security/PairingManager.swift`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/SessionAuthTests.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/ModePolicyTests.swift`

**Interfaces / 技術實作：** `Security`、`Keychain`、`CryptoKit` HMAC、`UserDefaults(suiteName:)`、BLE encrypted GATT。

**交付範圍：** Mac 一次性配對碼/QR+Keychain、challenge-response；只有明確 Remote 模式輸出 Mac；未開權限維持 Local。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T09`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`SessionAuth.respond(challenge: Data, key: SymmetricKey)->Data`、`verify`；`KeyboardModePolicy.canSendRemote(hasFullAccess:Bool, paired:Bool, userOptIn:Bool, macReady:Bool)->Bool`。
- **測試**：`testUnpairedDeviceRejected`、`testReplayedNonceRejected`、`testRemoteFalseWithoutOptIn`、`testLocalAvailableWithoutFullAccess`、`testWrongMacCannotReceive`。
- **真機**：Mac revoke pairing → iPhone 顯示未配對，無事件注入；關 Full Access→Local 仍可打字，Remote 轉 disabled；配對秘密只在 Keychain。

**驗收結果判準：** PASS：未配對設備/錯 token/撤銷配對不能注入；模式清晰、Remote 關閉不送 Mac；FAIL：無授權送資料。

**若失敗：** 先停用 Remote Mode，將配對和 Full Access 文案修正，再試。

**Gate 3：** Security/Mode 不通過時，不得開放 Remote Mode 予使用者。

### Task 10: 原生風格英文 QWERTY 操作 — M3 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Keyboard/EnglishKeyboardView.swift`
- Create/Modify: `iOS/MacKeyboardExtension/Keyboard/ShiftStateMachine.swift`
- Create/Modify: `iOS/MacKeyboardExtension/Keyboard/KeyAction.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/ShiftStateMachineTests.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionUITests/EnglishLayoutUITests.swift`

**Interfaces / 技術實作：** UIKit `UIInputViewController`＋UIControl/UIView、`UITextDocumentProxy`、`UIInputViewAudioFeedback`。

**交付範圍：** QWERTY 排列、Shift 單次/雙擊 Caps Lock、backspace repeat、按鍵按下回饋、Return/Space、globe、橫豎屏。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T10`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`ShiftReducer.transition(state:ShiftState, action:ShiftAction)->ShiftState`；`KeyLayout.english(locale: ...)` 提供 26 個字母 mapping；`KeyAction` 唔依賴 private keyboard assets。
- **測試**：`testSingleShiftReturnsToLowercaseAfterCharacter`、`testDoubleShiftLocksUntilToggled`、`testBackspaceRepeatStopsOnTouchEnd`、`testAutoCapStartsAtSentenceBoundary`。
- **真機**：對照使用者指定 iPhone 原生英文鍵盤，檢查 3 排、Shift、Delete、Space、Return、hit targets、橫豎屏；行為吻合但不宣稱 Apple 私有預測字詞已復刻。

**驗收結果判準：** PASS：操作表 40/40、iPhone 尺寸 UI 不重疊；FAIL：Shift stuck/丟字/誤觸。

**若失敗：** 可考慮 KeyboardKit UI 但先核對授權；不得直接使用私有 Apple assets。

### Task 11: 數字 123／符號 #+= 兩頁 — M3 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Keyboard/SymbolKeyboardView.swift`
- Create/Modify: `iOS/MacKeyboardExtension/Keyboard/KeyboardPageRouter.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/SymbolPageTests.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionUITests/KeyboardPageUITests.swift`

**Interfaces / 技術實作：** 頁面狀態機 `KeyboardPage.english/numbers/symbols/handwriting`，依 iPhone 原生布局參考。

**交付範圍：** ABC -> 123 -> #+= -> 123 -> ABC；標點符號、數字、Delete/Return/Space 全部有正確 semantic event。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T11`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`KeyboardPageReducer.transition(page:KeyboardPage,key:PageKey)->KeyboardPage`；symbol layout 固定 `123` 與 `#+=` 兩層，每個可見鍵必有 `KeyAction`。
- **測試**：`test123ThenSymbolsThenABC` → page `.numbers -> .symbols -> .english`；`testAllSymbolsMapToExpectedUnicode`、`testDeleteDoesNotInsertACharacter`。
- **真機**：兩層所有按鍵逐一輸出到 Mac TextEdit；比對符號順序和清單，頁面切換中途不得重複送字。

**驗收結果判準：** PASS：全部鍵位 mapping unit tests 100%，不因切換頁重覆注入；FAIL：錯字符映射。

**若失敗：** 分離 layout 資料與 view、加入 snapshot tests。

### Task 12: 繁體中文手寫與候選字 — M3 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Handwriting/HandwritingCanvasView.swift`
- Create/Modify: `iOS/MacKeyboardExtension/Handwriting/HandwritingRecognizer.swift`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/HandwritingSelectionTests.swift`
- Test/Evidence: `e2e/E2E-HANDWRITING.md`

**Interfaces / 技術實作：** `PencilKit` PKStrokeRecognizer（先驗 availability/zh-Hant support），如無則 ML Kit Digital Ink zh-Hani-TW/HK。

**交付範圍：** 用戶手寫→顯示候選字→點選候選→只發送已提交 Unicode；清除筆畫不送字。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T12`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`HandwritingRecognizer.recognize(strokes:[Stroke])->[Candidate]` async；`CandidateCommitter.select(_ candidate: Candidate)->EventKind.text`；擱置筆畫/取消不產生遠端事件。
- **測試**：`testUnselectedCandidatesDoNotCommit`、`testSelectingSecondCandidateSendsOnlySecond`、`testClearResetsStrokes`、`testRecognitionUnavailableReportsError`。
- **真機**：先列出 `PKStrokeRecognizer` API availability 與 supported languages 截圖；100 字 Top-3 >=90% 的目標測，30 次切換無 memory kill；否則改驗 ML Kit 繁中模型。

**驗收結果判準：** PASS：指定 100 字測例 top-3 >=90%，25 字混合詞語輸入無殘留，extension 30 次切換無 OOM；FAIL：語言/記憶體不可用。

**若失敗：** 改 ML Kit；如仍過大採低記憶體推論或把手寫列為 MVP blocker。

### Task 13: 語音聽寫獨立可行性 Gate — M3 / P0-風險

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Dictation/DictationCompatibilityProbe.swift`
- Create/Modify: `iOS/RemoteKeyboardApp/Dictation/DictationFallbackScreen.swift`
- Test/Evidence: `e2e/E2E-DICTATION.md`
- Test/Evidence: `iOS/MacKeyboardExtensionTests/DictationDiffTests.swift`

**Interfaces / 技術實作：** `hasDictationKey` 僅 UI flag；`textDidChange`/limited `documentContextBeforeInput` 只作研究；主 App 可做明確手動 speech UI。

**交付範圍：** 真 iPhone 在 Notes/Safari/Messages 測 system dictation 顯示、開始/修改/取消、extension 可見變化和是否能準確傳 Mac。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T13`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`DictationObservation` 明確記 `systemMicVisible, began, hostTextChanged, extensionCallbackSeen, exactCommittedDiffAvailable, macRemoteMatched`；不要憑 `hasDictationKey` 推論任何能力。
- **測試**：`testContextDiffWithUnknownBeforeReturnsInconclusive`、`testReplacementDoesNotGetMisreportedAsAppend`；保留原始觀察表而不是假定 API 有 transcript callback。
- **真機**：Notes/Safari/Messages，各測系統語音一次簡單短句、修正詞、取消和混合中文；擴大至 100 語句才可以判 PASS。若 callback 缺失，立刻記 FAIL/INCONCLUSIVE 而不是私有 API hack。

**驗收結果判準：** PASS：100 句中英語音及修正 100% 正確到 Mac 且 API 合規；FAIL：只可看見 mic/片段差分不可靠。

**若失敗：** FAIL 時不可默默標記完成；移至主 App 明確手動模式或將語音保留未實現，需使用者批准 scope 變更。

**Gate 4：** Dictation 結果獨立於英文/手寫；必須清楚標示 PASS/FAIL/INCONCLUSIVE，不能用語音按鈕出現代替。

### Task 14: 跨 App 相容性、Mac 焦點安全矩陣 — M4 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `macOS/MacReceiver/Focus/FocusMonitor.swift`
- Create/Modify: `iOS/MacKeyboardExtension/State/KeyboardModeStore.swift`
- Test/Evidence: `e2e/E2E-HOST-MATRIX.md`
- Test/Evidence: `macOS/MacReceiverTests/FocusGuardTests.swift`

**Interfaces / 技術實作：** AXObserver/前台 App PID/focusEpoch；每事件重新驗證焦點和授權。

**交付範圍：** iOS Notes/Safari/Messages/Mail/至少三個第三方 App；Mac TextEdit/Word/Safari/VS Code；密碼欄位和 secure fields 按平台預期回退。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T14`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`FocusGuard.authorize(event.focusEpoch, current:FocusSnapshot)->Authorization`；只授權 `editable && epochMatches && frontmostPIDMatches && sessionApproved`。
- **測試**：`testCmdTabBeforeArrivalRejectsEvent`、`testDialogStealsFocusRejectsEvent`、`testSecureInputDoesNotSendViaThirdPartyKeyboard`、`testTargetAppClosedRejectsEvent`。
- **真機**：iOS Notes/Safari/Messages/Mail + 3 第三方 App；Mac TextEdit/Word/Safari/VS Code 各 10 次；blocked 欄位需被系統正常回退，不列為程式 bug。

**驗收結果判準：** PASS：容許欄位、已建立遠端模式輸入無錯焦；blocked 欄位正確回退；FAIL：送到錯 App。

**若失敗：** 標示不相容 App，不可自動 fallback 到錯誤 text box；提供停止鍵。

### Task 15: 穩定性、權限、Wi-Fi 降級驗證 — M4 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `iOS/MacKeyboardExtension/Transport/TransportSelector.swift`
- Create/Modify: `macOS/MacReceiver/Transport/ReceiverTransport.swift`
- Create/Modify: `macOS/MacReceiver/Diagnostics/DiagnosticsStore.swift`
- Test/Evidence: `e2e/E2E-ROBUSTNESS.md`
- Test/Evidence: `Packages/RemoteKeyboardCore/Tests/CoreTests/TransportSelectionTests.swift`

**Interfaces / 技術實作：** CoreBluetooth state machine；Network.framework/Bonjour/TLS 僅 fallback；OSLog redaction。

**交付範圍：** Bluetooth toggle、Mac sleep 1/10/60 min、extension kill、iPhone lock/unlock、雙 Mac 不亂連；必要時 LAN WebSocket fallback。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T15`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`TransportSelector.choose(ble:TransportHealth, localNetworkAuthorized:Bool, userPref:TransportPreference)->TransportChoice`；不得自動切到未授權 Wi-Fi 目標。
- **測試**：`testPrefersReadyBLE`、`testNoWiFiWithoutPermission`、`testTwoMacsRequireExplicitActiveSelection`、`testReconnectDoesNotFlushToWrongFocus`。
- **真機**：Mac sleep(1/10/60min)、手機 lock/unlock、BLE off/on、斷線、雙 Mac；所有錯誤狀況有明確診斷及 no silent data transfer。

**驗收結果判準：** PASS：無授權/無焦點永遠 fail closed，任一失敗可提示及恢復；Wi-Fi 測試有權限和身份驗證；FAIL：黑洞或跨 Mac 錯送。

**若失敗：** 首選修 BLE 重連；若 LAN fallback 更穩則由用戶決定是否改傳輸主線。

**Gate 5：** 只有在 BLE 體驗未達產品要求，才進一步納入 Wi-Fi fallback。

### Task 16: Release Candidate QA、文件與分發審核 — M5 / P1

**目前結果：** `NOT_STARTED`。研究層可行性 ≠ 工程通過。

**Files:**
- Create/Modify: `README.md`
- Create/Modify: `docs/PRIVACY.md`
- Create/Modify: `docs/USER-GUIDE.md`
- Create/Modify: `docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md`
- Test/Evidence: `e2e/E2E-RELEASE.md`
- Test/Evidence: `CI/workflow-build-checklist.md`

**Interfaces / 技術實作：** `xcodebuild`、`swift test`、TestFlight/Apple notarization（依分發方案）、手動簽收表。

**交付範圍：** build、unit+integration、真機 E2E、隱私政策、App Review 4.4.1、Mac Accessibility notarization/sandbox 審查。

- [ ] **Step 1 — Red：**先在上述測試路徑建立可重現的特定測試（若為硬體 E2E，寫成可重複的真機腳本），包含正常、異常與權限被撤銷情境。
- [ ] **Step 2 — 證明測試先失敗：**執行純邏輯 `swift test --package-path Packages/RemoteKeyboardCore`，或相關 Xcode scheme／真機腳本；保存本項 RED log，說明失敗是預期缺少功能而非編譯環境故障。
- [ ] **Step 3 — 最小實作：**僅修改 `Files` 所列責任模組與其必要依賴；實作後不得繞過測試或擴大權限。
- [ ] **Step 4 — Green：**重新執行本任務 unit/integration；需 0 failures；Xcode relevant scheme 能成功 build；保存 log 和 `git diff --check`。
- [ ] **Step 5 — 實機／人手驗收：**依下列 Pass/Fail 執行，寫入驗收報告 case `T16`；由人員審查真機截圖、文字輸出及裝置 log。
- [ ] **Step 6 — Review/Commit：**對照設計規格、私隱要求和測試證據，無 blocker 才提交小型 commit；有失敗提交 issue 並標注 BLOCKED/FAIL。

**具體測試與模組 API 合約（計劃中的介面，未實作）：**

- **合約**：`ReleaseGate.evaluate(taskStatuses:[TaskID:Status], signedVoiceScopeChange:Bool)->ReleaseDecision`（僅品質檢查輔助，不代替人員驗收）。
- **測試**：`testAnyP0FailedBlocksRelease`、`testMissingRealDeviceEvidenceBlocksRelease`、`testVoiceFailWithoutApprovedScopeChangeBlocksRelease`、`testAllMandatoryEvidenceAllowsCandidate`。
- **人工確認**：重新跑 `swift test`/Xcode build/真機回歸、比對 16 個簽名 case；檢查 4.4.1、Full Access、privacy、Mac notarization。若有任何必需項 `NOT_STARTED`，結果只能 `BLOCKED`。

**驗收結果判準：** PASS：全部必需 Gate 通過且帶 log/截圖/測試版本，無 blocker；FAIL：任何強制 Gate 缺證據。

**若失敗：** 發 internal preview，不宣稱 App Store ready。

**Gate 6：** Release Candidate 必須有全部重大功能的簽名驗收紀錄；尚未做分發，不應寫成已上架。

## 任務之間的依賴與里程碑

- **M1 / 證明核心路徑**：T01 → T02 & T03（可平行）→ T04（可與 BLE 平行）→ T05 → T06。**未通過 T05 不投資完整鍵盤皮膚**。
- **M2 / 正確性與安全**：T07 → T08 → T09；需要 T05 有實際可用的基本路徑。
- **M3 / UI 與輸入方法**：T10 → T11、T12（可平行），T13（**語音可行性 probe 在 T01 後即優先進行，不應等完整鍵盤；正式整合在 M3**）。
- **M4 / 跨 App 與壓力**：T14 → T15；先讀取 M1/M2 連線、驗證、模式結果。
- **M5 / Release QA**：T16 依賴所有 P0/P1 mandatory gates，若語音失敗須和使用者確認變更規格，不得自行將 FAIL 重分類為 PASS。

## 驗收優先順序與停止準則

| Stop Condition | 判定 | 決策 |
|---|---|---|
| Extension 無法 scan/connect 真 Mac BLE | T03 FAIL | 啟動限時 LAN WebSocket 小型替代試驗；不繼續 UI |
| E2E A 無法在 Mac TextEdit 出現 | T05 FAIL | 先解決傳輸/AX/權限；不開始完整英文鍵盤 |
| iOS app switch 後 BLE 無法穩定恢復 | T06 FAIL | 評估 LAN fallback，或把「任何 App」能力改為已知限制 |
| 只有主 App 輸入可行，Extension 遠端不可行 | T05/T06 BLOCKED | 根本設計需重新確認，不能說符合原需求 |
| 只顯示原生系統 mic 按鈕，無可靠 text diff | T13 FAIL | 語音不算完成，改明示受限 fallback/重新確認 |
| Remote 模式有未授權文字外洩／錯焦點 | T09/T14 FAIL | **Security blocker**，不能分發 |
| 100 次重連不及格、10k events 有重複 | T06/T08 FAIL | 不能進 RC；先補 reliability/ledger semantics |

## Definition of Done（每任務皆適用）

- [ ] 當前分支乾淨、沒有未審核的依賴升級、`git diff --check` 無錯。
- [ ] 正常/失敗測試均有明確斷言；TDD RED→GREEN 記錄可用。
- [ ] 合法權限取得與撤銷可測，privileged path 有 fail-closed。
- [ ] 對應功能 iOS/macOS build、unit/integration（如適用）及真機條件全部達標。
- [ ] 不在 OSLog/analytics 保存明文輸入；安全檢視完成。
- [ ] 測試裝置版本、commit SHA、輸出、截圖／影片、pass/fail 在驗收報告完整記錄。
- [ ] Code review 已提出並回應重大疑點；提交小型可回退 commit。

**最後交付**：Mac Receiver 可執行 App、iOS host App + Keyboard Extension、版本化 Shared Protocol、完整驗收報告、測試矩陣、使用者安裝／權限說明；實際分發方式另依使用者核准。

**計劃狀態：** DRAFT / 已編排，待審核，無任何 build 或 E2E 完成聲明。
