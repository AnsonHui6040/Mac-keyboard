# E2E-TP1-MEASURE：觸控板決策關卡的 BLE 量測（M1–M8）

執行者：M2、M3、M5、M6、M7、M8 由主代理以 XCUITest 在實機跑；M1、M4 由使用者親手跑。全部結果欄在實測完成前維持 TBD，不得填入估計值。規格見 `docs/superpowers/specs/2026-11-01-trackpad-design.md` §13，計畫見 `docs/superpowers/plans/2026-11-01-trackpad-implementation.md` Task TP1。

量測封包與回覆全部是 AEAD 加密的 `0x7E` 計數器封包（與正式觸控板封包同大小：41 bytes，M2 另有 182 bytes），只存在於 Debug build。Release 的 Mac 與 iPhone 不含量測程式，收到 `0x7E` 一律略過。

## 2026-11-01 修訂：主要驗收與健壯性

依使用者修訂（spec §13.2、§13.4）：鍵盤模式與觸控板模式分開，觸控板期間不會持續輸入大量文字。

| 類別 | 項目 | 條件 | 是否為 PASS／FAIL 依據 |
|---|---|---|---|
| 主要 | M1、M2、M3a、M3b、M3c、M4、M6（30 分鐘）、M7、M8 | **`.low`**、沒有長文字背景負載 | M4、M6、M7、M8 是關卡；M3 只記錄 |
| 健壯性 | M5、M6-L（長文字中的心跳）、M6-X（負載、遮蔽、干擾） | 依各項 | 否，只記錄；不得當機或卡住，長文字結束後要回到前段水準 |

- **M3 拆成三項**：M3a 往返延遲（RTT，含 Mac 回覆的 write with response 往返）、M3b 回覆覆蓋率（只說明樣本代表性）、M3c 估計單程延遲（以 Mac 回覆中的 Mac 單調時間估計時鐘差，假設去回程延遲相等）。不得以 RTT 直接判定觸控板性能。
- **M7 模式切換**：鍵盤模式送出 3,000 字長文字後立即進入觸控板量測，量第一個 cursor 封包的估計單程延遲與長文字是否完整送達；觸控板模式 0x03 優先（spec §8.2 規則 4）。
- **M8 觸控板工作負載**：連續移動、點擊、捲動、拖曳心跳同時進行 10 分鐘。
- 每次量測必須註明連線延遲偏好；以下 2026-11-01 02:28–03:04 的第一輪結果是**未設定偏好**、舊版工具量的，只作參考，不作關卡依據（其中 M5 的恢復段沒有樣本，是舊工具的缺陷，新版固定時間三段）。
- 用語固定：單程數字一律稱「估計單程」（鍵名 `est_` 開頭）；看門狗結果一律稱「模擬誤釋放」（`simulated_release`）；點擊 RTT 一律稱「點擊代理 RTT」（`click_proxy_rtt_`）。
- 工具已依計畫 TP1 Step 10b 補齊（M3a／b／c、`.low` 偏好、M5 固定三段、M7、M8、M6 30 分鐘）。以下各節是操作與輸出欄位；結果欄在實機重量完成前全部是 TBD。

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
| M3a RTT P50／P95／P99、M3b 覆蓋率、M3c 估計單程 P50／P95／P99 與誤差範圍（`.low`） | TBD |
| M4 E2E P50／P95／P99 | TBD |
| M6 30 分鐘（`.low`）：模擬誤釋放次數 | TBD |
| M7 模式切換 20 次：baseline 與切換後第一個封包的估計單程延遲、長文字完整、文字未被餓死 | TBD |
| M8 工作負載 10 分鐘：cursor 估計單程 P50／P95／P99、點擊代理 RTT P50／P95、模擬誤釋放次數 | TBD |

### 待量（健壯性，只記錄）

| 項目 | 結果 |
|---|---|
| M5（baseline 20 秒、load 60 秒、recovery 30 秒）：三段 RTT、`drain_ms`、`recover_ms`、`valid` | TBD |
| M6-L（長文字中的心跳 10 分鐘）：模擬誤釋放次數 | TBD |

## 前置

