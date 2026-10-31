# E2E-TP1-MEASURE：觸控板決策關卡的 BLE 量測（M1–M8）

執行者：M2、M3、M5、M6 由主代理以 XCUITest 在實機跑；M1、M4 由使用者親手跑。全部結果欄在實測完成前維持 TBD，不得填入估計值。規格見 `docs/superpowers/specs/2026-11-01-trackpad-design.md` §13，計畫見 `docs/superpowers/plans/2026-11-01-trackpad-implementation.md` Task TP1。

量測封包與回覆全部是 AEAD 加密的 `0x7E` 計數器封包（與正式觸控板封包同大小：41 bytes，M2 另有 182 bytes），只存在於 Debug build。Release 的 Mac 與 iPhone 不含量測程式，收到 `0x7E` 一律略過。

## 2026-11-01 修訂：主要驗收與健壯性

依使用者修訂（spec §13.2、§13.4）：鍵盤模式與觸控板模式分開，觸控板期間不會持續輸入大量文字。

| 類別 | 項目 | 條件 | 是否為 PASS／FAIL 依據 |
|---|---|---|---|
| 主要 | M1、M2、M3a、M3b、M3c、M4、M6（30 分鐘）、M7、M8 | **`.low`**、沒有長文字背景負載 | M4、M6、M7、M8 是關卡；M3 只記錄 |
| 健壯性 | M5、M6-L（長文字中的心跳）、M6-X（負載、遮蔽、干擾） | 依各項 | 否，只記錄；不得當機或卡住，長文字結束後要回到前段水準 |

- **M3 拆成三項**：M3a 往返延遲（RTT，含 Mac 回覆的 write with response 往返）、M3b 回覆覆蓋率（只說明樣本代表性）、M3c 單程延遲（以 Mac 回覆中的 Mac 單調時間估計時鐘差）。不得以 RTT 直接判定觸控板性能。
- **M7 模式切換**：鍵盤模式送出 3,000 字長文字後立即進入觸控板量測，量第一個 cursor 封包的單程延遲與長文字是否完整送達；觸控板模式 0x03 優先（spec §8.2 規則 4）。
- **M8 觸控板工作負載**：連續移動、點擊、捲動、拖曳心跳同時進行 10 分鐘。
- 每次量測必須註明連線延遲偏好；以下各節 2026-11-01 02:28–03:04 的第一輪結果是**未設定偏好**，只作參考，不作關卡依據。
- M3c、M7、M8、`.low` 切換的工具支援待補（見計畫 TP1 Step 10b），各節操作細節在工具更新後補上。

### 第一輪結果（未設定偏好，參考用）

| 項目 | 結果 |
|---|---|
| M2 | 每輪只接受 1 個封包；排空 P95 20.9（41 bytes）／25.1 ms（182 bytes） |
| M3a | RTT P50 53.2／P95 83.2／P99 119.4 ms（10,001 樣本） |
| M3b | 回覆覆蓋率 26.5%（略過 73.5%） |
| M5（健壯性） | 長文字期間 RTT P95 421.1 ms；恢復段 0 樣本（工具缺陷） |
| M6 一般 | Mac 收到間隔 > 350 ms：4／5,999（最大 540.6 ms）；iPhone 交出最大 135.4 ms |
| M6-L（健壯性） | > 350 ms：532／5,999（最大 858.0 ms） |

### 待量（主要，`.low`、無長文字）

| 項目 | 結果 |
|---|---|
| M1 connection interval（`.low`／預設／`.medium`） | TBD |
| M2（`.low`） | TBD |
| M3a／M3b／M3c（`.low`） | TBD |
| M4 E2E P50／P95／P99 | TBD |
| M6 30 分鐘：模擬誤釋放次數 | TBD |
| M7 模式切換 20 次：baseline 與切換後第一個封包的估計單程延遲、長文字完整、文字未被餓死 | TBD |
| M8 工作負載 10 分鐘：cursor 估計單程 P50／P95／P99、點擊代理 RTT P95、模擬誤釋放次數 | TBD |

## 前置

