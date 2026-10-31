# iPhone 觸控板模式設計（D25）

- 狀態：修訂 2，待獨立審查（2026-11-01）。修訂 1 經使用者審閱，架構方向批准；修訂 2 處理量測加密、次序屏障、按鍵狀態版本、欄位容量、M4 量測方法與開關版本
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

- Mac 收到 `event` notification 時先看第 1 個 byte：`0x02` 交既有 `FrameReassembler`；`0x03` 交 `PointerReceiver`；`0x7E` 只在 DEBUG build 交量測模組（§13）；其他一律略過並只記種類與長度。已查證舊版 Receiver 對非 `0x02` frame 只記 log，不斷線，也不影響進行中的長訊息。
- 純邏輯（封包編解碼、加密、防重播、去重、傳送次序、累加器、加速曲線、看門狗、手勢判定）放 `RemoteKeyboardCore`，以 `swift test` 驗證；CoreBluetooth、UIKit、CGEvent 只做薄 adapter。

## 5. 能力協商、開關版本與權限

### 5.1 啟用條件

觸控板通道必須同時滿足以下全部條件才啟用：

1. 連線已完成雙向 challenge-response（`PhoneHandshake` 與 `MacHandshake` 都是 authenticated）。
2. Mac 端「允許觸控板控制」開關已開（Mac 面板新增；**預設關**，見 §15 C1）。
3. Mac 在 sealed `ReceiverStatus` 帶 `pointerGrant: UInt32`（開關開時才有；關時不寫入，舊版 iPhone 讀到的位元組與現在相同）。`pointerGrant` 是「授權版本」：每次新連線認證完成、每次開關由關轉開，Mac 都產生一個新值（同一 Receiver 執行期間遞增，起始值隨機）。
4. iPhone 進入觸控板頁時送 `EventKind.pointerOpen(version: 1, grant: UInt32, stateSeq: UInt32)`，`grant` 為最近一次收到的 `pointerGrant`。
5. Mac 回 `ack`。結果為 `posted` 時，iPhone 才開始送 `0x03`；其他結果見 §5.2。

### 5.2 開關訊息的版本保護

- `stateSeq`（UInt32）是 iPhone 端觸控板開關訊息的版本，存在 `PointerSession`，每送一個 `pointerOpen` 或 `pointerClose(stateSeq: UInt32)` 就加 1，從 1 起。
- Mac 記住最後套用的 `stateSeq` 及其結果：
  - 收到的 `stateSeq` 大於最後套用值：依下列規則處理並更新。
  - 等於：重複送達，回原結果，不重新處理。
  - 小於：過期，不處理，回 `outOfOrder`。
- **處理 `pointerOpen` 時重新檢查權限**（不沿用先前結果）：連線仍是已認證、開關仍開、`grant` 等於 Mac 目前的 `pointerGrant`、`version` 為 1。全部成立才開啟通道並回 `posted`；否則通道維持關閉並回 `notAuthorized`。
- `pointerClose` 不需權限即可處理：關閉通道、釋放所有按鍵、結束捲動，回 `posted`。
- `pointerOpen`、`pointerClose` 在 Mac 收到並解密後**立即同步處理**，不排在文字注入的序列後面（文字注入可能因輸入法切換花數百毫秒）；不經事件去重與焦點檢查：`carriesFocusEpoch` 為 false、不記入 `EventDeduplicator`。iPhone 以 `eventId` 等待 ack，不計入打字的待確認數。
- iPhone 不重送同一則開關訊息；1 秒（Provisional）內沒有 ack，就以新的 `stateSeq` 送一則新的。
- iPhone 只依「最新一則開關訊息」的 ack 行動：收到較舊 `pointerOpen` 的遲到 ack 時，若之後已送出 `pointerClose` 或新的 `pointerOpen`，一律略過，不開始送 `0x03`。
- Mac 的 `PointerGate`（最後套用的 `stateSeq`、結果、通道狀態）屬於單一連線：每次新連線認證完成時重設，因此新連線的 `stateSeq = 1` 會被正常處理。

### 5.3 每個封包都重新檢查

Mac 處理每一個 `0x03` 時都檢查：通道為開啟、連線已認證、開關仍開且 `pointerGrant` 未變。任一不成立即丟棄（不解密之後的動作），並在通道原本開啟時執行關閉清理。

### 5.4 關閉條件

任何一項發生即關閉，Mac 立即釋放所有按鍵並結束捲動：

- 套用 `pointerClose`。
- Mac 關閉開關：立即關閉，並送出不帶 `pointerGrant` 的 status。再次打開會產生新 `pointerGrant`，iPhone 必須送新的 `pointerOpen`。
- 斷線或認證失敗。
- 連續 8 個 `0x03` 無法通過 AEAD 驗證（單一失敗只丟棄並計數）。

舊版相容：舊 iPhone 不會送 `pointerOpen`；舊 Mac 不會帶 `pointerGrant`，因此新 iPhone 不會送 `0x03`。

## 6. 計數器 AEAD 封包

### 6.1 共用信封

