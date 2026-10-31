# iPhone 觸控板模式（D25）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先以 TP1 量測 BLE 是否能讓觸控到游標可見 P95 < 60 ms；通過決策關卡後，再依序完成 0x03 指標協定、Mac 端注入、鍵盤觸控板頁與整合測試。

**Architecture:** 沿用既有 service 與兩個 characteristic。Mac 依 notification 首 byte 分流：`0x02` 走既有 FrameReassembler，`0x03` 走新的 `PointerReceiver`。封包、加密、防重播、去重、累加器、手勢判定、加速曲線、看門狗全部是 `RemoteKeyboardCore` 純邏輯（`swift test`）；CoreBluetooth、UIKit、CGEvent 只做薄 adapter。

**Tech Stack:** Swift 6.4（language mode 6）、CryptoKit（ChaChaPoly、HKDF）、CoreBluetooth、UIKit、CoreGraphics（CGEvent）、XCTest、XcodeGen、CocoaPods。

**Spec:** `docs/superpowers/specs/2026-11-01-trackpad-design.md`（D25，草稿待批准）；上層 `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`；依據 `docs/superpowers/research/2026-11-01-trackpad-research-review.md`。

## Global Constraints

- 不改：`KeyboardEvent.protocolVersion` = 3、`FrameCodec` 0x02 格式、`FrameReassembler`、配對、握手、`EventDeduplicator`、長文字傳送。
- 不新增 GATT characteristic；service `706AA642-68A3-41FA-889D-24E30709B0D0`、`event` `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`、`control` `320468E2-53B6-4B6A-88EC-AE2752415818`。
- 0x03 只在「已認證＋Mac 開關開＋status 帶 `pointer`＋`pointerOpen` 已 ACK」後才送與處理；每個 0x03 都經 AEAD 驗證。
- 所有標 Provisional 的數值（spec §14）在 TP1／TP5 實測前不得寫成已驗證。
- log 只記 opcode、長度、計數器間隔、延遲統計、錯誤碼；不得含位移、座標、點擊位置、輸入文字、App 名稱。
- 量測封包 `0x7E` 只存在於 `#if DEBUG`；Release build 收到 `0x7E` 一律略過。
- 每個 Task 結束必須全綠：`swift test --package-path Packages/RemoteKeyboardCore`、`MacReceiverTests`、iOS 模擬器 build、真機 build-for-testing；並重跑 `HitAreaUITests`（真機）。
- 建置：改 `project.yml` 後 `xcodegen generate` 再 `LANG=en_US.UTF-8 pod install`；build 用 `-workspace RemoteKeyboard.xcworkspace`；不提交 `*.xcodeproj`、`*.xcworkspace`、`Pods/`。
- 實機驗收標 TBD，使用者親手測完才算 PASS；介面文字用台灣繁體中文。
- 實機：iPhone 17 Pro，UDID `00008150-000C65DA26C0401C`；模擬器沒有 CoreBluetooth。

## 執行規則

- 每個 Task 一個 worktree、一條 branch、一個 PR；Sonnet 子代理寫程式，不得 commit 或 push；主代理重跑全部驗證並經獨立 reviewer 審查後 commit、開 PR、merge。
- 每個 Task 完成即停下回報。**TP1 完成後必須停在決策關卡，由使用者決定是否進入 TP2。**
- TP4 開始前先向使用者提 2–3 個觸控板頁 UI 方向，選定後才寫 UI。

## Review Focus