| # | 項目 | 做法 |
|---|---|---|
| P1 | Mac | 執行 Debug 版 MacReceiver（不用 `/Applications` 內已安裝的版本，也不要覆蓋它）。面板頂端 build 時間與主代理告知的一致；已授權輔助使用（M4 要移動游標）；已與這支 iPhone 配對 |
| P2 | Mac 啟動參數 | 以 `-rkMeasureMode YES` 啟動：量測模式開啟並開始接收。範例：`open -n <MacReceiver.app 路徑> --args -rkMeasureMode YES`。也可在面板「除錯」區切換「量測模式」；模式只在記憶體，App 重開即關（有啟動參數時除外） |
| P3 | iPhone | 安裝 Debug 版，鍵盤已開啟「允許完整取用」，已配對；設定 › 顯示與亮度 › 自動鎖定改為「永不」（M6 每次數分鐘不碰螢幕） |
| P4 | 連線 | 鍵盤切到遠端模式，狀態列顯示已連線。Mac 的量測模式開啟後，鍵盤的 status 帶 `measure: true` |
| P5 | 量測頁 | 在鍵盤（遠端模式、英文頁）長按狀態列 2 秒開啟檢查面板。Mac 量測模式開啟且已認證時，面板顯示量測頁（結果文字加 M2、M3、M3 小、M5、M6、M7、M8、M4 觸控、延遲、停止）；否則仍是聽寫檢查清單。再長按一次會關閉面板 |
| P6 | 負載 | M5 與 M6 的長文字會被 Mac 當成輸入：先在 Mac 開 TextEdit 純文字文件並讓游標停在文件內，否則 Mac 回 `noFocus`（藍牙上的負載相同，但不會真的打字） |

結果字串只有計數、毫秒與項目名稱，沒有輸入文字、游標座標或 `dx`。Mac 的 CSV 寫到 `~/Library/Logs/RemoteKeyboard/measure-<日期>.csv`，iPhone 的 CSV 寫到 Extension 暫存目錄。

### CSV 欄位

| 檔案 | 欄位 |
|---|---|
| Mac `measure-<日期>.csv` | `seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,phoneTimeMicros,macTimeMicros` |
| iPhone `measure-<項目>-<時間>.csv` | `seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,rttMicros,handoffWaitMicros` |

- `kind`：`burst`、`rtt`、`cursor`、`heartbeat`；M7 另有 `longTextMatch`、`longTextMismatch`（長文字到達後 Mac 比對長度與 SHA-256 的結果，`bytes` 是長度，`seq` 為 0）。
- `counterGap`：與前一個收到的封包之間沒有到達的封包數，每次量測的第一個封包為 0。
- `interArrivalMicros`：與前一個封包的到達間隔（iPhone 的 heartbeat 與 cursor 列是交出間隔）。
- `holdMicros`：Mac 收到 `rtt` 探測到寫出回覆的時間；-1 表示沒有回覆（前一個回覆尚未完成，或寫入被拒）；其他種類為 0。
- `phoneTimeMicros`：封包內 iPhone 單調時鐘的交出時間（長文字列為 0）。`macTimeMicros`：Mac 單調時鐘的到達時間（每個心跳列都有，供 M6、M8 計算模擬誤釋放）。兩個時鐘不同，只能經 M3c 的時鐘差估計後比較。
- `rttMicros`、`handoffWaitMicros`：只在 iPhone 檔。後者是「交出時間 − 最早樣本時間」。
- 兩邊都不寫輸入文字、游標座標與 `dx`；Mac 不記錄長文字內容，只記相符或不符。
- Mac 的 CSV 在流量停止 1 秒後寫入檔案（不必等滿 200 列），所以一次量測結束後稍等即可讀取。
- 檔案內有多次量測依序接在一起：每次量測的 `seq` 從 1 開始，後處理工具依 `seq` 回到較小值切開。

### 取得 Mac 端數字

Mac 面板量測模式下方一行顯示「收、回、略過、拒收、模擬誤釋放」。量測模式關閉或連線結束時，Mac 把這些計數（含長文字相符／不符次數）寫入 log（只有數字）：

```bash
log show --last 30m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver" AND category == "measure"' --style compact
```

面板與 log 的計數從量測模式開啟起累計，不分次；每次量測的數字以 CSV 與後處理工具為準（見「後處理」）。

## 連線延遲偏好（所有量測共通）

