# Remote Keyboard Implementation Plan v1.2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 M1：證明 iPhone 第三方 Keyboard Extension 可經 BLE GATT 把按鍵送進 Mac TextEdit 的目前焦點，並在鍵盤反覆重開後穩定重連。

**Architecture:** 傳輸採 D11 角色對調：iPhone Keyboard Extension 為 GATT Peripheral（notify 送事件），Mac Receiver 為 Central（掃描、連入、write 回 ACK 與狀態）。一個 Swift Package `RemoteKeyboardCore` 放所有純邏輯（路由、狀態機、焦點守衛、輸入法切換流程、編碼、統計），以 `swift test` 驗證；iOS Extension、iOS host App、macOS Receiver 只做 UIKit／SwiftUI／CoreBluetooth／AX／CGEvent／TIS 的薄 adapter。Xcode project 由 XcodeGen 從 `project.yml` 產生。

**Tech Stack:** Xcode 27.1、Swift 6.4（language mode 6）、XcodeGen 2.46.0、UIKit `UIInputViewController`、SwiftUI、CoreBluetooth、ApplicationServices（AXUIElement）、CoreGraphics（CGEvent）、Carbon TIS、OSLog、XCTest／XCUITest。

**Spec:** `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（v1.2 APPROVED，設計決定見 §12 D1–D13）。

**範圍：** T01、T02 已完成。v1.2 依 D11 重寫 T03（拆成 T03a、T03b）、T05、T06；T04 不受影響。舊 T03（iPhone 為 Central）實機失敗，branch `t03-extension-central` 封存不 merge。T07–T16 保留任務定義與 v1.1 調整，於 M1 Gate 通過後再以 writing-plans 細化。v1.0 原文見 `docs/archive/planning-package-v1.0/RemoteKeyboard-Superpowers-v1-Implementation-Plan.md`。

## Global Constraints

- 不採用 Bluetooth HID；主傳輸為自訂 BLE GATT，Mac 安裝 Receiver。
- D11／D12：iPhone 發佈 service `706AA642-68A3-41FA-889D-24E30709B0D0`，`event` `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`（notify）、`control` `320468E2-53B6-4B6A-88EC-AE2752415818`（write with response）；Mac 只走掃描路徑；notify 不超過 `maximumUpdateValueLength`，佇列滿時暫存不丟。
- D13：Mac Receiver 登入時啟動並常駐；平時待命，點擊可編輯輸入框才開始掃描連線；`ReceiverSession.idleTimeout = 1800` 秒無活動自動停止，收到事件或再點輸入框即延長；焦點離開輸入框不斷線。
- Peripheral 只在鍵盤可見且有 Full Access 時廣播；T09 前 Mac 連入任何廣播此 service 的 iPhone，僅供開發。
- 依使用者守則不刪 source：T02 的 `GATTPeripheralServer` 保留但不再啟動。
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
- 模擬器沒有 CoreBluetooth：T03a、T03b、T05、T06 的驗收只能用實體 iPhone（iPhone 17 Pro，UDID `00008150-000C65DA26C0401C`）。

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
4. **Bluetooth 權限被拒或未開 Full Access**：鍵盤必須顯示狀態、不 crash，Local 照常打字。由 T03a 的 `testUnauthorizedPowerShowsUnavailableAndNoEffects`、`testAppearWithoutFullAccessDoesNothing` 與 O4 矩陣覆蓋。
5. **notify 佇列滿時丟字**：快速連按時 `updateValue` 回傳 `false`，事件必須依序暫存再送。由 T05 的 `testDrainStopsWhenSendReturnsFalseAndKeepsOrder` 覆蓋。
6. **切段時拆開 grapheme**：ZWJ emoji 或組合重音被 CGEvent 長度上限切開會變亂碼。由 T04 的 `testChunkerNeverSplitsGraphemeCluster` 覆蓋。

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
    Shared/ControlMessage.swift               Mac → iPhone 的 ACK 與狀態
    Keyboard/KeyboardLinkStateMachine.swift   iPhone Peripheral 狀態機（純 reducer）
    Keyboard/NotifyQueue.swift                notify 佇列（滿時暫存）
    Keyboard/ReconnectStats.swift             成功率與 P95
    Receiver/AdvertisingGate.swift            何時可以廣播（T02，現由 iPhone 端沿用 PeripheralPower）
    Receiver/ReceiverLinkStateMachine.swift   Mac Central 狀態機（純 reducer）
    Receiver/FocusGuard.swift                 FocusSnapshot、InjectionDecision
    Receiver/UnicodeChunker.swift             依 grapheme 切段
    Receiver/InputSourceSwitcher.swift        切 ABC、驗證、注入、延遲、切回
  Tests/RemoteKeyboardCoreTests/              每個 Source 檔一個對應測試檔
iOS/RemoteKeyboardApp/
  RemoteKeyboardApp.swift                     SwiftUI：安裝教學、Bluetooth 授權按鈕、診斷
  AppGroupProbe.swift                         寫入／讀取 App Group 測試值（O3）
iOS/RemoteKeyboardExtension/
  Info.plist                                  keyboard-service、RequestsOpenAccess=YES
  KeyboardViewController.swift                組裝 view、router、peripheral
  MinimalKeyboardView.swift                   M1 用的簡易 QWERTY（原生風格在 T10）
  Bluetooth/KeyboardBLEPeripheral.swift       CBPeripheralManager adapter
iOS/RemoteKeyboardUITests/ReconnectUITests.swift   T06 自動 100 次
macOS/MacReceiver/
  MacReceiverApp.swift                        MenuBarExtra：BLE 狀態、焦點狀態、Test Insert
  Bluetooth/ReceiverBLECentral.swift          CBCentralManager adapter
  Bluetooth/GATTPeripheralServer.swift        T02 產物，保留不啟動
  Focus/FocusMonitor.swift                    AX + NSWorkspace，產生 FocusSnapshot
  Input/TextInjector.swift                    CGEvent Unicode／Backspace／Return
  Input/TISInputSourceController.swift        Carbon TIS adapter
  Diagnostics/ReconnectLog.swift              寫 ~/Library/Logs/RemoteKeyboard/reconnect.csv
macOS/MacReceiverTests/AdapterSmokeTests.swift
e2e/E2E-T01-LOCAL.md、E2E-T02-GATT.md、E2E-T03A-PERIPHERAL.md、E2E-T03B-LINK.md、E2E-T04-INJECT.md、E2E-T05-A-KEY.md、E2E-T06-RECONNECT.md
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
| iOS 真機 build | `xcodebuild build -project RemoteKeyboard.xcodeproj -scheme RemoteKeyboardApp -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet` | exit 0 |
| 空白檢查 | `git diff --check` | 無輸出 |

以下各 Task 的「Run all」即依序執行上表全部指令（macOS adapter 測試需 `-allowProvisioningUpdates`）。

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

### Task 03a: iPhone 鍵盤 BLE Peripheral

**Branch:** `t03a-keyboard-peripheral`（由 main 開出）

**Files:**
- Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/GATTServiceSpec.swift`（新增 `Link`）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/KeyboardLinkStateMachine.swift`、`Shared/DiagnosticEvent.swift`
- Create: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`；Modify: `KeyboardViewController.swift`、`MinimalKeyboardView.swift`（`rk.status` 狀態列）、`iOS/RemoteKeyboardApp/RemoteKeyboardApp.swift`（「允許藍牙」按鈕）、`project.yml`（host App 與 Extension 的 `NSBluetoothAlwaysUsageDescription`）
- Test: `Tests/RemoteKeyboardCoreTests/KeyboardLinkStateMachineTests.swift`、`DiagnosticEventTests.swift`
- Evidence: `e2e/E2E-T03A-PERIPHERAL.md`