1. **長文字傳送途中開始移動游標**：0x03 不可插進 0x02 多 frame 訊息導致殘片被丟，也不可排在長文字後面造成游標延遲。由 TP2 `testMoveWaitsWhileNotifyQueueHasFrames` 與 TP3 `testPointerPacketDuringLongMessageKeepsPartial` 覆蓋。
2. **拖曳中鍵盤被系統收起或 Extension 被暫停**：Mac 必須在 350 ms 內放開左鍵，且一般延遲下不得誤放開。由 TP3 `testWatchdogReleasesAfter350ms`、`testHeartbeatEvery100msKeepsButtonDown` 與 TP1 M6、TP5 實機覆蓋。
3. **ACK 遺失後重送點擊**：同一 `actionId` 只點一次，即使中間夾了 64 個以上其他可靠事件也不得重新點擊。由 TP2 `testDuplicateActionIdIsAckedNotExecuted`、`testActionIdOlderThanWindowIsRefused` 覆蓋。
4. **重連後計數器歸零**：新連線必須是新金鑰；同一連線內切頁不得歸零。由 TP2 `testNewSessionUsesDifferentKey`、`testReopenWithinSessionKeepsCounter` 覆蓋。
5. **Mac 關閉觸控板開關時正在拖曳**：立即放開並停止處理 0x03。由 TP3 `testDisablingSwitchReleasesButtons` 覆蓋。

---

### Task TP1: 量測工具與決策關卡

Branch：`tp1-measurement`。只做 DEBUG 量測工具，不做正式協定或觸控板 UI。

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Measurement/MeasureProbe.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Measurement/LatencyStats.swift`
- Test: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/MeasureProbeTests.swift`、`LatencyStatsTests.swift`
- Create: `iOS/RemoteKeyboardExtension/Debug/MeasurementRunner.swift`（`#if DEBUG`）
- Create: `iOS/RemoteKeyboardExtension/Debug/MeasurementTouchView.swift`（`#if DEBUG`，M4 測試觸控面）
- Modify: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`（DEBUG：`sendRaw(_:) -> Bool`、`didReceiveWrite` 在 JSON 解碼前分流 `0x7E`、`setLatency(_:)`）
- Modify: `iOS/RemoteKeyboardExtension/KeyboardViewController.swift`、`UI/DictationProbePanel.swift`（DEBUG 面板加量測按鈕）
- Create: `macOS/MacReceiver/Diagnostics/MeasurementEcho.swift`（`#if DEBUG`）
- Modify: `macOS/MacReceiver/Bluetooth/ReceiverBLECentral.swift`（`receive(eventData:)` 在 reassembler 前分流首 byte；DEBUG 才處理 `0x7E`）
- Modify: `macOS/MacReceiver/ReceiverPanel.swift`（DEBUG「量測模式」開關，預設關）
- Test: `macOS/MacReceiverTests/MeasurementEchoTests.swift`
- Create: `e2e/E2E-TP1-MEASURE.md`、`docs/superpowers/verification/evidence/TP1-*.csv`（由量測產生）
- Modify: 驗收報告加 TP1 列

**Interfaces:**
- Produces（Core）：
  - `public struct MeasureProbe: Equatable, Sendable { public static let magic: UInt8 = 0x7E; public let kind: Kind; public let seq: UInt32; public let phoneTimeMicros: UInt64; public let dxSixteenths: Int16 }`，`public enum Kind: UInt8 { case burst = 1, rtt = 2, cursor = 3, heartbeat = 4 }`
  - `public static func encode(_ p: MeasureProbe, totalBytes: Int) -> Data`（不足補 0；`totalBytes` 41 或 182）；`public static func decode(_ d: Data) -> MeasureProbe?`
  - `public struct MeasureEcho { public let seq: UInt32; public let phoneTimeMicros: UInt64; public let macHoldMicros: UInt32 }`，`encode() -> Data`（首 byte `0x7E`）、`static func decode(_:) -> MeasureEcho?`
  - `public struct LatencyStats { public init(samplesMs: [Double]); public var p50: Double; p95: Double; p99: Double; jitterMs: Double /* P95 − P50 */; count: Int }`
- Produces（Mac，供 TP3 沿用）：`ReceiverBLECentral.receive(eventData:)` 依首 byte 分流到 `eventFrameHandler`（0x02）與 `pointerHandler: ((Data) -> Void)?`（0x03，TP1 先留空不處理）。

- [ ] **Step 1: 寫 Core 測試（RED）**

