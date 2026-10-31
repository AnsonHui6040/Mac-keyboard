# iPhone 觸控板模式（D25）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先以 TP1 量測 BLE 是否能讓觸控到游標可見 P95 < 60 ms；通過決策關卡後，再依序完成 0x03 指標協定、Mac 端注入、鍵盤觸控板頁與整合測試。

**Architecture:** 沿用既有 service 與兩個 characteristic。Mac 依 notification 首 byte 分流：`0x02` 走既有 FrameReassembler，`0x03` 走新的 `PointerReceiver`，`0x7E`（只限 DEBUG）走量測。`0x03` 與 `0x7E` 共用同一種計數器 AEAD 信封（獨立金鑰、計數器 nonce、64 位元防重播）。封包、加密、防重播、去重、有序出口、手勢判定、加速曲線、看門狗、開關版本全部是 `RemoteKeyboardCore` 純邏輯（`swift test`）；CoreBluetooth、UIKit、CGEvent 只做薄 adapter。

**Tech Stack:** Swift 6.4（language mode 6）、CryptoKit（ChaChaPoly、HKDF）、CoreBluetooth、UIKit、CoreGraphics（CGEvent）、XCTest、XcodeGen、CocoaPods。

**Spec:** `docs/superpowers/specs/2026-11-01-trackpad-design.md`（D25 修訂 2）；上層 `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`；依據 `docs/superpowers/research/2026-11-01-trackpad-research-review.md`。

## Global Constraints

- 不改：`KeyboardEvent.protocolVersion` = 3、`FrameCodec` 0x02 格式、`FrameReassembler`、配對、握手流程、`EventDeduplicator`、長文字傳送。
- 不新增 GATT characteristic；service `706AA642-68A3-41FA-889D-24E30709B0D0`、`event` `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`、`control` `320468E2-53B6-4B6A-88EC-AE2752415818`。
- **所有 `0x03` 與 `0x7E` 都經 AEAD 加密與驗證**；不得有任何明文測試或觸控事件。
- 0x03 只在 spec §5 全部條件成立後才送與處理；Mac 處理 `pointerOpen` 與每個 0x03 時都重新檢查權限。
- 所有標 Provisional 的數值（spec §14）在 TP1／TP5 實測前不得寫成已驗證。
- log 只記 opcode、長度、計數器間隔、延遲統計、錯誤碼；不得含位移、座標、點擊位置、輸入文字、App 名稱。
- 量測通道只存在於 `#if DEBUG`；Release build 不派生量測金鑰，收到 `0x7E` 一律略過。
- 每個 Task 結束必須全綠：`swift test --package-path Packages/RemoteKeyboardCore`、`MacReceiverTests`、iOS 模擬器 build、真機 build-for-testing、Mac build；並重跑 `HitAreaUITests`（真機）。
- 建置：改 `project.yml` 後 `xcodegen generate` 再 `LANG=en_US.UTF-8 pod install`；build 用 `-workspace RemoteKeyboard.xcworkspace`；不提交 `*.xcodeproj`、`*.xcworkspace`、`Pods/`。
- 實機驗收標 TBD，使用者親手測完才算 PASS；介面文字用台灣繁體中文。
- 實機：iPhone 17 Pro，UDID `00008150-000C65DA26C0401C`；模擬器沒有 CoreBluetooth。

## 執行規則

- 每個 Task 一個 worktree、一條 branch、一個 PR；Sonnet 子代理寫程式，不得 commit 或 push；主代理重跑全部驗證並經獨立 reviewer 審查後 commit、開 PR、merge。
- 每個 Task 完成即停下回報。**TP1 完成後必須停在決策關卡，由使用者決定是否進入 TP2。**
- TP4 開始前先向使用者提 2–3 個觸控板頁 UI 方向，選定後才寫 UI。

## Review Focus

1. **背壓中點擊**：`updateValue` 回 `false` 期間先移動、再點擊、再移動，恢復後必須依「位移 → 點擊 → 位移」送出。由 TP2 `testBarrierOrderUnderBackpressure` 覆蓋。
2. **ACK 遺失後重送的舊按鍵狀態**：按下（ACK 遺失）→ 放開 → 按下重送，Mac 不得重新按下。由 TP2 `testRetransmittedOldButtonStateDoesNotOverrideNewer` 覆蓋。
3. **拖曳中 Extension 被暫停或鍵盤被收起**：Mac 必須在 350 ms 內放開，遲到的心跳不得重新按下；一般延遲下不得誤放開。由 TP3 `testWatchdogReleasesAfter350ms`、`testLateHeartbeatAfterWatchdogDoesNotRepress` 與 TP1 M6、TP5 實機覆蓋。
4. **開關關過再開、過期的 pointerOpen**：舊授權版本或舊 `stateSeq` 不得開啟通道。由 TP2 `testOpenWithOldGrantNotAuthorized`、`testOlderStateSeqOutOfOrder` 覆蓋。
5. **長阻塞後大量位移**：開放段只送最近 150 ms，封閉段完整送且不超出欄位。由 TP2 `testOpenSegmentDropsMotionOlderThan150ms`、`testDxOverflowSplitsIntoMovesPreservingTotal` 覆蓋。

