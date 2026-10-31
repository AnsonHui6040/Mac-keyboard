# iPhone 當 Mac 觸控板：現有連線方式與待定參數（交給外部研究用）

日期：2026-10-31｜專案：Mac-keyboard（main `e031532`）

## 0. 請你（研究者）做的事

1. 依第 1–4 節的現況，設計「觸控板」功能的**傳輸協定**與 **Mac 端游標演算法**。
2. 為第 5 節每個參數給出建議值、可接受範圍與理由（附來源）。
3. 回答第 6 節的問題；不確定的地方標「需實測」，並寫出實測方法。
4. 交付格式：參數表（參數｜建議值｜範圍｜理由｜來源）、訊息格式（逐 byte）、Mac 端虛擬碼、實測計畫。

不要改變的前提：iPhone 只能當 BLE Peripheral、Mac 當 Central（見 1.2）；事件必須加密；log 不得含輸入內容。

## 1. 現有架構

### 1.1 元件

| 端 | 元件 | 角色 |
|---|---|---|
| iPhone | 第三方鍵盤 Extension（UIKit，`UIInputViewController`） | `CBPeripheralManager`，只在鍵盤顯示期間存在 |
| iPhone | 主 App（SwiftUI） | 配對、設定；平常不連線 |
| Mac | Remote Keyboard Receiver（menu bar App，已有「輔助使用」權限） | `CBCentralManager`；以 `CGEvent` 注入鍵盤事件 |
| 共用 | Swift Package `RemoteKeyboardCore` | 協定、加密、狀態機（純邏輯，有單元測試） |

### 1.2 為何 iPhone 是 Peripheral（已實測，不可改）

- 同一 iCloud 帳號的 iPhone 與 Mac 已有系統 LE 連線，第三方 App 經 `retrieveConnectedPeripherals` 取不到對方。
- iPhone 主動連 Mac：link layer 即斷（reason 762）。Mac 主動連 iPhone：成功（514–561 ms）。
- iOS 不允許 App 發佈 HID service（0x1812，錯誤「The specified UUID is not allowed」），所以 iPhone **不能**扮成標準藍牙滑鼠／觸控板，所有游標動作都要經 Receiver 注入。

### 1.3 生命週期

- 鍵盤出現且已開「允許完整取用」→ 廣播 service；鍵盤收起 → 停止廣播並斷線。
- Mac 只在「接收時段」掃描：使用者點了可編輯輸入框或手動開始；30 分鐘無活動自動停止，收到事件或連上即延長。
- 觸控板若做在鍵盤內，會沿用這個生命週期；若做在主 App 內，主 App 需自己再發佈一份 service（目前沒有）。

## 2. GATT 與傳輸

| 項目 | 值 |
|---|---|
| Service UUID | `706AA642-68A3-41FA-889D-24E30709B0D0` |
| `event` characteristic | `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`，`notify`，iPhone → Mac |
| `control` characteristic | `320468E2-53B6-4B6A-88EC-AE2752415818`，`write`（with response），Mac → iPhone |
| 廣播內容 | 只有 `CBAdvertisementDataServiceUUIDsKey: [service]` |
| Mac 掃描 | `scanForPeripherals(withServices: [service])`，找到即 `connect` |
| 連線逾時 | 5 秒；握手連續失敗時重掃退避 0 → 0.5 → 1 → 2 秒 |
| 單一 notify 上限 | `CBCentral.maximumUpdateValueLength`，實測 **182 bytes**（含 frame header） |
| 傳送佇列 | `updateValue` 回 `false` 時暫存，等 `peripheralManagerIsReady(toUpdateSubscribers:)` 再依序送，不丟棄 |
| 連線參數 | 沒有呼叫 `setDesiredConnectionLatency`；connection interval 由系統決定，**未量度** |

### 2.1 Frame 格式（`FrameCodec`）

```
[0]    版本 0x02
[1-2]  message id（UInt16，big-endian）
[3]    frame index
[4]    frame count（1–255）
[5..]  訊息切片
```

單一訊息上限 16,384 bytes；Mac 端 `FrameReassembler` 重組，殘片在斷線或新訊息到來時丟棄。

### 2.2 訊息格式（目前全部是 JSON）

- iPhone → Mac（`PeripheralMessage`，一個平面 JSON 物件，含 `type` 與 `protocolVersion`=3）：
  `pairOffer`、`pairReveal`、`helloReply`、`sealed`（認證後所有事件都包在這裡）。