```swift
func testProbeRoundTrip41Bytes() // encode(totalBytes: 41).count == 41；decode 回原值；data[0] == 0x7E
func testProbeRoundTrip182Bytes() // count == 182
func testDecodeRejectsWrongMagicOrShort() // 0x02 開頭 → nil；少於 16 bytes → nil
func testEchoRoundTrip()
func testStatsPercentiles() // samples 1...100 → p50 == 50.5、p95 == 95.05、p99 == 99.01（線性內插），jitter == p95 - p50
func testStatsEmpty() // count == 0，百分位為 .nan
```

- [ ] **Step 2: 執行 `swift test --package-path Packages/RemoteKeyboardCore --filter "MeasureProbeTests|LatencyStatsTests"`，預期 FAIL（型別不存在）**
- [ ] **Step 3: 實作 `MeasureProbe`、`MeasureEcho`、`LatencyStats`**（純值型別，big-endian）
- [ ] **Step 4: 同指令，預期 PASS；全套 Core 測試全綠**
- [ ] **Step 5: Mac 測試（RED）`MeasurementEchoTests`**

```swift
func testEchoOnlyWhenMeasureModeOnAndLinkReady() // 模式關或未認證 → 不回寫
func testNon02FrameDoesNotTouchReassembler() // 先送 0x02 長訊息第 1 frame，再送 0x7E，再送第 2 frame → 長訊息完整
func testCursorProbeMovesByDxTimesOne() // 注入 fake poster，dxSixteenths 32 → 位移 2 pt
func testCsvHasNoCoordinates() // CSV 標頭只含 seq、kind、bytes、interArrivalMicros、holdMicros
```

- [ ] **Step 6: 實作 Mac 分流與 `MeasurementEcho`**：回寫經 control（write with response，raw `MeasureEcho`）；記錄到 `~/Library/Logs/RemoteKeyboard/measure-<日期>.csv`；M4 cursor probe 以 `CGEvent .mouseMoved` 倍率 1 移動。
- [ ] **Step 7: 實作 iPhone DEBUG 量測**：
  - `MeasurementRunner`：M2（ready 回呼中連送直到 `false`，各 100 輪，41／182 bytes）、M3（41 bytes、60 Hz、10,000 個，收到 echo 算 RTT）、M5（M3 同時用既有 `sendDebugLongText()` 送 3,000 字）、M6（每 100 ms heartbeat 探針，Mac 端 350 ms 看門狗只記錄「會放開」事件不注入）。
  - `setLatency`：面板可切 `.low`／`.medium`／不設定。
  - `MeasurementTouchView`：觸碰時整塊閃白一格；`touchesMoved` 用 `coalescedTouches` 累加，每 16.7 ms 送一個 cursor probe。
  - `didReceiveWrite`：首 byte `0x7E` 時（DEBUG）交 `MeasurementRunner`，不走 `ControlCodec`。
  - 結果只在面板顯示統計，並寫 App Group 外的 Extension 暫存 CSV（同 Mac 欄位規則）。
- [ ] **Step 8: 驗證**：Core、`MacReceiverTests`、iOS 模擬器 build、真機 build-for-testing、Mac build 全過；`grep -rn "0x7E\|MeasureProbe" iOS macOS` 確認全部在 `#if DEBUG` 內；Release 設定 build Mac 並以單元測試確認 0x7E 被略過。
- [ ] **Step 9: 寫 `e2e/E2E-TP1-MEASURE.md`**：M1（PacketLogger 安裝與擷取步驟、三種延遲偏好各 10 次 × 60 秒）、M2–M6 操作步驟、M4 錄影方法（另一支手機 240 fps，同框 iPhone 與 Mac 游標，≥ 100 次，逐格計數 × 4.167 ms）、回填表格。
- [ ] **Step 10: 主代理在實機跑 M2、M3、M5、M6（可自動部分），使用者跑 M1、M4**；結果填入驗收報告（實機項 TBD 直到使用者確認）。
- [ ] **Step 11: 第一階段驗收對照（使用者 2026-11-01 指定）**