| # | 項目 | 做法 |
|---|---|---|
| P1 | Mac | 執行 Debug 版 MacReceiver（不用 `/Applications` 內已安裝的版本，也不要覆蓋它）。面板頂端 build 時間與主代理告知的一致；已授權輔助使用（M4 要移動游標）；已與這支 iPhone 配對 |
| P2 | Mac 啟動參數 | 以 `-rkMeasureMode YES` 啟動：量測模式開啟並開始接收。範例：`open -n <MacReceiver.app 路徑> --args -rkMeasureMode YES`。也可在面板「除錯」區切換「量測模式」；模式只在記憶體，App 重開即關（有啟動參數時除外） |
| P3 | iPhone | 安裝 Debug 版，鍵盤已開啟「允許完整取用」，已配對；設定 › 顯示與亮度 › 自動鎖定改為「永不」（M6 每次數分鐘不碰螢幕） |
| P4 | 連線 | 鍵盤切到遠端模式，狀態列顯示已連線。Mac 的量測模式開啟後，鍵盤的 status 帶 `measure: true` |
| P5 | 量測頁 | 在鍵盤（遠端模式、英文頁）長按狀態列 2 秒開啟檢查面板。Mac 量測模式開啟且已認證時，面板顯示量測頁（結果文字加 M2、M3、M3 小、M5、M6、M4 觸控、延遲、停止）；否則仍是聽寫檢查清單。再長按一次會關閉面板 |
| P6 | 負載 | M5 與 M6 的長文字會被 Mac 當成輸入：先在 Mac 開 TextEdit 純文字文件並讓游標停在文件內，否則 Mac 回 `noFocus`（藍牙上的負載相同，但不會真的打字） |

結果字串只有計數、毫秒與項目名稱，沒有輸入文字、游標座標或 `dx`。Mac 的 CSV 寫到 `~/Library/Logs/RemoteKeyboard/measure-<日期>.csv`，iPhone 的 CSV 寫到 Extension 暫存目錄。

### CSV 欄位

| 檔案 | 欄位 |
|---|---|
| Mac `measure-<日期>.csv` | `seq,kind,bytes,counterGap,interArrivalMicros,holdMicros` |
| iPhone `measure-<項目>-<時間>.csv` | `seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,rttMicros,handoffWaitMicros` |

- `counterGap`：與前一個收到的封包之間沒有到達的封包數，每次量測的第一個封包為 0。
- `interArrivalMicros`：與前一個封包的到達間隔（iPhone 的 heartbeat 與 cursor 列是交出間隔）。
- `holdMicros`：Mac 收到 `rtt` 探測到寫出回覆的時間；-1 表示沒有回覆（前一個回覆尚未完成，或寫入被拒）；其他種類為 0。
- `rttMicros`、`handoffWaitMicros`：只在 iPhone 檔。後者是「交出時間 − 最早樣本時間」。
- 兩邊都不寫輸入文字、游標座標與 `dx`。

### 取得 Mac 端數字

Mac 面板量測模式下方一行顯示「收、回、略過、拒收、誤放開」。量測模式關閉或連線結束時，Mac 把這些計數寫入 log（只有數字）：

```bash
log show --last 30m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver" AND category == "measure"' --style compact
```

## M1：BLE connection interval

目的：量預設、`.low`、`.medium` 三種延遲偏好下實際的 connection interval 分佈。執行者：使用者。

安裝 PacketLogger：
1. 到 developer.apple.com/download/all，下載 Additional Tools for Xcode（與目前 Xcode 同版本），打開 dmg，把 `Hardware/PacketLogger.app` 複製到 `/Applications` 之外的位置（例如 `~/Applications`）。
2. 第一次開啟時按系統提示允許。若看不到任何 HCI 事件，依 Apple 的 Bluetooth Logging 說明安裝記錄設定檔後再試（TBD：是否需要，待實機確認）。

擷取 LE Connection Update：
1. 開 PacketLogger，File › New PacketLogger Capture（Bluetooth HCI 內建控制器）。
2. 在篩選欄輸入 `LE Connection`，只留 `LE Connection Complete` 與 `LE Connection Update Complete`。
3. 先開始擷取，再讓 iPhone 與 Mac 連線（重開鍵盤即可），這樣會抓到初始連線參數。
4. 每個事件的 `Interval` 欄位單位是 1.25 ms；記錄 interval、latency、supervision timeout。
5. 同時間 iPhone 跑 M3（見下，樣本數 1,500，使用 60 Hz 穩定送出），Mac 的 CSV 記錄封包到達間隔；每次擷取至少 60 秒。