每次量測開始時，iPhone 對已訂閱的 central 呼叫 `setDesiredConnectionLatency`。偏好由環境變數 `TEST_RUNNER_RKMEAS_LATENCY=low|medium|none` 指定，**預設 `low`**；`none` 不呼叫。

時序（M4 例外：由人操作，要求立刻送出，沒有前後流量）：

| 時間 | 動作 |
|---|---|
| 0–5 秒 | 60 Hz 的 `burst` 封包（41 bytes），Mac 只計數 |
| 5 秒 | 呼叫 `setDesiredConnectionLatency`，iPhone 記下當時的 iPhone 單調時間 `request_phone_us` |
| 5–12 秒 | 繼續送 `burst`（前 2 秒是等待生效，後 5 秒是旁證用的量測窗） |
| 12 秒起 | 量測本身開始（前 12 秒的封包不列入任何統計） |

- 每個 RKMEAS 結果行都帶 `latency_requested=low|medium|none` 與 `latency_confirmed=unconfirmed`。CoreBluetooth 沒有讀取實際 connection interval 的方法，所以一律是「已要求，生效未確認」；只有 M1 的 PacketLogger 能確認。
- `latency_carryover=low|medium`：本次要求 `none`，但同一連線上先前已要求過（CoreBluetooth 無法取消），實際可能仍是該偏好。要比較預設與 `.low`，兩組之間重新連線（重開鍵盤）。
- 旁證：結果有一行 `LAT request_phone_us=…`。後處理工具用 Mac CSV 中 `burst` 列的 `phoneTimeMicros` 找出要求前 5 秒與要求後第 2–7 秒的到達間隔中位數，印出 `arrival_interval_before_ms`、`arrival_interval_after_ms`、`change_ms`。這只是旁證，不是確認。

## 後處理（Mac CSV 與 iPhone 輸出合併）

估計單程與模擬誤釋放需要 Mac 的到達時間，只在 Mac 的 CSV 內。工具 `scripts/tp1-oneway-stats/main.swift` 用 Core 的同一份程式讀取：

```bash
cd <worktree>
swiftc -DDEBUG -o <暫存資料夾>/rk-oneway \
  Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Measurement/*.swift scripts/tp1-oneway-stats/main.swift
<暫存資料夾>/rk-oneway <RKMEAS 輸出檔> ~/Library/Logs/RemoteKeyboard/measure-<日期>.csv [--run N]
```

- `<RKMEAS 輸出檔>`：測試附件 `measure-<項目>.txt`，或 `xcodebuild` 輸出中的 `RKMEAS ...` 行存成的檔案。
- 預設讀 CSV 最後一次量測；`--run N` 指定第 N 次。
- 時鐘模型取 iPhone 輸出的 `CAL` 行（`offset_est_us`、`ref_phone_us`、`drift_us_per_min`），所以只有 M7、M8 能用；M3 的 M3c 由 iPhone 直接輸出。
- 輸出：`MODEL`（假設與誤差範圍）、`LAT`（旁證）、M8 的 cursor 估計單程與模擬誤釋放、M6 的模擬誤釋放、M7 每輪的 baseline 估計單程、切換後第一個封包與前 1 秒的估計單程、是否在 baseline P99 × 2 內，以及長文字相符／不符次數。
- 所有單程數字都是估計，誤差範圍見 `MODEL` 行的 `error_bound_ms`；不得表述為實測。`drift_measured=false` 時工具會印 `WARNING`，誤差範圍已含 100 ppm 的保守份量。
- `CAL_CHECK`：頭尾兩段校時各自的偏移所推出的漂移（`start_end_drift_us_per_min`），應與 `CAL` 行的漂移直線（`line_drift_us_per_min`）一致；差很多代表模型不可信。

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
5. 同時間 iPhone 跑 M3（見下，`TEST_RUNNER_RKMEAS_M3_SAMPLES=1500`，60 Hz 穩定送出），Mac 的 CSV 記錄封包到達間隔；每次擷取至少 60 秒。量測開始前 12 秒的流量裡有要求偏好的時間點（`LAT request_phone_us`），PacketLogger 的 LE Connection Update 時間應落在它之後，可對照。

