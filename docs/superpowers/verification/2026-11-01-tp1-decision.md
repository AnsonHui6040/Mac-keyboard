# TP1 BLE 性能決策關卡（草稿）

- 狀態：**等待實機量測**。本文件所有性能數字欄位都是 TBD，未經實測不得填寫。
- 依據：`docs/superpowers/specs/2026-11-01-trackpad-design.md` §13；操作步驟：`e2e/E2E-TP1-MEASURE.md`
- 量測工具：branch `tp1-measurement`（DEBUG build）

## 1. 自動驗證（主代理 2026-11-01 重跑）

| 項目 | 結果 |
|---|---|
| Core `swift test` | 697 tests，0 failures（基線 646） |
| `MacReceiverTests` | 214 tests，0 failures（基線 187） |
| iOS 模擬器 build、真機 build-for-testing | 成功 |
| Mac Release、iOS Release build | 成功 |
| Release 符號檢查（`nm -a` 與 `strings -a`：`MeasurePayload`、`MeasureEchoPayload`、`measureP2M`、`measureM2P`、`MeasurementEcho`、`MeasurementRunner`、`MeasureCSV`、`MeasureFlashWindow`、`measureMode`、`rk-measure`） | MacReceiver、RemoteKeyboardApp、RemoteKeyboardExtension 皆 0；Debug `MacReceiver.debug.dylib` 正控制 603 筆 |
| 獨立 reviewer | 第一輪 2 項 Important（M4 觸控面在斷線後仍可送、Release 殘留量測參數）已修正；複審 APPROVE |
| `HitAreaUITests` | 模擬器 13/13（子代理）；真機 TBD |

這些只證明程式與加密通道正確，**不代表 BLE 性能**。

## 2. 實機量測

| 編號 | 指標 | 結果 |
|---|---|---|
| M1 | connection interval 分佈（預設、`.low`、`.medium`） | TBD（使用者，PacketLogger） |
| M2 | `updateValue` 連送至 `false` 的次數（41／182 bytes）、排空時間 | TBD |
| M3 | RTT P50／P95／P99、jitter、略過比例 | TBD |
| M4 | E2E（T6 − T0）P50／P95／P99；T6 − T2；T6 − T5′；節奏等待 | TBD（使用者，240 fps 錄影） |
| M5 | 有無長文字時 RTT 走勢、阻塞時間 | TBD |
| M6 | 五種情境的誤放開次數、心跳間隔最大值與 P99 | TBD |

## 3. 決策

| 條件 | 結果 |
|---|---|
| E2E P95 < 60 ms | TBD |
| M5 沒有積壓 | TBD |
| 是否落在邊界（52–68 ms，需增至 ≥ 200 筆） | TBD |
| 建議 | TBD（量測完成後填寫；由使用者決定是否進入 TP2） |

## 4. 風險與尚未驗證

1. 量測頁整個流程（長按狀態列、量測按鈕、`MeasurementUITests` 的元素查詢）只經編譯，模擬器上切不到遠端模式而 skip；第一次實機執行可能需要修正 UI 測試。
2. 4:1 交錯與 `sendChannelPacket` 只經程式審查與單元測試；首次 M5／M6 要檢查 `refused`、`superseded`、`blocked_count` 是否合理。M2、M4 的連送刻意繞過交錯（不同 magic，不會打亂 0x02 frame）。
3. M4 假設 `UITouch.timestamp` 與 `DispatchTime` 同一時基（reviewer 確認兩者都來自 `mach_absolute_time`）；若「節奏等待」出現負值，需重新檢查。
4. Mac T5 − T4 沒有獨立量測，以 M3 的 Mac 處理時間（`holdMicros`）估計。
5. M4 進行中斷線時觸控面應自動關閉：只經編譯與審查，實機待確認。
6. 已安裝到 `/Applications` 的 Mac Receiver 目前是 TP1 Debug build；量測結束後需重裝 main 版本。若系統要求，需重新允許「輔助使用」與「藍牙」。
7. M5 的長文字節奏（前 10 秒不送、之後每秒一則、最後不送）是實作者的設計，規格只寫「同時送 3,000 字」，請使用者確認。