| 延遲偏好 | 設定方式 | 次數 | 每次 | interval P50 | interval P95 | 其他值比例 | 結果 |
|---|---|---|---|---|---|---|---|
| 預設 | 面板「延遲」顯示「延遲 預設」（不呼叫） | 10 | 60 秒 | TBD | TBD | TBD | TBD |
| `.low` | 按「延遲」到「延遲 低」 | 10 | 60 秒 | TBD | TBD | TBD | TBD |
| `.medium` | 按「延遲」到「延遲 中」 | 10 | 60 秒 | TBD | TBD | TBD | TBD |

「延遲」鈕依序為 預設 → 低 → 中 → 預設。切回「預設」不會呼叫（CoreBluetooth 沒有取消的方式），要重新連線才回到系統預設；每組次數之間重開鍵盤。

## M2：`updateValue` 背壓

方法：在 `peripheralManagerIsReady` 回呼內連續送 41 bytes 與 182 bytes 的加密量測封包，直到 `updateValue` 回 `false`；各 100 輪。被拒的密文丟棄，下一次重新加密（計數器不回收）。記錄每輪被接受的封包數，以及從 `false` 到下一次 ready 的時間。每輪上限 2,000 個封包（防止沒有背壓時不停止）。

M2 的連發不經 4:1 交錯：它直接呼叫 `updateValue`，不排在 `0x02` frame 的佇列後面，所以量到的是純封包的背壓；M4 的 cursor 封包同樣直接交出。這樣不會打亂 `0x02` 長訊息：量測封包是首 byte `0x7E` 的單一 notification，Mac 依首 byte 分流，不進 `FrameReassembler`，不會插入、重排或截斷任何 `0x02` frame 序列（`testNon02FrameDoesNotTouchReassembler`）。只有 M3、M5、M6 的探測依 4:1 規則交出。

操作：量測頁按「M2」。輸出（每種大小一行）：`M2 packet=41 rounds=100 accepted_p50=… accepted_min=… accepted_max=… drain_p50_ms=… drain_p95_ms=… drain_max_ms=…`。

| 封包 | 每輪接受數 P50／最小／最大 | 排空時間 P50／P95／最大（ms） | 結果 |
|---|---|---|---|
| 41 bytes | TBD | TBD | TBD |
| 182 bytes | TBD | TBD | TBD |

## M3：應用層 RTT

方法：41-byte `rtt` 封包 60 Hz；Mac 只在沒有回覆寫入在途時回覆（其餘計為略過），回覆經 control write；iPhone 以 `measureM2P` 驗證回覆後，用「封包交出時間 → 收到回覆」算 RTT。跑到收滿樣本數（預設 10,000 個回覆）；若送出數超過樣本數的 4 倍仍未收滿就中止並回報已有的數字。

操作：量測頁按「M3」（預設 10,000），或「M3 小」（200 個，確認鏈路用）。

輸出：
- `M3 count=… p50_ms=… p95_ms=… p99_ms=… jitter_ms=… max_ms=…`
- `M3 sent=… skipped=… skipped_pct=… refused=… superseded=… arrival_sd_ms=… hold_p50_ms=… wait_p50_ms=… wait_p95_ms=…`

`jitter_ms` 是 P95 − P50；`refused` 是 `updateValue` 回 `false` 的次數；`superseded` 是還沒交出就被下一個取代的探測數；`arrival_sd_ms` 是回覆到達間隔的標準差。

| 指標 | 值 | 結果 |
|---|---|---|
| P50／P95／P99（ms） | TBD | TBD |
| jitter（ms） | TBD | TBD |
| 到達間隔標準差（ms） | TBD | TBD |
| 略過比例 | TBD | TBD |

## M5：積壓（健壯性，不作關卡）

方法：M3 的 RTT 探測進行中，中段每秒送一則 3,000 字元長文字（與既有 `sendDebugLongText()` 相同內容）。三個階段：前 10 秒不送長文字（baseline）、其後送到收滿樣本數的 80%（load）、最後不送（recovery）。比較三段 RTT；記錄 iPhone 出口被背壓阻塞的時間與次數。