| 延遲偏好 | 設定方式 | 次數 | 每次 | interval P50 | interval P95 | 其他值比例 | 結果 |
|---|---|---|---|---|---|---|---|
| 預設 | `TEST_RUNNER_RKMEAS_LATENCY=none`，並先重新連線（不呼叫） | 10 | 60 秒 | TBD | TBD | TBD | TBD |
| `.low` | `TEST_RUNNER_RKMEAS_LATENCY=low`（預設） | 10 | 60 秒 | TBD | TBD | TBD | TBD |
| `.medium` | `TEST_RUNNER_RKMEAS_LATENCY=medium`，並先重新連線 | 10 | 60 秒 | TBD | TBD | TBD | TBD |

面板的「延遲」鈕仍可手動依序切換 預設 → 低 → 中 → 預設，但開始量測時會依環境變數（預設 `low`）再要求一次。切回「預設」不會呼叫（CoreBluetooth 沒有取消的方式），要重新連線才回到系統預設；每組次數之間重開鍵盤。

## M2：`updateValue` 背壓

方法：在 `peripheralManagerIsReady` 回呼內連續送 41 bytes 與 182 bytes 的加密量測封包，直到 `updateValue` 回 `false`；各 100 輪。被拒的密文丟棄，下一次重新加密（計數器不回收）。記錄每輪被接受的封包數，以及從 `false` 到下一次 ready 的時間。每輪上限 2,000 個封包（防止沒有背壓時不停止）。

M2 的連發不經交錯：它直接呼叫 `updateValue`，不排在 `0x02` frame 的佇列後面，所以量到的是純封包的背壓；M4 的 cursor 封包同樣直接交出。這樣不會打亂 `0x02` 長訊息：量測封包是首 byte `0x7E` 的單一 notification，Mac 依首 byte 分流，不進 `FrameReassembler`，不會插入、重排或截斷任何 `0x02` frame 序列（`testNon02FrameDoesNotTouchReassembler`）。只有 M3、M5、M6、M7、M8 的探測依交錯規則交出。

操作：`testM2BackPressure`（量測頁「M2」）。輸出（每種大小一行）：`M2 packet=41 rounds=100 accepted_p50=… accepted_min=… accepted_max=… drain_p50_ms=… drain_p95_ms=… drain_max_ms=… latency_requested=… latency_confirmed=unconfirmed`。

| 封包 | 每輪接受數 P50／最小／最大 | 排空時間 P50／P95／最大（ms） | 結果 |
|---|---|---|---|
| 41 bytes | TBD | TBD | TBD |
| 182 bytes | TBD | TBD | TBD |

## M3：應用層 RTT 與估計單程

方法：41-byte `rtt` 封包 60 Hz；Mac 只在沒有回覆寫入在途時回覆（其餘計為略過），回覆經 control write；回覆明文 24 bytes（封包 49 bytes），含 `seq`、iPhone 時間、Mac 保留時間與 Mac 收到該封包時的單調時間（`macTimeMicros`）。iPhone 以 `measureM2P` 驗證回覆後：
- M3a：封包交出時間 → 收到回覆，算 RTT。
- M3b：有回覆的封包比例與略過比例，只說明 M3a 樣本的代表性，**不用來判定性能**。
- M3c：以每個回覆的（iPhone 交出、Mac 收到、iPhone 收到回覆）三個時間估計兩端時鐘差，再對每個回覆算「估計單程」（iPhone 交出 → Mac 收到）。

M3c 三者分開列出，不得合併成一個數字：

| 部分 | 輸出鍵 | 內容 |
|---|---|---|
| ① 時鐘差估計值 | `offset_est_us`（在 `ref_phone_us` 那一刻的 Mac 時鐘減 iPhone 時鐘） | 以最小 RTT 的樣本為準 |
| ② 假設 | `assumption=symmetric`、`drift_us_per_min`、`drift_measured` | 假設去程與回程延遲相等（這是假設，無法量到）；量測期間兩端時鐘漂移量，並已在估計單程中補償。漂移的估計方式：樣本若分成相隔超過 20 秒的群（M7：頭尾各 5 秒校時），每群取一個錨點，兩個錨點相隔 ≥ 30 秒就量得漂移；連續的樣本（M3、M8）把整段分十等份各取一個錨點，至少 3 個、跨度 ≥ 30 秒才量得漂移。量不到就是 `drift_measured=false`，漂移記 0 |
| ③ 誤差範圍 | `error_bound_ms` | ± 最小 RTT／2，加上殘差（各錨點偏離漂移直線的最大距離，以及主錨點內各樣本的離散；這是「模型沒解釋的部分」的代理，不是對不對稱的證明上限）。`drift_measured=false` 且樣本跨度超過 10 秒時，再加「跨度 × 100 ppm」的保守份量（猜測，不是量測；跨度 25 秒約加 2.5 ms） |

