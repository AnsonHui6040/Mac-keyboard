# iPhone 觸控板模式設計（D25）

- 狀態：草稿，待使用者批准（2026-11-01）
- 依據：`docs/superpowers/research/2026-11-01-trackpad-research-review.md`（整合外部報告 A、B 並對照程式碼）
- 上層規格：`docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（D1–D24）
- 實作計畫：`docs/superpowers/plans/2026-11-01-trackpad-implementation.md`

**所有標「Provisional」的數值都未經實測，只是起始值。** TP1 量測完成前，不得把它們當作已驗證結果寫入驗收報告或文件結論。

## 1. 意圖

使用者已用 iPhone 鍵盤遠端打字到 Mac，希望同一個鍵盤也能控制 Mac 游標：移動、點擊、拖曳、捲動，以及以快捷鍵代替的多指手勢。這樣在 Mac 前不必伸手去拿觸控板或滑鼠。

## 2. 目標、非目標、反目標

| 類別 | 內容 |
|---|---|
| 目標 | 觸控到游標可見移動 P95 < 60 ms；不會重複點擊；斷線後不會卡住拖曳；現有打字功能完全不受影響 |
| 非目標（v1） | 原生多指手勢事件（無公開 API）；捲動慣性（第二階段）；主 App 全螢幕觸控板；LAN 傳輸（只在 BLE 未達標且找到瓶頸後另行研究） |
| 反目標 | 為了觸控板改動 Keyboard v3 協定、0x02 FrameCodec、配對或認證流程；未認證或未協商就接受 0x03；log 出現位移、點擊位置或任何輸入內容；游標資料在佇列中積壓後連續重播 |

## 3. 前提與限制（不可改）

1. iPhone 是 BLE Peripheral、Mac 是 Central（D11）；iPhone 不能扮 HID 裝置。
2. 沿用同一個 service 與 `event`（notify）、`control`（write with response）兩個 characteristic，不新增 characteristic。
3. 觸控板只在鍵盤 Extension 可見期間存在，生命週期同鍵盤。
4. Mac Receiver 已有「輔助使用」權限，以 `CGEvent` 注入。
5. ACK 只代表 Receiver 已處理；不承諾 exactly-once。

## 4. 架構

```text
iPhone Keyboard Extension                         Mac Receiver
┌─────────────────────────────┐                  ┌──────────────────────────────┐
│ 現有：KeyboardEvent JSON      │── 0x02 frames ──▶│ FrameReassembler → 既有管線    │
│   (sealed, ACK, 不丟棄)       │                  │                              │
│ 新增：PointerSender           │── 0x03 packet ──▶│ 首 byte 分流 → PointerReceiver │
│   accumulator + 可靠佇列       │                  │   AEAD 驗證 → 防重播 → 演算法   │
│                             │◀─ control write ─│   → CGEvent mouse/scroll/key  │
│   (pointerAck 走既有 sealed)  │                  │                              │
└─────────────────────────────┘                  └──────────────────────────────┘
```

- Mac 收到 `event` notification 時先看第 1 個 byte：`0x02` 交既有 `FrameReassembler`；`0x03` 交 `PointerReceiver`；其他一律略過並只記種類與長度。已查證舊版 Receiver 對非 `0x02` frame 只記 log，不斷線，也不影響進行中的長訊息。
- 純邏輯（封包編解碼、加密、防重播、去重、累加器、加速曲線、看門狗、手勢判定）放 `RemoteKeyboardCore`，以 `swift test` 驗證；CoreBluetooth、UIKit、CGEvent 只做薄 adapter。

## 5. 能力協商與啟用

觸控板通道必須同時滿足以下全部條件才啟用：

1. 連線已完成雙向 challenge-response（`PhoneHandshake` 與 `MacHandshake` 都是 authenticated）。
2. Mac 端「允許觸控板控制」開關已開（Mac 面板新增；**預設關**，見 §15 C1）。
3. Mac 在 sealed `ReceiverStatus` 中帶 `pointer: 1`（新欄位；值為 0 時不寫入，舊版 iPhone 讀到的位元組與現在相同）。
4. iPhone 進入觸控板頁時，經既有 sealed 事件送 `EventKind.pointerOpen(version: 1)`，Mac 以既有 `ack`（`posted`）回覆。`pointerOpen`、`pointerClose` 與 `ping`、`probe` 一樣在 Mac 管線的去重與焦點檢查之前處理：`carriesFocusEpoch` 為 false、不記入 `EventDeduplicator`、不檢查焦點、重複收到一律回 `posted`（冪等）。iPhone 以 `eventId` 等待該 ack，不計入打字的待確認數。
5. iPhone 收到該 ack 後才開始送 `0x03`。Mac 只在收到並接受 `pointerOpen` 之後才處理 `0x03`。

關閉條件（任何一項發生即關閉，Mac 立即釋放所有按鍵並結束捲動）：iPhone 離開觸控板頁並送 `pointerClose`；Mac 關閉開關（下一個 status 不帶 `pointer`）；斷線；認證失敗；Mac 收到無法通過 AEAD 驗證的 `0x03`（只丟棄並計數，連續 8 個失敗才關閉通道，避免單一雜訊封包中斷操作）。

舊版相容：舊 iPhone 不會送 `pointerOpen`；舊 Mac 不會帶 `pointer`，因此新 iPhone 不會送 `0x03`。

## 6. 0x03 封包格式

每個封包固定 41 bytes，一定只佔一個 notification（上限實測 182 bytes），不經 FrameCodec。

| Byte | 長度 | 欄位 | 加密 |
|---|---|---|---|
| 0 | 1 | magic `0x03` | 明文，列入 AAD |
| 1–8 | 8 | `counter`，UInt64 big-endian，每把金鑰從 1 起 | 明文，列入 AAD |
| 9–24 | 16 | 密文（明文負載 16 bytes） | ChaCha20 |
| 25–40 | 16 | Poly1305 tag | — |

明文負載（16 bytes）：

| Byte | 欄位 | 說明 |
|---|---|---|
| 0 | `opcode` | 見下表 |
| 1 | `buttons` | 完整按鍵狀態：bit0 左、bit1 右；bit4–7 目前觸點數（0–15） |
| 2–3 | `dx` | Int16 BE，單位 1/16 iPhone pt（±2,048 pt） |
| 4–5 | `dy` | Int16 BE，單位 1/16 pt，向下為正 |
| 6–7 | `dt` | UInt16 BE，單位 0.1 ms：本封包累積的觸控樣本跨越的時間 |
| 8–11 | `actionId` | UInt32 BE；不可靠事件為 0 |
| 12 | `arg` | 依 opcode：點擊次數、捲動階段、手勢指令 |
| 13 | `status` | bit0：此封包是佇列阻塞後的累積結果 |
| 14–15 | 保留 | 必須為 0；非 0 視為格式錯誤 |

| opcode | 名稱 | 可靠 | 說明 |
|---|---|---|---|
| `0x01` | MOVE | 否 | 位移累加，可合併，不 ACK |
| `0x02` | SCROLL | 否；`ended`／`cancelled` 階段為可靠 | `dx`／`dy` 為捲動量；`arg`：0 changed、1 began、2 ended、3 cancelled |
| `0x10` | CLICK | 是 | `arg` 低 2 bit 為按鍵（0 左、1 右），高 4 bit 為點擊次數（1–3） |
| `0x11` | BUTTON_STATE | 是 | `buttons` 為完整目標狀態（拖曳開始與結束） |
| `0x12` | HEARTBEAT | 否 | 有按鍵按住時定期送，`buttons` 為目前狀態 |
| `0x20` | GESTURE | 是 | `arg`：1 左桌面、2 右桌面、3 Mission Control、4 App Exposé、5 放大、6 縮小 |

**移動與可靠事件的次序**：要送可靠事件（CLICK、BUTTON_STATE、GESTURE、SCROLL ended／cancelled）時，iPhone 先把累加器裡尚未送出的位移以一個 MOVE 立即送出，再送可靠事件；可靠事件本身的 `dx`、`dy`、`dt` 一律為 0。連線中的 notification 依序送達、Mac 依序處理，因此「移到目標再點」的次序成立；可靠事件重送時封包內容（含 `actionId`）完全相同，只換計數器，不會重複套用位移。

### 6.1 欄位與狀態規則

- **`buttons` 是目標狀態**：每個有效封包（MOVE、SCROLL、HEARTBEAT、BUTTON_STATE；CLICK 與 GESTURE 除外）的 `buttons` 都代表 iPhone 目前的按鍵狀態。Mac 只在該封包計數器大於已處理的最大計數器時才依它調整自己的按鍵狀態（只送差異），因此遺失的 BUTTON_STATE 會被下一個 MOVE 或 HEARTBEAT 修正。移動時用 Mac 調整後的狀態決定 `.leftMouseDragged`、`.rightMouseDragged` 或 `.mouseMoved`。v1 的手勢只產生左鍵拖曳；右鍵拖曳由 Mac 支援但 iPhone 不產生。
- **觸點數**（`buttons` bit4–7）只供診斷統計，Mac 不據此做任何動作。
- **SCROLL**：未收到 began 就收到 changed，Mac 視為 began。
- **保留欄位**：byte 14–15 非 0，任何 opcode 都整包拒收。

### 6.2 可靠事件與 ACK

- `actionId` 在每個 `PointerSession` 內由 1 遞增。
- Mac 執行可靠事件後回 `pointerAck`。Mac 把待回的 `actionId` 合併：同一時間最多一個 `pointerAck` 寫入在途，在途期間新增的 id 併入下一次。`pointerAck` 走既有 sealed control 寫入佇列，與文字 `ack`、`status`、`bye` 依序處理；「再見」流程等待的在途寫入也包含它。
- **重複**：`actionId` 在最近 64 個已執行記錄內 → 不執行，回 ACK。
- **過舊**：`actionId` ≤ 已執行最大 id − 64 → 不執行，回 ACK（讓 iPhone 停止重送；寧可漏一下也不重複點擊）。
- **放棄**：iPhone 重送 3 次仍無 ACK 時，CLICK 與 GESTURE 放棄並計數；BUTTON_STATE 的放開不放棄，由後續封包的 `buttons` 與看門狗保證。
- GESTURE 的 ACK 只代表快捷鍵已送出，不代表 Mac 的對應功能已開啟或生效。

## 7. 加密與防重播

- **獨立金鑰**：`pointerKey = HKDF-SHA256(pairKey, salt: 空, info: "rk-pointer-p2m" ‖ macNonce ‖ phoneNonce, 32 bytes)`。與事件、控制通道的 session key 分開，避免同一把金鑰混用隨機 nonce 與計數器 nonce。只有 iPhone → Mac 方向用 `0x03`；Mac → iPhone 的 pointer ACK 走既有 sealed control 通道。
- **Nonce**：12 bytes = `"PTR3"`（`0x50 0x54 0x52 0x33`）‖ `counter`（8 bytes BE）。
- **AAD**：封包 byte 0–8。
- **計數器規則**：
  1. 計數器、金鑰、防重播視窗綁在同一個 `PointerSession` 物件，三者只能一起建立與一起丟棄。
  2. 只有新的握手（新 macNonce 與 phoneNonce）才會建立新的 `PointerSession`；同一條連線內切換鍵盤頁、`pointerClose` 再 `pointerOpen` 都沿用原計數器，不得歸零。
  3. 重送可靠事件時重新加密，使用新的計數器值；同一個 `actionId` 可以出現在多個計數器值。
  4. 計數器達 `UInt64.max` 時關閉通道（實際不可能發生，但程式要有此分支）。
  5. `pointerKey`、計數器、防重播視窗、`actionId` 只存記憶體，不寫入 UserDefaults、App Group、Keychain 或檔案。Extension 被系統結束後重新載入一定是新連線與新握手（既有行為），因此一定是新金鑰。
- **防重播**：Mac 記住目前最大計數器與其下 64 個的位元圖。大於最大值：接受並移動視窗；在視窗內且未見過：接受；見過或比視窗更舊：丟棄。必須先通過 AEAD 驗證才更新視窗。
- **可靠事件去重**：Mac 記住最近 64 個已執行的 `actionId` 及結果。重複的 `actionId` 只回 ACK，不再執行。`actionId` 由 iPhone 在每個 `PointerSession` 內從 1 遞增。

## 8. iPhone 端傳送

- **取樣**：`touchesMoved` 使用 `coalescedTouches(for:)`；不用 `predictedTouches` 送 Mac。位移在 iPhone 以 `Double` 累加，送出時才量化成 1/16 pt，餘數留到下一個封包。
- **節奏**：以 `CADisplayLink`（或等效）約每 16.7 ms 檢查一次（Provisional，範圍 12–25 ms），有累積位移才送一個 MOVE。
- **阻塞處理**：
  1. 既有 `NotifyQueue` 有待送的 0x02 frame 時，不送 MOVE，位移繼續累加（打字與長文字優先，也避免 MOVE 排在長訊息後面）。
  2. `updateValue` 回 `false` 後停止送任何 0x03，直到 `peripheralManagerIsReady`；期間位移只累加，不建立封包佇列。
  3. 恢復後只送一個累加結果，並設 `status` bit0。
- **CoreBluetooth 內部佇列**：`updateValue` 回 `true` 只代表交給系統佇列，不代表已送出。為避免系統佇列中積壓過時的 MOVE，送 MOVE 的頻率不得高於 TP1 量到的實際排空速率（Provisional 上限：每個實測 connection interval 一個）。TP1 的 M5 驗證此規則：持續送 MOVE 並同時送長文字時，回傳延遲不得隨時間持續上升。
- **可靠佇列**：最多 8 個未 ACK 的可靠事件（Provisional）。逾時重送：`max(3 × TP1 RTT P95, 150 ms)`，最多 3 次（Provisional；150 ms 下限高於 30 ms connection interval 下一次 write with response 往返）。放棄規則見 §6.2。
- **連線延遲偏好**：進入觸控板頁時 `setDesiredConnectionLatency(.low, for: central)`，離開時改回 `.medium`。是否改為訂閱後即設 `.low`，依 TP1 結果決定。
- **心跳**：任一按鍵處於按住狀態時，每 100 ms（Provisional）送 HEARTBEAT。
- **觸控取消**：`touchesCancelled`、鍵盤收起、離開觸控板頁，一律送 BUTTON_STATE（全放開）與 SCROLL cancelled。

## 9. iPhone 端手勢判定（純邏輯）

| 手勢 | 判定（全部 Provisional） | 送出 |
|---|---|---|
| 單指移動 | 位移超過輕點門檻 | MOVE |
| 單指輕點 | ≤ 200 ms 且總位移 ≤ 8 pt | CLICK 左鍵 1 下 |
| 雙擊 | 第二次輕點在 Mac `NSEvent.doubleClickInterval` 內（Mac 在 status 中提供，預設 500 ms）且距離 ≤ 12 pt | 第二次送 CLICK 次數 2 |
| 雙擊後按住（拖曳） | 第一次輕點後在雙擊間隔內第二次按下並超過 200 ms 或開始移動 | BUTTON_STATE 左鍵按下；手指離開時送放開 |
| 雙指輕點 | 兩指同時落下，≤ 200 ms，各自位移 ≤ 12 pt | CLICK 右鍵 |
| 雙指移動 | 兩指同向移動超過 8 pt | SCROLL began → changed → ended |
| 三指左右上下 | 位移 ≥ 40 pt | GESTURE 1–4 |
| 雙指捏合 | 距離變化 ≥ 20% | GESTURE 5／6 |

判定邏輯放 Core 的狀態機，以合成觸控序列測試。

## 10. Mac 端處理

- **游標移動**：讀目前游標全域座標（Quartz 點座標，不乘 Retina 倍率），加上 `(dx, dy) × g(v)`，夾到所有螢幕聯集內最近的位置；設定 `mouseEventDeltaX／Y`；按住左鍵時用 `.leftMouseDragged`，否則 `.mouseMoved`。小數餘數累積到下一次。
- **加速曲線**（Provisional）：`v = hypot(dx, dy) / dt`（pt/s），`g(v) = g0 + (gmax − g0) · v² / (v² + v0²)`，`g0 = 1.25`、`v0 = 550 pt/s`、`gmax = 3.5`；`dt` 夾在 5–150 ms。TP5 以三組參數對照（含報告 B 的三次曲線）。
- **平滑**：v1 收到即注入。120 Hz 分段補間與 1-Euro 濾波實作為預設關閉的實驗開關，只在 TP1／TP5 實測顯示「一跳一跳」比延遲更影響使用時才開啟。
- **點擊**：在目前游標位置送 down／up，`mouseEventClickState` = 次數。
- **按鍵狀態**：依 §6.1 調整，只送差異（down 或 up）。
- **捲動**：`CGEvent(scrollWheelEvent2Source:units: .pixel, wheelCount: 2, …)`，倍率 1.0 Mac 點／iPhone pt（Provisional），設 `scrollWheelEventIsContinuous = 1` 與 scroll phase（began 1、changed 2、ended 4、cancelled 8）。方向：內容跟手指走；是否與 Mac「自然捲動」設定互動於 TP5 實測。
- **手勢**：⌃← 左桌面、⌃→ 右桌面、⌃↑ Mission Control、⌃↓ App Exposé、⌘＋ 放大、⌘－ 縮小。不使用私有手勢事件。
- **看門狗**：任一按鍵按住時，350 ms（Provisional）未收到任何有效 `0x03` 即送放開。捲動中 150 ms（Provisional）未收到即送 ended。
- **斷線、關閉通道、Mac 關閉開關、Receiver 結束**：立即放開所有按住的按鍵、結束捲動、清空小數餘數與實驗補間狀態。
- **不受 focusEpoch 限制**，也不觸發輸入法切換（D4 只適用文字注入）。
- **接收時段**：收到有效 `0x03` 視同活動，延長 D13 的 30 分鐘計時。

## 11. 安全

| 威脅 | 對策 | 驗證 |
|---|---|---|
| 未配對裝置控制游標 | 必須認證＋協商＋Mac 開關 | TP3 單元測試、TP5 實機 |
| 竄改或偽造封包 | AEAD（含 header AAD） | TP2 竄改每個 byte 均被拒 |
| 重播 | 64 位元滑動視窗，驗證後才更新 | TP2 重播、亂序、過舊 |
| Nonce 重用 | 計數器綁 `PointerSession`；重送用新計數器 | TP2：同一 session 內所有封包計數器嚴格遞增；重連必定新金鑰 |
| 重複點擊 | 64 個 `actionId` 去重 | TP2／TP3：ACK 遺失重送 → 只點一次；第 65 個舊 id 的行為有測試 |
| 卡住拖曳 | 斷線釋放、心跳、看門狗、touchesCancelled | TP3 單元測試、TP5 實機 100 次 |
| 看門狗誤放開 | 實測 Extension 暫停、系統負載、BLE 延遲 | TP1 M6、TP5 |
| 過時 MOVE 積壓 | 累加器、不排佇列、節奏不超過排空速率 | TP1 M5、TP2 單元測試 |
| log 洩漏 | 只記 opcode、長度、計數器間隔、延遲統計、錯誤碼 | 每個 Task grep log |

## 12. 相容性

- `KeyboardEvent.protocolVersion` 維持 3；新增 `EventKind.pointerOpen(version:)`、`pointerClose`，只在 Mac 宣告 `pointer` 後才送，舊 Mac 不會收到。
- `ReceiverStatus` 新增 `pointer` 與 `doubleClickMs`，值為預設時不寫入。
- `ControlMessage` 新增 `pointerAck(actionIds: [UInt32])`，只在 sealed 內；只會送給已送過 `pointerOpen` 的 iPhone。
- `0x02` FrameCodec、`FrameReassembler`、配對、握手、長文字、去重邏輯不改。每個 Task 必須跑全部既有測試與 T07 長文字實機回歸。

## 13. 量測與決策關卡（TP1）

TP1 只做量測工具（DEBUG build），不做正式觸控板 UI，不實作 §6–§10 的正式協定。

| 編號 | 量測 | 方法 | 輸出 |
|---|---|---|---|
| M1 | BLE connection interval | Mac 上 PacketLogger 看 LE Connection Update；同時 Mac 記錄封包到達間隔。預設、`.low`、`.medium` 各 ≥ 10 次、每次 60 秒 | 分佈（P50／P95／其他值比例） |
| M2 | `updateValue` 背壓 | 在 ready 回呼內連續送 41 bytes 與 182 bytes 測試封包直到 `false`；記錄次數與到下一次 ready 的時間 | 次數分佈、排空時間 |
| M3 | 應用層 RTT | 41-byte 測試封包，Mac 收到即經 control 回寫；iPhone 記錄往返時間；≥ 10,000 次 | P50／P95／P99、jitter |
| M4 | 觸控到游標可見 | 測試觸控面：觸碰時畫面閃白；Mac 收到即以倍率 1 移動游標；另一支手機 240 fps 錄影，逐格計算 | P50／P95／P99（≥ 100 次） |
| M5 | 積壓 | 持續 60 Hz 測試封包，同時送 3,000 字長文字；比較有無長文字時 M3 的延遲走勢 | 延遲是否隨時間上升、最大值 |
| M6 | 心跳與看門狗 | 模擬按住拖曳，iPhone 每 100 ms 心跳，Mac 350 ms 看門狗；情境：系統負載（Mac 與 iPhone 各跑壓力程式）、鍵盤暫時被遮蔽、BLE 干擾 | 誤放開次數、放開延遲 |

量測封包（TP1 專用）：首 byte `0x7E`，內容只有序號、iPhone 單調時間與填充，沒有輸入內容、不加密；兩端都包在 `#if DEBUG` 內，Mac 面板有「量測模式」開關（預設關、Receiver 重開即關），且只在已認證的連線上回應。Release build 必須略過 `0x7E`（TP5 驗證）。

