# Remote Keyboard Implementation Plan v1.1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 M1：證明 iPhone 第三方 Keyboard Extension 可經 BLE GATT 把按鍵送進 Mac TextEdit 的目前焦點，並在鍵盤反覆重開後穩定重連。

**Architecture:** 一個 Swift Package `RemoteKeyboardCore` 放所有純邏輯（路由、狀態機、焦點守衛、輸入法切換流程、編碼、統計），以 `swift test` 驗證；iOS Extension、iOS host App、macOS Receiver 只做 UIKit／SwiftUI／CoreBluetooth／AX／CGEvent／TIS 的薄 adapter。Xcode project 由 XcodeGen 從 `project.yml` 產生。

**Tech Stack:** Xcode 27.1、Swift 6.4（language mode 6）、XcodeGen 2.46.0、UIKit `UIInputViewController`、SwiftUI、CoreBluetooth、ApplicationServices（AXUIElement）、CoreGraphics（CGEvent）、Carbon TIS、OSLog、XCTest／XCUITest。

**Spec:** `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（v1.1 APPROVED，設計決定見 §12 D1–D10）。

**範圍：** 本版只把 M1（T01–T06）寫到可直接執行的程度。T07–T16 保留任務定義與 v1.1 調整，於 M1 Gate 通過後再以 writing-plans 細化。v1.0 原文見 `docs/archive/planning-package-v1.0/RemoteKeyboard-Superpowers-v1-Implementation-Plan.md`。

## Global Constraints

- 不採用 Bluetooth HID；主傳輸為自訂 BLE GATT，Mac 安裝 Receiver。
- 無 Full Access 時 Local Mode 必須可打字並可切換下一個鍵盤。
- App Review 4.4.1：鍵盤不得啟動 Settings 以外的 App，不使用 private API。
- `hasDictationKey` 不等於可讀取系統聽寫內容；語音另有 Gate（T13）。
- Mac 每次注入前以 AX 驗證焦點，任何不確定一律 fail closed。
- 傳送語義 Unicode，不傳 HID scan code。
- ACK 只代表 Receiver 已處理，不承諾任意 App exactly-once。
- log 不得含輸入文字；只記事件種類、長度、時間、結果。
- 每個 Task 更新驗收報告並附實際證據；研究不算 PASS。
- 部署下限：iOS 18.0、macOS 15.0。
- Bundle ID：`com.ansonhui.remotekeyboard`（host App）、`com.ansonhui.remotekeyboard.keyboard`（Extension）、`com.ansonhui.remotekeyboard.receiver`（Mac）。App Group：`group.com.ansonhui.remotekeyboard`。
- 簽名：Personal Team（D2）。Mac Receiver 也用 Personal Team 的 Apple Development 憑證簽名，避免每次重 build 後 Bluetooth／Accessibility 授權失效。
- 模擬器沒有 CoreBluetooth：T03、T05、T06 的驗收只能用實體 iPhone。

## 執行規則

- 每個 Task：一個 worktree、一條 branch（名稱見各 Task）、一個 PR。
- 子代理（Sonnet）寫程式與測試，不得 commit 或 push；每份 brief 列出可改檔案、驗收清單、需交付的證據。
- 主代理自行重跑全部指令並經獨立 reviewer 審查後 commit、開 PR、merge。各 Task 的「Commit」步驟由主代理執行。
- 實機步驟由使用者親手執行；結果填入驗收報告前一律標 `TBD`。
- 每個 Task 完成即停下回報，不自動開始下一個 Task。

## Review Focus

1. **Mac 輸入法切回太早**：CGEvent 是非同步投遞，若注入後立刻切回注音，目標 App 可能在切回後才處理事件，文字被輸入法攔截。由 T04 的 `testRestoreHappensAfterSettleDelay` 與實機 100 次注音狀態注入測試覆蓋。
2. **讀取狀態與事件抵達之間切換 App**：iPhone 依據舊的 `focusEpoch` 送出，Mac 已 Cmd-Tab 到其他 App，必須拒收。由 T04 的 `testEpochChangedRejectsInsertion` 與 T05 實機步驟覆蓋。
3. **記住 Remote 模式但 Full Access 已關閉**：鍵盤重開時必須回到 Local 且可打字。由 T05 的 `testSavedRemoteFallsBackToLocalWithoutFullAccess` 覆蓋。
4. **host App 未取得或被拒 Bluetooth 權限**：Extension 必須顯示不可用狀態，不得 crash 或卡在 scanning。由 T03 的 `testUnauthorizedTransitionsToUnavailable` 覆蓋。
5. **切段時拆開 grapheme**：ZWJ emoji 或組合重音被 CGEvent 長度上限切開會變亂碼。由 T04 的 `testChunkerNeverSplitsGraphemeCluster` 覆蓋。

---

## 檔案結構

```text
project.yml                                  XcodeGen：3 個 app target + 2 個 test target
Packages/RemoteKeyboardCore/
  Package.swift
  Sources/RemoteKeyboardCore/
    Shared/KeyboardMode.swift                 KeyboardMode、ModeResolver
    Shared/GATTServiceSpec.swift              固定 UUID 與 characteristic 屬性
    Shared/KeyboardEvent.swift                KeyboardEvent、EventKind、EventCodec
    Shared/ReceiverStatus.swift               ReceiverStatus、Ack
    Shared/DiagnosticEvent.swift              不含文字內容的診斷事件
    Keyboard/KeyAction.swift                  KeyAction、TextSink、RemoteEventSink
    Keyboard/KeyboardActionRouter.swift       依模式分派按鍵
    Keyboard/ConnectionStateMachine.swift     BLE Central 狀態機（純 reducer）
    Keyboard/ReconnectStats.swift             成功率與 P95
    Receiver/AdvertisingGate.swift            何時可以廣播
    Receiver/FocusGuard.swift                 FocusSnapshot、InjectionDecision
    Receiver/UnicodeChunker.swift             依 grapheme 切段
    Receiver/InputSourceSwitcher.swift        切 ABC、驗證、注入、延遲、切回
  Tests/RemoteKeyboardCoreTests/              每個 Source 檔一個對應測試檔