---

### Task TP1: 加密量測通道與決策關卡

Branch：`tp1-measurement`。只做 DEBUG 量測工具與共用的計數器 AEAD 信封；不做觸控板語意或 UI。

**Files:**
- Create（Core，Release 也編譯，TP2 沿用）：`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Channel/CounterChannel.swift`（信封、金鑰派生、sealer／opener）、`Channel/ReplayWindow.swift`
- Create（Core）：`Channel/ChannelSet.swift`（每條連線一次）、`Measurement/MeasurePayload.swift`（`#if DEBUG`）、`Measurement/LatencyStats.swift`、`Measurement/VideoFrameStats.swift`
- Modify（Core）：`Shared/AuthHandshake.swift`（兩端 reducer 在 authenticated 後提供一次 `mutating func takeChannelSet() -> ChannelSet?`；未認證或第二次取用回 nil；不提供取得金鑰本身的 API）、`Shared/ControlMessage.swift`（`ReceiverStatus.measure: Bool`，false 時不寫入）
- Test：`CounterChannelTests.swift`、`ReplayWindowTests.swift`、`MeasurePayloadTests.swift`、`LatencyStatsTests.swift`、`VideoFrameStatsTests.swift`、`ReceiverStatusTests`（擴充）
- Create（iOS，`#if DEBUG`）：`iOS/RemoteKeyboardExtension/Debug/MeasurementRunner.swift`、`Debug/MeasurementTouchView.swift`
- Modify（iOS）：`Bluetooth/KeyboardBLEPeripheral.swift`（DEBUG：`sendChannelPacket(_:) -> Bool`、`didReceiveWrite` 在 JSON 解碼前分流 `0x7E`、`setLatency(_:)`）、`KeyboardViewController.swift`、`UI/DictationProbePanel.swift`（DEBUG 面板量測按鈕）
- Create（Mac，`#if DEBUG`）：`macOS/MacReceiver/Diagnostics/MeasurementEcho.swift`、`Diagnostics/MeasureFlashWindow.swift`
- Modify（Mac）：`Bluetooth/ReceiverBLECentral.swift`（`receive(eventData:)` 在 reassembler 前依首 byte 分流）、`ReceiverPanel.swift`（DEBUG「量測模式」開關，預設關）、`Pipeline/ReceiverCoordinator.swift`（status 帶 `measure`）
- Test：`macOS/MacReceiverTests/MeasurementEchoTests.swift`、`FirstByteRoutingTests.swift`
- Create：`e2e/E2E-TP1-MEASURE.md`、`scripts/tp1-m4-stats.swift`
- Modify：驗收報告加 TP1 列

**Interfaces:**
- Produces（Core，TP2 沿用）：
  - `public enum CounterChannel { public enum Kind: Sendable { case pointer; #if DEBUG case measureP2M, measureM2P #endif } }`；每個 Kind 固定 `magic`（`0x03`／`0x7E`／`0x7E`）、HKDF info（`rk-pointer-p2m`／`rk-measure-p2m`／`rk-measure-m2p`）、nonce 前綴（`PTR3`／`MSR3`／`MSE3`）
  - 以下三個 class 只在單一序列執行環境使用（spec §6.3 規則 1），不加鎖。
  - `public final class ChannelSet`：只能由 `takeChannelSet()` 建立（`init` 非 public），內部派生金鑰；`func sealer(_ kind: Kind) -> ChannelSealer`、`func opener(_ kind: Kind) -> ChannelOpener` 每個 Kind 回傳同一個實例（reference type）。adapter 持有到斷線為止
  - `public final class ChannelSealer { var lastCounter: UInt64 { get }; func seal(_ plaintext: Data) throws -> Data }`（每次呼叫先把計數器加 1 再加密；到 `UInt64.max` 拋錯；init 非 public）
  - `public final class ChannelOpener { func open(_ packet: Data) -> Result<Data, ChannelOpenError> }`，`ChannelOpenError`: `.badMagic, .badLength, .replayed, .tooOld, .authFailed`
  - `public struct ReplayWindow { mutating func check(_ c: UInt64) -> Bool; mutating func commit(_ c: UInt64) }`
  - `public struct MeasurePayload { kind: Kind /* burst 1, rtt 2, cursor 3, heartbeat 4 */, dxSixteenths: Int16, seq: UInt32, phoneTimeMicros: UInt64; func encode(padTo: Int) -> Data /* 16 或 157 */; static func decode(_:) -> MeasurePayload? }`
  - `public struct MeasureEchoPayload { seq: UInt32, phoneTimeMicros: UInt64, macHoldMicros: UInt32; encode() -> Data /* 16 */; static func decode(_:) -> MeasureEchoPayload? }`
  - `public struct LatencyStats { init(samplesMs: [Double]); p50, p95, p99: Double; jitterMs: Double /* p95 − p50 */; count: Int }`
  - `public struct VideoFrameStats { init(fps: Double, rows: [(t0: Int, t2: Int?, t5p: Int?, t6: Int)]); e2e: LatencyStats; transportToDisplay: LatencyStats?; macDisplay: LatencyStats?; quantizationErrorMs: Double /* 1000/fps */; isBorderline(target: Double) -> Bool /* |p95 − target| ≤ 2 幀 */ }`
