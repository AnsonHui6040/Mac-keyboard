# Remote Keyboard Implementation Plan v1.3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M1（T01–T06，已完成）證明 iPhone 第三方 Keyboard Extension 可經 BLE GATT 把按鍵送進 Mac 目前焦點並穩定重連；M2–M5（T07–T16、T12b）完成分幀、ACK、配對加密、原生風格三頁鍵盤（中文手寫與速成、英文、符號）、頂部區與即時／草稿、語音 Gate、相容矩陣、穩定性與 RC QA。

**Architecture:** 傳輸採 D11 角色對調：iPhone Keyboard Extension 為 GATT Peripheral（notify 送事件），Mac Receiver 為 Central（掃描、連入、write 回 ACK 與狀態）。一個 Swift Package `RemoteKeyboardCore` 放所有純邏輯（路由、狀態機、焦點守衛、輸入法切換流程、編碼、統計），以 `swift test` 驗證；iOS Extension、iOS host App、macOS Receiver 只做 UIKit／SwiftUI／CoreBluetooth／AX／CGEvent／TIS 的薄 adapter。Xcode project 由 XcodeGen 從 `project.yml` 產生。

**Tech Stack:** Xcode 27.1、Swift 6.4（language mode 6）、XcodeGen 2.46.0、UIKit `UIInputViewController`、SwiftUI、CoreBluetooth、ApplicationServices（AXUIElement）、CoreGraphics（CGEvent）、Carbon TIS、OSLog、XCTest／XCUITest。

**Spec:** `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（v1.3 APPROVED 2026-10-30，設計決定見 §12 D1–D17）。

**範圍：** T01、T02 已完成。v1.2 依 D11 重寫 T03（拆成 T03a、T03b）、T05、T06；T04 不受影響。舊 T03（iPhone 為 Central）實機失敗，branch `t03-extension-central` 封存不 merge。M1 Gate 已通過（2026-10-30）；v1.3 細化 T07–T16，新增 T12b（速成），並納入交接文件的延後項目。v1.0 原文見 `docs/archive/planning-package-v1.0/RemoteKeyboard-Superpowers-v1-Implementation-Plan.md`。

## Global Constraints

- 不採用 Bluetooth HID；主傳輸為自訂 BLE GATT，Mac 安裝 Receiver。
- D11／D12：iPhone 發佈 service `706AA642-68A3-41FA-889D-24E30709B0D0`，`event` `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`（notify）、`control` `320468E2-53B6-4B6A-88EC-AE2752415818`（write with response）；Mac 只走掃描路徑；notify 不超過 `maximumUpdateValueLength`，佇列滿時暫存不丟。
- D13：Mac Receiver 登入時啟動並常駐；平時待命，點擊可編輯輸入框才開始掃描連線；`ReceiverSession.idleTimeout = 1800` 秒無活動自動停止，收到事件、鍵盤連上或再點輸入框即延長；焦點離開輸入框不斷線。
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
- v1.3（D14–D17）：鍵盤三頁（中文、英文、符號），底列 `中英`、`符號`、空白鍵、Return；中文輸入法皆實作 `ChineseInputMethod`；手寫用 Google ML Kit Digital Ink，需 Full Access；無 Full Access 時中文頁用速成，速成未完成前為英文頁。
- 遠端模式草稿：草稿非空、草稿狀態或未就緒時，按鍵（含刪除、Return）只編輯草稿；`◀ ▶` 不送 Mac；草稿上限 1,000 字元，只存記憶體。
- 速成字碼表須授權可散布（O9），授權檔隨 App 附上。
- 新增依賴前先跑網路 preflight；ML Kit 為本專案唯一第三方依賴，只能在 `MLKitRecognizer.swift` import。
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

v1.3 新增（M2–M5）：

7. **草稿仍有字時按刪除或 Return**：使用者切回即時但草稿未清，刪除若送到 Mac 會刪錯地方。由 T10 `testBackspaceEditsDraftWhileDraftNotEmptyInInstant` 覆蓋。
8. **斷線時半則訊息與下一則混在一起**：多 frame 訊息中途斷線，殘片不得與重連後的訊息拼接。由 T07 `testResetDropsPartialMessage`、`testNewMessageDropsPartialOne` 覆蓋。
9. **重連後同一事件再到**：iPhone 未收 ACK 而 Mac 已注入，同一 `eventId` 再到不得注入兩次。由 T08 `testDuplicateEventIsAckedWithOriginalCodeAndInjectedOnce` 覆蓋。
10. **選了手寫但沒開 Full Access**：鍵盤仍須可打中文或英文，不得空白或 crash。由 T12 `testResolverHandwritingNeedsFullAccess` 覆蓋。
11. **速成打到表內沒有的碼或第三碼**：不得送出亂碼或 crash。由 T12b `testThirdCodeIsIgnored`、`testUnknownCodeShowsNoCandidatesAndSpaceCommitsNothing` 覆蓋。
12. **未配對或已解除配對的 Mac 收到事件**：由 T09 `testPhoneSendsNoEventBeforeMacAuth`、`testRevokedPairingCannotAuthenticate` 與實機步驟覆蓋。

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

v1.3 新增的主要位置（細節見各 Task 的 Files）：

```text
Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/
  Shared/FrameCodec.swift、Pairing.swift、SessionCrypto.swift、AuthHandshake.swift、AppGroup.swift
  Receiver/FrameReassembler.swift、EventDeduplicator.swift
  Keyboard/EventSender.swift、PageNavigator.swift、DraftBuffer.swift、InputRouter.swift、SymbolLayouts.swift、ContextDiff.swift
  Chinese/ChineseInputMethod.swift、HandwritingInputMethod.swift、ChineseMethodResolver.swift、QuickInputMethod.swift、QuickDictionary.swift、CangjieRadicals.swift