iOS/RemoteKeyboardApp/
  RemoteKeyboardApp.swift                     SwiftUI：安裝教學、Bluetooth 授權按鈕、診斷
  AppGroupProbe.swift                         寫入／讀取 App Group 測試值（O3）
iOS/RemoteKeyboardExtension/
  Info.plist                                  keyboard-service、RequestsOpenAccess=YES
  KeyboardViewController.swift                組裝 view、router、central
  MinimalKeyboardView.swift                   M1 用的簡易 QWERTY（原生風格在 T10）
  Bluetooth/KeyboardBLECentral.swift          CoreBluetooth adapter
iOS/RemoteKeyboardUITests/ReconnectUITests.swift   T06 自動 100 次
macOS/MacReceiver/
  MacReceiverApp.swift                        MenuBarExtra：BLE 狀態、焦點狀態、Test Insert
  Bluetooth/GATTPeripheralServer.swift        CBPeripheralManager adapter
  Focus/FocusMonitor.swift                    AX + NSWorkspace，產生 FocusSnapshot
  Input/TextInjector.swift                    CGEvent Unicode／Backspace／Return
  Input/TISInputSourceController.swift        Carbon TIS adapter
  Diagnostics/ReconnectLog.swift              寫 ~/Library/Logs/RemoteKeyboard/reconnect.csv
macOS/MacReceiverTests/AdapterSmokeTests.swift
e2e/E2E-T01-LOCAL.md、E2E-T02-GATT.md、E2E-T03-CENTRAL.md、E2E-T04-INJECT.md、E2E-T05-A-KEY.md、E2E-T06-RECONNECT.md
```

v1.0 的 `MacKeyboardExtension` 改名為 `RemoteKeyboardExtension`，避免與 Mac 端混淆。

## 共用指令

| 用途 | 指令 | 通過條件 |
|---|---|---|
| 產生 project | `xcodegen generate` | exit 0 |
| 純邏輯測試 | `swift test --package-path Packages/RemoteKeyboardCore` | `0 failures` |
| iOS 模擬器 build | `xcodebuild build -project RemoteKeyboard.xcodeproj -scheme RemoteKeyboardApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' CODE_SIGNING_ALLOWED=NO -quiet` | exit 0 |
| macOS build | `xcodebuild build -project RemoteKeyboard.xcodeproj -scheme MacReceiver -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -quiet` | exit 0 |
| macOS adapter 測試 | `xcodebuild test -project RemoteKeyboard.xcodeproj -scheme MacReceiver -destination 'platform=macOS,arch=arm64'` | `** TEST SUCCEEDED **` |
| 空白檢查 | `git diff --check` | 無輸出 |

以下各 Task 的「Run all」即依序執行上表前四列；T02 起加第五列。

---

## M1 任務

### Task 01: 工程骨架與離線 Local Mode

**Branch:** `t01-local-keyboard`