**決策關卡**：

| 結果 | 決定 |
|---|---|
| M4 P95 < 60 ms，且 M5 沒有積壓 | 繼續 TP2–TP5，以 BLE 為正式傳輸 |
| M4 P95 ≥ 60 ms 或 M5 有積壓 | 先分解瓶頸：iPhone 觸控到送出、BLE（M1／M3）、Mac 注入到畫面。能調整的先調（`.low`、節奏、封包大小）再量一次；仍未達標才另開 LAN 研究（D8），不立即放棄 BLE |

P50、P99、jitter 只記錄，不設硬性門檻。

## 14. Provisional 參數總表

| 參數 | 起始值 | 範圍 | 由誰定案 |
|---|---|---|---|
| MOVE 節奏 | 16.7 ms | 12–25 ms | TP1 M1／M2／M5 |
| 連線延遲偏好 | 觸控板頁 `.low` | `.low`／`.medium` | TP1 M1 |
| 可靠事件逾時 | max(3×RTT P95, 150 ms) | 100–300 ms | TP1 M3 |
| 重送次數 | 3 | 2–4 | TP5 |
| 可靠佇列深度 | 8 | 4–16 | TP5 |
| 心跳／看門狗 | 100／350 ms | 75–150／250–500 ms | TP1 M6、TP5 |
| 捲動看門狗 | 150 ms | 80–200 ms | TP5 |
| 加速曲線 g0／v0／gmax | 1.25／550 pt/s／3.5 | 0.9–1.8／350–900／2.5–5 | TP5 |
| 輕點時間／距離 | 200 ms／8 pt | 150–300 ms／6–14 pt | TP5 |
| 捲動倍率 | 1.0 | 0.6–2.5 | TP5 |
| 三指門檻／捏合門檻 | 40 pt／20% | 30–60 pt／15–30% | TP5 |
| AEAD 連續失敗關閉門檻 | 8 | 4–16 | TP5 |