iOS/RemoteKeyboardExtension/UI/          KeyboardRootView、TopAreaView、EnglishPageView、SymbolPageView、HandwritingPageView、QuickPageView、CandidateBarView、BottomRowView、KeyButton
iOS/RemoteKeyboardExtension/Chinese/MLKitRecognizer.swift
iOS/RemoteKeyboardExtension/Resources/quick-table.txt、quick-table-LICENSE.txt
iOS/RemoteKeyboardApp/PairingView.swift、PairingPeripheral.swift、SettingsView.swift
iOS/Shared/PairingStore.swift
macOS/MacReceiver/Pairing/MacPairingStore.swift、PairingSheet.swift
scripts/make-quick-table.swift
```

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
  - `enum ReceiverSessionInput: Equatable { case editableFocusGained, eventReceived, linkReady, manualStart, manualStop, timerFired }`；`enum ReceiverSessionEffect: Equatable { case arm, disarm, scheduleTimeout(at: Date) }`
  - `struct ReceiverSession { static let idleTimeout: TimeInterval = 1800; private(set) var isArmed: Bool; private(set) var deadline: Date?; init(idleTimeout: TimeInterval = idleTimeout); mutating func handle(_ input: ReceiverSessionInput, now: Date) -> [ReceiverSessionEffect] }`：`arm` 對應 link `.start`，`disarm` 對應 link `.stop`；`timerFired` 在 `now >= deadline` 時 disarm，提早觸發則重新排到 deadline；`linkReady` 與 `eventReceived` 同樣延長；待命時兩者都不會 arm。
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

**Branch:** `t05-e2e-a-key`（由 `t04-mac-inject` 開出；T04 實機測試併入 T05 實機測試，兩者測完一起 merge）

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

- 組字規則（D4 修訂，2026-10-29）：
  - `enum CompositionState: Equatable, Sendable { case composing, notComposing, unknown }`
  - `protocol CompositionControlling { func state() -> CompositionState; func cancel() }`（Mac adapter：讀焦點元素 `AXTextInputMarkedTextMarkerRange`，非 NULL → `.composing`、NULL → `.notComposing`、屬性不支援或 AX 錯誤 → `.unknown`；`cancel()` 送 Escape，virtualKey 53）
  - `InputSourceSwitcher` 改為 `init(controller:composition:settle:)`，`composition` 預設 `nil`（等同永遠 `.unknown`）。`withASCII` 在 gate 內、目前不是 ABC 時：`.composing` → `cancel()`、`await settle(settleSeconds)`、再讀 `state()`，仍 `.composing` 則回傳 `.compositionActive` 且不切換不注入；`.notComposing`／`.unknown` → 照 T04 流程。目前是 ABC 時不查組字。
  - `SwitchResult` 新增 `.compositionActive`；Mac 對應 ack 用 `AckCode` 既有的拒收類別（實作時選最接近者並在報告說明）。

- [ ] **Step 1: 寫失敗測試**

```swift
func testComposingIsCancelledBeforeSwitch() async   // current = Zhuyin、state 先 .composing 後 .notComposing → 記錄順序 ["cancel", "settle:0.05", "select:ABC", "inject", "settle:0.05", "select:Zhuyin"]
func testStillComposingAfterCancelRefuses() async   // state 一直 .composing → .compositionActive，selected == []，injected 0
func testUnknownCompositionSwitchesAsBefore() async // state .unknown → 與 testSwitchesAndRestores 相同，cancel 0 次
func testABCSkipsCompositionCheck() async           // current = ABC → state() 0 次、cancel 0 次
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
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** `T05-E2E-A-01`：Notes → Mac TextEdit 按 `A` 20 次；`T05-E2E-A-02`：Safari → TextEdit 20 次；每次錄影，不得用主 App 代打。Mac 用注音打一半（候選字未選）時按 iPhone `A`：TextEdit 未完成文字被刪除、出現 `A`、輸入法切回注音。另做 5 次「按 A 前 1 秒內 Cmd-Tab 到 Finder」，Mac 不得出現字元，ack 為 `staleFocus` 或 `noFocus`。關閉 Full Access 後重開鍵盤，確認回到 Local 可打字。D13：Receiver 待命時點擊 TextEdit 文字框即開始接收並連上；以 `defaults write com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds 60` 將逾時改為 60 秒，確認 60 秒不打字即斷線回待命、期間持續打字則不斷線，測完以 `defaults delete com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds` 還原。
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

## M2–M5 任務（v1.3，2026-10-30 細化）

**里程碑：** M2 = T07–T10（協定、配對、鍵盤主體）；M3 = T11、T12、T12b（符號頁與中文輸入）；M4 = T13–T15（語音 Gate、相容矩陣、穩定性）；M5 = T16（RC QA）。

**依賴：** T07 → T08 → T09；T10 需 T08 與 T09（`AppGroup` 常數、配對狀態列）；T11 需 T10；T12 需 T10；T12b 需 T12 的介面；T13 需 T10；T14 需 T12b；T15 需 T09；T16 最後。

**驗收報告：** 新增 T12b 一列，總數由 16 改為 17（目前 6/17）。

### Task 07: 協定分幀與事件信封

**Branch:** `t07-framing`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/FrameCodec.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/FrameReassembler.swift`
- Modify: `Shared/KeyboardEvent.swift`（`currentVersion = 2`；新增 `PeripheralMessage` 信封）
- Modify: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`（每則訊息切成多個 frame 後逐一進 `NotifyQueue`）
- Modify: `macOS/MacReceiver/Bluetooth/ReceiverBLECentral.swift`（收到 notify 先進 reassembler，完整才交給 `eventHandler`；斷線時 `reset()`）
- Test: `Tests/RemoteKeyboardCoreTests/FrameCodecTests.swift`、`FrameReassemblerTests.swift`、`macOS/MacReceiverTests/ReceiverBLECentralTests.swift`
- Evidence: `e2e/E2E-T07-FRAMING.md`

**Interfaces:**
- Produces:
  - `enum PeripheralMessage: Codable, Equatable, Sendable { case event(KeyboardEvent) }`（T09 加 case）
  - `enum PeripheralCodec { static func encode(_ m: PeripheralMessage) throws -> Data; static func decode(_ d: Data) throws -> PeripheralMessage }`：版本先檢查（沿用 `EventCodec` 做法），`currentVersion = 2`。
  - `enum FrameCodec { static let headerBytes = 5; static let maxMessageBytes = 16_384; static func split(_ payload: Data, messageId: UInt16, maxFrameBytes: Int) throws -> [Data] }`
  - frame 格式：`[0] 版本 0x02`、`[1–2] messageId UInt16 big-endian`、`[3] index`、`[4] count`、其後為 payload 片段；`count` 1–255，`index < count`。
  - `enum FrameError: Error, Equatable, Sendable { case frameTooSmall, payloadTooLarge(Int), badHeader, badIndex, countMismatch, duplicateIndex, messageTooLarge }`
  - `struct FrameReassembler: Sendable { init(maxMessageBytes: Int = FrameCodec.maxMessageBytes); mutating func accept(_ frame: Data) -> ReassemblyResult; mutating func reset() }`
  - `enum ReassemblyResult: Equatable, Sendable { case incomplete, complete(Data), rejected(FrameError) }`
  - 規則：同時只組一則訊息；收到不同 `messageId` 的 index 0 時丟棄未完成的舊訊息並以 `.rejected(.countMismatch)` 回報一次；非 index 0 而 messageId 不符時 `.rejected(.badHeader)`。
- 同時處理交接延後項目：ping 線路格式改短鍵後未升版本，本 Task 升為 2。

- [ ] **Step 1: 寫失敗測試**

```swift
func testSplitFitsEachFrameWithinMax() throws {
    let payload = Data(repeating: 0x41, count: 1_000)
    let frames = try FrameCodec.split(payload, messageId: 7, maxFrameBytes: 182)
    XCTAssertTrue(frames.allSatisfy { $0.count <= 182 })
    XCTAssertEqual(frames.count, Int((1_000.0 / 177.0).rounded(.up)))
}
func testSplitThenReassembleRoundTrips() throws { /* 0、1、177、178、16_384 bytes 各一次；最後一個 frame 交出 .complete(payload) */ }
func testFrameSmallerThanHeaderPlusOneThrows() { XCTAssertThrowsError(try FrameCodec.split(Data([1]), messageId: 1, maxFrameBytes: 5)) }
func testPayloadOverMaxThrows() { /* 16_385 bytes → .payloadTooLarge(16_385) */ }
func testDuplicateIndexRejected() { /* 同一 frame 收兩次 → 第二次 .rejected(.duplicateIndex)，之後補齊其餘 frame 仍可 .complete */ }
func testIndexBeyondCountRejected() { /* index 3、count 3 → .rejected(.badIndex) */ }
func testNewMessageDropsPartialOne() { /* 訊息 1 收 frame 0/3，訊息 2 的 frame 0/1 到達 → 先回 .rejected(.countMismatch)，訊息 2 下一次 accept 可 .complete */ }
func testResetDropsPartialMessage() { /* frame 0/2 後 reset()，再送同訊息 frame 1/2 → .rejected(.badHeader)，不得 .complete */ }
func testFuzzedFramesNeverCrashOrComplete() { /* 固定種子產生 1_000 個隨機 frame（長度 0–200）：不 crash，且 .complete 只在合法序列出現；計數寫入測試輸出 */ }
func testVersion1PayloadRejectedAsUnsupported() { /* protocolVersion 1 的 JSON → EventCodecError.unsupportedVersion(1) */ }
func testUTF8AndEmojiSurviveSplitAcrossFrames() { /* "香港👨‍👩‍👧‍👦café" 重複 200 次，切 frame 後重組再 decode，字串完全相同 */ }
```