**Files:**
- Create: `project.yml`、`Packages/RemoteKeyboardCore/Package.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/KeyAction.swift`、`Keyboard/KeyboardActionRouter.swift`、`Shared/KeyboardMode.swift`
- Create: `iOS/RemoteKeyboardApp/RemoteKeyboardApp.swift`、`iOS/RemoteKeyboardApp/AppGroupProbe.swift`
- Create: `iOS/RemoteKeyboardExtension/Info.plist`、`KeyboardViewController.swift`、`MinimalKeyboardView.swift`
- Create: `macOS/MacReceiver/MacReceiverApp.swift`（只有空的 MenuBarExtra，讓三個 target 都能 build）
- Test: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/KeyboardActionRouterTests.swift`
- Evidence: `e2e/E2E-T01-LOCAL.md`

**Interfaces:**
- Produces:
  - `enum KeyboardMode: String, Codable, Sendable { case local, remote }`
  - `enum KeyAction: Equatable, Sendable { case character(String), backspace, space, returnKey, nextKeyboard, toggleMode }`
  - `protocol TextSink { func insertText(_ text: String); func deleteBackward() }`
  - `protocol RemoteEventSink { func enqueue(_ kind: EventKind) }`（`EventKind` 先以 `enum EventKind: Equatable, Sendable { case text(String), backspace, returnKey }` 定義於 `KeyAction.swift`，T05 移到 `KeyboardEvent.swift`）
  - `enum RouteOutcome: Equatable { case insertedLocally, enqueuedRemote, advanceInputMode, modeToggled(KeyboardMode), rejected }`
  - `struct KeyboardActionRouter { init(local: TextSink, remote: RemoteEventSink); func route(_ action: KeyAction, mode: KeyboardMode) -> RouteOutcome }`

- [ ] **Step 1: 寫失敗測試**（fake sink 以陣列記錄呼叫）

```swift
func testLocalModeInsertsAWithoutFullAccess() {
    let (router, local, remote) = makeRouter()
    XCTAssertEqual(router.route(.character("A"), mode: .local), .insertedLocally)
    XCTAssertEqual(local.inserted, ["A"]); XCTAssertEqual(remote.events, [])
}
func testGlobeSwitchIsAvailable() {
    let (router, local, _) = makeRouter()
    XCTAssertEqual(router.route(.nextKeyboard, mode: .local), .advanceInputMode)
    XCTAssertEqual(local.inserted, [])
}
func testSpaceAndReturnInsertLocally() {
    let (router, local, _) = makeRouter()
    _ = router.route(.space, mode: .local); _ = router.route(.returnKey, mode: .local)
    XCTAssertEqual(local.inserted, [" ", "\n"])
}
func testBackspaceDeletesLocally() {
    let (router, local, _) = makeRouter()
    _ = router.route(.backspace, mode: .local)
    XCTAssertEqual(local.deleteCount, 1)
}
```

- [ ] **Step 2: 執行 `swift test --package-path Packages/RemoteKeyboardCore`，預期 FAIL：`cannot find 'KeyboardActionRouter' in scope`。**
- [ ] **Step 3: 實作 Core 型別與 `route`。** Local 模式只呼叫 local sink；`.remote` 分支在本 Task 一律回傳 `.rejected`（T05 實作）。
- [ ] **Step 4: 執行 `swift test`，預期 4 tests PASS。**
- [ ] **Step 5: 寫 `project.yml`。** target：`RemoteKeyboardApp`（iOS application，embed `RemoteKeyboardExtension`）、`RemoteKeyboardExtension`（iOS app-extension）、`MacReceiver`（macOS application，`LSUIElement: YES`，不開 sandbox）；三者都依賴本地 package。Extension 與 host App 的 `CFBundleVersion`、`CFBundleShortVersionString` 由同一組 setting（`CURRENT_PROJECT_VERSION: 1`、`MARKETING_VERSION: 0.1.0`）提供。Extension `Info.plist`：`NSExtensionPointIdentifier = com.apple.keyboard-service`、`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController`、`RequestsOpenAccess = YES`、`PrimaryLanguage = en-US`、`IsASCIICapable = YES`。host App 與 Extension 加 App Group entitlement `group.com.ansonhui.remotekeyboard`。
- [ ] **Step 6: 實作 `KeyboardViewController` 與 `MinimalKeyboardView`。** 三排 QWERTY、單次 Shift、Backspace、Space、Return；`needsInputModeSwitchKey == true` 時才顯示 🌐，並以 `handleInputModeList(from:with:)` 綁定。`TextSink` 由包裝 `textDocumentProxy` 的 adapter 實作。
- [ ] **Step 7: 實作 `AppGroupProbe`。** host App 按鈕寫入 `UserDefaults(suiteName: "group.com.ansonhui.remotekeyboard")` 鍵 `probe` 為目前時間；Extension 開啟時讀取並在鍵盤角落顯示「AppGroup: OK／NIL」。
- [ ] **Step 8: Run all。** 預期 `xcodegen generate`、`swift test`、iOS 模擬器 build、macOS build 全部 exit 0。
- [ ] **Step 9: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T01-LOCAL.md`：Settings 加入鍵盤，**關閉** Allow Full Access；Notes 輸入 `Hello World` 加 9 個字共 20 字逐字一致；長按 🌐 可切到其他鍵盤；記錄 App Group probe 結果（O3）。若 Personal Team 簽名因 App Group 失敗，移除 entitlement 後重簽，O3 記 FAIL，改走 D3。
- [ ] **Step 10: 更新驗收報告 T01 與 O3，主代理 commit。**

**PASS：** 真機 Notes 20 字正確，無 Full Access 照常輸入，🌐 可切換。**若失敗：** 只保留 Local 鍵盤，先修 entitlement／Info.plist，不加 BLE。

### Task 02: Mac Receiver GATT Advertiser