- Produces（Mac，TP3 沿用）：`ReceiverBLECentral` 依首 byte 分流到既有 reassembler（0x02）、`pointerHandler: ((Data) -> Void)?`（0x03，TP1 不處理）、`measureHandler`（0x7E，DEBUG）。

- [ ] **Step 1: Core 測試（RED）**

```swift
// CounterChannelTests
func testPacketSizes() // pointer 16-byte 明文 → 41；measure 157 → 182
func testNonceIsPrefixPlusCounter() // 以已知金鑰與計數器重算，與輸出一致（PTR3、MSR3、MSE3）
func testTamperAnyByteRejected() // 41 與 182 bytes 版本，逐一翻轉每個 byte 的 1 bit → 全部 .authFailed 或 .badMagic
func testKeysDifferPerKindAndFromSessionKeys() // 以測試用 internal hook 比對：三種 Kind 金鑰互不相同，也不同於 SessionCrypto 兩個方向
func testChannelSetTakenOnlyOnce() // takeChannelSet 第二次回 nil
func testSameSealerInstancePerKind() // sealer(.pointer) 兩次回傳同一實例；兩次量測執行之間計數器延續不歸零
func testNewHandshakeNoncesGiveNewKey()
func testCounterStrictlyIncreasesEvenWhenDiscarded() // 1,000 次 seal（其中 300 個丟棄不送）→ 計數器 1…1000 無重複
func testCounterMaxThrows()
func testOpenerRejectsReplay(); func testOpenerAcceptsOutOfOrderWithin64(); func testOpenerRejectsOlderThan64()
func testWindowCommitOnlyAfterAuth() // 偽造 tag 的高計數器不移動視窗
// AuthHandshake
func testChannelSetNilBeforeAuthenticated(); func testChannelSetsInteroperateBothSides() // iPhone sealer 封的封包 Mac opener 能開
// MeasurePayloadTests
func testMeasureRoundTrip16And157(); func testEchoRoundTrip()
// ReceiverStatus
func testStatusWithoutMeasureEncodesSameBytesAsBefore(); func testOldStatusBytesDecodeMeasureFalse()
// LatencyStatsTests
func testStatsPercentiles() // samples 1…100 → p50 50.5、p95 95.05、p99 99.01（線性內插），jitter = p95 − p50
func testStatsEmpty() // count 0，百分位為 .nan
// VideoFrameStatsTests
func testFramesToMs() // fps 240：t6 − t0 = 12 幀 → 50.0 ms
func testBorderlineWithinTwoFrames() // p95 = 55 ms、target 60、fps 240 → true；p95 = 50 → false
```

- [ ] **Step 2: `swift test --package-path Packages/RemoteKeyboardCore`，預期新測試 FAIL**
- [ ] **Step 3: 實作 Core**（計數器在 `seal` 內配給；opener 先驗 AEAD 再 commit 視窗）
- [ ] **Step 4: 全套 Core PASS，既有測試數不減少**
- [ ] **Step 5: Mac 測試（RED）**

```swift
// FirstByteRoutingTests
func testNon02FrameDoesNotTouchReassembler() // 0x02 長訊息第 1 frame → 0x7E → 0x03 → 第 2 frame → 長訊息完整
func testMeasureIgnoredWhenRoutingDisabled() // 以 Release 等效旗標（measureEnabled = false）注入 → 0x7E 不解密、不回覆
// MeasurementEchoTests
func testNoEchoWhenMeasureModeOff(); func testNoEchoBeforeAuthenticated()
func testEchoIsSealedWithM2PKey() // 回覆 41 bytes、首 byte 0x7E、只有 measureM2P 金鑰能開
func testTamperedProbeIgnoredAndCounted()
func testCursorProbeMovesByDxTimesGain() // dxSixteenths 32、量測倍率 4 → 位移 8 pt；同時觸發閃白
func testEchoAtMostOneWriteInFlight() // 在途時到達的 rtt 封包不回覆、計為略過
func testMeasureToggleKeepsSealer() // 量測模式關再開，回覆計數器延續
func testWatchdogRecorderDoesNotInject() // M6：超過 350 ms 只記錄，不送任何滑鼠事件
func testCsvHasNoCoordinates() // CSV 標頭只含 seq、kind、bytes、counterGap、interArrivalMicros、holdMicros
```