| 指標 | 目標 | 在哪裡驗證 |
|---|---|---|
| 觸控到游標可見 P95 | < 60 ms | TP1 M4（量測封包）；TP5 以正式協定重測 |
| P50／P99 | 完整記錄，不設門檻 | TP1 M3、M4 |
| BLE connection interval | 實測分佈 | TP1 M1 |
| 背壓 | 不累積過時 MOVE | TP1 M5；TP2 `testBlockedTransmitAccumulatesSingleMove` |
| 重複點擊 | 0 次 | TP2、TP3 單元測試；TP5 實機 |
| 斷線後卡住拖曳 | 0 次 | TP1 M6 只量看門狗誤放開；TP3 單元測試；TP5 實機 100 次 |
| 現有鍵盤回歸 | 全部通過 | 每個 Task 的全套測試＋TP5 |

- [ ] **Step 12: 決策關卡報告** `docs/superpowers/verification/2026-11-xx-tp1-decision.md`：各指標 P50／P95／P99／jitter、M5 是否積壓、M6 誤放開次數、建議（進 TP2，或分解瓶頸後重測）；並把 spec §14 已量到的 Provisional 值改成實測值。停下等使用者決定。
- [ ] **Step 13: Commit／PR**（主代理）

---

### Task TP2: 指標協定（Core）