**Branch:** `t02-mac-gatt`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/GATTServiceSpec.swift`、`Receiver/AdvertisingGate.swift`
- Create: `macOS/MacReceiver/Bluetooth/GATTPeripheralServer.swift`；Modify: `macOS/MacReceiver/MacReceiverApp.swift`、`project.yml`（Mac `NSBluetoothAlwaysUsageDescription`；加 `MacReceiverTests` target 並放入 `MacReceiver` scheme 的 test action）
- Test: `Tests/RemoteKeyboardCoreTests/GATTServiceSpecTests.swift`、`AdvertisingGateTests.swift`、`macOS/MacReceiverTests/AdapterSmokeTests.swift`
- Evidence: `e2e/E2E-T02-GATT.md`

**Interfaces:**
- Produces:
  - `enum GATTServiceSpec`：`static let serviceUUID = "2A6F212A-3B7A-4293-87B4-FAD198077EFB"`、`inputUUID = "92A59A91-80A0-4743-8E65-F297A9B05104"`（write with response）、`ackUUID = "6AEB18CE-45D1-47B8-9F18-96939C182189"`（notify）、`statusUUID = "99FA0347-3B23-498D-A0F0-1EE6B0AAA76E"`（read + notify）。型別為 `String`，Core 不 import CoreBluetooth。
  - `enum PeripheralPower: Sendable { case unknown, poweredOff, unauthorized, unsupported, poweredOn }`
  - `enum AdvertisingGate { static func shouldAdvertise(power: PeripheralPower, serviceAdded: Bool) -> Bool }`
  - `enum GATTServerState: Equatable { case idle, waitingForPower, addingService, advertising, failed(String) }`（`failed` 的字串只放錯誤碼，不放使用者文字）

- [ ] **Step 1: 寫失敗測試**

```swift
func testUniqueUUIDs() {
    let all = [GATTServiceSpec.serviceUUID, .inputUUID, .ackUUID, .statusUUID]
    XCTAssertEqual(Set(all).count, 4)
    all.forEach { XCTAssertNotNil(UUID(uuidString: $0)) }
}
func testAdvertiseWaitsForPoweredOnAndServiceReady() {
    XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .poweredOff, serviceAdded: true))
    XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .poweredOn, serviceAdded: false))
    XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .unauthorized, serviceAdded: true))
    XCTAssertTrue(AdvertisingGate.shouldAdvertise(power: .poweredOn, serviceAdded: true))
}
```

`AdapterSmokeTests.testServiceHasExpectedCharacteristicProperties`：呼叫 `GATTPeripheralServer.makeService()`，斷言 input 含 `.write`、ack 含 `.notify`、status 含 `.read` 與 `.notify`，三者 UUID 與 spec 一致。

- [ ] **Step 2: 執行 `swift test` 與 macOS `xcodebuild test`，預期 FAIL：找不到 `GATTServiceSpec`／`makeService`。**
- [ ] **Step 3: 實作 Core 型別，再實作 `GATTPeripheralServer`。** `static func makeService() -> CBMutableService`；`start()` 建立 `CBPeripheralManager`，`peripheralManagerDidUpdateState` 轉成 `PeripheralPower`，`didAdd` 後依 `AdvertisingGate` 呼叫 `startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID], CBAdvertisementDataLocalNameKey: "RemoteKeyboard"])`；`stop()` 停止廣播並移除 service；`state` 以 `@Published` 給 menu bar 顯示。
- [ ] **Step 4: Run all（含 macOS adapter 測試），全部 PASS。**
- [ ] **Step 5: 實機驗收（使用者，標 TBD）。** 以 Personal Team 簽名執行 Receiver，允許 Bluetooth；iPhone 安裝 BLE 掃描 App（例如 nRF Connect），截圖顯示 service UUID 與 3 個 characteristic 屬性；menu bar 顯示 `advertising`。
- [ ] **Step 6: 更新驗收報告 T02，主代理 commit。**

**PASS：** iPhone 掃描到完整 service 與 3 個 characteristic。**若失敗：** 記錄 delegate 回傳的 state，對照 Apple BLE sample。

### Task 03: Extension BLE Central 冷連線

**Branch:** `t03-extension-central`（T02 merge 後開始）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/ConnectionStateMachine.swift`、`Shared/DiagnosticEvent.swift`
- Create: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLECentral.swift`；Modify: `KeyboardViewController.swift`、`MinimalKeyboardView.swift`（狀態列）、`iOS/RemoteKeyboardApp/RemoteKeyboardApp.swift`（「允許 Bluetooth」按鈕）、`project.yml`（host App 與 Extension 加 `NSBluetoothAlwaysUsageDescription`）
- Test: `Tests/RemoteKeyboardCoreTests/ConnectionStateMachineTests.swift`、`DiagnosticEventTests.swift`
- Evidence: `e2e/E2E-T03-CENTRAL.md`

**Interfaces:**
- Consumes: `GATTServiceSpec`（T02）
- Produces:
  - `enum CentralPower: Sendable { case unknown, poweredOff, unauthorized, unsupported, poweredOn }`
  - `enum ConnectionState: Equatable, Sendable { case idle, unavailable(CentralPower), scanning, connecting, discovering, ready, failed(FailureReason) }`；`enum FailureReason: Equatable, Sendable { case timeout, disconnected, serviceMissing }`
  - `enum ConnectionInput: Equatable { case keyboardAppeared, keyboardDisappeared, power(CentralPower), discovered(peripheralID: UUID), connected(UUID), servicesReady(UUID), disconnected(UUID), timeout }`
  - `enum ConnectionEffect: Equatable { case startScan, stopScan, connect(UUID), discoverServices(UUID), cancel(UUID), startTimeout(seconds: Double) }`
  - `struct ConnectionStateMachine { private(set) var state: ConnectionState; mutating func handle(_ input: ConnectionInput) -> [ConnectionEffect] }`；連線逾時固定 `5.0` 秒。
  - `enum DiagnosticEvent: Equatable, Sendable { case stateChanged(ConnectionState), keySent(kind: String, utf8Length: Int), ackReceived(result: String), reconnectSample(shownAtMs: Int64, readyAtMs: Int64?) }`；`kind` 只能是 `"text" / "backspace" / "return"`；`func log()` 以 OSLog `privacy: .public` 輸出這些欄位。

- [ ] **Step 1: 寫失敗測試**

```swift
func testKeyboardAppearStartsScanWhenPoweredOn() {
    var m = ConnectionStateMachine()
    _ = m.handle(.power(.poweredOn))
    XCTAssertEqual(m.handle(.keyboardAppeared), [.startScan, .startTimeout(seconds: 5.0)])
    XCTAssertEqual(m.state, .scanning)
}
func testHappyPathReachesReady() {
    var m = poweredOnAppeared(); let p = UUID()
    XCTAssertEqual(m.handle(.discovered(peripheralID: p)), [.stopScan, .connect(p)])
    XCTAssertEqual(m.handle(.connected(p)), [.discoverServices(p)])
    _ = m.handle(.servicesReady(p)); XCTAssertEqual(m.state, .ready)
}
func testBluetoothOffTransitionsToUnavailable() {
    var m = poweredOnAppeared(); _ = m.handle(.power(.poweredOff))
    XCTAssertEqual(m.state, .unavailable(.poweredOff))
}
func testUnauthorizedTransitionsToUnavailable() {
    var m = ConnectionStateMachine(); _ = m.handle(.power(.unauthorized))
    XCTAssertEqual(m.handle(.keyboardAppeared), [])
    XCTAssertEqual(m.state, .unavailable(.unauthorized))
}
func testReappearDoesNotReuseStalePeripheral() {
    var m = readyMachine(peripheral: old)
    XCTAssertEqual(m.handle(.keyboardDisappeared), [.cancel(old)])
    XCTAssertEqual(m.handle(.keyboardAppeared), [.startScan, .startTimeout(seconds: 5.0)])
}
func testTimeoutFails() { var m = poweredOnAppeared(); _ = m.handle(.timeout); XCTAssertEqual(m.state, .failed(.timeout)) }
func testDiagnosticEventCarriesNoText() {
    let e = DiagnosticEvent.keySent(kind: "text", utf8Length: 6)
    XCTAssertFalse(String(describing: e).contains("香港"))
}
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL：找不到 `ConnectionStateMachine`。**
- [ ] **Step 3: 實作狀態機與 `DiagnosticEvent`。** 已 `ready` 或 `connecting` 時再收到 `keyboardAppeared` 回傳 `[]`（防重複連線，T06 依賴此行為）。
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作 `KeyboardBLECentral`。** 持有 `CBCentralManager`（`queue: nil`）與 `ConnectionStateMachine`；delegate 轉成 `ConnectionInput`，effect 轉成 CoreBluetooth 呼叫；`scanForPeripherals(withServices: [serviceUUID])`；`viewWillAppear` 送 `keyboardAppeared`，`viewWillDisappear` 送 `keyboardDisappeared`。狀態列顯示 `ConnectionState`，並設 `accessibilityIdentifier = "rk.status"`、`accessibilityValue` 為 state 名稱（T06 使用）。
- [ ] **Step 6: host App 加「允許 Bluetooth」按鈕**，建立一次 `CBCentralManager` 觸發系統授權提示並顯示結果。
- [ ] **Step 7: Run all，全部 exit 0。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T03-CENTRAL.md` 記錄 O4 矩陣：host App 授權（有／無）× Full Access（開／關）共 4 格，每格記錄 Extension 狀態列最終值。先強制關閉 host App，再分別在 Notes 與 Safari 叫出鍵盤，錄影顯示 `scanning → connecting → discovering → ready`。
- [ ] **Step 9: 更新驗收報告 T03 與 O4，主代理 commit。**

**PASS：** Notes 與 Safari 中 Extension 均到達 `ready`，host App 不在前景。**若失敗：** 記錄 4 格矩陣與 console，依 D8 啟動 LAN WebSocket 限時 PoC，暫停 UI 工作。

### Task 04: Mac 焦點守衛、輸入法切換與 Unicode 注入

**Branch:** `t04-mac-inject`（可與 T03 平行；兩者不改同一檔案，`project.yml` 由主代理合併）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/FocusGuard.swift`、`Receiver/UnicodeChunker.swift`、`Receiver/InputSourceSwitcher.swift`
- Create: `macOS/MacReceiver/Focus/FocusMonitor.swift`、`Input/TextInjector.swift`、`Input/TISInputSourceController.swift`；Modify: `MacReceiverApp.swift`（「Test Insert」選單與焦點狀態）
- Test: `Tests/RemoteKeyboardCoreTests/FocusGuardTests.swift`、`UnicodeChunkerTests.swift`、`InputSourceSwitcherTests.swift`
- Evidence: `e2e/E2E-T04-INJECT.md`