- [ ] **Step 6: 實作 Mac**：分流；`MeasurementEcho` 以 `measureP2M` opener 驗證，回覆以 `measureM2P` sealer 經 control write（with response）送出；`MeasureFlashWindow` 是角落小視窗，收到 cursor 封包時變白一格；CSV 寫到 `~/Library/Logs/RemoteKeyboard/measure-<日期>.csv`。`measureEnabled` 在 Release 為 false。
- [ ] **Step 7: 實作 iPhone（DEBUG）**：
  - 只在 status `measure: true` 且已認證時啟用面板按鈕。
  - `MeasurementRunner`：M2（ready 回呼中以 41 與 182 bytes 量測封包連送直到 `false`，各 100 輪；被拒的密文丟棄，下一次重新加密）、M3（41 bytes、60 Hz、10,000 個；以 `measureM2P` opener 驗證回覆後算 RTT）、M5（M3 同時以既有 `sendDebugLongText()` 送 3,000 字，記錄阻塞時間）、M6（每 100 ms heartbeat，五種情境各 10 分鐘，含同時傳送 3,000 字長文字；長文字期間依 4:1 交錯交出）。所有 cursor 與 rtt 封包另記「交出時間 − 最早樣本時間」。
  - `setLatency`：面板可切 `.low`／`.medium`／不設定。
  - `MeasurementTouchView`：每一筆劃第一個 `touchesMoved` 時整塊變白一格；`coalescedTouches` 累加，每 16.7 ms 送一個 cursor 量測封包。
  - `didReceiveWrite`：首 byte `0x7E` 時交 `MeasurementRunner`，不走 `ControlCodec`。
  - 統計只在面板顯示，CSV 寫 Extension 暫存目錄（同欄位規則）。
- [ ] **Step 8: 驗證**：Core、`MacReceiverTests`、iOS 模擬器 build、真機 build-for-testing、Mac Debug 與 Release build 全過；`grep -rn "measureP2M\|measureM2P\|MeasurePayload\|MeasurementRunner\|MeasurementEcho" Packages iOS macOS` 確認全部在 `#if DEBUG` 內；Release 產物（Mac App、iOS App 與 Extension）以 `nm` 檢查不含 `MeasurePayload`、`MeasureEchoPayload`、`measureP2M`、`measureM2P`、`MeasurementEcho`、`MeasurementRunner` 符號（`ReceiverStatus.measure` 欄位為相容保留，不列入）；`HitAreaUITests` 13/13。
- [ ] **Step 9: 寫 `e2e/E2E-TP1-MEASURE.md`**：
  - M1：PacketLogger（Additional Tools for Xcode）安裝與擷取 LE Connection Update 步驟；預設、`.low`、`.medium` 各 10 次 × 60 秒。
  - M2、M3、M5、M6：面板操作與輸出位置。
  - M4：依 spec §13.3（時間點 T0–T6 表、器材設定、游標放大、高對比背景、確認影片實際幀率與兩端螢幕更新率、每筆從靜止開始、≥ 100 筆、邊界時 ≥ 200 筆）；逐筆記錄 T0、T2、T5′、T6 的幀號到 `docs/superpowers/verification/evidence/TP1-m4-frames.csv`，以 `swift scripts/tp1-m4-stats.swift <csv> <fps>` 算出 E2E、T6 − T2、T6 − T5′ 的 P50／P95／P99 與量化誤差，並標示是否落在邊界。
- [ ] **Step 10: 主代理在實機跑 M2、M3、M5、M6，使用者跑 M1、M4**；結果填入驗收報告（實機項 TBD 直到使用者確認）。
- [ ] **Step 10b: 依使用者 2026-11-01 修訂補強量測工具並重量**（spec §13.2、§13.4）：
  - 回覆加 `macTimeMicros`（回覆明文 24 bytes、封包 49 bytes）；Core `ClockOffsetEstimator`（以最小 RTT 樣本估計時鐘差，TDD：已知偏移與對稱延遲還原誤差 < 1 ms、非對稱延遲時誤差 ≤ 最小 RTT／2）；M3 輸出 M3a（RTT）、M3b（覆蓋率）、M3c（單程 P50／P95／P99 與估計誤差）。
  - 量測前可指定連線延遲偏好（UI 測試環境變數 `RKMEAS_LATENCY=low|medium|none`），每行結果帶 `latency=`。
  - Mac CSV 每列加 `macTimeMicros`，供心跳間隔異常分析（不含內容）。
  - M5 恢復段改為固定 10 秒，必須有樣本。
  - 新增 M7（模式切換，20 次）與 M8（觸控板工作負載，10 分鐘），兩者的出口規則採 spec §8.2 規則 4 的觸控板模式優先。
  - M6 主要量測改為 `.low`、30 分鐘；分析心跳間隔 > 200 ms 的時間分佈，對照 M1 的 connection interval 與 Mac 端紀錄，判斷異常來自 iPhone 交出之後的系統佇列、空中傳輸還是 Mac 端處理。
  - 先寫測試再實作；全套 regression 重跑。之後在實機依序跑：M2、M3、M6（30 分鐘）、M7、M8（`.low`），再跑健壯性 M5、M6-L。
- [ ] **Step 11: 第一階段驗收對照（使用者 2026-11-01 指定；同日修訂為主要／健壯性兩類）**