**可重用來源（唯讀取用）：** `git show t03-extension-central:<path>` 取 `DiagnosticEvent.swift`、host App 藍牙按鈕、`project.yml` 藍牙字串與狀態列寫法；`git show spike-role-reversal:iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheralProbe.swift` 取 Peripheral 寫法。兩條 branch 不 merge。

**Interfaces:**
- Consumes: `PeripheralPower`（T02）
- Produces:
  - `GATTServiceSpec.Link`：`serviceUUID = "706AA642-68A3-41FA-889D-24E30709B0D0"`、`eventUUID = "C7FC0313-53E7-4DCD-B75F-2AE66FE9C586"`（notify）、`controlUUID = "320468E2-53B6-4B6A-88EC-AE2752415818"`（write with response）
  - `enum LinkFailure: Equatable, Sendable { case addService, advertise }`
  - `enum KeyboardLinkState: Equatable, Sendable { case idle, noFullAccess, unavailable(PeripheralPower), publishing, advertising, connected, failed(LinkFailure) }`
  - `enum KeyboardLinkInput: Equatable { case appeared(hasFullAccess: Bool), disappeared, power(PeripheralPower), serviceAdded(ok: Bool), advertisingStarted(ok: Bool), subscribed, unsubscribed }`
  - `enum KeyboardLinkEffect: Equatable { case addService, startAdvertising, stopAdvertising, removeServices }`
  - `struct KeyboardLinkStateMachine { private(set) var state: KeyboardLinkState; mutating func handle(_ input: KeyboardLinkInput) -> [KeyboardLinkEffect] }`：鍵盤可見且 poweredOn 才發佈；Mac 訂閱 `event` 即 `connected` 並停止廣播；取消訂閱回到廣播；收起鍵盤停止廣播並移除 service。
  - `enum DiagnosticKeyKind: String, Sendable { case text, backspace, `return` }`；`enum DiagnosticEvent: Equatable, Sendable { case keyboardLink(KeyboardLinkState), receiverLink(String), keySent(kind: DiagnosticKeyKind, utf8Length: Int), ackReceived(AckCode), reconnectSample(shownAtMs: Int64, connectedAtMs: Int64?) }`；`AckCode` 先定義為 `enum AckCode: String, Sendable { case posted, notAuthorized, noFocus, staleFocus, switchFailed, malformed }`（T05 沿用）。`receiverLink` 的字串只能是狀態名稱。