**Interfaces:**
- Produces:
  - `struct FocusSnapshot: Equatable, Sendable { let axTrusted: Bool; let frontmostPID: Int32; let appName: String?; let editable: Bool; let epoch: UInt64 }`
  - `enum InjectionDecision: Equatable { case allow, notAuthorized, noFocus, staleFocus }`
  - `enum FocusGuard { static func authorize(eventEpoch: UInt64?, current: FocusSnapshot?) -> InjectionDecision }`：判斷順序為 `current == nil || !axTrusted` → `.notAuthorized`；`!editable` → `.noFocus`；`eventEpoch != nil && eventEpoch != current.epoch` → `.staleFocus`；否則 `.allow`。
  - `enum UnicodeChunker { static let defaultMaxUTF16 = 20; static func chunks(_ text: String, maxUTF16: Int = defaultMaxUTF16) -> [String] }`：以 `Character` 為單位累積，加入下一個 Character 會超過上限時先輸出目前段；單一 Character 超過上限時自成一段。
  - `protocol InputSourceControlling { func currentID() -> String; func select(_ id: String) -> Bool }`
  - `enum SwitchResult: Equatable { case injected, switchFailed }`
  - `struct InputSourceSwitcher { static let asciiID = "com.apple.keylayout.ABC"; init(controller: InputSourceControlling, settle: @escaping (Double) async -> Void); func withASCII(settleSeconds: Double, _ inject: () -> Void) async -> SwitchResult }`：目前已是 ABC 則直接注入且不切換；否則 `select(asciiID)`，再以 `currentID()` 驗證，不是 ABC 回傳 `.switchFailed` 且不注入；注入後 `await settle(settleSeconds)` 才切回原 ID。`settleSeconds` 預設 `0.05`，實際值由 Step 8 量測後寫回 spec §5。

- [ ] **Step 1: 寫失敗測試**

