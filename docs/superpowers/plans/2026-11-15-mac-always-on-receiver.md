# Mac Receiver 常駐接收 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac Receiver 啟動即掃描並連線，無閒置逾時，只保留手動暫停（D29）。

**Architecture:** `ReceiverSession`（Core）縮成只有開始／停止；`ReceiverBLECentral` 刪除逾時計時器、倒數與活動延長；app 啟動時呼叫 `startReceiving()`；「本次接收時段略過」改為 10 秒定時 hold。

**Tech Stack:** Swift 6.4、XCTest、CoreBluetooth、XcodeGen + CocoaPods workspace。

**Spec:** `docs/superpowers/specs/2026-11-15-mac-always-on-receiver-design.md`

## Global Constraints

- 焦點安全閘（T14）、D4 輸入法切換、注入判斷全部不改。
- log 不得含文字內容；只記事件種類、長度、時間與結果。
- 不改 `receiver/`（Rust）。
- 面板文字用台灣繁體：「接收中」「已暫停」「已暫停接收」。
- 暫停狀態不寫入磁碟。

## Review Focus

1. 暫停中打開配對視窗，配對結束後要回到暫停；接收中打開，結束後仍接收（`ReceiverSecurityTests`）。
2. 驗證失敗的手機 10 秒內被略過，10 秒後再被發現要能重連（Task 2 測試）。
3. 手動暫停後再開始，之前 hold 的手機立即可連（Task 2 測試）。
4. 量測模式 `-rkMeasureMode YES` 啟動時不可重複 arm 造成雙重掃描（`startReceiving` 冪等）。
5. 單元測試 host（`isRunningUnitTests`）啟動時絕不可開始掃描。

---

### Task 1: `ReceiverSession` 簡化（Core）

**Files:**
- Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/ReceiverSession.swift`
- Test: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/ReceiverSessionTests.swift`

**Interfaces:**
- Produces: `enum ReceiverSessionInput { case start, stop }`；`enum ReceiverSessionEffect { case arm, disarm }`；`struct ReceiverSession { var isArmed: Bool; init(); mutating func handle(_:) -> [ReceiverSessionEffect] }`。移除 `idleTimeout`、`deadline`、`now:` 參數。

- [ ] 改寫測試：`testStartArms`（`[.arm]`、isArmed）、`testStartWhileArmedIsNoOp`（`[]`）、`testStopDisarms`、`testStopWhilePausedIsNoOp`、`testStartsPaused`（新實例 `isArmed == false`）。刪除所有逾時相關測試。
- [ ] `swift test --package-path Packages/RemoteKeyboardCore --filter ReceiverSessionTests` → 編譯失敗（RED）。
- [ ] 實作。
- [ ] `swift test --package-path Packages/RemoteKeyboardCore` 全綠。

### Task 2: Mac Receiver 常駐

**Files:**
- Modify: `macOS/MacReceiver/Bluetooth/ReceiverBLECentral.swift`、`macOS/MacReceiver/MacReceiverApp.swift`、`macOS/MacReceiver/ReceiverPanel.swift`、`macOS/MacReceiver/Pipeline/ReceiverCoordinator.swift`、`macOS/MacReceiver/Pipeline/EventPipeline.swift`、`macOS/MacReceiver/Input/PointerReceiver.swift`、`macOS/MacReceiver/Diagnostics/MeasurementEcho.swift`、`macOS/MacReceiver/MacTutorialView.swift`
- Test: `macOS/MacReceiverTests/ReceiverBLECentralTests.swift`、`ReceiverCoordinatorTests.swift`、`ReceiverSecurityTests.swift`、`ReceiverGoodbyeTests.swift` 及其他因簽名改變而需調整者