Branch：`tp2-pointer-protocol`。只動 Core 與相容欄位。

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/PointerPacket.swift`、`PointerSession.swift`、`ReplayWindow.swift`、`ActionDeduplicator.swift`、`PointerSender.swift`、`ReliableQueue.swift`
- Modify: `Shared/KeyboardEvent.swift`（`EventKind.pointerOpen(version: Int)`、`pointerClose`；`carriesFocusEpoch` 回 false）、`Shared/ControlMessage.swift`（`ReceiverStatus.pointer: Bool`、`doubleClickMs: Int?`，預設值不寫入；`ControlMessage.pointerAck(actionIds: [UInt32])`）、`Shared/AuthHandshake.swift`（`sealControl` 允許 `pointerAck`；兩端 reducer 提供 `pointerKey`）
- Test: 對應 `*Tests.swift`

**Interfaces:**
- Produces：
  - `public enum PointerOpcode: UInt8 { case move = 0x01, scroll = 0x02, click = 0x10, buttonState = 0x11, heartbeat = 0x12, gesture = 0x20 }`
  - `public struct PointerPayload: Equatable, Sendable { opcode, buttons: UInt8, dxSixteenths: Int16, dySixteenths: Int16, dtTenthsMs: UInt16, actionId: UInt32, arg: UInt8, status: UInt8 }`；`encode() -> Data`（16 bytes）、`static func decode(_:) throws -> PointerPayload`
  - `public enum PointerKey { public static func derive(pairKey: SymmetricKey, macNonce: Data, phoneNonce: Data) -> SymmetricKey }`（info `"rk-pointer-p2m"`）
  - `public struct PointerSealer { init(key:); mutating func seal(_ p: PointerPayload) throws -> Data /* 41 bytes */ }`；`public struct PointerOpener { init(key:); mutating func open(_ packet: Data) -> Result<PointerPayload, PointerOpenError> }`（`PointerOpenError`: `.badMagic, .badLength, .replayed, .tooOld, .authFailed, .badReserved`）
  - `public struct ReplayWindow { mutating func check(_ c: UInt64) -> Bool; mutating func commit(_ c: UInt64) }`
  - `public struct ActionDeduplicator { init(capacity: Int = 64); func seen(_ id: UInt32) -> Bool; mutating func record(_ id: UInt32) }`
  - `public struct PointerSender`：`mutating func addMotion(dx: Double, dy: Double, dt: Double)`、`mutating func nextMove(notifyQueueEmpty: Bool, transmitBlocked: Bool) -> PointerPayload?`、`mutating func enqueueReliable(_ p: PointerPayload) -> UInt32 /* actionId */`、`mutating func acked(_ ids: [UInt32])`、`mutating func dueRetransmits(now: TimeInterval) -> [PointerPayload]`、`mutating func heartbeatIfNeeded(now:) -> PointerPayload?`

- [ ] **Step 1: 測試（RED）**

```swift
// PointerPacketTests
func testPayloadIs16BytesAndPacketIs41()
func testTamperAnyByteIsRejected() // 逐一翻轉 41 個 byte 的 1 bit → 全部 .authFailed 或 .badMagic
func testNonZeroReservedRejected()
func testNonceIsPTR3PlusCounter()
// PointerSessionTests
func testCounterStrictlyIncreasesAcrossAllPackets() // 1,000 個含重送 → 計數器嚴格遞增、無重複
func testNewSessionUsesDifferentKey() // 不同 macNonce → 封包互不能開
func testReopenWithinSessionKeepsCounter() // pointerClose 後 pointerOpen → 計數器延續
func testPointerKeyDiffersFromEventKey()
// ReplayWindowTests
func testReplayRejected(); func testOutOfOrderWithin64Accepted(); func testOlderThan64Rejected(); func testCommitOnlyAfterAuth()
// ActionDeduplicatorTests
func testDuplicateActionIdIsAckedNotExecuted(); func testActionIdOlderThanWindowIsRefused() // id ≤ 最大已執行 − 64 → 不執行但回 ACK
// PointerSenderTests
func testMoveWaitsWhileNotifyQueueHasFrames()
func testBlockedTransmitAccumulatesSingleMove() // 阻塞期間 100 次 addMotion → 恢復後只出 1 個 MOVE，總和正確，status bit0 = 1
func testQuantizationKeepsRemainder() // 1,000 次 0.01 pt → 送出總和誤差 < 1/16 pt
func testReliableFlushesMotionAsMoveFirst() // 有未送位移時 enqueueReliable → 先出 MOVE，再出 CLICK；CLICK 的 dx、dy、dt 皆 0
func testRetransmitUsesSameActionIdNewCounter() // 重送封包明文完全相同，計數器不同
func testAbandonAfterThreeRetries() // CLICK 放棄並計數；BUTTON_STATE 放開不放棄
func testSessionStateNeverPersisted() // PointerSession 不符合 Codable；Core 內無 UserDefaults／Keychain 參照（以原始碼 grep 測試）
func testReliableQueueCapacity8()
func testHeartbeatEvery100msWhileButtonDown(); func testNoHeartbeatWhenNoButton()
// 相容
func testStatusWithoutPointerEncodesSameBytesAsBefore()
func testOldStatusBytesDecodeWithPointerFalse()
func testPointerOpenNotSentInKeyboardV3TextPath() // 既有 EventKind 編碼不變
```

- [ ] **Step 2: 執行，預期 FAIL**
- [ ] **Step 3: 實作**（數值依 spec §6–§8；Provisional 數值集中在 `PointerTuning` 一個 struct，方便 TP5 調整）
- [ ] **Step 4: 全套 Core 測試 PASS；既有測試數不減少**
- [ ] **Step 5: 更新 spec §12 相容性實際欄位、驗收報告 TP2 列；Commit／PR**

---

### Task TP3: Mac Receiver 指標處理

Branch：`tp3-mac-pointer`。

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/PointerAcceleration.swift`、`PointerButtonState.swift`、`PointerWatchdog.swift`、`ScrollPhaseTracker.swift`（純邏輯）
- Create: `macOS/MacReceiver/Pointer/PointerReceiver.swift`、`PointerInjector.swift`（CGEvent adapter，以 protocol 注入方便測試）、`ScreenClamp.swift`
- Modify: `ReceiverBLECentral.swift`（`pointerHandler` 接 `PointerReceiver`；`pointerAck` 合併寫入）、`Pipeline/EventPipeline.swift`（`pointerOpen`／`pointerClose` 在去重與焦點檢查前處理，同 `ping`／`probe`）、`Pipeline/ReceiverCoordinator.swift`（`pointerOpen`／`pointerClose`、status 帶 `pointer` 與 `doubleClickMs`、斷線清理、計時延長）、`ReceiverPanel.swift`（「允許觸控板控制」開關，預設關，存 UserDefaults）
- Test: Core 測試＋`macOS/MacReceiverTests/PointerReceiverTests.swift`