```swift
func testAXUntrustedRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(ax: false)), .notAuthorized) }
func testNoEditableFocusRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(editable: false)), .noFocus) }
func testEpochChangedRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(epoch: 2)), .staleFocus) }
func testMatchingEpochAllows() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 2, current: snap(epoch: 2)), .allow) }

func testChunkerNeverSplitsGraphemeCluster() {
    let family = "👨‍👩‍👧‍👦"                       // 11 UTF-16 units
    let chunks = UnicodeChunker.chunks(family + family, maxUTF16: 20)
    XCTAssertEqual(chunks, [family, family])
}
func testChunkerKeepsCombiningAccent() { XCTAssertEqual(UnicodeChunker.chunks("cafe\u{301}", maxUTF16: 4), ["caf", "e\u{301}"]) }
func testChunkerJoinsBackToOriginal() {
    let s = "繁體中文，標點：「你好嗎？」👨‍👩‍👧‍👦 café"
    XCTAssertEqual(UnicodeChunker.chunks(s).joined(), s)
    XCTAssertTrue(UnicodeChunker.chunks(s).allSatisfy { $0.utf16.count <= 20 })
}

func testAlreadyABCDoesNotSwitch() async   // fake.current = ABC → result .injected, fake.selected == []
func testSwitchesAndRestores() async       // current = Zhuyin → selected == [ABC, Zhuyin], injected once
func testVerifyFailureDoesNotInject() async // select returns true 但 current 仍是 Zhuyin → .switchFailed，injected 0 次，selected 最後一筆不是 ABC
func testRestoreHappensAfterSettleDelay() async // 記錄順序 == ["select:ABC", "inject", "settle:0.05", "select:Zhuyin"]
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL：找不到 `FocusGuard`。**
- [ ] **Step 3: 實作三個 Core 型別。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作 macOS adapter。** `FocusMonitor`：`AXIsProcessTrustedWithOptions` 提示授權；監聽 `NSWorkspace.didActivateApplicationNotification`，並每 250 ms 讀取 `kAXFocusedUIElementAttribute`；frontmost PID 或焦點元素改變時 `epoch += 1`；`editable` 以 role 屬於 `AXTextField / AXTextArea / AXComboBox / AXSearchField` 或 `kAXValueAttribute` 可設定判斷。`TextInjector`：每段建立 keyDown／keyUp `CGEvent(virtualKey: 0)` 並 `keyboardSetUnicodeString`，post 到 `.cghidEventTap`；Backspace 用 virtualKey 51、Return 用 36。`TISInputSourceController` 以 `TISCopyCurrentKeyboardInputSource`、`TISCreateInputSourceList`、`TISSelectInputSource` 實作 protocol。
- [ ] **Step 6: Menu bar「Test Insert」**：選擇字串後倒數 3 秒，期間使用者點進 TextEdit；經 `FocusGuard`（`eventEpoch: nil`）→ `InputSourceSwitcher` → `TextInjector` 注入；選單顯示焦點狀態（App 名稱、editable、epoch）。
- [ ] **Step 7: Run all（含 macOS adapter 測試），全部 PASS。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** TextEdit 依序插入 `A`、`Hello`、`香港`、`👨‍👩‍👧‍👦`、`café` 逐字一致；切到注音後重複 `香港` 20 次，記錄失敗次數，失敗時把 settle 調高到 0.1、0.2 秒重測並記錄；倒數中切到 Finder 桌面、Spotlight、關閉文件，0 誤注入；以 30 個字元字串測出 CGEvent 單一事件上限（O5）。
- [ ] **Step 9: 更新驗收報告 T04 與 O5、spec §5 寫入實測 settle 值，主代理 commit。**

**PASS：** 5 組字串完全一致，注音狀態 20/20，非可編輯焦點 0 誤注入。**若失敗：** 測 AXValue 寫入作對照；無法可靠注入時停用，不貼到其他欄位。

### Task 05: 端到端 A 鍵 PoC

**Branch:** `t05-e2e-a-key`（T03、T04 merge 後開始）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/KeyboardEvent.swift`、`Shared/ReceiverStatus.swift`；Modify: `Keyboard/KeyAction.swift`（移出 `EventKind`）、`Keyboard/KeyboardActionRouter.swift`、`Shared/KeyboardMode.swift`
- Modify: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLECentral.swift`（write input、subscribe ack 與 status）、`KeyboardViewController.swift`、`MinimalKeyboardView.swift`（模式切換鍵、`Mac → App` 狀態列）
- Modify: `macOS/MacReceiver/Bluetooth/GATTPeripheralServer.swift`（接收 input、回 ack、推送 status）
- Test: `Tests/RemoteKeyboardCoreTests/EventCodecTests.swift`、`KeyboardModeTests.swift`、擴充 `KeyboardActionRouterTests.swift`
- Evidence: `e2e/E2E-T05-A-KEY.md`

**Interfaces:**
- Consumes: `FocusGuard`、`InputSourceSwitcher`、`TextInjector`（T04）；`KeyboardBLECentral`、`ConnectionState`（T03）
- Produces:
  - `enum EventKind: Codable, Equatable, Sendable { case text(String), backspace, returnKey, ping(shownAtMs: Int64, readyAtMs: Int64) }`
  - `struct KeyboardEvent: Codable, Equatable, Sendable { static let currentVersion = 1; let protocolVersion: Int; let eventId: UUID; let sessionId: UUID; let seq: UInt64; let focusEpoch: UInt64?; let kind: EventKind }`
  - `enum EventCodecError: Error, Equatable { case unsupportedVersion(Int), tooLarge(Int), malformed }`
  - `enum EventCodec { static func encode(_ e: KeyboardEvent, maxBytes: Int) throws -> Data; static func decode(_ d: Data) throws -> KeyboardEvent }`：M1 用 `JSONEncoder`（sortedKeys）；超過 `maxBytes`（呼叫端傳 `maximumWriteValueLength(for: .withResponse)`）丟 `.tooLarge`。分包在 T07。
  - `struct ReceiverStatus: Codable, Equatable { let ready: Bool; let appName: String?; let focusEpoch: UInt64 }`；`struct Ack: Codable, Equatable { let eventId: UUID; let result: AckResult }`；`enum AckResult: String, Codable { case posted, notAuthorized, noFocus, staleFocus, switchFailed, malformed }`
  - `enum ModeResolver { static func effectiveMode(saved: KeyboardMode, hasFullAccess: Bool) -> KeyboardMode }`
  - Router 擴充：`init(local:remote:isRemoteReady: @escaping () -> Bool)`；`.remote` 且 ready → `enqueue` 並回傳 `.enqueuedRemote`，local sink 0 次；`.remote` 且未 ready → `.rejected`（M1 暫行行為；D6 草稿列於 T10 實作）；`.toggleMode` → `.modeToggled(mode == .local ? .remote : .local)`，不呼叫任何 sink。

- [ ] **Step 1: 寫失敗測試**

```swift
func testTapAProducesOneRemoteSemanticEvent() {
    let (router, local, remote) = makeRouter(ready: true)
    XCTAssertEqual(router.route(.character("A"), mode: .remote), .enqueuedRemote)
    XCTAssertEqual(remote.events, [.text("A")]); XCTAssertEqual(local.inserted, [])
}
func testRemoteNotReadyRejectsWithoutLocalFallback() {
    let (router, local, remote) = makeRouter(ready: false)
    XCTAssertEqual(router.route(.character("A"), mode: .remote), .rejected)
    XCTAssertEqual(remote.events, []); XCTAssertEqual(local.inserted, [])
}
func testSavedRemoteFallsBackToLocalWithoutFullAccess() {
    XCTAssertEqual(ModeResolver.effectiveMode(saved: .remote, hasFullAccess: false), .local)
    XCTAssertEqual(ModeResolver.effectiveMode(saved: .remote, hasFullAccess: true), .remote)
}
func testTextARoundTrip() throws {
    let e = KeyboardEvent(protocolVersion: 1, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 7, kind: .text("A"))
    XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 512)), e)
}
func testRejectsUnknownVersion() throws   // protocolVersion 2 → .unsupportedVersion(2)
func testRejectsTooLarge()                // .text(String(repeating: "香", count: 400)), maxBytes 512 → .tooLarge
func testMalformedDataRejected()          // Data("{".utf8) → .malformed
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL。**
- [ ] **Step 3: 實作 Core 型別與 router 擴充。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 接上兩端。** Receiver：`didReceiveWrite` → `EventCodec.decode` → `FocusGuard.authorize(eventEpoch: event.focusEpoch, current: monitor.snapshot)` → `InputSourceSwitcher` → `TextInjector`，以 ack characteristic notify `Ack`；status 在 epoch 或 ready 改變時 notify。Extension：訂閱 status 並把最新 `focusEpoch` 放進每個事件；`seq` 每個 session 從 1 遞增；Ack 結果以 `DiagnosticEvent.ackReceived` 記錄並在狀態列短暫顯示。模式以 `UserDefaults.standard` 鍵 `rk.mode` 保存，載入時經 `ModeResolver`（`hasFullAccess` 取 `UIInputViewController.hasFullAccess`）。
- [ ] **Step 6: Run all，全部 exit 0。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** `T05-E2E-A-01`：Notes → Mac TextEdit 按 `A` 20 次；`T05-E2E-A-02`：Safari → TextEdit 20 次；每次錄影，不得用主 App 代打。另做 5 次「按下 A 前 1 秒內 Cmd-Tab 到 Finder」，Mac 不得出現字元，ack 為 `staleFocus` 或 `noFocus`。關閉 Full Access 後重開鍵盤，確認回到 Local 可打字。
- [ ] **Step 8: 更新驗收報告 T05，主代理 commit。**