- [ ] **Step 1: 寫失敗測試**

```swift
func testAppearWithoutFullAccessDoesNothing() {
    var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.poweredOn))
    XCTAssertEqual(m.handle(.appeared(hasFullAccess: false)), [])
    XCTAssertEqual(m.state, .noFullAccess)
}
func testAppearPoweredOnPublishesThenAdvertises() {
    var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.poweredOn))
    XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [.addService])
    XCTAssertEqual(m.handle(.serviceAdded(ok: true)), [.startAdvertising])
    _ = m.handle(.advertisingStarted(ok: true)); XCTAssertEqual(m.state, .advertising)
}
func testAppearBeforePowerPublishesWhenPoweredOn() {
    var m = KeyboardLinkStateMachine()
    XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [])
    XCTAssertEqual(m.handle(.power(.poweredOn)), [.addService])
}
func testSubscribeConnectsAndStopsAdvertising() {
    var m = advertisingMachine()
    XCTAssertEqual(m.handle(.subscribed), [.stopAdvertising]); XCTAssertEqual(m.state, .connected)
}
func testUnsubscribeResumesAdvertising() {
    var m = connectedMachine()
    XCTAssertEqual(m.handle(.unsubscribed), [.startAdvertising]); XCTAssertEqual(m.state, .advertising)
}
func testDisappearStopsAndRemoves() {
    var m = connectedMachine()
    XCTAssertEqual(m.handle(.disappeared), [.stopAdvertising, .removeServices]); XCTAssertEqual(m.state, .idle)
}
func testUnauthorizedPowerShowsUnavailableAndNoEffects() {
    var m = KeyboardLinkStateMachine(); _ = m.handle(.power(.unauthorized))
    XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), [])
    XCTAssertEqual(m.state, .unavailable(.unauthorized))
}
func testPowerOffWhileConnectedThenOnRepublishes() {
    var m = connectedMachine(); _ = m.handle(.power(.poweredOff))
    XCTAssertEqual(m.state, .unavailable(.poweredOff))
    XCTAssertEqual(m.handle(.power(.poweredOn)), [.addService])
}
func testServiceAddFailureFails() { var m = publishingMachine(); _ = m.handle(.serviceAdded(ok: false)); XCTAssertEqual(m.state, .failed(.addService)) }
func testDuplicateAppearIgnored() { var m = advertisingMachine(); XCTAssertEqual(m.handle(.appeared(hasFullAccess: true)), []) }
func testDiagnosticEventCarriesNoText() { XCTAssertFalse(String(describing: DiagnosticEvent.keySent(kind: .text, utf8Length: 6)).contains("香港")) }
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL：找不到 `KeyboardLinkStateMachine`。**
- [ ] **Step 3: 實作 `GATTServiceSpec.Link`、狀態機與 `DiagnosticEvent`。** `failed` 之後收到 `disappeared` 回到 `idle`。
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作 `KeyboardBLEPeripheral`。** `@MainActor`；第一次 `viewWillAppear` 且 `hasFullAccess` 時才建立 `CBPeripheralManager(delegate:queue: nil)`；service 含 `event`（`.notify`，permissions 空，`value: nil`）與 `control`（`.write`，`.writeable`）；`didReceiveWrite` 一律回 `.success`（內容在 T05 處理）；`didSubscribeTo`／`didUnsubscribeFrom` 只認 `event` characteristic；effect 對應 `add`／`startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Link.serviceUUID]])`／`stopAdvertising`／`removeAllServices`。藍牙不可用或無 Full Access 時 Local Mode 照常打字。
- [ ] **Step 6: 狀態列與主 App。** `rk.status` 的 `accessibilityValue` 為狀態名稱（`idle`、`no-full-access`、`unavailable`、`publishing`、`advertising`、`connected`、`failed`），文字如 `BLE: advertising`；不得改動 T01 的鍵位約束。主 App 加「允許藍牙」按鈕並顯示授權結果。
- [ ] **Step 7: Run all（含 generic iOS 真機 build），全部 exit 0。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T03A-PERIPHERAL.md` 記錄 O4 矩陣：主 App 藍牙授權（有／無）× Full Access（開／關），每格記錄狀態列與 Local 打字是否正常；Full Access 開、授權有時，Notes 與 Safari 皆顯示 `BLE: advertising`。
- [ ] **Step 9: 更新驗收報告 T03（子項 T03a）與 O4，主代理 commit。**