觸控板封包（`0x03`）與 TP1 量測封包（`0x7E`，§13）使用同一種信封，只差 magic、金鑰與 nonce 前綴：

| Byte | 長度 | 欄位 | 加密 |
|---|---|---|---|
| 0 | 1 | magic | 明文，列入 AAD |
| 1–8 | 8 | `counter`，UInt64 big-endian，每把金鑰從 1 起 | 明文，列入 AAD |
| 9 … N−17 | 明文長度 | 密文 | ChaCha20 |
| N−16 … N−1 | 16 | Poly1305 tag | — |

| 通道 | magic | 方向 | 金鑰 HKDF info | nonce 前綴（4 bytes） | 明文長度 | 封包總長 |
|---|---|---|---|---|---|---|
| 觸控板 | `0x03` | iPhone → Mac（notify） | `rk-pointer-p2m` | `PTR3` | 16 | 41 |
| 量測 | `0x7E` | iPhone → Mac（notify） | `rk-measure-p2m` | `MSR3` | 16 或 157 | 41 或 182 |
| 量測回覆 | `0x7E` | Mac → iPhone（control write） | `rk-measure-m2p` | `MSE3` | 16 | 41 |

- 金鑰：`HKDF-SHA256(pairKey, salt: 空, info: 上表字串 ‖ macNonce ‖ phoneNonce, 32 bytes)`。與既有事件、控制通道的 session key 分開，避免同一把金鑰混用隨機 nonce 與計數器 nonce。
- Nonce：12 bytes = 前綴 ‖ `counter`（8 bytes BE）。AAD：封包 byte 0–8。
- 一律單一 notification（或單一 control write），不經 FrameCodec。

### 6.2 觸控板明文負載（16 bytes）

| Byte | 欄位 | 說明 |
|---|---|---|
| 0 | `opcode` | 見下表 |
| 1 | `buttons` | bit0 左、bit1 右（目標狀態，見 §6.4）；bit4–7 觸點數（只供診斷）；bit2–3 必須為 0 |
| 2–3 | `dx` | Int16 BE，單位 1/16 iPhone pt（−2,048 … +2,047.9375 pt） |
| 4–5 | `dy` | Int16 BE，單位 1/16 pt，向下為正 |
| 6–7 | `dt` | UInt16 BE，單位 0.1 ms（0 … 6,553.5 ms）：本封包位移涵蓋的觸控樣本時間跨度 |
| 8–11 | `actionId` | UInt32 BE；不可靠事件為 0 |
| 12 | `arg` | 依 opcode：點擊次數、捲動階段、手勢指令 |
| 13 | `status` | bit0 阻塞後累積；bit1 已捨棄過時位移；bit2 已截斷到欄位上限；bit3–7 必須為 0 |
| 14–15 | `buttonSeq` | UInt16 BE，按鍵狀態版本（§6.4） |

任何必須為 0 的位元不為 0，整包拒收。

| opcode | 名稱 | 可靠 | 說明 |
|---|---|---|---|
| `0x01` | MOVE | 否 | 位移，不 ACK |
| `0x02` | SCROLL | 否；`ended`／`cancelled` 為可靠 | `dx`／`dy` 為捲動量；`arg`：0 changed、1 began、2 ended、3 cancelled。未收到 began 就收到 changed，Mac 視為 began |
| `0x10` | CLICK | 是 | `arg` 低 2 bit 為按鍵（0 左、1 右），高 4 bit 為點擊次數（1–3） |
| `0x11` | BUTTON_STATE | 是 | 按鍵狀態改變（拖曳開始與結束） |
| `0x12` | HEARTBEAT | 否 | 有按鍵按住時定期送 |
| `0x20` | GESTURE | 是 | `arg`：1 左桌面、2 右桌面、3 Mission Control、4 App Exposé、5 放大、6 縮小 |

可靠事件本身的 `dx`、`dy`、`dt` 一律為 0；位移一律由 MOVE 承載（§8.2）。

### 6.3 防重播與計數器規則

1. 每條已認證的連線只建立一次 `ChannelSet`：握手 reducer 只提供一次（第二次取用回 nil），金鑰在 `ChannelSet` 內部派生，外部取不到金鑰本身。`ChannelSet` 內每個通道各有唯一的 sealer 與 opener（含計數器與防重播視窗），由該連線的 adapter 獨佔持有直到斷線，且只在該 adapter 的單一序列執行環境（iPhone 為 main thread 的 CoreBluetooth 委派、Mac 為 central 的委派佇列）中使用；量測重跑、量測模式開關切換、觸控板頁進出都沿用同一個 sealer，不得重新建立。這樣不可能在同一把金鑰下出現第二個從 1 開始的計數器。
2. 只有新的握手（新 macNonce 與 phoneNonce）才會建立新的 session；同一條連線內切換鍵盤頁、`pointerClose` 再 `pointerOpen` 都沿用原計數器，不得歸零。
3. 計數器在「交給 `updateValue`（或 control write）之前」才配給並加密。`updateValue` 回 `false` 時，該密文作廢、計數器不回收（留下間隙），內容於下次機會用新計數器重新加密。可靠事件重送同樣用新計數器。因此同一金鑰下 nonce 永不重複。
4. 計數器達 `UInt64.max` 時關閉通道。
5. 金鑰、計數器、防重播視窗、`actionId`、`buttonSeq`、`stateSeq` 只存記憶體，不寫入 UserDefaults、App Group、Keychain 或檔案。Extension 被系統結束後重新載入一定是新連線與新握手（既有行為），因此一定是新金鑰。
6. 防重播：接收端記住最大計數器與其下 64 個的位元圖。大於最大值：接受並移動視窗；在視窗內且未見過：接受；見過或更舊：丟棄。必須先通過 AEAD 驗證才更新視窗。