錨點不是單一最小 RTT 樣本，而是該群最低約 5% RTT 樣本的偏移中位數（至少 1 個），所以一個幸運的樣本不會決定結果；誤差範圍的 ± 最小 RTT／2 仍用整體最小 RTT。

Mac 的到達時間是 Receiver 的 main actor 處理函式開始時讀的單調時間，所以從無線電交付封包到該函式開始之間的 Mac 軟體延遲，也算在估計單程裡（單程不是純 BLE 空中時間）。

跑到收滿樣本數（預設 10,000 個回覆）；若送出數超過樣本數的 4 倍仍未收滿就中止並回報已有的數字。

操作：`testM3RoundTrip`（量測頁「M3」，預設 10,000），或 `testM3Smoke`（「M3 小」，200 個，確認鏈路用）。

輸出（每行最後都帶 `latency_requested=… latency_confirmed=unconfirmed`）：
- `M3a count=… p50_ms=… p95_ms=… p99_ms=… jitter_ms=… max_ms=…`
- `M3b sent=… replies=… coverage_pct=… skipped=… skipped_pct=… refused=… superseded=… arrival_sd_ms=… hold_p50_ms=… wait_p50_ms=… wait_p95_ms=…`
- `M3c 估計單程 est_oneway_p50_ms=… est_oneway_p95_ms=… est_oneway_p99_ms=… offset_est_us=… ref_phone_us=… drift_us_per_min=… drift_measured=… error_bound_ms=… samples=… assumption=symmetric`

`jitter_ms` 是 P95 − P50；`refused` 是 `updateValue` 回 `false` 的次數；`superseded` 是還沒交出就被下一個取代的探測數；`arrival_sd_ms` 是回覆到達間隔的標準差。

| 指標 | 值 | 結果 |
|---|---|---|
| M3a P50／P95／P99（ms） | TBD | TBD |
| M3a jitter（ms） | TBD | TBD |
| M3b 覆蓋率／略過比例 | TBD | TBD |
| M3c 估計單程 P50／P95／P99（ms） | TBD | TBD |
| M3c 時鐘差估計、漂移、誤差範圍 | TBD | TBD |

## M5：積壓（健壯性，不作關卡）

方法：M3 的 RTT 探測進行中，依時間分三段：baseline 20 秒（不送長文字）、load 60 秒（每秒一則 3,000 字元長文字，與既有 `sendDebugLongText()` 相同內容）、recovery 30 秒（停止送文字）。每個 RTT 算在它被送出時所屬的那一段。任何一段的樣本數少於 30，整次標 `valid=false`（測試會失敗，但數字仍印出）。記錄：
- `drain_ms`：停止送文字起，到 `0x02` 佇列（`NotifyQueue`）排空的時間（停止時已空則為 0；`not_empty` 表示直到結束仍未空）。
- `recover_ms`：佇列排空後，到「連續 10 個 RTT 都不高於 baseline P95」的第一個 RTT 的時間（`never` 表示沒有回到）。

不要求達到 P95 60 ms；長文字結束後延遲要回到前段水準，且沒有當機或卡住。

操作：`testM5Backlog`（量測頁「M5」）。長文字送出需要 Mac 面板的接收中且鍵盤已認證；Mac 要開 TextEdit（見 P6）。

輸出：每階段一行 `M5 phase=… count=… rtt_p50_ms=… rtt_p95_ms=… rtt_p99_ms=… rtt_max_ms=…`（load 另有 `texts=`）；`M5 trend_p50_ms=… blocked_count=… blocked_p50_ms=… blocked_p95_ms=… blocked_max_ms=… sent=… skipped=… refused=… superseded=…`（`trend_p50_ms` 是 load 段最後四分之一的 P50 減最前四分之一的 P50，持續上升代表積壓）；`M5 drain_ms=… recover_ms=… recover_run=10 min_samples=30 valid=…`。