**PASS：** O4 四格皆不 crash、Local 照常打字；授權齊全時 Notes、Safari 都進入 `advertising`。

### Task 03b: Mac Receiver BLE Central

**Branch:** `t03b-receiver-central`（T03a merge 後開始）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/ReceiverLinkStateMachine.swift`、`Receiver/ReceiverSession.swift`
- Create: `macOS/MacReceiver/Bluetooth/ReceiverBLECentral.swift`、`macOS/MacReceiver/LoginItem.swift`；Modify: `MacReceiverApp.swift`（menu 顯示 `Link:` 狀態、剩餘接收時間、「開始接收／停止接收」、「登入時啟動」；不再啟動 `GATTPeripheralServer`，檔案保留不刪）
- Test: `Tests/RemoteKeyboardCoreTests/ReceiverLinkStateMachineTests.swift`、`ReceiverSessionTests.swift`
- Evidence: `e2e/E2E-T03B-LINK.md`

**Interfaces:**
- Consumes: `GATTServiceSpec.Link`（T03a）
- Produces:
  - `enum CentralPower: Sendable { case unknown, poweredOff, unauthorized, unsupported, poweredOn }`
  - `enum ReceiverLinkState: Equatable, Sendable { case idle, unavailable(CentralPower), scanning, connecting(UUID), discovering(UUID), ready(UUID) }`
  - `enum ReceiverLinkInput: Equatable { case start, stop, power(CentralPower), discovered(UUID), connected(UUID), linkReady(UUID), disconnected(UUID), serviceInvalidated(UUID), connectTimeout }`
  - `enum ReceiverLinkEffect: Equatable { case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID), startConnectTimeout(seconds: Double), cancelConnectTimeout }`
  - `enum ReceiverSessionInput: Equatable { case editableFocusGained, eventReceived, manualStart, manualStop, timerFired }`；`enum ReceiverSessionEffect: Equatable { case arm, disarm, scheduleTimeout(at: Date) }`
  - `struct ReceiverSession { static let idleTimeout: TimeInterval = 1800; private(set) var isArmed: Bool; private(set) var deadline: Date?; init(idleTimeout: TimeInterval = idleTimeout); mutating func handle(_ input: ReceiverSessionInput, now: Date) -> [ReceiverSessionEffect] }`：`arm` 對應 link `.start`，`disarm` 對應 link `.stop`；`timerFired` 只在 `now >= deadline` 時 disarm（過期計時器忽略）；待命時 `eventReceived` 不會 arm。
  - `struct ReceiverLinkStateMachine { private(set) var state: ReceiverLinkState; mutating func handle(_ input: ReceiverLinkInput) -> [ReceiverLinkEffect] }`：連線逾時固定 `5.0` 秒；斷線、逾時或 iPhone 移除 service（鍵盤收起時連線可能仍在，因為系統連線共用）一律回到掃描；只有 `stop` 或藍牙不可用才停止。

- [ ] **Step 1: 寫失敗測試**

```swift
func testStartPoweredOnScans() {
    var m = ReceiverLinkStateMachine(); _ = m.handle(.power(.poweredOn))
    XCTAssertEqual(m.handle(.start), [.startScan]); XCTAssertEqual(m.state, .scanning)
}
func testHappyPathToReady() {
    var m = scanningMachine(); let p = UUID()
    XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
    XCTAssertEqual(m.handle(.connected(p)), [.discover(p)])
    XCTAssertEqual(m.handle(.linkReady(p)), [.cancelConnectTimeout]); XCTAssertEqual(m.state, .ready(p))
}
func testDisconnectFromReadyRescans() {
    var m = readyMachine(p); XCTAssertEqual(m.handle(.disconnected(p)), [.startScan]); XCTAssertEqual(m.state, .scanning)
}
func testDisconnectOfOtherPeripheralIgnored() { var m = readyMachine(p); XCTAssertEqual(m.handle(.disconnected(UUID())), []) }
func testConnectTimeoutCancelsAndRescans() {
    var m = connectingMachine(p); XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScan]); XCTAssertEqual(m.state, .scanning)
}
func testServiceInvalidatedCancelsAndRescans() {
    var m = readyMachine(p); XCTAssertEqual(m.handle(.serviceInvalidated(p)), [.cancel(p), .startScan]); XCTAssertEqual(m.state, .scanning)
}
func testDiscoveredWhileConnectingIgnored() { var m = connectingMachine(p); XCTAssertEqual(m.handle(.discovered(UUID())), []) }
func testStopFromReadyCancels() { var m = readyMachine(p); XCTAssertEqual(m.handle(.stop), [.cancel(p)]); XCTAssertEqual(m.state, .idle) }
func testPowerOffThenOnWhileStartedRescans() {
    var m = readyMachine(p); _ = m.handle(.power(.poweredOff)); XCTAssertEqual(m.state, .unavailable(.poweredOff))
    XCTAssertEqual(m.handle(.power(.poweredOn)), [.startScan])
}
func testFocusArmsAndSchedulesThirtyMinutes() {
    var s = ReceiverSession(); let t0 = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(s.handle(.editableFocusGained, now: t0), [.arm, .scheduleTimeout(at: t0.addingTimeInterval(1800))])
}
func testEventExtendsDeadline() {
    var s = armedSession(at: t0)
    XCTAssertEqual(s.handle(.eventReceived, now: t0.addingTimeInterval(600)), [.scheduleTimeout(at: t0.addingTimeInterval(2400))])
}
func testRefocusWhileArmedExtendsWithoutRearm() {
    var s = armedSession(at: t0)
    XCTAssertEqual(s.handle(.editableFocusGained, now: t0.addingTimeInterval(60)), [.scheduleTimeout(at: t0.addingTimeInterval(1860))])
}
func testTimerAtDeadlineDisarms() { var s = armedSession(at: t0); XCTAssertEqual(s.handle(.timerFired, now: t0.addingTimeInterval(1800)), [.disarm]); XCTAssertFalse(s.isArmed) }
func testStaleTimerIgnoredAfterExtension() {
    var s = armedSession(at: t0); _ = s.handle(.eventReceived, now: t0.addingTimeInterval(600))
    XCTAssertEqual(s.handle(.timerFired, now: t0.addingTimeInterval(1800)), [])
}
func testEventWhileStandbyDoesNotArm() { var s = ReceiverSession(); XCTAssertEqual(s.handle(.eventReceived, now: t0), []) }
func testManualStopDisarms() { var s = armedSession(at: t0); XCTAssertEqual(s.handle(.manualStop, now: t0), [.disarm]) }
func testStartBeforePowerScansOnPowerOn() { var m = ReceiverLinkStateMachine(); XCTAssertEqual(m.handle(.start), []); XCTAssertEqual(m.handle(.power(.poweredOn)), [.startScan]) }
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL：找不到 `ReceiverLinkStateMachine`。**
- [ ] **Step 3: 實作 `ReceiverSession` 與 `ReceiverLinkStateMachine`。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作 `ReceiverBLECentral`。** `@MainActor`、`CBCentralManager(queue: nil)`；App 啟動後待命；`ReceiverSession` 的 `.arm` 送 `.start`、`.disarm` 送 `.stop`，計時器依 `.scheduleTimeout(at:)` 設定；T03b 先以 menu「開始接收」觸發 `.manualStart`（點擊輸入框觸發在 T05 接上 `FocusMonitor`）；開發用 `UserDefaults` 鍵 `rk.idleTimeoutSeconds` 可覆寫 1800 秒；`LoginItem` 以 `SMAppService.mainApp.register()`／`unregister()` 實作「登入時啟動」，預設開啟；`scanForPeripherals(withServices: [Link.serviceUUID])`；連上後只探索 `Link.serviceUUID`，再探索 `event`／`control`，對 `event` `setNotifyValue(true)`，`didUpdateNotificationStateFor` 成功即 `.linkReady`；`didModifyServices` 包含 `Link.serviceUUID`，或 `event` 的通知狀態變為關閉，送 `.serviceInvalidated`；保留 peripheral 強參照；計時器只在 `connecting`／`discovering` 有效。menu 顯示 `Link: scanning`、`Link: ready (N ms)`（由 `discovered` 起算）。OSLog subsystem `com.ansonhui.remotekeyboard.receiver`、category `link`，只記狀態名稱與毫秒。
- [ ] **Step 6: Run all（含 macOS adapter 測試），全部 exit 0。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T03B-LINK.md`：先強制關閉 host App；Mac Receiver 執行中並按「開始接收」；確認「登入時啟動」顯示已啟用（`SMAppService.mainApp.status == .enabled`）；Notes、Safari 各叫出鍵盤 10 次，記錄鍵盤 `BLE: connected` 與 Mac `Link: ready (N ms)`；收起鍵盤後 Mac 回到 `scanning`。
- [ ] **Step 8: 更新驗收報告 T03（子項 T03b，T03 整體結論）與 O8，主代理 commit。**

**PASS：** Notes、Safari 各 10/10 進入 connected／ready，host App 不在前景。**若失敗：** 依 D8 啟動 LAN WebSocket 限時 PoC，暫停 UI 工作。

### Task 04: Mac 焦點守衛、輸入法切換與 Unicode 注入

**Branch:** `t04-mac-inject`（可與 T03a、T03b 平行；不改同一檔案，`project.yml` 由主代理合併）

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

**Branch:** `t05-e2e-a-key`（T03b、T04 merge 後開始）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/KeyboardEvent.swift`、`Shared/ControlMessage.swift`、`Keyboard/NotifyQueue.swift`；Modify: `Keyboard/KeyAction.swift`（移出 `EventKind`）、`Keyboard/KeyboardActionRouter.swift`、`Shared/KeyboardMode.swift`
- Modify: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`（送 event、收 control）、`KeyboardViewController.swift`、`MinimalKeyboardView.swift`（模式切換鍵、`Mac → App` 狀態列）
- Modify: `macOS/MacReceiver/Bluetooth/ReceiverBLECentral.swift`（收 event、寫 control）
- Test: `Tests/RemoteKeyboardCoreTests/EventCodecTests.swift`、`ControlMessageTests.swift`、`NotifyQueueTests.swift`、`KeyboardModeTests.swift`、擴充 `KeyboardActionRouterTests.swift`
- Evidence: `e2e/E2E-T05-A-KEY.md`

**Interfaces:**
- Consumes: `FocusGuard`、`InputSourceSwitcher`、`TextInjector`（T04）；`KeyboardBLEPeripheral`、`KeyboardLinkState`（T03a）；`ReceiverBLECentral`（T03b）；`AckCode`、`DiagnosticEvent`（T03a）
- Produces:
  - `enum EventKind: Codable, Equatable, Sendable { case text(String), backspace, returnKey, ping(shownAtMs: Int64, connectedAtMs: Int64) }`
  - `struct KeyboardEvent: Codable, Equatable, Sendable { static let currentVersion = 1; let protocolVersion: Int; let eventId: UUID; let sessionId: UUID; let seq: UInt64; let focusEpoch: UInt64?; let kind: EventKind }`
  - `enum EventCodecError: Error, Equatable { case unsupportedVersion(Int), tooLarge(Int), malformed }`
  - `enum EventCodec { static func encode(_ e: KeyboardEvent, maxBytes: Int) throws -> Data; static func decode(_ d: Data) throws -> KeyboardEvent }`：M1 用 `JSONEncoder`（sortedKeys）；`maxBytes` 由呼叫端傳入訂閱 central 的 `maximumUpdateValueLength`；超過丟 `.tooLarge`。分包在 T07。
  - `struct ReceiverStatus: Codable, Equatable { let ready: Bool; let appName: String?; let focusEpoch: UInt64 }`；`struct Ack: Codable, Equatable { let eventId: UUID; let result: AckCode }`（`AckCode` 加上 `Codable`）
  - `enum ControlMessage: Codable, Equatable { case ack(Ack), status(ReceiverStatus) }`；`enum ControlCodec { static func encode(_ m: ControlMessage) throws -> Data; static func decode(_ d: Data) throws -> ControlMessage }`
  - `struct NotifyQueue { var pendingCount: Int { get }; mutating func enqueue(_ frame: Data); mutating func drain(send: (Data) -> Bool) }`：依序送出，`send` 回傳 `false` 即停止並保留該筆與其後所有資料。
  - `enum ModeResolver { static func effectiveMode(saved: KeyboardMode, hasFullAccess: Bool) -> KeyboardMode }`
  - Router 擴充：`init(local:remote:isRemoteReady: @escaping () -> Bool)`；`.remote` 且 ready → `enqueue` 並回傳 `.enqueuedRemote`，local sink 0 次；`.remote` 且未 ready → `.rejected`（M1 暫行；D6 草稿列在 T10）；`.toggleMode` → `.modeToggled(mode == .local ? .remote : .local)`。

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
    XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 182)), e)
}
func testRejectsUnknownVersion() throws   // protocolVersion 2 → .unsupportedVersion(2)
func testRejectsTooLarge()                // .text(String(repeating: "香", count: 100)), maxBytes 182 → .tooLarge
func testMalformedDataRejected()          // Data("{".utf8) → .malformed
func testControlStatusRoundTrip() throws  // .status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 3)) 編解碼相等
func testDrainStopsWhenSendReturnsFalseAndKeepsOrder() {
    var q = NotifyQueue(); ["a","b","c"].forEach { q.enqueue(Data($0.utf8)) }
    var sent: [String] = []; q.drain { d in if sent.count == 1 { return false }; sent.append(String(decoding: d, as: UTF8.self)); return true }
    XCTAssertEqual(sent, ["a"]); XCTAssertEqual(q.pendingCount, 2)
    q.drain { d in sent.append(String(decoding: d, as: UTF8.self)); return true }
    XCTAssertEqual(sent, ["a", "b", "c"]); XCTAssertEqual(q.pendingCount, 0)
}
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL。**
- [ ] **Step 3: 實作 Core 型別與 router 擴充。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 接上兩端。** Mac：`FocusMonitor` 由非可編輯轉為可編輯時送 `ReceiverSession` `.editableFocusGained`，每收到一個有效 event 送 `.eventReceived`。iPhone：Remote 按鍵 → `KeyboardEvent`（`focusEpoch` 取最新 `ReceiverStatus`，`seq` 每 session 從 1 遞增）→ `EventCodec.encode(maxBytes: central.maximumUpdateValueLength)` → `NotifyQueue`；以 `updateValue(_:for:onSubscribedCentrals:)` drain，`peripheralManagerIsReady(toUpdateSubscribers:)` 再 drain。`control` write 解成 `ControlMessage`：`.status` 更新 ready 與狀態列 `Mac → 目前 App`；`.ack` 以 `DiagnosticEvent.ackReceived` 記錄並短暫顯示。模式以 `UserDefaults.standard` 鍵 `rk.mode` 保存，載入經 `ModeResolver`（`hasFullAccess` 取 `UIInputViewController.hasFullAccess`）。Mac：`event` 通知 → `EventCodec.decode` → `FocusGuard.authorize(eventEpoch: event.focusEpoch, current:)` → `InputSourceSwitcher` → `TextInjector` → `control` 寫回 `.ack`；`linkReady` 後與焦點／epoch 改變時寫 `.status`（`.withResponse`）。
- [ ] **Step 6: Run all，全部 exit 0。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** `T05-E2E-A-01`：Notes → Mac TextEdit 按 `A` 20 次；`T05-E2E-A-02`：Safari → TextEdit 20 次；每次錄影，不得用主 App 代打。另做 5 次「按 A 前 1 秒內 Cmd-Tab 到 Finder」，Mac 不得出現字元，ack 為 `staleFocus` 或 `noFocus`。關閉 Full Access 後重開鍵盤，確認回到 Local 可打字。D13：Receiver 待命時點擊 TextEdit 文字框即開始接收並連上；以 `defaults write com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds 60` 將逾時改為 60 秒，確認 60 秒不打字即斷線回待命、期間持續打字則不斷線，測完以 `defaults delete com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds` 還原。
- [ ] **Step 8: 更新驗收報告 T05，主代理 commit。**

**PASS：** 兩組各 20/20，錯焦點 0 次。**Gate 1：** 失敗即停止 T10–T12 的完整 UI，改依 D8 驗證 LAN 傳輸；任何 Extension 傳輸都失敗時重新確認產品方向。

### Task 06: BLE 生命週期與重連 Gate

**Branch:** `t06-reconnect-gate`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/ReconnectStats.swift`
- Create: `iOS/RemoteKeyboardUITests/ReconnectUITests.swift`、`macOS/MacReceiver/Diagnostics/ReconnectLog.swift`；Modify: `KeyboardBLEPeripheral.swift`（記錄時間、connected 後送 `.ping`）、`ReceiverBLECentral.swift`（收到 ping 寫 CSV，不注入）、`project.yml`（加 `RemoteKeyboardUITests` target 並放入 `RemoteKeyboardApp` scheme 的 test action）
- Test: `Tests/RemoteKeyboardCoreTests/ReconnectStatsTests.swift`、擴充 `KeyboardLinkStateMachineTests.swift`、`ReceiverLinkStateMachineTests.swift`
- Evidence: `e2e/E2E-T06-RECONNECT.md`