- [ ] **Step 2: 執行 `swift test --package-path Packages/RemoteKeyboardCore`，預期 FAIL：`cannot find 'FrameCodec' in scope`。**
- [ ] **Step 3: 實作 `PeripheralMessage`／`PeripheralCodec`、`FrameCodec.split`、`FrameReassembler`。** 單一 frame 的 payload 上限 `maxFrameBytes - headerBytes`；`maxFrameBytes <= headerBytes` 擲 `.frameTooSmall`。
- [ ] **Step 4: 執行 `swift test`，預期新增測試全部 PASS，既有測試無回歸。**
- [ ] **Step 5: 接線。** iPhone：`KeyboardBLEPeripheral` 以每次訂閱的 `maximumUpdateValueLength` 切 frame，`messageId` 每則訊息 `&+= 1`；切 frame 失敗記 `DiagnosticEvent.keyDropped(reason: .tooLarge)`。Mac：`ReceiverBLECentral` 每個 peripheral 一個 reassembler，`onLinkLost` 與斷線時 `reset()`；`.rejected` 只記 log 種類與長度。
- [ ] **Step 6: Mac adapter 測試。** `testCentralReassemblesBeforeHandingToPipeline`（三個 frame 只呼叫 `eventHandler` 一次）、`testLinkLostResetsReassembler`。
- [ ] **Step 7: Run all。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T07-FRAMING.md`：鍵盤打字照常（回歸）；DEBUG build 中長按鍵盤 `return` 2 秒，由 iPhone 送一則 3,000 字元的 `TEXT`，TextEdit 收到字數一致。
- [ ] **Step 9: 更新驗收報告 T07（1,000 組 fuzz 0 誤解析 = Step 1 `testFuzzedFramesNeverCrashOrComplete` 輸出）並 commit。**

### Task 08: ACK、去重、排序與失敗語義

**Branch:** `t08-ack-dedup`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/EventDeduplicator.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/EventSender.swift`（由 `KeyboardBLEPeripheral` 搬出：建事件、seq、epoch、待確認清單）
- Modify: `Shared/DiagnosticEvent.swift`（`AckCode` 新增 case）、`Keyboard/StatusLine.swift`
- Modify: `macOS/MacReceiver/Pipeline/EventPipeline.swift`、`iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`
- Test: `EventDeduplicatorTests.swift`、`EventSenderTests.swift`、`StatusLineTests.swift`、`macOS/MacReceiverTests/EventPipelineTests.swift`、`ReceiverCoordinatorTests.swift`
- Evidence: `e2e/E2E-T08-ACK.md`

**Interfaces:**
- Consumes: T07 `PeripheralMessage`、`FrameCodec`。
- Produces:
  - `AckCode` 新增：`injectFailed`（注入失敗，取代目前誤用的 `malformed`）、`pong`（ping 的回覆，取代 `posted`）、`outOfOrder`。
  - `struct EventDeduplicator: Sendable { init(capacity: Int = 256); mutating func check(_ e: KeyboardEvent) -> DedupDecision; mutating func record(_ e: KeyboardEvent, result: AckCode) }`
  - `enum DedupDecision: Equatable, Sendable { case fresh, duplicate(AckCode), outOfOrder }`：同 `eventId` 已處理 → `.duplicate(原結果)`；同 `sessionId` 而 `seq` 不大於已見最大值且非重複 → `.outOfOrder`；新 `sessionId` 從頭計。只保留最近 256 個 `eventId`。
  - `struct EventSender: Sendable { init(sessionId: UUID); mutating func make(_ kind: EventKind, focusEpoch: UInt64?) -> KeyboardEvent; mutating func acknowledged(_ ack: Ack); mutating func linkLost() -> Int; var pendingCount: Int { get } }`：`linkLost()` 回傳未收到 ACK 的事件數，清空清單，**不重送**。
  - `StatusLine.unconfirmedText(_ count: Int) -> String`：`"\(count) 個按鍵未確認是否送達"`。
- 同時處理交接延後項目：ping 回 `posted`、注入失敗回 `malformed`（T05）；coordinator 接線與 iPhone 送出路徑缺自動測試（T05）。

- [ ] **Step 1: 寫失敗測試**

```swift
func testDuplicateEventIdReturnsCachedAckWithoutInjecting() {
    var d = EventDeduplicator(); let e = event(seq: 1)
    XCTAssertEqual(d.check(e), .fresh); d.record(e, result: .posted)
    XCTAssertEqual(d.check(e), .duplicate(.posted))
}
func testLowerSeqSameSessionIsOutOfOrder() { /* seq 2 record 後送新 eventId 的 seq 1 → .outOfOrder */ }
func testNewSessionStartsFresh() { /* 新 sessionId 的 seq 1 → .fresh */ }
func testCapacityEvictsOldest() { /* capacity 2，記 3 個後第 1 個再來 → .outOfOrder（seq 較小）而非 duplicate */ }
func testSenderNumbersSeqFromOneAndCarriesEpoch() { /* make 兩次 → seq 1、2，focusEpoch 照傳；ping 的 focusEpoch 為 nil */ }
func testLinkLostReportsPendingAndNeverResends() { /* make 3、ack 1 → linkLost() == 2，pendingCount == 0 */ }
func testUnconfirmedText() { XCTAssertEqual(StatusLine.unconfirmedText(2), "2 個按鍵未確認是否送達") }
```

Mac adapter（`EventPipelineTests`）：
```swift
func testDuplicateEventIsAckedWithOriginalCodeAndInjectedOnce()  // 同一 frame 序列送 100 次 → injector 呼叫 1 次，ACK 100 次皆 .posted
func testOutOfOrderEventIsNotInjected()                          // ACK .outOfOrder，injector 0 次
func testInjectionFailureAcksInjectFailed()
func testPingAcksPong()
```
`ReceiverCoordinatorTests`：`testCoordinatorArmsOnEditableFocusAndForwardsEvents`（fake central 與 focus，驗證點擊可編輯欄位 → `focusGainedEditable` → 事件交 pipeline）。

- [ ] **Step 2: 執行 `swift test` 與 macOS adapter 測試，預期 FAIL：`cannot find 'EventDeduplicator' in scope`。**
- [ ] **Step 3: 實作 Core 型別與 `AckCode` 新 case，更新 `StatusLine.ackText`（`injectFailed`：「Mac 輸入失敗」；`pong`：不顯示；`outOfOrder`：「順序錯誤，未輸入」）。**
- [ ] **Step 4: 接線。** Mac：`EventPipeline.handle` 先 `check`，`.duplicate` 直接回原碼不注入，處理後 `record`；Receiver 斷線不清空 deduplicator（重連後同 session 的重送仍可辨識）。iPhone：`KeyboardBLEPeripheral` 改用 `EventSender`；斷線時若 `linkLost() > 0`，狀態列附註 `unconfirmedText` 2 秒。
- [ ] **Step 5: 執行全部測試，預期 PASS。**
- [ ] **Step 6: Run all。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** 打字 3 分鐘無回歸；打字途中關 iPhone 藍牙，狀態列出現「N 個按鍵未確認是否送達」且重連後不自動補送；10,000 事件受控測試併入 T15。
- [ ] **Step 8: 更新驗收報告 T08 並 commit。**

### Task 09: 配對、加密、隱私與模式

