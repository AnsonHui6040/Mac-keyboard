# TP1 BLE 性能決策關卡（草稿）

- 狀態：**M2、M3、M5、M6 已實機量測（2026-11-01 02:28–03:04，主代理以 `MeasurementUITests` 執行）；M1、M4 待使用者量測**。未實測欄位維持 TBD。
- 器材：iPhone 17 Pro（iOS 27.0.1）、Mac Receiver TP1 Debug build；連線延遲偏好**未設定**（`.low`／`.medium` 對照屬 M1，待量）
- 原始統計：`docs/superpowers/verification/evidence/TP1-device-summary.txt`
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
| M2 | `updateValue` 連送至 `false` 前接受的封包數 | 41 bytes 與 182 bytes 各 100 輪：**每輪都只接受 1 個**（min = max = 1） |
| M2 | 回 `false` 到下一次可送的時間 | 41 bytes：P50 0.7、P95 20.9、最大 26.5 ms；182 bytes：P50 0.9、P95 25.1、最大 32.3 ms |
| M3 | RTT（10,001 個回覆樣本） | **P50 53.2、P95 83.2、P99 119.4 ms**，最大 286.6 ms，jitter（P95 − P50）30.0 ms |
| M3 | 其他 | 送出 37,799，Mac 因回覆在途而略過 73.5%；`refused` 42；Mac 處理時間 P50 0.1 ms；到達間隔標準差 14.5 ms |
| M4 | E2E（T6 − T0）等 | TBD（使用者，240 fps 錄影） |
| M5 | 無長文字（baseline，154 樣本） | RTT P50 53.4、P95 81.5、P99 126.9 ms |
| M5 | 長文字傳送中（load，1,781 樣本，201 則） | RTT P50 55.5、**P95 421.1、P99 559.4 ms**，最大 855.4 ms |
| M5 | 恢復段（recovery） | **0 個樣本**（量測工具缺陷，見 §4） |
| M5 | 出口阻塞 | 4,031 次，P50 0.7、P95 19.1、最大 194.7 ms；`refused` 1,451、`superseded` 462 |
| M6 normal（10 分鐘） | iPhone 交出心跳間隔 | P50 100.0、P99 124.3、最大 135.4 ms；未被阻塞 |
| M6 normal | **Mac 收到心跳間隔** | 最大 540.6 ms；> 350 ms（**會誤放開**）**4 次** / 5,999 |
| M6 longText（10 分鐘） | iPhone 交出心跳間隔 | P50 100.0、P99 125.8、最大 143.1 ms；阻塞 9,690 次、最長 24.2 ms |
| M6 longText | **Mac 收到心跳間隔** | 最大 858.0 ms；> 350 ms **532 次** / 5,999；> 200 ms 613 次 |
| M6 load／covered／interference | — | TBD（需使用者製造條件） |

當機前那次（未完成）的 M6 也留在 Mac CSV：normal 系列 4 次 > 350 ms（最大 400 ms），長文字系列在 1,537 個時被截斷、133 次 > 350 ms。兩次結果一致。

### 2.1 讀法（主代理分析，非結論）

1. **iPhone 送出準時，延遲在交出之後**：M6 的 iPhone 交出間隔最大只有 143 ms，但 Mac 收到的間隔最大 540–858 ms。`updateValue` 接受之後到 Mac 收到之間還有排隊或重送，這正是設計擔心的「已接受但未送出」。
2. **單程延遲粗估**：M3 RTT P95 83 ms，對半約 42 ms，但回程走 write with response（比 notify 慢），單程不一定是一半。加上觸控面板與 Mac 畫面延遲後，E2E P95 < 60 ms 有難度，要以 M4 確認。
3. **長文字會嚴重拖慢指標封包**：M5 load 的 P95 由 82 ms 升到 421 ms；M6 長文字情境 532 次會誤放開。4:1 交錯在 iPhone 端有效（交出間隔正常），但瓶頸在 iPhone 交出之後。
4. **系統佇列深度實際為 1**：M2 每輪只接受 1 個，排空約一個 connection interval（P95 21–25 ms，推測 interval 約 15–30 ms，待 M1 確認）。

## 3. 決策

| 條件 | 結果 |
|---|---|
| E2E P95 < 60 ms | TBD（待 M4） |
| M5 沒有積壓 | **未通過**：長文字期間 RTT P95 421 ms |
| M6 沒有誤放開 | **未通過**：一般 4／5,999、長文字 532／5,999 次會觸發 350 ms 看門狗 |
| 建議 | 依 spec §13.4 先分解瓶頸，不立即放棄 BLE：① 量 M1，並以 `.low` 重跑 M3、M5、M6；② 由使用者做 M4；③ 視結果評估：觸控板期間暫停或限速長文字、看門狗放寬（spec §14 範圍 250–500 ms）、回覆改走 notify 量測單程。是否進入 TP2 由使用者決定 |

## 4. 風險與尚未驗證

1. 量測頁流程（長按狀態列、量測按鈕、`MeasurementUITests`）已在實機跑通 M2、M3、M5、M6，全部 PASS；M4 觸控面與斷線時自動關閉尚未實機確認。
2. 4:1 交錯與 `sendChannelPacket` 只經程式審查與單元測試；首次 M5／M6 要檢查 `refused`、`superseded`、`blocked_count` 是否合理。M2、M4 的連送刻意繞過交錯（不同 magic，不會打亂 0x02 frame）。
3. M4 假設 `UITouch.timestamp` 與 `DispatchTime` 同一時基（reviewer 確認兩者都來自 `mach_absolute_time`）；若「節奏等待」出現負值，需重新檢查。
4. Mac T5 − T4 沒有獨立量測，以 M3 的 Mac 處理時間（`holdMicros`）估計。
5. M4 進行中斷線時觸控面應自動關閉：只經編譯與審查，實機待確認。
6. 已安裝到 `/Applications` 的 Mac Receiver 目前是 TP1 Debug build；量測結束後需重裝 main 版本。若系統要求，需重新允許「輔助使用」與「藍牙」。
7. M5 的長文字節奏（前 10 秒不送、之後每秒一則、最後不送）是實作者的設計，規格只寫「同時送 3,000 字」，請使用者確認。
8. **M5 恢復段 0 個樣本**：推測是長文字送到收滿 80% 樣本才停，其餘樣本在長文字仍排隊期間就收滿，恢復段沒有量到（未查證）。需修正工具（例如恢復段固定 10 秒）後重跑。
9. **M3 只回覆 26.5% 的封包**：回覆走 write with response，一次只能一個在途。RTT 樣本只來自 Mac 當下沒有回覆在途的封包，可能偏樂觀。
10. 本次量測連線延遲偏好**未設定**；`.low` 的效果未量。