| 指標 | 目標 | 在哪裡驗證 |
|---|---|---|
| 觸控到游標可見 P95 | < 60 ms（`.low`、無長文字） | TP1 M4（加密量測封包，與正式封包同大小）；TP5 以正式協定重測 |
| P50／P99 | 完整記錄，不設門檻 | TP1 M3、M4 |
| BLE connection interval | 實測分佈 | TP1 M1 |
| 背壓 | 不累積過時 MOVE | 主要：TP1 M8、M7；健壯性：M5（長文字併發，不要求 P95 60 ms）；TP2 出口與過時測試 |
| 模式切換 | 尚未送完的文字不影響觸控板即時操作 | TP1 M7 |
| 重複點擊 | 0 次 | TP2、TP3 單元測試；TP5 實機 |
| 斷線後卡住拖曳 | 0 次 | TP1 M6（`.low`、30 分鐘）與 M8 的會誤放開次數必須為 0；TP3 單元測試；TP5 實機 100 次 |
| 現有鍵盤回歸 | 全部通過 | 每個 Task 全套測試＋TP5 |

- [ ] **Step 12: 決策關卡報告** `docs/superpowers/verification/2026-11-xx-tp1-decision.md`：各指標 P50／P95／P99／jitter、M4 分解（E2E、T6 − T2、T6 − T5′、iPhone 軟體、Mac 軟體、BLE 估計）與誤差、M5 積壓、M6 誤放開次數、建議；並把 spec §14 已量到的 Provisional 值改成實測值。停下等使用者決定。
- [ ] **Step 13: Commit／PR**（主代理）

---

### Task TP2: 觸控板協定（Core）

Branch：`tp2-pointer-protocol`。只動 Core 與相容欄位。

**Files:**
- Create：`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/PointerPayload.swift`、`PointerSession.swift`、`PointerOutbox.swift`、`MotionAccumulator.swift`、`TransmitScheduler.swift`、`ActionDeduplicator.swift`、`ButtonStateTracker.swift`、`PointerGate.swift`、`PointerTuning.swift`
- Modify：`Shared/KeyboardEvent.swift`（`EventKind.pointerOpen(version: Int, grant: UInt32, stateSeq: UInt32)`、`pointerClose(stateSeq: UInt32)`；`carriesFocusEpoch` 回 false）、`Shared/ControlMessage.swift`（`ReceiverStatus.pointerGrant: UInt32?`、`doubleClickMs: Int?`，預設不寫入；`ControlMessage.pointerAck(actionIds: [UInt32])`、`pointerReleased(buttonSeq: UInt16)`）、`Shared/AuthHandshake.swift`（`sealControl` 允許 `pointerAck`、`pointerReleased`）
- Test：對應 `*Tests.swift`

**Interfaces:**
- Consumes：TP1 `ChannelSet`（`.pointer` 的 sealer 與 opener）、`ReplayWindow`。
- Produces：
  - `public enum PointerOpcode: UInt8 { case move = 0x01, scroll = 0x02, click = 0x10, buttonState = 0x11, heartbeat = 0x12, gesture = 0x20 }`
  - `public struct PointerPayload: Equatable, Sendable { opcode: PointerOpcode; buttons: UInt8; dxSixteenths: Int16; dySixteenths: Int16; dtTenthsMs: UInt16; actionId: UInt32; arg: UInt8; status: UInt8; buttonSeq: UInt16 }`；`encode() -> Data`（16 bytes）、`static func decode(_:) throws -> PointerPayload`（必須為 0 的位元不為 0 → 拋錯）
  - `public final class PointerSession { init(sealer: ChannelSealer) }`：持有該連線唯一的 sealer、`nextActionId`、`buttonSeq`、`stateSeq`；`buttonSeq` 只由 `PointerOutbox.enqueueReliable(.buttons)` 遞增；不符合 `Codable`
  - `public struct PointerOutbox`（`init(session: PointerSession)`）：
    - `mutating func addMotion(dx: Double, dy: Double, at: TimeInterval)`、`mutating func addScroll(dx: Double, dy: Double, at: TimeInterval)`
    - `mutating func enqueueReliable(_ r: ReliableAction, now: TimeInterval) -> UInt32?`（`ReliableAction`: `.click(button:count:)`、`.buttons(UInt8)`、`.gesture(UInt8)`、`.scrollEnd(cancelled: Bool)`；CLICK／GESTURE 超過上限回 nil）
    - `mutating func scheduleHeartbeat()`（最多一個待送，新的取代舊的）
    - `mutating func front(now: TimeInterval) -> PointerPayload?`（不移除；開放段受節奏限制；距上一個 MOVE 超過一個間隔時立即可送）
    - `mutating func frontAccepted()`、`mutating func transmitRefused()`、`mutating func transmitReady()`
    - `mutating func acked(_ ids: [UInt32])`、`mutating func scheduleRetransmits(now: TimeInterval)`、`mutating func heartbeatIfDue(now: TimeInterval)`、`mutating func macReleased(buttonSeq: UInt16)`
  - `public struct TransmitScheduler { init(ratio: Int = 4); mutating func next(textPending: Bool, pointerPending: Bool) -> Source? /* .text, .pointer */ }`
  - `public struct ActionDeduplicator { init(capacity: Int = 64); mutating func decide(_ id: UInt32) -> ActionDecision /* .execute, .duplicate, .tooOld */ }`
  - `public struct ButtonStateTracker { mutating func apply(buttons: UInt8, seq: UInt16) -> (down: UInt8, up: UInt8); mutating func forceRelease() -> UInt8; var current: UInt8 }`（16 位元序號算術）
  - `public struct PointerGate`（Mac）：`mutating func grantChanged(enabled: Bool) -> UInt32?`、`mutating func handleOpen(version:grant:stateSeq:authenticated:switchOn:) -> AckCode`、`mutating func handleClose(stateSeq:) -> AckCode`、`func acceptsPackets(authenticated: Bool, switchOn: Bool) -> Bool`、`var isOpen: Bool`、`mutating func reset()`