**Interfaces:**
- Consumes：TP2 全部 Pointer 型別；TP1 的首 byte 分流。
- Produces：`protocol PointerInjecting { func move(to: CGPoint, delta: CGVector, dragging: CGMouseButton?); func button(_: CGMouseButton, down: Bool, at: CGPoint, clickState: Int); func scroll(dx: Int32, dy: Int32, phase: ScrollPhase); func shortcut(_: PointerGesture) }`
- `public struct PointerAcceleration { init(g0: Double = 1.25, v0: Double = 550, gmax: Double = 3.5); func gain(dx: Double, dy: Double, dtSeconds: Double) -> Double }`（`dt` 夾 0.005–0.15 s）

- [ ] **Step 1: 測試（RED）**

```swift
func testGainAtZeroIsG0(); func testGainMonotonic(); func testGainApproachesGmax() // v = 1e6 → |g − 3.5| < 0.01
func testGainAt550IsMidpoint() // g == 1.25 + 2.25 / 2
func testPointerIgnoredBeforePointerOpen()
func testPointerIgnoredWhenSwitchOff()
func testPointerPacketDuringLongMessageKeepsPartial()
func testMoveThenClickOrder() // CLICK 帶位移 → 先 move 再 down/up
func testDuplicateClickInjectsOnce() // 同 actionId 3 次 → 1 次點擊、3 次 ACK
func testButtonStateSendsOnlyDifferences()
func testMoveButtonsRepairLostButtonState() // 漏掉 BUTTON_STATE 放開，下一個 MOVE buttons = 0 → 送 up
func testButtonsFromOlderCounterIgnored() // 視窗內亂序的舊封包不改按鍵狀態
func testChangedWithoutBeganStartsScroll()
func testPointerOpenBypassesDedupAndFocus() // 無焦點時 pointerOpen 仍回 posted；重複 pointerOpen 也回 posted；之後文字事件 seq 檢查不受影響
func testPointerAcksBatchedOneInFlight() // 在途時新增 3 個 id → 下一次寫入含 3 個
func testGoodbyeWaitsForPointerAckWrite()
func testGestureAckMeansPosted()
func testWatchdogReleasesAfter350ms(); func testHeartbeatEvery100msKeepsButtonDown()
func testScrollWatchdogEndsPhaseAfter150ms()
func testDisconnectReleasesAllButtonsAndEndsScroll()
func testDisablingSwitchReleasesButtons()
func testEightConsecutiveAuthFailuresClosePointer(); func testSingleAuthFailureKeepsPointer()
func testClampKeepsCursorInsideScreenUnion()
func testValidPointerPacketExtendsIdleTimer()
func testLogHasNoCoordinates() // 擷取 log 字串，不得含 dx、dy、x=、y= 數值
```

- [ ] **Step 2: FAIL → Step 3: 實作 → Step 4: PASS（Core＋MacReceiverTests）**
- [ ] **Step 5: 回歸**：既有 `EventPipelineTests`、`ReceiverSecurityTests`、`ReceiverGoodbyeTests` 全過；Mac 安裝後打字、長文字實機回歸（TBD 由使用者確認）。
- [ ] **Step 6: 驗收報告 TP3 列；Commit／PR**

---

### Task TP4: 鍵盤觸控板頁

Branch：`tp4-trackpad-ui`。