| 階段 | count | P50／P95／P99／最大（ms） | 結果 |
|---|---|---|---|
| baseline | TBD | TBD | TBD |
| load | TBD | TBD | TBD |
| recovery | TBD | TBD | TBD |

| 項目 | 值 | 結果 |
|---|---|---|
| valid（每段 ≥ 30 樣本） | TBD | TBD |
| drain_ms、recover_ms | TBD | TBD |
| trend_p50_ms | TBD | TBD |
| 阻塞次數與時間分佈 | TBD | TBD |

## M6：心跳與看門狗

方法：iPhone 每 100 ms 送一個 `heartbeat` 探測（一個系列從 `seq` 1 開始）。Mac 以 350 ms 看門狗只記錄「模擬誤釋放」，不送任何滑鼠事件：一個系列內相鄰兩個 heartbeat 的到達間隔超過 350 ms 就計一次。Mac 把每個心跳的到達時間（`macTimeMicros`）寫入 CSV。TP1 沒有正式拖曳協定，結果不得稱為已通過真實拖曳測試（真實拖曳在 TP3、TP5）。

情境：

| 情境 | 名稱（`RKMEAS_M6_SCENARIO`） | 條件 | 時間 | 誰造成 |
|---|---|---|---|---|
| 主要（關卡） | `normal` | `.low`、無長文字 | 30 分鐘（`TEST_RUNNER_RKMEAS_M6_SECONDS=1800`） | — |
| 健壯性 M6-L | `longText` | 同時每秒送 3,000 字元長文字 | 10 分鐘 | 程式自動 |
| 健壯性 M6-X | `load` | Mac 與 iPhone 各跑壓力程式 | 10 分鐘 | 執行者在量測期間造成 |
| 健壯性 M6-X | `covered` | 鍵盤暫時被遮蔽（例如拉出控制中心） | 10 分鐘 | 執行者在量測期間造成 |
| 健壯性 M6-X | `interference` | 附近大量藍牙／Wi-Fi 傳輸 | 10 分鐘 | 執行者在量測期間造成 |

名稱只決定結果行上的標記；`longText` 以外的情境不由程式造成條件。鍵盤整個消失會結束連線，那次量測以「中止」收場並保留已有的數字。

操作：`testM6Heartbeat`（量測頁「M6」）；秒數與情境用環境變數（見下）。

輸出：iPhone：`M6 scenario=… seconds=… sent=… superseded=… refused=… texts=…`、`M6 handoff_gap_p50_ms=… handoff_gap_p99_ms=… handoff_gap_max_ms=… blocked_count=… blocked_max_ms=…`，以及 `M6 模擬誤釋放 simulated_release=pending_mac_csv`（iPhone 不知道 Mac 端的到達間隔，這個值要由 Mac 的 CSV 取得）。Mac：用後處理工具讀 CSV，得到 `M6 模擬誤釋放 simulated_release=…`、心跳間隔數與最大間隔。

| 情境 | 模擬誤釋放次數（Mac CSV） | 心跳到達間隔最大值（ms，Mac） | 交出間隔最大值／P99（ms，iPhone） | 結果 |
|---|---|---|---|---|
| normal（30 分鐘，關卡） | TBD | TBD | TBD | TBD |
| longText（M6-L） | TBD | TBD | TBD | TBD |
| load（M6-X） | TBD | TBD | TBD | TBD |
| covered（M6-X） | TBD | TBD | TBD | TBD |
| interference（M6-X） | TBD | TBD | TBD | TBD |

## M7：模式切換

目的：鍵盤模式剛送出 3,000 字長文字、文字還沒送完時切到觸控板模式，觸控板即時操作不能被文字拖慢，文字也不能被餓死。

每一輪（預設 20 輪，`TEST_RUNNER_RKMEAS_M7_RUNS` 調整）：
1. 10 秒 cursor baseline：60 Hz、41 bytes、與 `.low`（或環境變數指定的偏好）相同條件、無長文字。cursor 封包不帶位移（`dx` 為 0）：Mac 不移動游標、不亮小視窗，只記錄到達。
2. 送出 3,000 字長文字（鍵盤模式）。
3. 立即進入觸控板模式，繼續 60 Hz cursor 10 秒，不等文字送完。出口依 spec §8.2 規則 4 的觸控板模式：`0x03`（此處是量測探測）優先，每交出 4 個探測才交出 1 個 `0x02` frame；沒有探測待送時 `0x02` 全速送出。
4. 休息 3 秒；若文字還沒送完，最多再等 10 秒，下一輪才開始。