**Branch:** `t09-pairing`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/Pairing.swift`（ECDH、HKDF、SAS、challenge 計算）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/SessionCrypto.swift`（事件 payload 加解密）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/AuthHandshake.swift`（雙向 challenge 狀態機，純 reducer）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/AppGroup.swift`（App Group 與鍵名常數，取代散落字串）
- Create: `iOS/RemoteKeyboardApp/PairingView.swift`、`iOS/RemoteKeyboardApp/PairingPeripheral.swift`、`iOS/Shared/PairingStore.swift`（Keychain，host App 與 Extension 共用）
- Create: `macOS/MacReceiver/Pairing/MacPairingStore.swift`、`macOS/MacReceiver/Pairing/PairingSheet.swift`
- Modify: `Shared/KeyboardEvent.swift`（`PeripheralMessage` 加 case、`currentVersion = 3`）、`Shared/ControlMessage.swift`、`KeyboardBLEPeripheral.swift`、`ReceiverBLECentral.swift`、`ReceiverPanel.swift`、`KeyboardLifecycleLog.swift`、`project.yml`（keychain access group）
- Test: `PairingTests.swift`、`SessionCryptoTests.swift`、`AuthHandshakeTests.swift`、`macOS/MacReceiverTests/ReceiverBLECentralTests.swift`
- Evidence: `e2e/E2E-T09-PAIRING.md`

**Interfaces:**
- Consumes: T07 信封與分幀、T08 `EventSender`。
- Produces:
  - `PeripheralMessage` 新增 `case pairOffer(publicKey: Data)`、`case helloReply(phoneNonce: Data, proof: Data)`、`case sealed(Data)`（加密後的 `KeyboardEvent`）。T09 後 `.event` 明文只在 DEBUG 未配對開發模式接受。
  - `ControlMessage` 新增 `case pairAccept(publicKey: Data)`、`case hello(macNonce: Data)`、`case auth(proof: Data)`、`case authFailed`。
  - `enum Pairing { static func sharedKey(myPrivate: P256.KeyAgreement.PrivateKey, peerPublic: Data, macPublic: Data, phonePublic: Data) throws -> SymmetricKey; static func sas(_ key: SymmetricKey) -> String; static func phoneProof(key:, macNonce:, phoneNonce:) -> Data; static func macProof(key:, macNonce:, phoneNonce:) -> Data }`
  - 固定值：HKDF-SHA256，salt `"rk-pair-v1"`，info = macPublic ‖ phonePublic，輸出 32 bytes；SAS = HKDF(key, info `"rk-sas"`) 前 4 bytes 轉 UInt32 後 `% 1_000_000`，左補 0 成 6 位；proof = HMAC-SHA256(key, 標籤 ‖ macNonce ‖ phoneNonce)，標籤 `"phone"`／`"mac"`；nonce 各 16 bytes。
  - `struct SessionCrypto { init(pairKey: SymmetricKey, macNonce: Data, phoneNonce: Data); func seal(_ plain: Data) throws -> Data; func open(_ sealed: Data) throws -> Data }`：session key = HKDF(pairKey, info `"rk-session"` ‖ macNonce ‖ phoneNonce)，ChaChaPoly。
  - `struct AuthHandshake`（iPhone 端與 Mac 端各一個 reducer）：iPhone 在驗證 `auth` 前不送任何 `KeyboardEvent`；Mac 在驗證 `helloReply` 前不寫含 `appName` 的 `ReceiverStatus`。驗證失敗 → Mac 寫 `authFailed` 並斷線，該 peripheral identifier 在本次接收時段內不再連入。
  - 儲存：iPhone Keychain，access group `$(AppIdentifierPrefix)group.com.ansonhui.remotekeyboard`（Step 0 實測），service `com.ansonhui.remotekeyboard.pairing`；Mac Keychain 同 service 名。各端只存一個配對對象。
- 配對流程：Mac 選單「配對新 iPhone」開 120 秒配對時段 → iPhone 主 App「配對 Mac」以同一 service 廣播並 notify `pairOffer` → Mac 回 `pairAccept` → 兩端顯示 6 位 SAS → 兩端都按「確認」才存；任一方取消或逾時則丟棄。配對時段外 Mac 忽略 `pairOffer` 並斷線。
- 規格差異（主代理決定，交使用者知悉）：§5 寫「BLE 加密權限及應用層驗證」。本 Task 以應用層 ECDH＋ChaChaPoly 加密事件內容取代 BLE characteristic 加密權限，原因：加密權限會觸發系統配對對話框，可能破壞 T06 已達標的重連時間；應用層加密同樣使旁人無法讀取打字內容。
- 同時處理交接延後項目：`KeyboardLifecycleLog.note(String)` 改為只收固定 enum；無 Full Access 時舊 manager 仍存活（T05）。

- [ ] **Step 0: 實測 Keychain access group。** host App 寫入、Extension（Full Access 開）讀取同一 Keychain 項目；結果記入 E2E。讀不到時改用 `keychain-access-groups` 的 `$(AppIdentifierPrefix)com.ansonhui.remotekeyboard.shared` 再試；兩者皆失敗則停下回報（D3 備案需使用者決定）。
- [ ] **Step 1: 寫失敗測試**

```swift
func testBothSidesDeriveSameKeyAndSAS() { /* 兩把 P256 私鑰互換公鑰 → sharedKey 相同、sas 相同且為 6 位數字 */ }
func testSASDiffersWhenPublicKeySwapped() { /* 中間人換公鑰 → 兩端 SAS 不同 */ }
func testWrongKeyProofRejected() { /* 用另一把 key 算的 phoneProof → Mac 端 handshake 回 .authFailed */ }
func testPhoneSendsNoEventBeforeMacAuth() { /* iPhone handshake 在收到 auth 前 canSendEvents == false */ }
func testMacWritesNoAppNameBeforePhoneVerified() { /* Mac handshake 未驗證時 statusToSend(appName:"Notes") 的 appName 為 nil */ }
func testSealOpenRoundTripAndTamperFails() { /* 改 1 byte → open 擲錯 */ }
func testReplayFromOldSessionFails() { /* 舊 nonce 的 sealed 事件在新 session open 失敗 */ }
func testRevokedPairingCannotAuthenticate() { /* 刪除 Mac 端配對後同一 iPhone 的 helloReply → .authFailed */ }
```
Mac adapter：`testUnpairedPeripheralIsDisconnectedAndSkippedForSession`、`testPairOfferIgnoredOutsidePairingWindow`。

- [ ] **Step 2: 執行測試，預期 FAIL：`cannot find 'Pairing' in scope`。**
- [ ] **Step 3: 實作 Core（CryptoKit）。**
- [ ] **Step 4: 執行 `swift test`，預期 PASS。**
- [ ] **Step 5: 實作 iPhone 主 App 配對頁、`PairingPeripheral`（只在配對頁顯示時廣播）、Extension 讀取 `PairingStore` 並走握手；未配對時遠端狀態列顯示「尚未配對 Mac，請開啟主 App 配對」。**
- [ ] **Step 6: 實作 Mac 配對時段、SAS 對話框、`MacPairingStore`、選單「解除配對」。**
- [ ] **Step 7: Run all。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T09-PAIRING.md`：配對成功兩端 SAS 相同；解除配對後鍵盤遠端打字 Mac 0 字元；另一台未配對裝置（或刪除 iPhone 端配對）無法注入；重開鍵盤 20 次連上時間仍在 T06 範圍內（P95 ≤ 2 秒）；`log stream` 中無打字內容。
- [ ] **Step 9: 更新驗收報告 T09、spec §5 註記規格差異，commit。**

### Task 10: 原生風格英文鍵盤、頁面切換、頂部區與即時／草稿

**Branch:** `t10-keyboard-ui`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/PageNavigator.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/DraftBuffer.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/InputRouter.swift`（取代 `KeyboardActionRouter` 的遠端分支）
- Create: `iOS/RemoteKeyboardExtension/UI/KeyboardRootView.swift`、`UI/TopAreaView.swift`、`UI/EnglishPageView.swift`、`UI/BottomRowView.swift`、`UI/KeyButton.swift`
- Modify: `Keyboard/KeyAction.swift`、`KeyboardViewController.swift`；`MinimalKeyboardView.swift` 保留不再使用（不刪 source）
- Test: `PageNavigatorTests.swift`、`DraftBufferTests.swift`、`InputRouterTests.swift`、`KeyboardActionRouterTests.swift`
- Evidence: `e2e/E2E-T10-KEYBOARD.md`、`evidence/T10-390.png`、`evidence/T10-*.png`