**Interfaces:**
- Consumes: `KeyboardLinkStateMachine`（T03a）、`ReceiverLinkStateMachine`（T03b）、`EventKind.ping`（T05）
- Produces:
  - `struct ReconnectSample: Equatable, Sendable { let shownAtMs: Int64; let connectedAtMs: Int64? }`（`nil` 表示 10 秒內未 connected）
  - `struct ReconnectSummary: Equatable { let attempts: Int; let successes: Int; let p95Ms: Int64? }`
  - `enum ReconnectStats { static func summarize(_ samples: [ReconnectSample]) -> ReconnectSummary }`：P95 只計成功樣本，nearest-rank：排序後取第 `ceil(0.95 × n)` 個（1-based）。

- [ ] **Step 1: 寫失敗測試**

```swift
func testP95NearestRank() {
    let s = (1...100).map { ReconnectSample(shownAtMs: 0, connectedAtMs: Int64($0)) }
    XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 100, successes: 100, p95Ms: 95))
}
func testFailuresExcludedFromP95() {
    let s = [ReconnectSample(shownAtMs: 0, connectedAtMs: 100), ReconnectSample(shownAtMs: 0, connectedAtMs: nil)]
    XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 2, successes: 1, p95Ms: 100))
}
func testNoSuccessHasNilP95() { XCTAssertNil(ReconnectStats.summarize([ReconnectSample(shownAtMs: 0, connectedAtMs: nil)]).p95Ms) }
func testTwentyAppearDisappearCyclesRepublishEachTime()   // KeyboardLink：每次 appeared(hasFullAccess: true) 都回傳 [.addService]，每次 disappeared 都回傳 [.stopAdvertising, .removeServices]
func testRapidDisappearAppearDoesNotDuplicatePublish()    // KeyboardLink：publishing 中再 appeared → []
func testTwentyDisconnectCyclesAlwaysRescan()             // ReceiverLink：ready(p) → disconnected(p) → [.startScan]，重複 20 次
func testLateDisconnectAfterRescanIgnored()               // ReceiverLink：scanning 狀態收到舊 p 的 disconnected → []
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL。**
- [ ] **Step 3: 實作 `ReconnectStats`，必要時修正兩個狀態機使新測試通過。**
- [ ] **Step 4: 執行 `swift test`，全部 PASS。**
- [ ] **Step 5: 實作計時與 ping。** iPhone 在 `viewWillAppear` 記 `shownAtMs`；只在狀態「轉入」`connected` 時記 `connectedAtMs`（重複事件不得改寫），狀態列顯示 `BLE: connected (N ms)`，並送 `.ping(shownAtMs:connectedAtMs:)`。Mac 收到 ping 只寫一行 `shownAtMs,connectedAtMs,latencyMs` 到 `~/Library/Logs/RemoteKeyboard/reconnect.csv`，不經注入流程。
- [ ] **Step 6: 實作 `ReconnectUITests.testHundredReopens`。** `XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")` 與 `"com.apple.mobilesafari"` 交替：點文字欄位叫出鍵盤，記 `shownAt`，等待 `rk.status` 的 value 變成 `connected`（逾時 10 秒），記 `connectedAt`，收起鍵盤；共 100 次，結果以 CSV 附加到 xcresult。若第一次就找不到 `rk.status`（O6 FAIL），以 `XCTSkip("O6: third-party keyboard not reachable")` 結束。
- [ ] **Step 7: Run all，全部 exit 0；UI test 只編譯，不在模擬器執行。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 真機執行 `xcodebuild test -scheme RemoteKeyboardApp -only-testing:RemoteKeyboardUITests/ReconnectUITests -destination "platform=iOS,id=$IOS_DEVICE_ID"`；使用者另外親手抽查 10 次並錄影。O6 FAIL 時改為使用者親手做 100 次，數據取 Mac CSV（失敗次數 = 100 − CSV 行數）。另各做 5 次：iPhone 藍牙關再開、Mac 藍牙關再開、Mac 睡眠 1 分鐘後喚醒、鍵盤顯示中強制關閉 host App。
- [ ] **Step 9: 以 `ReconnectStats` 計算結果，更新驗收報告 T06 與 O6，主代理 commit。**