- [ ] **Step 1: 測試（RED）**

```swift
// PointerPayloadTests
func testPayloadIs16BytesAndPacketIs41()
func testNonZeroMustBeZeroBitsRejected() // buttons bit2–3、status bit3–7
// PointerSessionTests
func testCounterStrictlyIncreasesAcrossAllPackets() // 1,000 個含被拒與重送 → 交出的計數器嚴格遞增、無重複
func testReopenWithinSessionKeepsCounter(); func testNewSessionUsesDifferentKey()
func testSessionStateNeverPersisted() // 以 #filePath 讀取 Pointer／Channel 資料夾原始碼：不含 Codable、UserDefaults、Keychain、FileManager
// PointerOutboxTests：次序屏障（spec §8.2）
func testBarrierOrderUnderBackpressure() // refused → addMotion a → click → addMotion b → ready → MOVE(a)、CLICK、MOVE(b)
func testButtonUpAfterDragMotion() // 拖曳位移 → buttons(0) → 順序為 MOVE（buttons 1）、BUTTON_STATE（buttons 0）
func testRefusedItemStaysAtFront() // transmitRefused 後 front 仍是同一內容；之後的項目不會先交出
func testNoItemBehindFrontIsSent()
func testClosedSegmentsIgnorePacing(); func testOpenSegmentPacedAt16_7ms()
func testScrollCoalescedLikeMotion() // 背壓期間 50 個 changed → 恢復後 1 個 SCROLL，總和正確
func testHeartbeatLatestOnly() // 背壓期間 10 次心跳 → 只 1 個待送
func testOutboxBoundedUnderAckLoss() // 永遠無 ACK、持續點擊與拖曳 10 秒 → 項目數有上限
func testClickRetransmitOnlyWithin300ms(); func testOlderButtonStateStopsRetransmitWhenNewerSent()
func testMacReleasedEndsLocalDrag() // pointerReleased(S)、本機 buttonSeq S 且按下 → 本機 buttons 0、buttonSeq 加 1、不送封包
func testStaleMacReleasedIgnored() // Mac 放開 S → 本機 up S+1、down S+2 → 遲到的 pointerReleased(S) 不影響新拖曳
func testLateOpenAckIgnoredAfterClose() // pointerOpen(1) → pointerClose(2) → open(1) 的 ack 到達 → 不開始送 0x03
// TransmitSchedulerTests
func testFairInterleaveFourToOne() // 兩邊都有 → text×4、pointer×1 循環
func testOnlyPendingSideSends(); func testPointerResumesWhenTextDrains()
func testReliableCarriesNoMotion() // CLICK、BUTTON_STATE、GESTURE 的 dx、dy、dt 皆 0
func testClosedSegmentCarriesButtonStateAtCloseTime()
func testRetransmitAppendedAsBarrierWithSameActionId()
func testClickGestureCap8ButtonStateAlwaysQueued()
func testHeartbeatEvery100msWhileButtonDown(); func testNoHeartbeatWhenNoButton()
// MotionAccumulatorTests：溢位與過時（spec §8.3）
func testQuantizationKeepsRemainder() // 1,000 次 0.01 pt → 送出總和誤差 < 1/16 pt
func testBlockedTransmitAccumulatesSingleMove() // 阻塞期間 100 次 → 恢復後 1 個 MOVE，status bit0
func testOpenSegmentDropsMotionOlderThan150ms() // 阻塞 400 ms → 只含最後 150 ms 的位移，status bit1
func testClosedSegmentNeverTrimmed()
func testDxOverflowSplitsIntoMovesPreservingTotal() // 封閉段 5,000 pt → 3 個 MOVE、總和 5,000、相鄰無其他項目
func testSplitCappedAt8SetsClampedBit() // 20,000 pt → 8 個、bit2
func testDtIsSampleSpanNotIdleTime(); func testDtClampedToUInt16Max()
// ButtonStateTrackerTests：按鍵狀態版本（spec §6.4）
func testRetransmittedOldButtonStateDoesNotOverrideNewer() // seq5 down、seq6 up、seq5 down 重送 → 狀態維持 up
func testNewerSeqRepairsLostButtonState() // 漏掉 seq6 up，seq7 MOVE buttons 0 → up
func testSameSeqNoChange(); func testSeqWrapAround() // 65535 → 0 視為較新
// ActionDeduplicatorTests
func testDuplicateActionIdIsAckedNotExecuted(); func testActionIdOlderThanWindowIsRefused() // id ≤ 最大 − 64 → .tooOld（不執行、回 ACK）
// PointerGateTests：開關版本與權限（spec §5）
func testOpenRequiresAuthSwitchAndCurrentGrant()
func testGateResetOnNewConnectionAcceptsStateSeq1()
func testOpenWithOldGrantNotAuthorized() // 開關關再開後，舊 grant → notAuthorized，通道維持關閉
func testDuplicateStateSeqReturnsOriginalResult(); func testOlderStateSeqOutOfOrder()
func testNoAckResendsWithNewStateSeqAfter1s() // iPhone 端
func testCloseAlwaysAllowed(); func testSwitchOffClosesAndRequiresNewGrant()
func testAcceptsPacketsRechecksEveryTime() // 開啟後關開關或失去認證 → false
// 相容
func testStatusWithoutPointerEncodesSameBytesAsBefore(); func testOldStatusBytesDecodeWithoutGrant()
func testExistingEventKindEncodingUnchanged()
```