- [ ] **Step 0: UI 方向（停下等使用者選）**：提出 2–3 個方向（進入鍵位置、頁面外觀、是否有左右鍵區、如何返回打字），附預覽截圖；選定後寫入 spec §17 再開始。

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/TrackpadGestureRecognizer.swift`（純邏輯，§9 表格）
- Create: `iOS/RemoteKeyboardExtension/UI/TrackpadPageView.swift`；Modify: `PageNavigator`、`BottomRowView`（依 Step 0）、`KeyboardViewController`、`KeyboardBLEPeripheral`（0x03 傳送、`pointerAck` 處理、`.low`／`.medium` 切換、阻塞規則）
- Test: `TrackpadGestureRecognizerTests.swift`、`iOS/RemoteKeyboardUITests/TrackpadUITests.swift`

**Interfaces:**
- Consumes：TP2 `PointerSender`、`EventKind.pointerOpen/pointerClose`、`ControlMessage.pointerAck`、`ReceiverStatus.pointer/doubleClickMs`。
- Produces：`public struct TrackpadGestureRecognizer { mutating func touches(_ e: TouchSample) -> [TrackpadOutput] }`，`TouchSample { id: Int, phase: Phase, location: CGPoint, time: TimeInterval }`，`TrackpadOutput { .move(dx,dy,dt), .click(button, count), .buttonState(UInt8), .scroll(dx,dy,dt,phase), .gesture(PointerGesture) }`

- [ ] **Step 1: 測試（RED）**

```swift
func testTapWithin200msAnd8ptIsLeftClick(); func testSlowTouchIsNotClick() // 250 ms
func testDoubleTapUsesMacInterval() // doubleClickMs 300：間隔 280 → count 2；320 → 兩個 count 1
func testDoubleTapHoldStartsDragAndReleaseEnds()
func testTwoFingerTapIsRightClick(); func testTwoFingerMoveScrollsBeganChangedEnded()
func testThreeFingerSwipeLeft40pt(); func testPinch20PercentZoom()
func testCancelledTouchesReleaseAndCancelScroll()
func testTrackpadHiddenWhenMacHasNoPointerCapability() // UI 測試或 ViewModel 測試
func testLeavingTrackpadSendsPointerCloseAndRelease()
```

- [ ] **Step 2: FAIL → Step 3: 實作 → Step 4: PASS**；模擬器截圖 390／402 pt 寬兩種。
- [ ] **Step 5: 回歸**：`HitAreaUITests` 13/13、`KeyboardT10UITests`、`ReconnectUITests`（真機）。
- [ ] **Step 6: 驗收報告 TP4 列；Commit／PR**

---

### Task TP5: 整合測試與參數定案

Branch：`tp5-integration`。

**Files:**
- Create: `e2e/E2E-TP5-TRACKPAD.md`、`docs/superpowers/verification/2026-11-xx-tp5-report.md`
- Modify: `PointerTuning`（依實測調整）、spec §14（實測值）、驗收報告、`e2e/E2E-T16-RC.md`（加觸控板組與總數）、README

- [ ] **Step 1: 自動測試**：Release build 收到 `0x7E` 略過（單元測試）；未協商的 0x03 被略過；全套測試全綠。
- [ ] **Step 2: 實機清單（使用者，TBD）**：

| 項目 | 次數 | 通過條件 |
|---|---|---|
| 觸控到游標可見（240 fps） | ≥ 100 | P95 < 60 ms；記錄 P50／P99 |
| 點擊、雙擊、右鍵 | 各 50 | 重複點擊 0 次、漏點記錄 |
| 拖曳中收起鍵盤、鎖屏、切 App、關 Mac 藍牙 | 各 25（共 100） | 卡住拖曳 0 次 |
| 一般拖曳 60 秒靜止按住 | 20 | 誤放開 0 次 |
| 長文字傳送中移動游標 | 10 | 長文字完整、游標無連續重播 |
| 捲動：Safari、Notes、Finder、Xcode、Chrome、Preview | 各 20 | 方向正確、phase 無殘留 |
| 三指與捏合快捷鍵 | 各 10 | 對應動作正確 |
| Mac 開關關閉中拖曳 | 10 | 立即放開 |
| 加速曲線三組對照（A 曲線三組＋B 三次曲線） | 每組 3 輪 | 使用者選定 |
| 現有鍵盤回歸（T16 B 組、長文字 3,000 字、配對、重連 20 次） | — | 全部通過 |

- [ ] **Step 3: 依實測更新 `PointerTuning` 與 spec §14，把定案值的 Provisional 標記移除並註明來源量測**
- [ ] **Step 4: 決定捲動慣性是否做第二階段（寫入報告，等使用者決定）**
- [ ] **Step 5: Commit／PR**