整個 M7 前後各有 5 秒的 60 Hz `rtt` 校時（供時鐘模型使用）；兩段相隔約 8 分鐘，各取一個錨點就能量得漂移（20–50 ppm 在這段時間約 10–25 ms，不補償就會直接進到估計單程）。

記錄：
- iPhone 每輪一行：`M7 round=… baseline_seq=a..b trackpad_seq=c..d text_accepted=… text_send_ms=… text_complete=… frames_per_s_min=… starved_s=… frames_per_s=x/y/z`。`text_send_ms` 是長文字交出到 `0x02` 佇列排空的時間；`frames_per_s` 是文字還在等待的那幾秒中，每秒交給無線電的 `0x02` frame 數，`frames_per_s_min` 必須 > 0、`starved_s` 必須為 0（文字沒被餓死）。
- iPhone 總結：`M7 rounds=…`，另有 `CAL`、`CAL_START`、`CAL_END`（時鐘模型，供後處理）。
- Mac：長文字到達時以長度與 SHA-256 比對，CSV 加一列 `longTextMatch` 或 `longTextMismatch`，只記相符／不符。
- 後處理（見上）算每輪 baseline 的估計單程 P50／P95／P99、切換後第一個 cursor 封包與前 1 秒的估計單程，以及「第一個封包是否不超過同一輪 baseline P99 × 2」。

判定（spec §13.4，M7 是關卡）：每一輪第一個封包的估計單程不超過同輪 baseline P99 × 2；20 輪長文字都完整（`long_text_complete=true`）；`starved_s_total=0`。單程數字是估計，判定須連同誤差範圍一起看。

操作：`testM7ModeSwitch`（量測頁「M7」）。Mac 要開 TextEdit（見 P6），否則長文字會被拒絕輸入（但傳輸與雜湊檢查不受影響）。

| 指標 | 值 | 結果 |
|---|---|---|
| 每輪 baseline 估計單程 P50／P95／P99 | TBD | TBD |
| 切換後第一個封包估計單程（20 輪） | TBD | TBD |
| 切換後前 1 秒估計單程 | TBD | TBD |
| 第一個封包 ≤ baseline P99 × 2 的輪數 | TBD | TBD |
| 長文字相符／不符次數 | TBD | TBD |
| 長文字送完所需時間 | TBD | TBD |
| 觸控板期間每秒 0x02 frame 數最小值、餓死秒數 | TBD | TBD |

## M8：觸控板工作負載

目的：用量測封包模擬 10 分鐘的觸控板使用，看估計單程與模擬誤釋放。不注入任何滑鼠事件（cursor 封包不帶位移）。

流量（`TEST_RUNNER_RKMEAS_M8_SECONDS` 調整，預設 600）：

| 代理 | 封包 | 節奏 |
|---|---|---|
| 連續移動 | `cursor`（41 bytes） | 60 Hz；每 5 秒的最後 1 秒加倍為 120 Hz（捲動代理） |
| 點擊 | `rtt` | 每 2 秒一個（Mac 只在沒有回覆在途時回覆） |
| 拖曳心跳 | `heartbeat` | 每 100 ms |

前後各 5 秒的 60 Hz `rtt` 校時。

輸出：`M8 seconds=… body_seq=a..b sent=… superseded=… refused=…`；`M8 點擊代理 RTT count=… click_proxy_rtt_p50_ms=… click_proxy_rtt_p95_ms=… click_proxy_rtt_p99_ms=…`（點擊代理 RTT 是量測封包的往返，不代表 TP3 正式 Click ACK 的延遲）；`M8 heartbeat_handoff_gap_p99_ms=… heartbeat_handoff_gap_max_ms=… blocked_count=… blocked_max_ms=…`；`M8 模擬誤釋放 simulated_release=pending_mac_csv`；`CAL`、`CAL_START`、`CAL_END`。後處理工具用 Mac CSV 補上：`M8 cursor 估計單程 est_oneway_p50_ms=… est_oneway_p95_ms=… est_oneway_p99_ms=…` 與 `M8 模擬誤釋放 simulated_release=…`。