### 6.4 按鍵狀態版本（`buttonSeq`）

- iPhone 每次按鍵狀態改變（產生一個 BUTTON_STATE）時 `buttonSeq` 加 1，從 1 起，存在 `PointerSession`。
- 每個 MOVE、SCROLL、HEARTBEAT、BUTTON_STATE 都帶「該封包所代表時刻」的 `buttons` 與 `buttonSeq`（§8.2 的封閉段帶封閉當時的值）。CLICK、GESTURE 也帶，但 Mac 不據此改變狀態。
- Mac 記住最後套用的 `buttonSeq`。只有當封包的 `buttonSeq` 比它新時，才依該封包的 `buttons` 調整按鍵（只送差異）；相同或較舊一律不改狀態。比較用 16 位元序號算術（RFC 1982：`0 < (a − b) mod 65536 < 32768` 表示 a 較新）。
- 結果：重送的舊 BUTTON_STATE 即使拿到較大的計數器，也因 `buttonSeq` 較舊而不會覆蓋較新的狀態（仍回 ACK）；遺失的 BUTTON_STATE 由下一個帶較新 `buttonSeq` 的封包修正。
- 移動時用 Mac 套用後的狀態決定 `.leftMouseDragged`、`.rightMouseDragged` 或 `.mouseMoved`。v1 手勢只產生左鍵拖曳。

### 6.5 可靠事件與 ACK

- `actionId` 在每個 `PointerSession` 內由 1 遞增。
- Mac 執行可靠事件後回 `pointerAck`，把待回的 `actionId` 合併：同一時間最多一個 `pointerAck` 寫入在途，在途期間新增的 id 併入下一次。`pointerAck` 走既有 sealed control 寫入佇列，與文字 `ack`、`status`、`bye` 依序處理；「再見」流程等待的在途寫入也包含它。
- 重複：`actionId` 在最近 64 個已執行記錄內 → 不執行，回 ACK。
- 過舊：`actionId` ≤ 已執行最大 id − 64 → 不執行，回 ACK（寧可漏一下也不重複點擊）。
- 重送：CLICK 與 GESTURE 只在原封包交出後 300 ms（Provisional）內重送，超過即放棄並計數，避免在游標已移走後才點下去。BUTTON_STATE 與 SCROLL ended／cancelled 最多重送 3 次；較新的 BUTTON_STATE 一旦交出，較舊的停止重送（`buttonSeq` 已使其失效）。放棄後的按鍵狀態由後續封包的 `buttons`／`buttonSeq` 與 Mac 看門狗保證。
- GESTURE 的 ACK 只代表快捷鍵已送出，不代表 Mac 的對應功能已開啟或生效。

## 7. （併入 §6）

加密、金鑰與防重播規則見 §6.1、§6.3。

## 8. iPhone 端傳送

### 8.1 取樣與節奏

- `touchesMoved` 使用 `coalescedTouches(for:)`；不用 `predictedTouches` 送 Mac。位移以 `Double` 累加，送出時才量化成 1/16 pt，餘數帶到下一個 MOVE。
- 開放中的累加段約每 16.7 ms（Provisional，範圍 12–25 ms）最多送一個 MOVE；距上一個 MOVE 已超過一個節奏間隔時（例如手指由靜止開始移動），第一個 MOVE 立即送出。送 MOVE 的頻率不得高於 TP1 量到的實際排空速率（Provisional 上限：每個實測 connection interval 一個）。

### 8.2 單一有序出口與次序屏障

iPhone 把所有 `0x03` 放進一個有序出口 `PointerOutbox`，內容是依序排列的項目：

- **累加段**：一段位移（`dx`、`dy` 總和、最早與最晚樣本時間、量化餘數），以及該段的 `buttons`／`buttonSeq`。佇列尾端永遠有一個「開放段」接收新位移。
- **可靠事件**：CLICK、BUTTON_STATE、GESTURE、SCROLL ended／cancelled，以及它們的重送。
- **捲動累加段**：SCROLL began／changed 的捲動量與位移一樣累加（同樣的量化、過時與容量規則），每段只產生一個 SCROLL 封包。
- **心跳**：最多一個待送的 HEARTBEAT；新的取代舊的。

規則：