操作：量測頁按「M5」（預設 3,000 個回覆）。長文字送出需要 Mac 面板的接收中且鍵盤已認證。

輸出：每階段一行 `M5 phase=… count=… rtt_p50=… rtt_p95=… rtt_p99=… rtt_max=…`（load 另有 `texts=`），加一行 `M5 trend_p50_ms=… blocked_count=… blocked_p50_ms=… blocked_p95_ms=… blocked_max_ms=… sent=… skipped=… refused=… superseded=…`。`trend_p50_ms` 是 load 段最後四分之一的 P50 減最前四分之一的 P50，持續上升代表積壓。

| 階段 | count | P50／P95／P99／最大（ms） | 結果 |
|---|---|---|---|
| baseline | TBD | TBD | TBD |
| load | TBD | TBD | TBD |
| recovery | TBD | TBD | TBD |

| 項目 | 值 | 結果 |
|---|---|---|
| trend_p50_ms | TBD | TBD |
| 阻塞次數與時間分佈 | TBD | TBD |

## M6：心跳與看門狗

方法：iPhone 每 100 ms 送一個 `heartbeat` 探測（一個系列從 `seq` 1 開始）。Mac 以 350 ms 看門狗只記錄「會放開」的事件，不送任何滑鼠事件：一個系列內相鄰兩個 heartbeat 的間隔超過 350 ms 就計一次。長文字依 4:1 交錯交出（每 4 個 `0x02` frame 讓出一個探測位置）。

情境（各 10 分鐘）：

| 情境 | 名稱（`RKMEAS_M6_SCENARIO`） | 條件 | 誰造成 |
|---|---|---|---|
| 一般 | `normal` | 無 | — |
| 長文字 | `longText` | 同時每秒送 3,000 字元長文字 | 程式自動 |
| 系統負載 | `load` | Mac 與 iPhone 各跑壓力程式 | 執行者在量測期間造成 |
| 鍵盤遮蔽 | `covered` | 鍵盤暫時被遮蔽（例如拉出控制中心） | 執行者在量測期間造成 |
| 藍牙干擾 | `interference` | 附近大量藍牙／Wi-Fi 傳輸 | 執行者在量測期間造成 |

名稱只決定結果行上的標記；`longText` 以外的情境不由程式造成條件。鍵盤整個消失會結束連線，那次量測以「中止」收場並保留已有的數字。

操作：量測頁按「M6」；秒數與情境用環境變數（見下）。

輸出：iPhone：`M6 scenario=… seconds=… sent=… superseded=… refused=… texts=…` 與 `M6 handoff_gap_p50_ms=… handoff_gap_p99_ms=… handoff_gap_max_ms=… blocked_count=… blocked_max_ms=…`。Mac：面板與 log 的「誤放開」次數，以及 `measure-<日期>.csv` 內 `heartbeat` 列的 `interArrivalMicros`（最大值與 P99）。

| 情境 | 誤放開次數（Mac） | 心跳到達間隔最大值／P99（ms，Mac） | 交出間隔最大值／P99（ms，iPhone） | 結果 |
|---|---|---|---|---|
| 一般 | TBD | TBD | TBD | TBD |
| 長文字 | TBD | TBD | TBD | TBD |
| 系統負載 | TBD | TBD | TBD | TBD |
| 鍵盤遮蔽 | TBD | TBD | TBD | TBD |
| 藍牙干擾 | TBD | TBD | TBD | TBD |

## 自動化（主代理）

M2、M3、M5、M6 的 XCUITest 在 `iOS/RemoteKeyboardUITests/MeasurementUITests.swift`。每個測試切到遠端模式、長按狀態列開量測頁、等按鈕可用、按下、等結果，並以 `RKMEAS <項目> key=value ...` 印出統計數字；同樣內容附成 `measure-<項目>.txt`。

先在 Mac 啟動 Debug 版 MacReceiver（`-rkMeasureMode YES`，見 P2），再執行：

