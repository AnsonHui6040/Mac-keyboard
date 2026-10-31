# 觸控板外部研究審查（2026-11-01）

來源：兩份外部研究報告（使用者提供，未納入 repo）。
- 報告 A：《iPhone 當 Mac 觸控板：BLE 傳輸協定、Mac 游標演算法與參數研究》，引用以 Apple 文件與 RFC 8439 為主，數字多標「需實測」。
- 報告 B：《iPhone 作為 Mac 觸控板之低延遲 BLE 傳輸協定、游標動力學演算法與系統參數研究報告》，細節多，但部分數字與來源無法查證。

## 1. 已對照程式碼查證

| 主張 | 結果 | 依據 |
|---|---|---|
| 舊 Receiver 收到首 byte 不是 0x02 的 frame 只會略過，不會斷線，也不會丟掉進行中的長訊息 | 成立 | `FrameReassembler.accept`：版本不符回 `.rejected(.badHeader)`，不動 `partial`；`ReceiverBLECentral.receive` 只記 log |
| 若指標訊息走 FrameCodec（新 message id），會把進行中的多 frame 訊息丟掉 | 成立 | `FrameReassembler`：新 message id 的第一個 frame 會丟棄未完成訊息 |
| 現有 iPhone 傳送佇列是 FIFO、不丟棄 | 成立 | `NotifyQueue` |
| 現有 session key 每則訊息用隨機 nonce | 成立 | `SessionCrypto.seal` |

## 2. 兩份報告的分歧與裁定建議

| 項目 | 報告 A | 報告 B | 建議 |
|---|---|---|---|
| 封包分流 | 沿用 5-byte FrameCodec header，不可插入多 frame 訊息中間 | 首 byte `0x03`，不經 FrameCodec | **B**：已查證舊 Receiver 安全略過，且不會打斷長文字 |
| 加密金鑰 | 沿用 session key，nonce 用方向常數＋計數器 | 以 HKDF 另派生指標專用金鑰 | **B**：避免同一把金鑰混用隨機與計數器 nonce |
| 計數器 | UInt32，接近上限強制重新握手 | UInt64 | UInt64，免處理 rekey |
| 防重播 | 64 位元滑動視窗 | 同 | 採用 |
| 可靠事件去重 | 最近 64 個 actionId | 只記最後一個 1-byte 序號 | **A**：B 的做法在連續兩個重傳時會重複點擊 |
| 按鍵狀態 | 獨立 BUTTON_STATE（完整狀態） | 每個移動封包帶左鍵狀態位元 | 兩者合用：完整狀態可冪等，移動封包帶狀態可自我修復 |
| 加速曲線 | `g0 + (gmax−g0)·v²/(v²+v0²)`，1.25／550 pt/s／3.5 | 三次多項式，0.85 起、上限 8.5 | 第一版用 A（三個參數，易調）；B 的上限 8.5 偏大，列為實測對照組 |
| 平滑 | 第一版不做；必要時才加一格補間 | 1-Euro＋120 Hz 指數補間 | 第一版直接套用；補間與濾波做成可關的實驗開關，以實測決定 |
| 捲動慣性 | 第一版不做 | 做，含 scrollPhase／momentumPhase | 第一版送 scrollPhase；慣性列第二階段 |
| 拖曳 | 雙擊後按住 | 同 | 採用；斷線、看門狗必放開 |
| 心跳／看門狗 | 100 ms／350 ms | 150 ms／350 ms | 100 ms／350 ms |
| `setDesiredConnectionLatency(.low)` | 只在觸控板模式 | 訂閱後即呼叫 | 實測後決定；先只在觸控板模式 |
| 輕點門檻 | 220 ms／10 pt，優先用 UIKit recognizer | 180 ms／4.5 pt | 起始 200 ms／8 pt，實測調整 |
| focusEpoch | 不檢查 | 不檢查 | 採用；觸控板事件不切換輸入法 |
| Mac 開關 | menu bar「允許觸控板」 | 同 | 採用 |

## 3. 報告 B 中無法採信的內容

以下內容不作為設計依據：
- 「Apple 晶片每個 connection event 可送 4–6 個 PDU」「傳送佇列 8–16 筆」：Apple 未公開，需實測。
- 「macOS 曲線已被擬合為 `0.1v + 0.01v² + 0.005v³`」：來源為第三方 gist，非 Apple 資料。
- 競品延遲數字與部分 CVE 編號：未查證。
- 「補間首拍 0 ms、守恆 100%」：其虛擬碼中封包到達後要等下一個 120 Hz tick 才注入，且 1-Euro 濾波會改變總位移，與敘述不符。
- 「服務探索常耗時 416–900 ms」：416 ms 是本專案 T07 的重連 ready 時間，被誤用。

## 4. 仍需實測（決定 BLE 是否足夠）

1. 實際 connection interval（PacketLogger），預設與 `.low` 各一組。
2. `updateValue` 連續送出至回傳 `false` 的次數（38 bytes 與 182 bytes）。
3. 應用層往返時間 P50／P95（38-byte 測試封包＋ACK）。
4. 240 fps 錄影量度觸控到游標移動 P95，目標 < 60 ms。

若第 3、4 項 P95 明顯超過 60 ms，再評估 D8 LAN 後備（UDP，同一封包格式）。