**Interfaces:**
- Consumes: T08 `EventSender`（草稿送出）、T07 分幀（長草稿）。
- Produces:
  - `KeyAction` 新增 `cursorLeft`、`cursorRight`、`sendDraft`、`toggleTransmit`、`switchChineseEnglish`、`switchSymbols`。
  - `enum TransmitMode: String, Codable, Sendable { case instant, draft }`，存 `rk.transmit`。
  - `enum KeyboardPage: Equatable, Sendable { case chinese, english, symbols(origin: SymbolOrigin) }`、`enum SymbolOrigin: Equatable, Sendable { case chinese, english }`
  - `enum FieldKind: Sendable { case text, emailOrURL, number }`（由 `UIKeyboardType` 映射；`.emailAddress`、`.URL`、`.webSearch` → `emailOrURL`；`.numberPad`、`.decimalPad`、`.numbersAndPunctuation`、`.asciiCapableNumberPad` → `number`）
  - `struct PageNavigator: Sendable { init(lastPage: KeyboardPage?, field: FieldKind, chineseAvailable: Bool); private(set) var page: KeyboardPage; mutating func switchChineseEnglish(); mutating func switchSymbols(); var persistablePage: KeyboardPage }`；`chineseAvailable == false` 時 `中英` 不切換（T12 前恆為 false，按鍵顯示為停用）。存 `rk.page`（只存 chinese 或 english）。
  - `struct DraftBuffer: Sendable { static let maxCharacters = 1_000; private(set) var text: String; private(set) var cursor: Int; var isEmpty: Bool; mutating func insert(_ s: String) -> Bool; mutating func deleteBackward(); mutating func moveLeft(); mutating func moveRight(); mutating func takeEvents() -> [EventKind] }`：游標以 `Character` 計；`insert` 超過上限回傳 `false` 且不改內容；`takeEvents` 依 `"\n"` 切成 `.text`／`.returnKey`、清空並把游標歸 0。
  - `struct InputRouter { init(local: TextSink, remote: RemoteEventSink); func route(_ a: KeyAction, mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draft: inout DraftBuffer) -> RouteOutcome }`
  - 判斷：遠端模式下，`draft` 非空、或 `transmit == .draft`、或 `!ready` → 編輯草稿（`.draftEdited`）；否則即時送出（`.enqueuedRemote`）。`.sendDraft` 只在 `ready && !draft.isEmpty` 時送出全部事件（`.draftSent(count)`），否則 `.rejected`。`.cursorLeft/.cursorRight` 只動草稿，絕不送 Mac。本機模式所有字元寫入 iPhone 欄位，草稿保持不動。
  - `RouteOutcome` 新增 `draftEdited`、`draftSent(Int)`、`transmitToggled(TransmitMode)`、`pageChanged`；移除 T05 的「未就緒 `.rejected`」行為。
- 版面（D17，主代理決定的尺寸）：頂部每行 36 pt；按鍵區 4 行，每行 46 pt、行距 10 pt；鍵盤總高 = 按鍵區 + 可見頂部行數 × 36，切換時以高度約束更新。不使用 Apple 私有資產；字型為系統字。
- 同時處理交接延後項目（T01）：dead guard、router 多餘 case、App Group 字串改用 T09 `AppGroup`、無障礙標籤（每顆鍵 `accessibilityLabel`）、Backspace 長按連續刪除（0.5 秒後每 0.1 秒一次）；本機／遠端掣移到頂部、底列回復原生樣式（使用者 2026-10-30）。

- [ ] **Step 1: 寫失敗測試**

```swift
func testBackspaceEditsDraftWhileDraftNotEmptyInInstant() {
    var draft = DraftBuffer(); _ = draft.insert("香港")
    let (router, _, remote) = makeRouter()
    XCTAssertEqual(router.route(.backspace, mode: .remote, transmit: .instant, ready: true, draft: &draft), .draftEdited)
    XCTAssertEqual(draft.text, "香"); XCTAssertEqual(remote.events, [])
}
func testNotReadyInstantWritesToDraft() { /* ready false、transmit .instant、空草稿 → .draftEdited，remote 0 事件 */ }
func testReadyInstantEmptyDraftSendsImmediately() { /* → .enqueuedRemote，remote == [.text("a")] */ }
func testSendDraftSplitsNewlines() {
    var draft = DraftBuffer(); _ = draft.insert("ab\ncd")
    let (router, _, remote) = makeRouter()
    XCTAssertEqual(router.route(.sendDraft, mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftSent(3))
    XCTAssertEqual(remote.events, [.text("ab"), .returnKey, .text("cd")]); XCTAssertTrue(draft.isEmpty)
}
func testSendDraftRejectedWhenNotReady() { /* ready false → .rejected，草稿不變 */ }
func testArrowKeysNeverReachMac() { /* 即時與草稿下 cursorLeft/Right → remote 0 事件 */ }
func testCursorInsertsInMiddleByGrapheme() { /* "香港你好"，moveLeft×2，insert("人") → "香港人你好"，cursor 3 */ }
func testDraftCapRejectsOverflow() { /* insert 1_000 個 "a" 成功，再 insert("b") 回傳 false */ }
func testLocalModeIgnoresDraft() { /* 草稿 "x"，本機打 "a" → local.inserted == ["a"]，草稿仍為 "x" */ }
func testEmailFieldOpensEnglish() { XCTAssertEqual(PageNavigator(lastPage: .chinese, field: .emailOrURL, chineseAvailable: true).page, .english) }
func testNumberFieldOpensSymbols() { /* → .symbols(origin: .english) */ }
func testSymbolsKeyReturnsToOriginPage() { /* chinese → switchSymbols → .symbols(.chinese) → switchSymbols → .chinese */ }
func testChineseEnglishDisabledWithoutChinese() { /* chineseAvailable false：switchChineseEnglish 後仍 .english */ }
```