1. **屏障**：加入可靠事件時，先把目前的開放段「封閉」（內容與當時的 `buttons`／`buttonSeq` 固定），排在可靠事件之前；之後的位移進入可靠事件之後新開的開放段。所以順序必定是「點擊前的位移 → 點擊 → 點擊後的位移」，BUTTON_STATE（放開）也同樣排在拖曳位移之後。
2. **依序交出**：只有佇列最前面的項目可以交給 `updateValue`；它被接受（回 `true`）後才輪到下一項。空的累加段直接略過。
3. **背壓**：`updateValue` 回 `false` 後整個出口停止，直到 `peripheralManagerIsReady`；期間新位移只加入尾端開放段，不新增封包。被拒的項目維持在最前面，下次用新計數器重新加密（§6.3）。
4. **與打字的關係（公平交錯）**：0x03 不是 0x02 frame，不影響 `FrameReassembler` 的重組（已查證），所以可以夾在長訊息的 frame 之間。兩邊都有待送項目時，每交出 4 個 0x02 frame（Provisional）就交出 1 個 0x03 項目，避免長文字期間心跳與放開被卡住而觸發看門狗誤放開；只有一邊有待送時就只送那一邊。
5. **節奏只限開放段**：封閉段、可靠事件與不可靠控制在輪到時立即交出；只有開放段受 §8.1 節奏限制。
6. **重送**：可靠事件逾時重送時，以新項目加入尾端（同樣形成屏障），受 §6.5 的時間與次數上限限制，所以出口不會因重送無限增長。連線中 notification 不會遺失也不會亂序，所以同一連線內的重送幾乎只發生在 ACK 遺失；Mac 以 `actionId` 去重。
7. **容量**：未 ACK 的 CLICK 與 GESTURE 合計最多 8 個（Provisional），滿了時新的 CLICK／GESTURE 不加入並計數。BUTTON_STATE 與 SCROLL ended／cancelled 一律加入、不合併（合併會改變其前後位移屬於拖曳或一般移動）；它們由手指動作產生，數量受手指動作限制。
8. **Mac 端**：依到達次序處理 `0x03`；連線中到達次序即交出次序。
9. **喚醒**：出口不會自己動，adapter 在下列時機呼叫一次「盡量交出」：加入任何項目、觸控樣本到達、觸控板頁可見期間的每個顯示更新（`CADisplayLink`，同時驅動節奏、心跳與重送計時）、`peripheralManagerIsReady`、`NotifyQueue` 送完最後一個 frame、收到 `pointerAck`。

### 8.3 溢位與過時資料

- **過時捨棄（只限開放段）**：開放段以 10 ms 為一格保存子總和。交出時若最早一格早於「現在 − 過時上限」（Provisional 150 ms），捨棄較舊的格子，`status` bit1 = 1，記錄捨棄次數（不記數值）。原因：阻塞恢復後，把手指很久以前的動作一次補上，會讓游標突然大跳。
- **封閉段不按時間捨棄**：封閉段決定點擊與放開的位置；捨棄點擊前的位移會讓點擊落在手指沒到的地方，所以寧可接受阻塞後一次大幅移動（使用者此時的意圖就是點在移動終點）。唯一的截斷是下述容量上限。
- **欄位容量**：
  - `dt` = 該封包涵蓋樣本的最晚時間 − 最早時間，上限 6,553.5 ms；開放段因過時上限不會超過 150 ms。封閉段超過上限時夾到上限並設 bit2（只影響 Mac 的速度估計，Mac 另會把 `dt` 夾在 5–150 ms）。
  - `dx`／`dy` 超過 Int16 範圍時，把同一段拆成連續數個 MOVE（或 SCROLL），每個都在範圍內，`dt` 按比例分配，總和不變；拆分屬同一項目，中間不可插入其他項目。單一段最多拆 8 個（約 ±16,000 pt，遠超過 390 pt 寬的觸控面在任何實際阻塞時間內能產生的量）；超過時截斷到上限並設 bit2。這是唯一的截斷情況。
- **阻塞後**：恢復後第一個 MOVE 設 bit0。

### 8.4 其他

- **可靠事件逾時**：`max(3 × TP1 RTT P95, 150 ms)`，最多重送 3 次（Provisional）。
- **連線延遲偏好**：進入觸控板頁時 `setDesiredConnectionLatency(.low, for: central)`，離開時改回 `.medium`。是否改為訂閱後即設 `.low`，依 TP1 結果決定。
- **心跳**：任一按鍵按住時，每 100 ms（Provisional）送 HEARTBEAT。
- **觸控取消**：`touchesCancelled`、鍵盤收起、離開觸控板頁，一律送 BUTTON_STATE（全放開）與 SCROLL cancelled，再送 `pointerClose`（離開頁面時）。

## 9. iPhone 端手勢判定（純邏輯）