## 15. 我的決定（請審閱）

| # | 決定 | 理由 |
|---|---|---|
| C1 | Mac「允許觸控板控制」預設關，使用者第一次在面板開啟 | 游標權限比打字大；報告 A、B 都建議要有獨立開關 |
| C2 | 封包 41 bytes（16-byte 明文負載），不追求最小 | 欄位對齊、保留 2 bytes；仍遠小於 182 bytes |
| C3 | 位移單位 1/16 pt | 範圍 ±2,048 pt 已足夠，精度 0.0625 pt |
| C4 | 計數器 UInt64 | 不必處理重新握手換金鑰 |
| C5 | 佇列阻塞後送累加總和，不截斷 | 截斷會讓游標停在手指沒到的位置；以 status bit 記錄供分析 |
| C6 | 量測封包不加密、只限 DEBUG | 內容只有序號與時間；TP1 不應先做正式協定 |
| C7 | 雙擊間隔用 Mac 系統設定，經 status 傳給 iPhone | 判定在 iPhone，但設定在 Mac |
| C8 | 可靠事件前先單獨送 MOVE，可靠事件本身不帶位移 | 重送、ACK 遺失、放棄時都不會重複或遺失位移 |
| C9 | 過舊 `actionId` 不執行但回 ACK | 寧可漏一下，不重複點擊；也讓 iPhone 停止重送 |
| C10 | `pointerAck` 合併送出，同時最多一個在途 | 不拖慢文字 ACK 與再見流程 |
| C11 | 除 CLICK、GESTURE 外，每個封包的 `buttons` 都是目標狀態，只依最新計數器調整 | 遺失的按鍵狀態封包可被下一個封包修正 |

## 16. 留給實作者

- Core 型別命名、檔案切分、測試命名。
- `CADisplayLink` 或計時器的選擇（需符合 §8 節奏與阻塞規則）。
- 量測資料的 CSV 欄位（不得含輸入內容或座標）。
- Mac 螢幕聯集夾限的實作方式。

## 17. 尚未決定（不在本設計）

- **觸控板頁 UI**（進入鍵位置、頁面外觀、是否顯示左右鍵區）：TP4 開始前另提 2–3 個方向，由使用者選定。
- **捲動慣性**：TP5 後依實測決定是否做第二階段。
- **LAN 後備**：只在決策關卡判定需要時另開研究。
