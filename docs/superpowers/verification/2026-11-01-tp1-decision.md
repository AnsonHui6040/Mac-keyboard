# TP1 BLE 性能決策關卡（草稿）

- 狀態：**第一輪（未設定連線延遲偏好）M2、M3、M5、M6 已實測，只作參考**。2026-11-01 使用者修訂驗收假設（spec §13.2、§13.4）：主要驗收改以 `.low`、沒有長文字背景負載的觸控板情境為準，長文字併發改為健壯性測試。主要量測尚未開始，決策待定。
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

## 2. 實機量測（第一輪：未設定連線延遲偏好，參考用）

| 編號 | 指標 | 結果 |
|---|---|---|
| M1 | connection interval 分佈（預設、`.low`、`.medium`） | TBD（使用者，PacketLogger） |
| M2 | `updateValue` 連送至 `false` 前接受的封包數 | 41 bytes 與 182 bytes 各 100 輪：**每輪都只接受 1 個**（min = max = 1） |
| M2 | 回 `false` 到下一次可送的時間 | 41 bytes：P50 0.7、P95 20.9、最大 26.5 ms；182 bytes：P50 0.9、P95 25.1、最大 32.3 ms |
| M3 | RTT（10,001 個回覆樣本） | **P50 53.2、P95 83.2、P99 119.4 ms**，最大 286.6 ms，jitter（P95 − P50）30.0 ms |
| M3 | 其他 | 送出 37,799，Mac 因回覆在途而略過 73.5%；`refused` 42；Mac 處理時間 P50 0.1 ms；到達間隔標準差 14.5 ms |
| M4 | E2E（T6 − T0）等 | TBD（使用者，240 fps 錄影） |
| M5（健壯性） | 無長文字（baseline，154 樣本） | RTT P50 53.4、P95 81.5、P99 126.9 ms |
| M5（健壯性） | 長文字傳送中（load，1,781 樣本，201 則） | RTT P50 55.5、**P95 421.1、P99 559.4 ms**，最大 855.4 ms |
| M5 | 恢復段（recovery） | **0 個樣本**（量測工具缺陷，見 §4） |
| M5 | 出口阻塞 | 4,031 次，P50 0.7、P95 19.1、最大 194.7 ms；`refused` 1,451、`superseded` 462 |
| M6 一般（10 分鐘，第一輪） | iPhone 交出心跳間隔 | P50 100.0、P99 124.3、最大 135.4 ms；未被阻塞 |
| M6 一般 | **Mac 收到心跳間隔** | 最大 540.6 ms；> 350 ms（**模擬誤釋放**）**4 次** / 5,999 |
| M6-L 長文字（10 分鐘，健壯性） | iPhone 交出心跳間隔 | P50 100.0、P99 125.8、最大 143.1 ms；阻塞 9,690 次、最長 24.2 ms |
| M6-L 長文字 | **Mac 收到心跳間隔** | 最大 858.0 ms；> 350 ms **532 次** / 5,999；> 200 ms 613 次 |
| M6 load／covered／interference | — | TBD（需使用者製造條件） |

當機前那次（未完成）的 M6 也留在 Mac CSV：normal 系列 4 次 > 350 ms（最大 400 ms），長文字系列在 1,537 個時被截斷、133 次 > 350 ms。兩次結果一致。

### 2.1 第一輪的讀法（參考，非結論）

1. **iPhone 交出準時，間隔變化發生在交出之後**：M6 一般情境的 iPhone 交出間隔最大 135 ms，Mac 收到的間隔卻散佈在 25–200 ms（> 200 ms 共 139 次、> 350 ms 4 次），長間隔之後常緊跟短間隔，代表封包在 iPhone 交出後被延後再成批送達。
2. **正常情境的異常集中在一段時間**：一般情境 > 200 ms 的間隔大多集中在第 128–177 秒，其餘時間零星出現，推測與當時的空中環境或系統排程有關（未查證）。這是「模擬誤釋放」的紀錄；TP1 的看門狗只記錄、不注入，所以**沒有發生實際的放開**。是否會在正式拖曳中誤放開，要以 `.low` 的 M6（30 分鐘）與 M8 判定。
3. **M3 的 RTT 不能直接代表游標延遲**：RTT 包含 Mac 回覆的 write with response 往返，而且只有 26.5% 的封包有回覆。單程延遲改以 M3c 估計，最終以 M4 錄影判定。
4. **長文字併發（M5、M6-L）明顯拖慢指標封包**：依修訂後的假設，這只作健壯性紀錄；產品設計另加「觸控板模式 0x03 優先」（spec §8.2 規則 4），並以 M7 驗證模式切換時尚未送完的文字不影響觸控板。
5. **系統佇列深度實際為 1**：M2 每輪只接受 1 個，排空 P95 21–25 ms，推測接近一個 connection interval（待 M1 確認）。

## 3. 決策（依修訂後的關卡）

主要條件（`.low`、無長文字）：

| 條件 | 結果 |
|---|---|
| M4 E2E P95 < 60 ms | TBD |
| M6 30 分鐘：模擬誤釋放 0 次 | TBD（第一輪未設定偏好時一般情境模擬誤釋放 4 次，僅參考） |
| M8 工作負載 10 分鐘：模擬誤釋放 0 次 | TBD |
| M7 模式切換：切換後第一個封包估計單程 ≤ 同次 baseline P99 × 2、長文字完整、文字持續前進 | TBD |
| M3a／M3b／M3c | 只記錄（TBD） |

健壯性（只記錄，不作 PASS／FAIL）：

| 項目 | 第一輪（未設定偏好） | `.low` |
|---|---|---|
| M5 長文字併發 | load 段 RTT P95 421.1 ms；恢復段 0 樣本（工具缺陷） | TBD |
| M6-L 長文字中的心跳 | 模擬誤釋放 532／5,999 | TBD |
| M6-X 負載、遮蔽、干擾 | 未量 | TBD |

**用語**：M6、M8 的看門狗結果只代表模擬誤釋放（TP1 沒有正式拖曳協定，不是真實拖曳測試）；M8 的點擊 RTT 是量測封包代理，不代表 TP3 正式 Click ACK；M3c、M7 的單程延遲都是估計值。每項結果註明要求的連線偏好與是否經 PacketLogger 確認生效。

**目前決定**：尚未達到決策條件。下一步依計畫 TP1 Step 10b 補強工具（M3c 單程、`.low` 切換、M7、M8、M5 恢復段、Mac CSV 時間欄），再以 `.low` 重量主要項目；M1、M4 由使用者量。PR #51 不合併、不開始 TP2。

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
10. 第一輪連線延遲偏好**未設定**；`.low` 的效果未量。
11. M3c 的單程延遲靠時鐘差估計，誤差最多為最小 RTT 的一半；只作分解參考，關卡仍以 M4 錄影為準。
12. M7、M8 使用量測封包模擬觸控板流量，出口規則照 spec §8.2 規則 4 實作在量測工具內；正式協定（TP2）完成後要在 TP5 重測。