- 事件本體 `KeyboardEvent`：`protocolVersion`、`eventId`（UUID）、`sessionId`（UUID，每次鍵盤出現一個）、`seq`（UInt64，從 1 起）、`focusEpoch`（Mac 焦點世代）、`kind`。
- `kind` 目前只有：`text(String)`、`backspace`、`returnKey`、`ping`、`probe`。**沒有任何指標或滑鼠事件。**
- Mac → iPhone（`ControlMessage`）：`ack(eventId, result)`、`status(ready, appName, focusEpoch, trusted)`、`pairAccept`、`hello`、`auth`、`authFailed`、`bye`、`sealed`。

一個加密後的單鍵事件大約要 1–2 個 182-byte frame（JSON + base64 + AEAD 開銷，**未精確量度**）。觸控板若沿用 JSON 會太大，預期要另做精簡的二進位格式。

### 2.3 加密與認證

- 配對：ECDH P-256，加公鑰承諾，再比對 6 位數碼，兩端各自確認才儲存 pair key。
- 每次連線：雙向 challenge-response（Mac 16-byte nonce → iPhone nonce＋proof → Mac proof）。
- Session key：`HKDF<SHA256>(pairKey, info = 方向字串 ‖ macNonce ‖ phoneNonce)`，兩個方向各一把。
- 加密：ChaCha20-Poly1305，輸出 `nonce(12) ‖ ciphertext ‖ tag(16)`，每則訊息 nonce 隨機，**沒有計數器**。
- 重播防護靠 Mac 端 `EventDeduplicator`：記住最近 256 個 `eventId`，同一 session 內 `seq` 不大於已見最大值的一律拒收。

### 2.4 可靠性語意（打字用）

- 每個打字事件都要 Mac 回 `ack`，iPhone 記 pending；斷線時 pending 的事件**不重送**（不知道 Mac 有沒有打出來）。
- 不承諾 exactly-once。ACK 只代表 Receiver 已處理。
- Mac 注入前檢查焦點（Accessibility）與 `focusEpoch`，不符即拒收（fail closed）。

## 3. Mac 端注入現況

- 文字：`CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown:)` 加 `keyboardSetUnicodeString`，每段 20 UTF-16，`post(tap: .cghidEventTap)`。
- 退格、Return：virtual key 的 keyDown／keyUp。
- 注入前會把輸入法切到 ABC，注入後切回（觸控板不需要這一步）。
- 已有「輔助使用」權限，因此 `CGEvent` 的滑鼠移動、點擊、捲動都可以直接用，不用再要權限。

## 4. 已有實測數字

| 量度 | 數值 | 說明 |
|---|---|---|
| 鍵盤出現到連上 P95 | Notes 389 ms、Safari 224 ms | 100 次自動重開 |
| Mac 端 ready 時間 | 182–1,491 ms | 20 次重開 |
| notify 上限 | 182 bytes | iPhone 17 Pro，iOS 27.0.1 |
| 3,000 字長文字 | 35 個 frame，完整收到 | |
| **單鍵端到端延遲** | **未量度** | 觸控板最需要的數字 |
| **實際 connection interval** | **未量度** | |

## 5. 觸控板需要決定的參數

建議值欄位請你填；「初步假設」只是我們目前的猜測。

### 5.1 iPhone 取樣與傳送

| 參數 | 初步假設 | 要你回答 |
|---|---|---|
| 觸控取樣來源 | `touchesMoved`，用 `coalescedTouches` | 是否要用 `predictedTouches` |
| 傳送頻率上限 | 每個 connection interval 一則（約 15–30 ms） | 固定頻率還是跟 interval 走；`updateValue` 回 `false` 時的處理 |
| 累積方式 | 未送出的位移相加，只送總和 | 溢位與精度（Int8／Int16、單位：pt 還是 0.1 pt） |
| 舊資料 | 佇列滿時合併成一則，不排隊 | 合併規則 |
| 點擊、按住、放開 | 要可靠送達（需 ACK 或重送） | 與位移共用一條通道還是分開 |
| 是否呼叫 `setDesiredConnectionLatency(.low)` | 要 | 對耗電與鍵盤其他功能的影響 |

### 5.2 訊息格式