**PASS：** 100 次中 ≥ 99 次 connected，P95 ≤ 2000 ms（Mac 醒著、同一房間）。**Gate 2：** 未達標不得宣稱「任何 App 叫出鍵盤即可連線」；先調整掃描與逾時，必要時依 D8 評估 LAN。

---

## M2–M5 任務（M1 Gate 通過後再細化）

| Task | 名稱 | v1.1 調整 |
|---|---|---|
| T07 | 協定分幀、UTF-8 與事件流 | 取代 T05 的 JSON 單包；長事件拆成多個 notify，每個不超過 `maximumUpdateValueLength` |
| T08 | ACK、去重、排序、失敗語義 | ACK 經 `control` write 回傳；草稿送出（D6）沿用同一套 seq／eventId 去重 |
| T09 | 配對、隱私與 Local／Remote 模式 | O3 PASS → 主 App 配對；challenge 經 `control` write、response 經 `event` notify；未配對的 Mac 不得收到事件，`appName` 只寫給已配對 Mac |
| T10 | 原生風格英文 QWERTY | 加入 D5 常駐狀態列與 D6 草稿列，取代 T05 的未就緒 `.rejected` |
| T11 | 數字 123／符號 #+= | 無變更 |
| T12 | 繁體中文手寫與候選字 | 開始前先完成 O7（`PKStrokeRecognizer` 官方查證） |
| T13 | 語音聽寫 Gate | 依 D7：系統麥克風加 context diff；失敗改主 App 手動語音頁。可在 T01 後先做探測 |
| T14 | 跨 App 相容性與焦點安全矩陣 | 加入輸入法狀態（ABC、注音、倉頡、粵拼）× Mac App 的注入矩陣 |
| T15 | 穩定性、權限、Wi-Fi 降級 | D8：僅 D11 路徑在 T05／T06 未達標才做 LAN；校園 Wi-Fi 隔離時用 iPhone 熱點 |
| T16 | Release Candidate QA | D1：以自用與展示為目標；App Store 審查另立 |

**依賴：** T01、T02 已完成 → T03a → T03b；T04 可與 T03a／T03b 平行 → T05 → T06。M2 需 T05 PASS。

**計劃狀態：** v1.2 APPROVED（2026-10-29）。T01、T02 PASS；舊 T03 FAIL（見 `verification/2026-10-29-handoff.md`）。