- [ ] **Step 2: 執行，預期 FAIL**
- [ ] **Step 3: 實作**（數值依 spec §6–§8；Provisional 數值集中在 `PointerTuning`）
- [ ] **Step 4: 全套 Core PASS；既有測試數不減少**
- [ ] **Step 5: 更新 spec §12、驗收報告 TP2 列；Commit／PR**

---

### Task TP3: Mac Receiver 觸控板處理

Branch：`tp3-mac-pointer`。

**Files:**
- Create（Core 純邏輯）：`Pointer/PointerAcceleration.swift`、`Pointer/PointerWatchdog.swift`、`Pointer/ScrollPhaseTracker.swift`
- Create（Mac）：`macOS/MacReceiver/Pointer/PointerReceiver.swift`、`PointerInjector.swift`（CGEvent adapter，protocol 注入）、`ScreenClamp.swift`
- Modify：`ReceiverBLECentral.swift`（`pointerHandler` 接 `PointerReceiver`；`pointerAck`／`pointerReleased` 合併寫入）、`Pipeline/EventPipeline.swift` 與 `ReceiverCoordinator.swift`（`pointerOpen`／`pointerClose` 解密後立即同步交 `PointerGate`，不進文字注入序列；`PointerGate` 每次新連線認證完成時重設）、`Pipeline/ReceiverCoordinator.swift`（status 帶 `pointerGrant`、`doubleClickMs`；開關變動；關閉清理；計時延長）、`ReceiverPanel.swift`（「允許觸控板控制」開關，預設關）
- Test：Core 測試＋`macOS/MacReceiverTests/PointerReceiverTests.swift`

**Interfaces:**
- Consumes：TP2 全部型別；TP1 首 byte 分流與 `ChannelOpener(.pointer)`。
- Produces：`protocol PointerInjecting { func move(to: CGPoint, delta: CGVector, held: UInt8); func button(_: CGMouseButton, down: Bool, at: CGPoint, clickState: Int); func scroll(dx: Int32, dy: Int32, phase: ScrollPhase); func shortcut(_ gesture: UInt8) }`
- `public struct PointerAcceleration { init(g0: Double = 1.25, v0: Double = 550, gmax: Double = 3.5); func gain(dx: Double, dy: Double, dtSeconds: Double) -> Double }`（`dt` 夾 0.005–0.15 s）

- [ ] **Step 1: 測試（RED）**