| 手勢 | 判定（全部 Provisional） | 送出 |
|---|---|---|
| 單指移動 | 位移超過輕點門檻 | MOVE |
| 單指輕點 | ≤ 200 ms 且總位移 ≤ 8 pt | CLICK 左鍵 1 下 |
| 雙擊 | 第二次輕點在 Mac `NSEvent.doubleClickInterval` 內（Mac 在 status 中以 `doubleClickMs` 提供，預設 500 ms）且距離 ≤ 12 pt | 第二次送 CLICK 次數 2 |
| 雙擊後按住（拖曳） | 第一次輕點後在雙擊間隔內第二次按下並超過 200 ms 或開始移動 | BUTTON_STATE 左鍵按下；手指離開時送放開 |
| 雙指輕點 | 兩指同時落下，≤ 200 ms，各自位移 ≤ 12 pt | CLICK 右鍵 |
| 雙指移動 | 兩指同向移動超過 8 pt | SCROLL began → changed → ended |
| 三指左右上下 | 位移 ≥ 40 pt | GESTURE 1–4 |
| 雙指捏合 | 距離變化 ≥ 20% | GESTURE 5／6 |

判定邏輯放 Core 的狀態機，以合成觸控序列測試。

## 10. Mac 端處理

- **游標移動**：讀目前游標全域座標（Quartz 點座標，不乘 Retina 倍率），加上 `(dx, dy) × g(v)`，夾到所有螢幕聯集內最近的位置；設定 `mouseEventDeltaX／Y`；事件種類依 §6.4 套用後的狀態決定。小數餘數累積到下一次。
- **加速曲線**（Provisional）：`v = hypot(dx, dy) / dt`（pt/s），`g(v) = g0 + (gmax − g0) · v² / (v² + v0²)`，`g0 = 1.25`、`v0 = 550 pt/s`、`gmax = 3.5`；`dt` 夾在 5–150 ms。TP5 以三組參數對照（含報告 B 的三次曲線）。
- **平滑**：v1 收到即注入。120 Hz 分段補間與 1-Euro 濾波實作為預設關閉的實驗開關，只在實測顯示「一跳一跳」比延遲更影響使用時才開啟。
- **點擊**：在目前游標位置送 down／up，`mouseEventClickState` = 次數。
- **捲動**：`CGEvent(scrollWheelEvent2Source:units: .pixel, wheelCount: 2, …)`，倍率 1.0 Mac 點／iPhone pt（Provisional），設 `scrollWheelEventIsContinuous = 1` 與 scroll phase（began 1、changed 2、ended 4、cancelled 8）。方向：內容跟手指走；與 Mac「自然捲動」設定的互動於 TP5 實測。
- **手勢**：⌃← 左桌面、⌃→ 右桌面、⌃↑ Mission Control、⌃↓ App Exposé、⌘＋ 放大、⌘－ 縮小。不使用私有手勢事件。
- **看門狗**：任一按鍵按住時，350 ms（Provisional）未收到任何有效 `0x03` 即送放開；捲動中 150 ms（Provisional）未收到即送 ended。看門狗放開後，Mac 記住此時的 `buttonSeq`，之後只接受更新的 `buttonSeq` 再按下（避免遲到的心跳把按鍵重新按下），並經 sealed control 送 `pointerReleased(buttonSeq:)` 通知 iPhone；iPhone 只在自己目前的 `buttonSeq` 等於通知中的值、且按鍵仍是按下時，才結束本機的拖曳狀態（視為已放開，`buttonSeq` 加 1）；否則（使用者已放開或已重新按下）略過這個遲到的通知。使用者需重新按住才會再拖曳。
- **關閉清理**（斷線、通道關閉、開關關閉、Receiver 結束）：立即放開所有按住的按鍵、結束捲動、清空小數餘數與實驗補間狀態。
- **不受 focusEpoch 限制**，也不觸發輸入法切換（D4 只適用文字注入）。
- **接收時段**：收到有效 `0x03` 視同活動，延長 D13 的 30 分鐘計時。

## 11. 安全

| 威脅 | 對策 | 驗證 |
|---|---|---|
| 未配對或未授權裝置控制游標 | 認證＋`pointerGrant`＋`pointerOpen` 權限重查＋每封包重查 | TP2、TP3 單元測試；TP5 實機 |
| 開關關閉後仍被控制 | 關閉即關通道；新 `pointerGrant`；舊 `grant` 的 `pointerOpen` 回 `notAuthorized` | TP3 |
| 過期的開關訊息 | `stateSeq` 版本：重複回原結果、較舊回 `outOfOrder` | TP2、TP3 |
| 竄改或偽造封包 | AEAD（含 header AAD），觸控板與量測封包一致 | TP1（量測）、TP2（觸控板）逐 byte 竄改 |
| 重播 | 64 位元滑動視窗，驗證後才更新 | TP1、TP2 |
| Nonce 重用 | 每條連線只建立一次 `ChannelSet`、sealer 唯一不可重建；交出前才配給；被拒與重送都用新計數器 | TP1、TP2：所有交出的封包計數器嚴格遞增；重連必定新金鑰 |
| 重複點擊 | 64 個 `actionId` 去重；過舊不執行 | TP2、TP3；TP5 實機 |
| 舊按鍵狀態覆蓋新狀態 | `buttonSeq` 序號比較，與計數器無關 | TP2、TP3 |
| 點擊落在錯誤位置 | 有序出口與屏障 | TP2（含背壓）、TP5 |
| 卡住拖曳 | 關閉清理、心跳、看門狗、touchesCancelled | TP3；TP5 實機 100 次 |
| 看門狗誤放開 | 0x03 與長文字公平交錯；實測 Extension 暫停、系統負載、BLE 延遲、長文字傳送 | TP1 M6、TP5 |
| 過時 MOVE 積壓 | 單一出口、只保留累加段、背壓時不建封包、節奏不超過排空速率、開放段過時捨棄 | TP1 M5、TP2 |
| log 洩漏 | 只記 opcode、長度、計數器間隔、延遲統計、錯誤碼 | 每個 Task grep log |