**PASS：** 兩組各 20/20，錯焦點 0 次。**Gate 1：** 失敗即停止 T10–T12 的完整 UI，改依 D8 驗證 LAN 傳輸；任何 Extension 傳輸都失敗時重新確認產品方向。

### Task 06: BLE 生命週期與重連 Gate

**Branch:** `t06-reconnect-gate`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/ReconnectStats.swift`
- Create: `iOS/RemoteKeyboardUITests/ReconnectUITests.swift`、`macOS/MacReceiver/Diagnostics/ReconnectLog.swift`；Modify: `KeyboardBLECentral.swift`（ready 後送 `.ping`）、`GATTPeripheralServer.swift`（收到 ping 寫 CSV，不注入）、`project.yml`（加 `RemoteKeyboardUITests` target 並放入 `RemoteKeyboardApp` scheme 的 test action）
- Test: `Tests/RemoteKeyboardCoreTests/ReconnectStatsTests.swift`、擴充 `ConnectionStateMachineTests.swift`
- Evidence: `e2e/E2E-T06-RECONNECT.md`

**Interfaces:**
- Consumes: `ConnectionStateMachine`（T03）、`EventKind.ping`（T05）
- Produces:
  - `struct ReconnectSample: Equatable, Sendable { let shownAtMs: Int64; let readyAtMs: Int64? }`（`readyAtMs == nil` 表示 10 秒內未 ready）
  - `struct ReconnectSummary: Equatable { let attempts: Int; let successes: Int; let p95Ms: Int64? }`
  - `enum ReconnectStats { static func summarize(_ samples: [ReconnectSample]) -> ReconnectSummary }`：P95 只計成功樣本，採 nearest-rank：排序後取第 `ceil(0.95 × n)` 個（1-based）。

- [ ] **Step 1: 寫失敗測試**

```swift
func testP95NearestRank() {
    let s = (1...100).map { ReconnectSample(shownAtMs: 0, readyAtMs: Int64($0)) }
    XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 100, successes: 100, p95Ms: 95))
}
func testFailuresExcludedFromP95() {
    let s = [ReconnectSample(shownAtMs: 0, readyAtMs: 100), ReconnectSample(shownAtMs: 0, readyAtMs: nil)]
    XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 2, successes: 1, p95Ms: 100))
}
func testNoSuccessHasNilP95() { XCTAssertNil(ReconnectStats.summarize([ReconnectSample(shownAtMs: 0, readyAtMs: nil)]).p95Ms) }
func testRepeatedAppearRestartsFromIdle()      // 20 次 appear/disappear 循環，每次 appear 都回傳 [.startScan, .startTimeout(seconds: 5.0)]
func testNoDuplicateConnectOnRapidAppear()     // connecting 狀態連續兩次 appear → 第二次回傳 []
func testBluetoothStateReset()                 // ready → power(.poweredOff) → power(.poweredOn) 且鍵盤仍顯示 → [.startScan, .startTimeout(seconds: 5.0)]
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL。**
- [ ] **Step 3: 實作 `ReconnectStats` 並修正狀態機使三個新測試通過。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作 ping 與 CSV。** Extension 在 `viewWillAppear` 記 `shownAtMs`，到 `ready` 時記 `readyAtMs` 並送 `.ping`；Receiver 收到 ping 只寫一行 `shownAtMs,readyAtMs,latencyMs` 到 `~/Library/Logs/RemoteKeyboard/reconnect.csv`，不經注入流程。
- [ ] **Step 6: 實作 `ReconnectUITests.testHundredReopens`。** `XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")` 與 `"com.apple.mobilesafari"` 交替：點文字欄位叫出鍵盤，記 `shownAt`，等待 `rk.status` 的 value 變成 `ready`（逾時 10 秒），記 `readyAt`，收起鍵盤；共 100 次，結果以 CSV 附加到 xcresult。若第一次就找不到 `rk.status`（O6 FAIL），test 以 `XCTSkip("O6: third-party keyboard not reachable")` 結束。
- [ ] **Step 7: Run all，全部 exit 0；UI test 只編譯，不在模擬器執行。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 真機執行 `xcodebuild test -scheme RemoteKeyboardApp -only-testing:RemoteKeyboardUITests/ReconnectUITests -destination "platform=iOS,id=$IOS_DEVICE_ID"`；使用者另外親手抽查 10 次並錄影。O6 FAIL 時改為使用者親手做 100 次，數據取 Mac CSV（失敗次數 = 100 − CSV 行數）。另各做 5 次：iPhone 藍牙關再開、Mac 睡眠 1 分鐘後喚醒、鍵盤顯示中強制關閉 host App。
- [ ] **Step 9: 以 `ReconnectStats` 計算結果，更新驗收報告 T06 與 O6，主代理 commit。**