```bash
cd <worktree>
# 先確認鏈路（200 個樣本）
xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
  -destination 'id=00008150-000C65DA26C0401C' -derivedDataPath /private/tmp/claude-501/rk-tp1-dd-dev -allowProvisioningUpdates \
  -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM3Smoke

# M2、M3（預設 10,000）、M5（預設 3,000）、M6（預設 normal、600 秒）
xcodebuild test ... -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM2BackPressure
xcodebuild test ... -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM3RoundTrip
xcodebuild test ... -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM5Backlog
TEST_RUNNER_RKMEAS_M6_SCENARIO=longText TEST_RUNNER_RKMEAS_M6_SECONDS=600 \
  xcodebuild test ... -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM6Heartbeat
```

| 環境變數 | 預設 | 作用 |
|---|---|---|
| `TEST_RUNNER_RKMEAS_M3_SAMPLES` | 10000 | M3 的回覆樣本數 |
| `TEST_RUNNER_RKMEAS_M5_SAMPLES` | 3000 | M5 的回覆樣本數 |
| `TEST_RUNNER_RKMEAS_M6_SCENARIO` | normal | `normal`、`longText`、`load`、`covered`、`interference` |
| `TEST_RUNNER_RKMEAS_M6_SECONDS` | 600 | M6 長度（秒） |

測試把設定經主 App 的啟動環境寫入 App Group，鍵盤在按下按鈕時讀取。若測試以 skip 結束（找不到鍵盤、量測頁沒出現），代表 Mac 量測模式沒開、沒有配對、或連線尚未認證。

## M4：觸控到游標可見

執行者：使用者。目的：量 E2E（T6 − T0）P95 是否低於 60 ms，並把延遲分解。

### 時間點

| 代號 | 事件 | 來源 | 時鐘 |
|---|---|---|---|
| T0 | 手指開始移動（實體）：手指與起點相比可見位移 ≥ 1 像素的第一幀 | 240 fps 錄影 | 影片 |
| T1 | UIKit 收到觸控（`UITouch.timestamp`） | iPhone 軟體 | iPhone |
| T2 | iPhone 畫面提示（測試面整塊變白）可見 | 240 fps 錄影 | 影片 |
| T3 | 量測封包交給 `updateValue` 並被接受 | iPhone 軟體 | iPhone |
| T4 | Mac 收到 notification | Mac 軟體 | Mac |
| T5 | Mac 送出 `CGEvent`（並同時讓 DEBUG 小視窗變白） | Mac 軟體 | Mac |
| T5′ | Mac 小視窗變白可見 | 240 fps 錄影 | 影片 |
| T6 | Mac 游標開始移動可見 | 240 fps 錄影 | 影片 |

軟體時間點只在同一台裝置內相減，不跨裝置相減。

### 器材與設定

| 項目 | 做法 |
|---|---|
| 錄影 | 另一支手機以 240 fps 同框拍 iPhone 觸控面、手指與 Mac 螢幕。確認影片實際幀率（檢查影片 metadata，不要只信相機設定），記錄實際 fps |
| 螢幕更新率 | 記錄 iPhone 與 Mac 螢幕的更新率（60 或 120 Hz），寫入結果 |
| 游標 | 系統設定 › 輔助使用 › 顯示器 › 指標，把游標放大 |
| 背景 | Mac 螢幕用高對比單色背景（全白或全黑，與游標對比） |
| Mac 小視窗 | 量測模式開啟時，主螢幕左上角出現 120 × 120 pt 的黑色視窗，收到 cursor 封包時變白約 50 ms（連續封包時持續白）；錄影要拍到它 |
| iPhone 觸控面 | 量測頁按「M4 觸控」，整個鍵盤區換成黑色觸控面；每一筆劃第一次移動時整塊變白約 100 ms，並立即送出第一個 cursor 封包；之後每 16.7 ms 送一個。左上角 × 關閉 |
| 游標倍率 | Mac 把 cursor 封包的 `dx` 乘 4 當作位移（不套用加速曲線），讓開始移動清楚可見 |
| 交出方式 | cursor 封包直接交給 `updateValue`，不經 4:1 交錯（與 M2 相同，理由見 M2）；M4 期間沒有長文字 |
| 每筆 | 每一筆都從靜止開始橫向滑動，筆與筆之間手指完全離開並等游標停下 |
| 筆數 | ≥ 100 筆；E2E P95 落在 52–68 ms（60 ± 8.3）視為邊界，增加到 ≥ 200 筆再判定 |