## 12. 相容性

- `KeyboardEvent.protocolVersion` 維持 3；新增 `EventKind.pointerOpen(version:grant:stateSeq:)`、`pointerClose(stateSeq:)`，只在 Mac 宣告 `pointerGrant` 後才送，舊 Mac 不會收到。
- `ReceiverStatus` 新增 `pointerGrant: UInt32?`、`doubleClickMs: Int?`，以及 DEBUG 量測用的 `measure: Bool`（預設 false）；值為預設時不寫入。
- `ControlMessage` 新增 `pointerAck(actionIds: [UInt32])` 與 `pointerReleased(buttonSeq: UInt16)`，只在 sealed 內，只送給已開啟觸控板通道的 iPhone。
- `AckCode` 不新增；沿用 `posted`、`notAuthorized`、`outOfOrder`。
- `0x02` FrameCodec、`FrameReassembler`、配對、握手、長文字、事件去重邏輯不改。每個 Task 必須跑全部既有測試與 T07 長文字實機回歸。

## 13. 量測與決策關卡（TP1）

TP1 只做量測工具（DEBUG build），不做正式觸控板 UI，也不做 §6.2 之後的觸控板語意；但量測封包使用 §6.1 的同一種 AEAD 信封，封包大小與密碼學開銷與正式觸控板封包相同。

### 13.1 量測通道

- Mac 面板（DEBUG）「量測模式」開關，預設關，Receiver 重開即關。開啟時 sealed status 帶 `measure: true`。
- iPhone（DEBUG）只在已認證且收到 `measure: true` 後才送 `0x7E`。Mac 每個封包都重查：已認證、量測模式開。
- `0x7E` 明文負載（16 bytes）：`kind`（1：burst、2：rtt、3：cursor、4：heartbeat）、保留 1 byte（0）、`dx` Int16（1/16 pt，只 cursor 用）、`seq` UInt32、`phoneTimeMicros` UInt64（iPhone 單調時鐘）。M2 的 182-byte 版本以 0 填充到 157 bytes 明文。
- Mac 回覆（`0x7E`，control write，41 bytes）明文：`seq` UInt32、`phoneTimeMicros` UInt64、`macHoldMicros` UInt32（Mac 收到到寫出之間的時間）。iPhone 以 `rk-measure-m2p` 金鑰與自己的防重播視窗驗證。
- 內容沒有任何輸入文字或座標以外的使用者資料；`dx` 只用於 M4 測試游標，不寫入 log。
- Release build：量測通道的型別、金鑰派生與處理程式（含 Core 內的部分）全部包在 `#if DEBUG`，Release 產物不含這些符號；收到 `0x7E` 一律略過。`ReceiverStatus.measure` 欄位為維持 status 編碼相容而保留在 Release，Release 的 Mac 永遠不設為 true。TP1 起每個 Task 以 Release build 加符號檢查驗證（檢查 `MeasurePayload`、`MeasureEchoPayload`、`measureP2M`、`measureM2P`、`MeasurementEcho`、`MeasurementRunner`）。

### 13.2 量測項目

| 編號 | 量測 | 方法 | 輸出 |
|---|---|---|---|
| M1 | BLE connection interval | Mac 上 PacketLogger 看 LE Connection Update；同時 Mac 記錄封包到達間隔。預設、`.low`、`.medium` 各 ≥ 10 次、每次 60 秒 | 分佈（P50／P95／其他值比例） |
| M2 | `updateValue` 背壓 | 在 ready 回呼內連續送 41 bytes 與 182 bytes 量測封包直到 `false`，各 100 輪；記錄次數與到下一次 ready 的時間 | 次數分佈、排空時間 |
| M3 | 應用層 RTT | 41-byte rtt 封包 60 Hz；Mac 只在沒有回覆寫入在途時回覆（其餘只記到達時間、計為略過），避免回覆排隊本身拉高 RTT；iPhone 記錄 `交出時間 → 收到回覆` 往返；≥ 10,000 個回覆樣本 | P50／P95／P99、jitter（P95 − P50）、到達間隔標準差、略過比例 |
| M4 | 觸控到游標可見 | 見 §13.3 | 見 §13.3 |
| M5 | 積壓 | M3 同時送 3,000 字長文字；比較有無長文字時 RTT 走勢；另記錄 iPhone 出口被背壓阻塞的時間與次數 | RTT 是否隨時間持續上升、最大值、阻塞時間分佈 |
| M6 | 心跳與看門狗 | iPhone 每 100 ms 送 heartbeat 量測封包，Mac 以 350 ms 看門狗只記錄「會放開」事件（不注入）；心跳依 §8.2 規則 4 與長文字公平交錯；情境：一般、同時傳送 3,000 字長文字、系統負載（Mac 與 iPhone 各跑壓力程式）、鍵盤暫時被遮蔽、BLE 干擾（附近大量藍牙／Wi-Fi 傳輸），各 10 分鐘 | 誤放開次數、心跳到達間隔最大值與 P99 |