| 參數 | 初步假設 | 要你回答 |
|---|---|---|
| 編碼 | 二進位，不用 JSON | 逐 byte 格式 |
| 加密 | 沿用 session key；不使用隨機 nonce，改用遞增計數器當 nonce 以兼做防重播 | 計數器方案是否安全；12-byte nonce 如何組成 |
| 每則大小目標 | 一個 frame 內（≤182 bytes，最好 < 40 bytes） | 是否還需要 5-byte frame header |
| 版本 | 新增 `protocolVersion` 或新 message type | 與現有 v3 相容的做法 |

### 5.3 Mac 端游標

| 參數 | 初步假設 | 要你回答 |
|---|---|---|
| 注入 API | `CGEvent(mouseEventSource:mouseType:.mouseMoved…)`，拖曳用 `.leftMouseDragged` | 相對移動的寫法；多螢幕、Retina 座標換算 |
| 加速曲線 | 類似 macOS 觸控板，速度越快倍率越高 | 曲線公式與參數（基礎倍率、門檻、上限） |
| 平滑／插值 | 收到資料時直接套用 | 是否要在 Mac 端以 120 Hz 補間，避免 15–30 ms 一跳的頓挫；補間帶來多少延遲 |
| 點擊 | 單指輕點 = 左鍵；雙指輕點 = 右鍵 | 輕點判定的時間與距離門檻 |
| 雙擊 | `mouseEventClickState` = 2 | 間隔門檻是否跟系統設定 |
| 拖曳 | 雙擊後按住，或按住一段時間 | 選哪一種；斷線時一定要送 mouseUp |
| 捲動 | 雙指，`CGEvent(scrollWheelEvent2Source:units:.pixel…)` | 單位、倍率、慣性（減速常數）、`scrollPhase`／`momentumPhase` 要不要設 |
| 手勢 | 三指左右 → ⌃←/⌃→；三指上 → ⌃↑；捏合 → ⌘＋/⌘－ | 有沒有公開 API 能送真正的手勢；沒有的話這樣對應是否合理 |

### 5.4 安全與失敗處理

| 參數 | 初步假設 | 要你回答 |
|---|---|---|
| 權限 | 只准已配對、已認證的連線 | 是否要另外的開關或確認 |
| 斷線 | 立即放開所有按住的按鍵與拖曳 | 其他要清理的狀態 |
| 看門狗 | 多久沒收到資料就視為手指離開 | 建議毫秒數 |
| 焦點 | 游標不受 `focusEpoch` 限制 | 是否同意 |

## 6. 需要你研究的問題

1. iOS 作為 Peripheral 時，實際 connection interval 是多少？Mac 作為 Central 能否要求更短？`setDesiredConnectionLatency(.low)` 實際效果？
2. 每個 connection event 可以送幾個 notify？`updateValue` 的傳送佇列有多深？
3. 一般第三方「iPhone 當 Mac 觸控板」產品（例如 Remote Mouse、Mobile Mouse）用 BLE 還是 Wi-Fi？延遲多少？有沒有公開資料？
4. 若 BLE 延遲不夠好，LAN（同一 Wi-Fi，UDP 或 WebSocket）方案的延遲與穩定度如何？我們的規格已把 LAN 列為後備（D8）。
5. macOS 游標加速曲線的公開資料（IOHIDFamily 的 acceleration table 或其他逆向文件）。
6. 在 15–30 ms 一筆的輸入下，Mac 端用什麼平滑方法能兼顧順暢與延遲（例如 one-euro filter、線性外推）？建議參數。
7. 鍵盤 Extension 的觸控區約 390 × 260 pt；這個大小做觸控板，合適的基礎倍率是多少？
8. 用遞增計數器當 ChaCha20-Poly1305 nonce 時，在斷線重連（新 session key）情況下是否安全？

## 7. 我們目前的推薦方向（供參考，可推翻）

- 做在鍵盤 Extension 內：底列加一個鍵，切到觸控板頁，整塊鍵區當觸控面板。
- 新增一種「指標」訊息：二進位、加密、位移累積、不 ACK、可丟棄；點擊與放開另外可靠送達。
- Mac 端：相對移動加加速曲線，捲動加慣性，手勢改成快捷鍵。
- 完成後實測：iPhone 觸控到 Mac 游標移動的延遲（可用高速錄影），目標 P95 < 60 ms。