### 誤差

| 來源 | 大小 |
|---|---|
| 每個影片時間點量化 | ±½ 幀（240 fps 為 ±2.08 ms） |
| 兩點相減 | 最大 ±1 幀（±4.17 ms） |
| T0 起點判讀 | ±1 幀；單次 E2E 誤差上限約 ±8.3 ms |
| T2 晚於 T1 | 至少一次 iPhone 畫面更新（120 Hz 約 8.3 ms，60 Hz 約 16.7 ms），所以 T6 − T2 會低估傳輸延遲，只作分解參考 |
| T6 受 Mac 更新率影響 | 60 Hz 時最多多 16.7 ms；報告須註明更新率 |

### 判讀與紀錄

1. 逐格判讀每一筆的 T0、T2、T5′、T6 所在的幀號（影片幀號，同一支影片內連續）。
2. 逐筆寫入 `docs/superpowers/verification/evidence/TP1-m4-frames.csv`，第一行為 `trial,t0,t2,t5p,t6`，每筆一列、只有幀號；`t2`、`t5p` 讀不到時留空，`t0` 與 `t6` 必填。
3. 執行統計：

```bash
swift scripts/tp1-m4-stats.swift docs/superpowers/verification/evidence/TP1-m4-frames.csv <實際 fps> [目標 ms，預設 60]
```

輸出 E2E（T6 − T0）、傳輸到畫面（T6 − T2）、Mac 畫面（T6 − T5′）的 n、P50、P95、P99、jitter，量化誤差，E2E P95 是否低於目標，以及是否落在邊界（|P95 − 目標| ≤ 2 幀）、邊界時筆數是否不足 200。

4. 軟體分解（iPhone 軟體 T3 − T1、Mac 軟體 T5 − T4、BLE 單程估計）：
   - iPhone：按「M4 觸控」的 × 關閉時，量測頁印出 `M4 first_wait_p50_ms=… first_wait_p95_ms=… paced_wait_p50_ms=… paced_wait_p95_ms=… paced_wait_p99_ms=…`。`first_wait` 是每筆第一個封包的「交出時間 − 觸控時間」，近似 T3 − T1；`paced_wait` 是持續移動時每個封包最多多出的一個節奏間隔等待（節奏等待）。
   - Mac：T5 − T4 在 TP1 沒有獨立量測；Mac 收到到寫出回覆的時間用 M3 的 `hold_p50_ms` 估計，注入時間以影片 T6 − T5′ 為準。
   - BLE 單程估計為 M3 RTT／2（兩端時鐘未同步，只能估計）。

### 結果

| 指標 | 值 | 結果 |
|---|---|---|
| 實際 fps、iPhone 更新率、Mac 更新率 | TBD | TBD |
| 筆數 | TBD | TBD |
| E2E P50／P95／P99／jitter（ms） | TBD | TBD |
| T6 − T2 P50／P95／P99（ms） | TBD | TBD |
| T6 − T5′ P50／P95／P99（ms） | TBD | TBD |
| 是否邊界、是否補到 200 筆 | TBD | TBD |
| 節奏等待 first／paced P50／P95（ms） | TBD | TBD |
| 決策關卡（E2E P95 < 60 ms 且 M5 無積壓） | TBD | TBD |

## 注意

- 量測相關的狀態旗標也只在 Debug：Mac 的 `ReceiverCoordinator.measureMode` 與 `FocusTransition.status(for:measure:)` 在 Release 不存在，Release 的 status 永遠不帶 `measure`（`ReceiverStatus.measure` 欄位為線上格式相容而保留）。
- 量測通道、量測金鑰、`MeasurementEcho`、`MeasurementRunner` 與 Mac 小視窗只在 Debug build；Release build 的 `nm` 檢查見驗收報告 TP1。
- 本文件所有結果欄在實機量測完成前保持 TBD。決策關卡報告（`docs/superpowers/verification/2026-11-xx-tp1-decision.md`）在 M1–M6 全部有真實數字後由主代理撰寫。