**PASS：** 100 次中 ≥ 99 次 ready，P95 ≤ 2000 ms（Mac 醒著、同一房間、已有連線紀錄）。**Gate 2：** 未達標不得宣稱「任何 App 叫出鍵盤即可連線」；先調整重試與逾時，必要時依 D8 評估 LAN。

---

## M2–M5 任務（M1 Gate 通過後再細化）

| Task | 名稱 | v1.1 調整 |
|---|---|---|
| T07 | 協定分幀、UTF-8 與事件流 | 取代 T05 的 JSON 單包；`maxBytes` 改由實際 MTU 決定 |
| T08 | ACK、去重、排序、失敗語義 | 草稿送出（D6）沿用同一套 seq／eventId 去重 |
| T09 | 配對、隱私與 Local／Remote 模式 | 依 O3 結果選擇主 App 配對或 D3 鍵盤內 6 位配對碼；status characteristic 的 `appName` 只對已配對裝置提供 |
| T10 | 原生風格英文 QWERTY | 加入 D5 常駐狀態列與 D6 草稿列，取代 T05 的未就緒 `.rejected` |
| T11 | 數字 123／符號 #+= | 無變更 |
| T12 | 繁體中文手寫與候選字 | 開始前先完成 O7（`PKStrokeRecognizer` 官方查證） |
| T13 | 語音聽寫 Gate | 依 D7：系統麥克風加 context diff；失敗改主 App 手動語音頁。可在 T01 後先做探測 |
| T14 | 跨 App 相容性與焦點安全矩陣 | 加入輸入法狀態（ABC、注音、倉頡、粵拼）× Mac App 的注入矩陣 |
| T15 | 穩定性、權限、Wi-Fi 降級 | D8：僅 BLE 證實不可行才做 LAN；校園 Wi-Fi 隔離時用 iPhone 熱點 |
| T16 | Release Candidate QA | D1：以自用與展示為目標；App Store 審查另立 |

**依賴：** T01 → T02 → T03；T04 可與 T03 平行 → T05 → T06。M2 需 T05 PASS。

**計劃狀態：** v1.1 DRAFT，待使用者審核；尚未有任何 build 或實機結果。