```swift
func testGainAtZeroIsG0(); func testGainMonotonic(); func testGainApproachesGmax() // v = 1e6 → |g − 3.5| < 0.01
func testGainAt550IsMidpoint() // g == 1.25 + 2.25 / 2
func testPointerIgnoredBeforePointerOpen(); func testPointerIgnoredWhenSwitchOff()
func testPointerOpenBypassesDedupAndFocus() // 無焦點時 pointerOpen 仍回 posted；之後文字事件 seq 檢查不受影響
func testPointerOpenRechecksPermissionAtProcessing() // status 已送出 grant 後才關開關 → pointerOpen 回 notAuthorized
func testPointerOpenNotQueuedBehindInjection() // 文字注入進行中（假注入器延遲 500 ms）→ pointerOpen 立即回覆
func testPointerPacketDuringLongMessageKeepsPartial()
func testMoveThenClickOrder() // MOVE 後 CLICK → 先 move 再 down/up
func testDuplicateClickInjectsOnce() // 同 actionId 3 次 → 1 次點擊、3 次 ACK
func testRetransmittedOldButtonStateDoesNotRepress()
func testDragMoveUsesLeftMouseDragged()
func testChangedWithoutBeganStartsScroll()
func testPointerAcksBatchedOneInFlight(); func testGoodbyeWaitsForPointerAckWrite()
func testGestureAckMeansPosted()
func testWatchdogReleasesAfter350ms(); func testHeartbeatEvery100msKeepsButtonDown()
func testLateHeartbeatAfterWatchdogDoesNotRepress() // 看門狗放開後，相同 buttonSeq 的遲到心跳不再按下
func testWatchdogSendsPointerReleased()
func testHeartbeatJitterNoFalseRelease() // 心跳間隔 300、349 ms → 不放開；351 ms 無封包 → 放開
func testScrollWatchdogEndsPhaseAfter150ms()
func testDisconnectReleasesAllButtonsAndEndsScroll(); func testDisablingSwitchReleasesButtons()
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
- Create：`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/TrackpadGestureRecognizer.swift`（純邏輯，spec §9）
- Create：`iOS/RemoteKeyboardExtension/UI/TrackpadPageView.swift`；Modify：`PageNavigator`、`BottomRowView`（依 Step 0）、`KeyboardViewController`、`KeyboardBLEPeripheral`（`TransmitScheduler` 接 `NotifyQueue` 與 `PointerOutbox`；spec §8.2 規則 9 的全部喚醒時機；`pointerAck`、`pointerReleased`、`pointerGrant`；`.low`／`.medium` 切換）
- Test：`TrackpadGestureRecognizerTests.swift`、`iOS/RemoteKeyboardUITests/TrackpadUITests.swift`

**Interfaces:**
- Consumes：TP2 `PointerSession`、`PointerOutbox`、`EventKind.pointerOpen/pointerClose`、`ControlMessage.pointerAck`、`ReceiverStatus.pointerGrant/doubleClickMs`。
- Produces：`public struct TrackpadGestureRecognizer { mutating func touches(_ e: TouchSample) -> [TrackpadOutput] }`，`TouchSample { id: Int, phase: Phase, location: CGPoint, time: TimeInterval }`，`TrackpadOutput { .move(dx,dy,at), .click(button,count), .buttons(UInt8), .scroll(dx,dy,phase), .scrollEnd(cancelled), .gesture(UInt8) }`

- [ ] **Step 1: 測試（RED）**

```swift
func testTapWithin200msAnd8ptIsLeftClick(); func testSlowTouchIsNotClick() // 250 ms
func testDoubleTapUsesMacInterval() // doubleClickMs 300：間隔 280 → count 2；320 → 兩個 count 1
func testDoubleTapHoldStartsDragAndReleaseEnds()
func testTwoFingerTapIsRightClick(); func testTwoFingerMoveScrollsBeganChangedEnded()
func testThreeFingerSwipeLeft40pt(); func testPinch20PercentZoom()
func testCancelledTouchesReleaseAndCancelScroll()
func testTrackpadHiddenWithoutPointerGrant()
func testLeavingTrackpadSendsReleaseThenPointerClose()
func testNewGrantRequiresNewPointerOpen() // status grant 改變 → 停送 0x03，直到新 pointerOpen 收到 posted
func testHeldReliableSentWhenTextDrains() // UI 或 adapter 測試：長文字送完後，等待中的 CLICK 不需新觸控即送出
```

- [ ] **Step 2: FAIL → Step 3: 實作 → Step 4: PASS**；模擬器截圖 390／402 pt 寬兩種。
- [ ] **Step 5: 回歸**：`HitAreaUITests` 13/13、`KeyboardT10UITests`、`ReconnectUITests`（真機）。
- [ ] **Step 6: 驗收報告 TP4 列；Commit／PR**

---

### Task TP5: 整合測試與參數定案

Branch：`tp5-integration`。

**Files:**
- Create：`e2e/E2E-TP5-TRACKPAD.md`、`docs/superpowers/verification/2026-11-xx-tp5-report.md`
- Modify：`PointerTuning`（依實測調整）、spec §14（實測值）、驗收報告、`e2e/E2E-T16-RC.md`（加觸控板組與總數）、README

- [ ] **Step 1: 自動測試**：Release build 不含量測程式碼（grep 與 `nm` 檢查，符號清單同 TP1 Step 8）；未協商的 0x03 被略過；全套測試全綠。
- [ ] **Step 2: 實機清單（使用者，TBD）**：

| 項目 | 次數 | 通過條件 |
|---|---|---|
| 觸控到游標可見（240 fps，依 spec §13.3） | ≥ 100 | E2E P95 < 60 ms；記錄 P50／P99 與分解 |
| 點擊、雙擊、右鍵 | 各 50 | 重複點擊 0 次、漏點記錄 |
| 移動後立刻點擊（含長文字傳送中） | 50 | 點擊位置在目標上 |
| 拖曳中收起鍵盤、鎖屏、切 App、關 Mac 藍牙 | 各 25（共 100） | 卡住拖曳 0 次 |
| 一般拖曳 60 秒靜止按住 | 20 | 誤放開 0 次 |
| 長文字傳送中移動游標 | 10 | 長文字完整、游標無連續重播 |
| 捲動：Safari、Notes、Finder、Xcode、Chrome、Preview | 各 20 | 方向正確、phase 無殘留 |
| 三指與捏合快捷鍵 | 各 10 | 快捷鍵已送出（功能是否生效依 Mac 設定，另記） |
| Mac 開關關閉中拖曳；關後再開 | 各 10 | 立即放開；再開需重新開啟觸控板頁才可用 |
| 加速曲線三組對照（A 曲線三組＋B 三次曲線） | 每組 3 輪 | 使用者選定 |
| 現有鍵盤回歸（T16 B 組、長文字 3,000 字、配對、重連 20 次） | — | 全部通過 |

- [ ] **Step 3: 依實測更新 `PointerTuning` 與 spec §14，把定案值的 Provisional 標記移除並註明來源量測**
- [ ] **Step 4: 決定捲動慣性是否做第二階段（寫入報告，等使用者決定）**
- [ ] **Step 5: Commit／PR**