- [ ] **Step 2: 執行 `swift test`，預期 FAIL：`cannot find 'DraftBuffer' in scope`。**
- [ ] **Step 3: 實作 `TransmitMode`、`KeyboardPage`、`PageNavigator`、`DraftBuffer`、`InputRouter`；`KeyboardActionRouter` 改為只處理本機模式並由 `InputRouter` 呼叫。**
- [ ] **Step 4: 執行 `swift test`，預期 PASS。**
- [ ] **Step 5: 實作 UI。** `TopAreaView` 三行依 D17；`即時｜草稿` 只在遠端模式顯示；第二行只在遠端且（草稿狀態或草稿非空或未就緒）時顯示；`傳送` 在 `ready && !draft.isEmpty` 時為藍色，否則灰色；候選字列本 Task 先保留空白占位（T12 填入）。`EnglishPageView`：Shift 單按一次大寫、雙按 Caps Lock；`BottomRowView`：`中英`、`符號`、空白鍵、Return；`needsInputModeSwitchKey == true` 時在 `中英` 左側加 🌐。
- [ ] **Step 6: Run all，並以 iOS 模擬器在 390 pt 與最小寬度（iPhone SE 3，375 pt）截圖，確認頂部三行、按鍵不重疊不截字。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T10-KEYBOARD.md` 的 40 項操作表（Shift、Caps、長按刪除、本機／遠端、即時／草稿、草稿中段插入、未就緒寫草稿、就緒後傳送、切回即時時草稿保留、遠端→本機草稿隱藏、email 欄位開英文頁、數字欄位開符號頁⋯）。
- [ ] **Step 8: 更新驗收報告 T10、spec §2（如尺寸有改），commit。**

### Task 11: 符號頁

**Branch:** `t11-symbols`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/SymbolLayouts.swift`
- Create: `iOS/RemoteKeyboardExtension/UI/SymbolPageView.swift`
- Modify: `UI/KeyboardRootView.swift`
- Test: `SymbolLayoutsTests.swift`
- Evidence: `e2e/E2E-T11-SYMBOLS.md`

**Interfaces:**
- Consumes: T10 `KeyboardPage.symbols(origin:)`、`PageNavigator`。
- Produces: `enum SymbolLayouts { static func layers(for origin: SymbolOrigin) -> [[[String]]] }`（層 → 行 → 鍵）。固定內容：
  - 英文第 1 層（同 Apple）：`1 2 3 4 5 6 7 8 9 0`／`- / : ; ( ) $ & @ "`／`. , ? ! '`
  - 英文第 2 層：`[ ] { } # % ^ * + =`／`_ \ | ~ < > € £ ¥ •`／`. , ? ! '`
  - 中文第 1 層（全形）：`1 2 3 4 5 6 7 8 9 0`／`「 」 『 』 （ ） ： ； 、 ～`／`， 。 ？ ！ …`
  - 中文第 2、3 層：分別同英文第 1、2 層。
  - 第 3 行左側為換層鍵，標示下一層（英文：`#+=`／`123`；中文：`半形`／`#+=`／`全形`），右側為刪除。

- [ ] **Step 1: 寫失敗測試：** `testEnglishLayerOneMatchesApple`（逐鍵比對上列字串）、`testChineseLayerOneIsFullWidth`（第 2、3 行每個字元的 Unicode 屬 CJK 標點或全形區）、`testChineseLayersTwoAndThreeEqualEnglish`、`testEveryKeyIsSingleGrapheme`、`testNoDuplicateKeyWithinLayer`。
- [ ] **Step 2: 執行，預期 FAIL：`cannot find 'SymbolLayouts' in scope`。**
- [ ] **Step 3: 實作 `SymbolLayouts` 與 `SymbolPageView`（按鍵送 `.character`，經 `InputRouter` 處理，與英文頁同一路徑）。**
- [ ] **Step 4: 執行，預期 PASS。Run all，390 與 375 pt 截圖。**
- [ ] **Step 5: 實機驗收（使用者，標 TBD）。** 每層全部鍵在本機（Notes）與遠端（TextEdit）各打一次，字元一致；切換層與頁面不重複送出。
- [ ] **Step 6: 更新驗收報告 T11，commit。**

### Task 12: 中文輸入法介面、主 App 設定頁與手寫（Google ML Kit）

**Branch:** `t12-handwriting`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/ChineseInputMethod.swift`（介面與共用型別）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/HandwritingInputMethod.swift`（純邏輯：候選字狀態）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/ChineseMethodResolver.swift`
- Create: `iOS/RemoteKeyboardExtension/Chinese/MLKitRecognizer.swift`（唯一 import ML Kit 的檔案）
- Create: `iOS/RemoteKeyboardExtension/UI/HandwritingPageView.swift`、`UI/CandidateBarView.swift`
- Create: `iOS/RemoteKeyboardApp/SettingsView.swift`
- Create: `Podfile`（或 SPM，見 Step 1）
- Modify: `project.yml`、`UI/KeyboardRootView.swift`、`UI/TopAreaView.swift`、`KeyboardViewController.swift`、`iOS/RemoteKeyboardApp/RemoteKeyboardApp.swift`
- Test: `ChineseInputMethodTests.swift`、`HandwritingInputMethodTests.swift`、`ChineseMethodResolverTests.swift`
- Evidence: `e2e/E2E-T12-HANDWRITING.md`、`evidence/T12-o7-*.md`

**Interfaces:**
- Consumes: T10 `PageNavigator(chineseAvailable:)`、`InputRouter`、候選字列占位。
- Produces:
  - `enum ChineseInputMethodID: String, Codable, CaseIterable, Sendable { case handwriting, quick }`，主 App 寫入 App Group 鍵 `rk.chineseMethod`。
  - `enum IMEInput: Equatable, Sendable { case key(String), shift, backspace, space, returnKey, selectCandidate(Int), recognized([String]), clear }`
  - `struct IMEOutput: Equatable, Sendable { var commit: String?; var composing: String; var candidates: [String]; var passThrough: KeyAction? }`：`commit` 交 `InputRouter`（本機寫入欄位，遠端依即時／草稿）；`passThrough` 表示輸入法不處理、照一般按鍵處理（例如沒有輸入碼時的刪除、空白、Return）。
  - `protocol ChineseInputMethod: Sendable { var id: ChineseInputMethodID { get }; mutating func handle(_ input: IMEInput) -> IMEOutput; mutating func reset() }`：新增倉頡、注音、粵拼只需新實作與 `ChineseInputMethodID` case，鍵盤其他部分不改。
  - `struct HandwritingInputMethod: ChineseInputMethod`：`.recognized(list)` 更新候選字（最多 9 個）；`.selectCandidate(i)` 送出並清空；`.space` 有候選字時送出第 1 個，否則 passThrough；`.backspace` 有候選字時清空候選字與筆跡，否則 passThrough。
  - `enum ChineseMethodResolver { static func effective(saved: ChineseInputMethodID?, hasFullAccess: Bool, installed: Set<ChineseInputMethodID>) -> ChineseInputMethodID? }`：手寫需 Full Access；不可用時改用 `installed` 中的速成；都不可用回傳 `nil`（`chineseAvailable = false`）。
  - `protocol HandwritingRecognizing { func recognize(strokes: [[CGPoint]], in size: CGSize) async throws -> [String] }`，`MLKitRecognizer` 實作；語言標籤以 O7 結果定為 `zh-Hani-TW` 或 `zh-Hani-HK`。
- 同時處理 spec §3 第 11 點：Full Access 關閉時讀取 App Group 的結果記入 E2E。

- [ ] **Step 0: 網路 preflight（`curl -sI https://registry.npmjs.org/ | head -1`、`curl -sI https://cdn.cocoapods.org/ | head -1`）。失敗先查 VPN、LuLu、DNS。**
- [ ] **Step 1: O7 查證（spike，branch `t12-o7-spike`，不 merge）。** 確認 ML Kit Digital Ink 的 iOS 整合方式（CocoaPods `GoogleMLKit/DigitalInkRecognition` 或官方 SPM）、最低 iOS 版本、能否在 Keyboard Extension 下載與載入模型。實機量測：模型下載時間與大小、辨識延遲 P95、Extension 記憶體峰值（`os_proc_available_memory` 前後差），以 20 個常用字各寫一次比較 `zh-Hani-TW` 與 `zh-Hani-HK` 首選正確數。**Gate**：記憶體峰值低於 Extension 上限並留 20% 餘量、延遲 P95 ≤ 500 ms、首選正確 ≥ 18/20。未過 Gate 即停下回報，不進 Step 2。結果寫 `evidence/T12-o7-result.md`，並更新驗收報告 O7。
- [ ] **Step 2: 手寫頁示意圖交使用者選擇（brainstorming visual companion）。** 2–3 款：書寫區大小與位置、辨識觸發（停筆 0.5 秒自動或按鍵）、清除與刪除鍵位置、鍵盤總高度。使用者選定後寫入 spec §2，才繼續。
- [ ] **Step 3: 寫失敗測試**