### 13.3 M4 觸控到游標可見的量測方法

**時間點定義**：

| 代號 | 事件 | 來源 | 時鐘 |
|---|---|---|---|
| T0 | 手指開始移動（實體） | 240 fps 錄影 | 影片 |
| T1 | UIKit 收到觸控（`UITouch.timestamp`） | iPhone 軟體 | iPhone |
| T2 | iPhone 畫面提示（測試面整塊變白）可見 | 240 fps 錄影 | 影片 |
| T3 | 量測封包交給 `updateValue` 並被接受 | iPhone 軟體 | iPhone |
| T4 | Mac 收到 notification | Mac 軟體 | Mac |
| T5 | Mac 送出 `CGEvent`（並同時讓 DEBUG 小視窗變白） | Mac 軟體 | Mac |
| T5′ | Mac 小視窗變白可見 | 240 fps 錄影 | 影片 |
| T6 | Mac 游標開始移動可見 | 240 fps 錄影 | 影片 |

**做法**：

1. iPhone 測試觸控面：每一筆劃第一個 `touchesMoved` 時整塊變白，並送出 cursor 量測封包；之後每 16.7 ms 送一個。
2. Mac 收到 cursor 封包即移動游標（量測倍率 4，讓開始移動清楚可見；不套用加速曲線）；同時讓角落 DEBUG 小視窗變白一格。
3. 輔助使用設定把游標放大，背景用高對比單色。
4. 另一支手機以 240 fps 同框拍 iPhone 觸控面、手指與 Mac 螢幕；確認影片實際幀率（metadata），記錄 iPhone 與 Mac 螢幕更新率（60／120 Hz）。
5. 每次手指由靜止開始移動，≥ 100 筆（決策邊界時增至 ≥ 200，見下）。
6. 逐格判讀 T0、T2、T5′、T6 所在的幀。T0 定義為「手指與起點相比可見位移 ≥ 1 像素的第一幀」。

**報告指標**：

| 指標 | 計算 | 用途 |
|---|---|---|
| E2E（關卡指標） | T6 − T0 | 真正的觸控到游標可見，含 iPhone 觸控面板延遲 |
| 傳輸到畫面 | T6 − T2 | 排除 iPhone 觸控面板延遲與部分繪圖延遲 |
| Mac 畫面 | T6 − T5′ | 游標與視窗繪製路徑差異（游標通常較快） |
| iPhone 軟體 | T3 − T1 | 取樣到交出 |
| Mac 軟體 | T5 − T4 | 收到到注入 |
| BLE 單程（估計） | M3 RTT／2 | 兩端時鐘未同步，只能估計 |
| 節奏等待 | 每個 cursor 封包的「交出時間 − 最早樣本時間」 | M4 起點量的是第一個封包（立即送出）；持續移動時每個封包另有最多一個節奏間隔的等待，以此分佈補充說明 |

**誤差**：

- 每個影片時間點量化誤差 ±½ 幀（±2.08 ms）；兩點相減最大 ±4.17 ms。加上起點判讀 ±1 幀，單次 E2E 誤差上限約 ±8.3 ms。
- T2 晚於 T1 至少一次 iPhone 畫面更新（120 Hz 約 8.3 ms，60 Hz 約 16.7 ms），所以 T6 − T2 會低估傳輸延遲，只作分解參考。
- T6 受 Mac 螢幕更新率影響（60 Hz 時最多多 16.7 ms）；報告須註明更新率。
- 軟體時間點只在同一台裝置內相減；不跨裝置相減。

**決策邊界**：E2E P95 落在 52–68 ms（60 ± 8.3）時視為邊界，增加到 ≥ 200 筆再判定。

### 13.4 決策關卡

| 結果 | 決定 |
|---|---|
| E2E P95 < 60 ms，且 M5 沒有積壓 | 繼續 TP2–TP5，以 BLE 為正式傳輸 |
| E2E P95 ≥ 60 ms 或 M5 有積壓 | 以 §13.3 的分解找出瓶頸（iPhone 觸控與軟體、BLE、Mac 注入與畫面）。能調整的先調（`.low`、節奏、封包大小）再量一次；仍未達標才另開 LAN 研究（D8），不立即放棄 BLE |

P50、P99、jitter、封包積壓只記錄，不設硬性門檻。

## 14. Provisional 參數總表