**Interfaces:**
- Consumes: Task 1。
- `ReceiverBLECentral`：保留 `startReceiving()`、`stopReceiving()`、`isArmed`、`restartScanning()`、`disconnectCurrent(skipForSession:)`（參數改名 `hold:`）。刪除 `idleTimeoutKey`、`deadline`、`remainingSeconds`、`noteEvent()`、`focusGainedEditable()`、`handleSession(_:)` 中的 timeout 分支、idle 計時器；一秒 tick 若只為倒數則一併刪除（`setPanelVisible` 若無其他用途也刪除，連同呼叫處）。
- `static let skipHoldSeconds = ReceiverLinkStateMachine.handshakeBackoffSeconds`（10 秒）。`skippedPeripherals` 改為 `[UUID: Double]`（到期的 uptime 秒數），用建構子已有的 `uptime` 閉包；`.discovered` 時過期即移除並放行。`startReceiving`／`stopReceiving`／`restartScanning` 清空。
- `ReceiverMenu.receivingText(isArmed: Bool) -> String`：`true` →「接收中」，`false` →「已暫停」（取代 `remainingText`）。`linkLabel` 的 `.idle` →「已暫停接收」。
- `EventPipeline` 的 `noteValidEvent`、`PointerReceiver` 與 `MeasurementEcho` 的 `noteActivity` 參數：只用於延長接收時段者，整個刪除。
- `ReceiverCoordinator.focusChanged`：不再呼叫 central，只送狀態。

- [ ] 先寫／改測試（RED）：
  - `testReceiverStartsPausedUntilStarted`（central 新建 `isArmed == false`）。
  - `testNoIdleTimeout`：`startReceiving()` 後讓 runloop 跑 0.3 秒，`isArmed` 仍為 true、driver 未收到 `stopScan`。
  - `testFocusOnEditableFieldDoesNotChangeReceiving`（Coordinator：暫停時 editable 焦點 → 仍 `isArmed == false`；接收中 → 不變）。
  - `testSkippedPeripheralHeldTenSeconds`：`disconnectCurrent(hold: true)` 後同 id 在 uptime +9.9 秒被發現 → 不連；+10.1 秒 → driver 收到 `connect(id)`。
  - `testStopAndStartClearsHolds`。
  - `testReceivingText`：`receivingText(isArmed: true) == "接收中"`、`false == "已暫停"`。
  - 保留現有配對測試語意：暫停中開配對視窗→結束後 `isArmed == false`；接收中→仍 true。
  - 刪除所有逾時、倒數、`rk.idleTimeoutSeconds` 相關測試。
- [ ] 跑 `MacReceiverTests` 確認 RED。
- [ ] 實作上述介面；`MacReceiverApp.init` 在 `!isRunningUnitTests` 分支、`focus.start()` 之後呼叫 `central.startReceiving()`。
- [ ] 面板：倒數那行改 `receivingText`；「開始接收」`.disabled(central.isArmed)`、「停止接收」`.disabled(!central.isArmed)`。
- [ ] `MacTutorialView` 第 1 點改為「在 Mac 允許輔助使用與藍牙，Receiver 開著就會自動接收。」
- [ ] 更新 D13 相關註解（`ReceiverCoordinator` 類別註解等）改指 D29。
- [ ] 全綠：`MacReceiverTests`、Mac build、iOS 模擬器 build。

### Task 3: 文件

**Files:** `docs/manual/04-install-mac-receiver.md`、`docs/manual/06-using-the-keyboard.md`、`docs/manual/10-troubleshooting.md` 及 `docs/manual/en/` 對應檔、`docs/distribution/sidestore-install-guide.md`、`e2e/E2E-T16-RC.md`（B1、H12–H16、H18、Z1）。

- [ ] 刪除「點文字欄位開始接收」「閒置 30 分鐘」「剩餘接收時間」的描述，改為 D29 行為；T16-RC 對應項目改寫為：啟動即連線、不點欄位也連上、長時間不打字不斷線、「停止接收」後顯示「已暫停」且 iPhone 連不上、「開始接收」後恢復。
- [ ] grep `30 分鐘|30 minutes|剩餘接收時間|rk.idleTimeoutSeconds` 於上述檔案為 0。