```swift
func testResolverHandwritingNeedsFullAccess() {
    XCTAssertEqual(ChineseMethodResolver.effective(saved: .handwriting, hasFullAccess: false, installed: [.handwriting, .quick]), .quick)
    XCTAssertNil(ChineseMethodResolver.effective(saved: .handwriting, hasFullAccess: false, installed: [.handwriting]))
}
func testResolverMissingSettingUsesHandwritingWhenAllowed() { /* saved nil、FA true → .handwriting */ }
func testRecognizedFillsCandidatesMaxNine() { /* 12 個結果 → candidates.count == 9 */ }
func testSelectCandidateCommitsAndClears() { /* select 1 → commit 第 2 個、candidates 空 */ }
func testSpaceCommitsFirstCandidate() { }
func testSpaceWithoutCandidatesPassesThrough() { /* passThrough == .space */ }
func testBackspaceClearsCandidatesBeforeDeleting() { /* 有候選字 → 清空、passThrough nil；再按 → passThrough == .backspace */ }
func testCommitInRemoteDraftGoesToDraft() { /* InputRouter：commit "香" 在草稿狀態 → draft.text == "香" */ }
```

- [ ] **Step 4: 執行，預期 FAIL：`cannot find 'ChineseMethodResolver' in scope`。**
- [ ] **Step 5: 實作 Core 型別，執行 `swift test`，預期 PASS。**
- [ ] **Step 6: 加入 ML Kit 依賴（依 Step 1 結果），更新 `project.yml` 與「共用指令」表（若改用 `.xcworkspace`，表中 build 指令一併改）。實作 `MLKitRecognizer`、`HandwritingPageView`、`CandidateBarView`、主 App `SettingsView`（「中文輸入：◉ 手寫 ○ 速成」，速成在 T12b 完成前顯示「即將推出」不可選）。**
- [ ] **Step 7: Run all，390 與 375 pt 截圖。**
- [ ] **Step 8: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T12-HANDWRITING.md`：100 字測例首 3 個候選字命中 ≥ 90%；25 字混合詞語在本機與遠端皆無殘留；鍵盤 30 次切換無 OOM；Full Access 關閉時中文頁不可用、英文照常，且記錄 App Group 能否讀取。
- [ ] **Step 9: 更新驗收報告 T12 與 O7，commit。**

### Task 12b: 速成

**Branch:** `t12b-quick`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/QuickInputMethod.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/QuickDictionary.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Chinese/CangjieRadicals.swift`
- Create: `scripts/make-quick-table.swift`（由倉頡碼表產生速成表）
- Create: `iOS/RemoteKeyboardExtension/Resources/quick-table.txt`、`iOS/RemoteKeyboardExtension/Resources/quick-table-LICENSE.txt`
- Create: `iOS/RemoteKeyboardExtension/UI/QuickPageView.swift`
- Modify: `project.yml`（資源）、`iOS/RemoteKeyboardApp/SettingsView.swift`、`UI/KeyboardRootView.swift`
- Test: `QuickInputMethodTests.swift`、`QuickDictionaryTests.swift`、`CangjieRadicalsTests.swift`
- Evidence: `e2e/E2E-T12B-QUICK.md`、`evidence/T12b-o9-license.md`

**Interfaces:**
- Consumes: T12 `ChineseInputMethod`、`IMEInput`、`IMEOutput`、`ChineseMethodResolver`、`CandidateBarView`。
- Produces:
  - `enum CangjieRadicals { static let byLetter: [Character: String] }`，固定：`a 日 b 月 c 金 d 木 e 水 f 火 g 土 h 竹 i 戈 j 十 k 大 l 中 m 一 n 弓 o 人 p 心 q 手 r 口 s 尸 t 廿 u 山 v 女 w 田 x 難 y 卜 z 重`
  - `struct QuickDictionary: Sendable { init(tableText: String) throws; func candidates(for code: String) -> [String] }`：表格式每行 `碼<TAB>字`，同碼依檔案行序。
  - `struct QuickInputMethod: ChineseInputMethod { init(dictionary: QuickDictionary) }`：輸入碼最多 2 碼，第 3 碼不接受（輸出不變）；`composing` 顯示字根（例如 `日月`）；空白選第 1 個候選字；無候選字時空白不送出任何字、清除輸入碼；Return 有輸入碼時清除輸入碼不送出；`⇧` 後下一個字母以大寫英文送出（passThrough `.character`）。
- O9（spec §3 第 10 點）：先查證來源授權，可隨 App 散布才使用；授權檔放入 `quick-table-LICENSE.txt` 並在主 App 設定頁「授權」列出。速成碼 = 倉頡碼的第一碼加最後一碼（單碼字即該碼）。

- [ ] **Step 0: O9 查證。** 列出 2–3 個開源倉頡碼表來源、授權條款、能否商用與散布；選一個並記錄於 `evidence/T12b-o9-license.md`；授權不明則停下回報。
- [ ] **Step 1: 寫失敗測試**

```swift
func testRadicalMappingCoversAToZ() { XCTAssertEqual(CangjieRadicals.byLetter.count, 26); XCTAssertEqual(CangjieRadicals.byLetter["a"], "日") }
func testCodeABListsMingFirstFromFixture() { /* fixture "ab\t明\nab\t盟" → candidates("ab") == ["明","盟"] */ }
func testThirdCodeIsIgnored() { /* key a、b、c → composing "日月"，candidates 不變 */ }
func testUnknownCodeShowsNoCandidatesAndSpaceCommitsNothing() { /* key z、z（表內無）→ candidates 空；space → commit nil、composing 空 */ }
func testSpaceCommitsFirstCandidate() { }
func testReturnClearsCodeWithoutCommit() { }
func testBackspaceRemovesOneCodeThenPassesThrough() { }
func testShiftTypesOneUppercaseLetter() { /* shift 後 key "a" → passThrough .character("A")，下一個 key 回到輸入碼 */ }
func testGeneratorTakesFirstAndLastCode() { /* 倉頡 "amr" → 速成 "ar"；"a" → "a" */ }
func testMalformedTableLineThrows() { }
```

- [ ] **Step 2: 執行，預期 FAIL：`cannot find 'QuickInputMethod' in scope`。**
- [ ] **Step 3: 實作 Core；以 `scripts/make-quick-table.swift` 產生 `quick-table.txt` 並 commit 產物與授權檔。**
- [ ] **Step 4: 執行 `swift test`，預期 PASS；另加 `testBundledTableLoadsUnder200ms`（以實際表檔量測，記錄行數）。**
- [ ] **Step 5: 實作 `QuickPageView`（鍵面主字為字根、角落小字為英文字母）；設定頁速成改為可選；`ChineseMethodResolver` 的 `installed` 加入 `.quick`。**
- [ ] **Step 6: Run all，390 與 375 pt 截圖。**
- [ ] **Step 7: 實機驗收（使用者，標 TBD）。** 依 `e2e/E2E-T12B-QUICK.md`：50 個常用字以速成打出（本機與遠端）；Full Access 關閉時中文頁為速成且可打字；切換手寫／速成設定後重開鍵盤生效。
- [ ] **Step 8: 更新驗收報告 T12b 與 O9，commit。**