| 參數 | 起始值 | 範圍 | 由誰定案 |
|---|---|---|---|
| MOVE 節奏 | 16.7 ms | 12–25 ms | TP1 M1／M2／M5 |
| 連線延遲偏好 | 觸控板頁 `.low` | `.low`／`.medium` | TP1 M1 |
| 可靠事件逾時 | max(3×RTT P95, 150 ms) | 100–300 ms | TP1 M3 |
| 重送次數 | 3 | 2–4 | TP5 |
| 未 ACK 可靠事件上限 | 8 | 4–16 | TP5 |
| 過時上限（開放段） | 150 ms | 75–300 ms | TP1 M5、TP5 |
| CLICK／GESTURE 重送時限 | 300 ms | 150–500 ms | TP1 M3、TP5 |
| 0x02／0x03 交錯比例 | 每 4 個 0x02 frame 交出 1 個 0x03 | 2–8 | TP1 M6、TP5 |
| 開關訊息無 ack 改送新版本 | 1 s | 0.5–2 s | TP5 |
| 單段最多拆分 | 8 個 MOVE | 4–16 | TP5 |
| 心跳／看門狗 | 100／350 ms | 75–150／250–500 ms | TP1 M6、TP5 |
| 捲動看門狗 | 150 ms | 80–200 ms | TP5 |
| 加速曲線 g0／v0／gmax | 1.25／550 pt/s／3.5 | 0.9–1.8／350–900／2.5–5 | TP5 |
| 輕點時間／距離 | 200 ms／8 pt | 150–300 ms／6–14 pt | TP5 |
| 捲動倍率 | 1.0 | 0.6–2.5 | TP5 |
| 三指門檻／捏合門檻 | 40 pt／20% | 30–60 pt／15–30% | TP5 |
| AEAD 連續失敗關閉門檻 | 8 | 4–16 | TP5 |
| M4 量測游標倍率 | 4 | 1–8 | TP1 |

## 15. 我的決定（請審閱）

| # | 決定 | 理由 |
|---|---|---|
| C1 | Mac「允許觸控板控制」預設關，使用者第一次在面板開啟 | 游標權限比打字大 |
| C2 | 觸控板封包 41 bytes（16-byte 明文） | 欄位對齊；遠小於 182 bytes |
| C3 | 位移單位 1/16 pt | 範圍約 ±2,048 pt，精度 0.0625 pt |
| C4 | 計數器 UInt64 | 不必處理換金鑰 |
| C5 | 開放段超過 150 ms 的位移捨棄；封閉段不按時間捨棄，只在超過 8 個 MOVE 時截斷 | 阻塞後避免游標大跳，但點擊與放開位置必須準確 |
| C6 | 量測通道用同一種 AEAD 信封與獨立金鑰，只限 DEBUG | 符合「所有事件必須加密」，並量到與正式封包相同的大小與開銷 |
| C7 | 雙擊間隔用 Mac 系統設定，經 status 傳給 iPhone | 判定在 iPhone，但設定在 Mac |
| C8 | 位移只由 MOVE 承載，可靠事件不帶位移 | 重送、ACK 遺失、放棄都不會重複或遺失位移 |
| C9 | 過舊 `actionId` 不執行但回 ACK | 寧可漏一下，不重複點擊 |
| C10 | `pointerAck` 合併送出，同時最多一個在途 | 不拖慢文字 ACK 與再見流程 |
| C11 | 按鍵狀態以 `buttonSeq` 決定新舊，與計數器無關 | 重送的舊狀態不會覆蓋新狀態 |
| C12 | 單一有序出口，可靠事件形成屏障 | 背壓下仍保證「位移 → 點擊 → 位移」次序 |
| C13 | `pointerGrant` 授權版本＋`stateSeq` 開關版本 | 開關關過再開、過期的開關訊息都不會誤開通道 |
| C14 | 計數器在交出前才配給；被拒密文作廢 | 背壓下也不會 nonce 重用 |
| C15 | 每條連線只建立一次 `ChannelSet`，sealer 唯一且不可重建 | 從 API 結構上杜絕同一金鑰下計數器重新從 1 開始 |
| C16 | 0x03 與長文字公平交錯，不再整段等待 | 長文字期間心跳不會被卡住而誤放開 |
| C17 | CLICK／GESTURE 重送只限 300 ms 內 | 不在游標移走後才點下 |
| C18 | 看門狗放開後通知 iPhone（`pointerReleased`） | iPhone 與 Mac 的拖曳狀態一致，不會卡在「以為按住」 |
| C19 | M3 回覆不排隊，同時最多一個在途 | 避免量測工具自身拉高 RTT |

## 16. 留給實作者

- Core 型別命名、檔案切分、測試命名。
- `CADisplayLink` 或計時器的選擇（需符合 §8 節奏與出口規則）。
- 量測資料的 CSV 欄位（不得含輸入內容或座標）。
- Mac 螢幕聯集夾限的實作方式。

## 17. 尚未決定（不在本設計）

- **觸控板頁 UI**（進入鍵位置、頁面外觀、是否顯示左右鍵區）：TP4 開始前另提 2–3 個方向，由使用者選定。
- **捲動慣性**：TP5 後依實測決定是否做第二階段。
- **LAN 後備**：只在決策關卡判定需要時另開研究。