關卡條件：模擬誤釋放次數必須為 0（只代表 BLE 傳送條件足夠；真實拖曳在 TP3、TP5 驗證）。

操作：`testM8Workload`（量測頁「M8」）。

| 指標 | 值 | 結果 |
|---|---|---|
| cursor 估計單程 P50／P95／P99（ms） | TBD | TBD |
| 點擊代理 RTT P50／P95（ms） | TBD | TBD |
| 模擬誤釋放次數 | TBD | TBD |
| 心跳到達間隔最大值（ms，Mac） | TBD | TBD |
| 時鐘模型：漂移、誤差範圍 | TBD | TBD |

## 自動化（主代理）

M2、M3、M5、M6、M7、M8 的 XCUITest 在 `iOS/RemoteKeyboardUITests/MeasurementUITests.swift`。每個測試切到遠端模式、長按狀態列開量測頁、等按鈕可用、按下、等結果，並以 `RKMEAS <項目> key=value ...` 印出統計數字；同樣內容附成 `measure-<項目>.txt`。

先在 Mac 啟動 Debug 版 MacReceiver（`-rkMeasureMode YES`，見 P2），再執行：

```bash
cd <worktree>
DEV="-workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination id=<你的 iPhone UDID> \
  -derivedDataPath <暫存資料夾>/rk-tp1-dd-dev -allowProvisioningUpdates"

# 先確認鏈路（200 個樣本）
xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM3Smoke

# 主要，依序（預設 .low）：M2、M3、M6（30 分鐘）、M7（20 輪）、M8（10 分鐘）
xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM2BackPressure
xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM3RoundTrip
TEST_RUNNER_RKMEAS_M6_SCENARIO=normal TEST_RUNNER_RKMEAS_M6_SECONDS=1800 \
  xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM6Heartbeat
TEST_RUNNER_RKMEAS_M7_RUNS=20 \
  xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM7ModeSwitch
TEST_RUNNER_RKMEAS_M8_SECONDS=600 \
  xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM8Workload

# 健壯性：M5、M6-L
xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM5Backlog
TEST_RUNNER_RKMEAS_M6_SCENARIO=longText TEST_RUNNER_RKMEAS_M6_SECONDS=600 \
  xcodebuild test $DEV -only-testing:RemoteKeyboardUITests/MeasurementUITests/testM6Heartbeat
```

每一項跑完，用「後處理」把 Mac 的 CSV 與該項的 RKMEAS 輸出合併（M6、M7、M8 必做）。

| 環境變數 | 預設 | 作用 |
|---|---|---|
| `TEST_RUNNER_RKMEAS_LATENCY` | low | `low`、`medium` 或 `none`：量測前要求的連線延遲偏好 |
| `TEST_RUNNER_RKMEAS_M3_SAMPLES` | 10000 | M3 的回覆樣本數 |
| `TEST_RUNNER_RKMEAS_M6_SCENARIO` | normal | `normal`、`longText`、`load`、`covered`、`interference` |
| `TEST_RUNNER_RKMEAS_M6_SECONDS` | 600 | M6 長度（秒）；30 分鐘關卡用 1800 |
| `TEST_RUNNER_RKMEAS_M7_RUNS` | 20 | M7 輪數 |
| `TEST_RUNNER_RKMEAS_M8_SECONDS` | 600 | M8 長度（秒） |

M5 的三段時間固定（20／60／30 秒），不再有樣本數設定（舊的 `RKMEAS_M5_SAMPLES` 已移除）。測試把設定經主 App 的啟動環境寫入 App Group，鍵盤在按下按鈕時讀取。若測試以 skip 結束（找不到鍵盤、量測頁沒出現），代表 Mac 量測模式沒開、沒有配對、或連線尚未認證。

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
| Mac 小視窗 | 量測模式開啟時，主螢幕左上角出現 120 × 120 pt 的黑色視窗，收到帶位移的 cursor 封包時變白約 50 ms（連續封包時持續白；M7、M8 的 cursor 封包不帶位移，不會變白）；錄影要拍到它 |
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
   - BLE 單程用 M3c 的估計單程（兩端時鐘未同步，只能估計，附誤差範圍）；不再用 RTT／2。

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