### Task 13: 語音聽寫 Gate

**Branch:** `t13-dictation-gate`

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/ContextDiff.swift`
- Modify: `KeyboardViewController.swift`（`textDidChange` 觀察，只在遠端模式且 Gate 開關開啟時運作）
- Test: `ContextDiffTests.swift`
- Evidence: `e2e/E2E-T13-DICTATION.md`

**Interfaces:**
- Produces: `enum ContextDiff { static func events(before: String, after: String) -> [EventKind] }`：取共同前綴，刪除部分轉為等量 `.backspace`（以 `Character` 計），新增部分為一個 `.text`。
- §6 五項逐項記錄：系統麥克風可見／確實寫入 host App／Extension 收到 `textDidChange`／Extension 能得知確切差分／Mac 收到確切差分，各標 `PASS / FAIL / INCONCLUSIVE`。

- [ ] **Step 1: 寫失敗測試：** `testAppendProducesText`（"你好" → "你好嗎" → `[.text("嗎")]`）、`testCorrectionProducesBackspacesThenText`（"今天天氣" → "今天的天氣" → `[.backspace, .backspace, .text("的天氣")]`）、`testEmojiCountsAsOneBackspace`、`testNoChangeProducesNothing`。
- [ ] **Step 2: 執行，預期 FAIL；實作；執行，預期 PASS。**
- [ ] **Step 3: 探測 build：遠端模式加 DEBUG 開關，聽寫期間只記錄差分長度（不記文字）。Run all。**
- [ ] **Step 4: 實機 Gate（使用者，標 TBD）。** 中英各 50 句，記錄五項結果。全部 PASS 才把同步功能開放於正式設定；任一 FAIL 或 INCONCLUSIVE：語音 Gate 記 FAIL，停下回報，主 App 手動語音頁另以 writing-plans 規劃（D7）。
- [ ] **Step 5: 更新驗收報告 T13，commit。**

### Task 14: 跨 App 相容性與焦點安全矩陣

**Branch:** `t14-compat-matrix`

**Files:**
- Modify: `macOS/MacReceiver/Focus/FocusMonitor.swift`（AX 讀取移出主執行緒）、`macOS/MacReceiver/Input/TestInsertController.swift`（gate 等待後再檢查焦點）、`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/InputSourceSwitcher.swift`（切回失敗回報）
- Test: `macOS/MacReceiverTests/FocusMonitorTests.swift`、`InjectionAdapterTests.swift`、`InputSourceSwitcherTests.swift`
- Evidence: `e2e/E2E-T14-MATRIX.md`、`evidence/T14-matrix.csv`

**Interfaces:**
- Produces: `SwitchResult` 新增 `.injectedRestoreFailed`；`EventPipeline` 對其回 `.posted` 並令 Mac 面板顯示「輸入法未能切回，請手動切換」。
- 同時處理交接延後項目：AX 讀取在主執行緒（T04）、切回失敗只記 log（T04）、測試插入 gate 後未再查焦點（T05）。

- [ ] **Step 1: 寫失敗測試：** `testRestoreFailureIsReportedNotSilent`、`testTestInsertRechecksFocusAfterGate`、`testSlowAXReadDoesNotBlockMainThread`（fake AX 延遲 2 秒，主執行緒 tick 不中斷）。
- [ ] **Step 2: 執行，預期 FAIL；實作；執行，預期 PASS。Run all。**
- [ ] **Step 3: 矩陣（使用者，標 TBD）。** Mac 輸入法（ABC、注音、倉頡、速成、粵拼）× Mac App（TextEdit、Notes、Safari 網址列與網頁輸入框、Chrome、VS Code、Word、Messages）；iPhone 端本機與遠端、英文／手寫／速成／符號。每格記錄：字元一致、組字取消、切回輸入法、錯誤焦點 0 次。阻擋第三方鍵盤的 iPhone 欄位（密碼、電話）確認回到系統鍵盤。
- [ ] **Step 4: 更新驗收報告 T14、spec §5（實測 settle 值若有更新），commit。**

### Task 15: 穩定性、權限與長時間測試

**Branch:** `t15-stability`

**Files:**
- Create: `iOS/RemoteKeyboardExtension/Debug/BurstGenerator.swift`（只在 DEBUG build 編入）
- Create: `macOS/MacReceiver/Diagnostics/BurstVerifier.swift`（只在 DEBUG build 編入）
- Test: `BurstFormatTests.swift`（Core）
- Evidence: `e2e/E2E-T15-STABILITY.md`、`evidence/T15-*.csv`

**Interfaces:**
- Produces: `enum BurstFormat { static func line(_ n: Int) -> String; static func verify(_ text: String, expected count: Int) -> BurstReport }`；`struct BurstReport: Equatable { let missing: [Int]; let duplicated: [Int]; let outOfOrder: [Int] }`。每行格式 `"#\(n)\n"`，n 由 1 起。
- D8：T06 已達標，LAN WebSocket 不做；驗收報告 T15 的 Wi-Fi 項目記 N/A 並引用 T06。

- [ ] **Step 1: 寫失敗測試：** `testVerifyFindsMissingDuplicateAndOrder`、`testCleanRunReportsNothing`。
- [ ] **Step 2: 執行，預期 FAIL；實作；執行，預期 PASS。**
- [ ] **Step 3: 實作 DEBUG burst（鍵盤設定隱藏手勢觸發，送 10,000 行）與 Mac 端以 AX 讀 TextEdit 內容驗證。Run all。**
- [ ] **Step 4: 實機（使用者，標 TBD）。** 10,000 事件 0 遺漏／0 重複／0 亂序；權限撤銷情境各 3 次：Mac 撤銷輔助使用、iPhone 關 Full Access、藍牙關閉、Mac 睡眠喚醒、iPhone 鎖屏；每種情境 fail closed 且恢復後可再打字。
- [ ] **Step 5: 更新驗收報告 T15，commit。**

### Task 16: Release Candidate QA

**Branch:** `t16-rc-qa`

**Files:**
- Modify: `ReceiverPanel.swift`（`unavailable` 顯示原因、輔助使用未授權時鍵盤顯示「Mac 未授權輔助使用」而非「無輸入欄位」）、`StatusLine.swift`、`ReconnectUITests.swift`
- Test: `StatusLineTests.swift`、`macOS/MacReceiverTests/ReceiverBLECentralTests.swift`（central 層 CoreBluetooth 接線）
- Evidence: `e2e/E2E-T16-RC.md`、更新 `README.md`

- [ ] **Step 1: 寫失敗測試：** `testReceiverNotAuthorizedShowsAuthorizationText`、`testCentralAdapterForwardsDidConnectAndDisconnect`（以 fake manager 驗證接線）。
- [ ] **Step 2: 執行，預期 FAIL；實作；執行，預期 PASS。**
- [ ] **Step 3: UI test 清理：Notes 停在某則備忘錄時先返回列表；Safari 網址列查找不再多等 3 秒；以 identifier 優先比對，避免比對到網頁內同名按鈕；`testProbeLabels` 輸出前移除資料夾名稱與網頁標題。**
- [ ] **Step 4: Run all。**
- [ ] **Step 5: 實機（使用者，標 TBD）。** 完成交接文件「延至 T16 最後測試的實機項目」全表（T03b 登入項目、T04 五組字串與注音 20 次、O5 長度上限、T05 逐次紀錄與錄影、T06 親手 10 次錄影⋯），並把實測值寫入 spec §5。
- [ ] **Step 6: Release checklist 全部勾選；README 狀態段更新；驗收報告 T16，commit。**

**計劃狀態：** v1.3（2026-10-30）待使用者批准。T01–T06 PASS（6/17）。
