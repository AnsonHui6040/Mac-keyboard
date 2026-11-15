# Windows／Linux 接收端排錯

## Log 在哪裡

| 系統 | 位置 |
|---|---|
| Windows | `%LOCALAPPDATA%\RemoteKeyboard\logs\` |
| Linux | `~/.local/state/remote-keyboard/logs/`（設了 `XDG_STATE_HOME` 時為 `$XDG_STATE_HOME/remote-keyboard/logs/`） |

每天一個檔 `rk-<日期>.log`，保留 7 天。log 只記事件種類、長度、時間與結果，不含打字內容。

## 匯出診斷資料

1. 系統匣圖示 → 「匯出診斷資料」，會在桌面產生 `RemoteKeyboard-diag-<時間>.zip`。
2. 命令列：`rk-receiver --diag` 把狀態印到畫面。
3. 要看更細的記錄：`rk-receiver --log-level debug`。

## 連線時間統計

    rk-diag stats <log 資料夾> --since 2026-11-14T20:23:00Z [--out <檔案>]

輸出次數、最小、中位、p95、最大、3 秒內比例與各種失敗的次數。`reason`、`kind`、`result` 只統計下表列出的詞，其他一律算 `other`。

`rk-diag` 與 `rk-receiver` 放在同一處：

| 系統 | 位置 |
|---|---|
| Windows | `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe` |
| Linux | `~/.local/bin/rk-diag` |

自己建置：在 `receiver/` 執行 `cargo build --release -p rk-receiver --bin rk-diag`，把 `target/release/rk-diag`（Windows 為 `rk-diag.exe`）複製到上表位置。

## 觸控板時間統計

用手指在手機觸控板上滑動一次，到停手後 300 毫秒，接收端會在 log 寫出下列幾行。一次滑動（stroke）從第一個觸控封包開始，到 300 毫秒內沒有新封包為止。這些行只有次數與時間，沒有任何游標位移量或打字內容，用預設的 `info` 等級就會寫出。

單位一律是微秒（`_us`），`b` 開頭的欄位是區間內的次數：`b2` 為 2 毫秒以內，`b5` 為 2 至 5 毫秒，依序為 `b10`、`b15`、`b20`、`b30`、`b40`、`b50`、`b75`、`b150`，超過 150 毫秒的是 `bover`。每個區間統計都帶這組欄位：`n`（筆數）、`p50_us`、`p90_us`、`p99_us`、`max_us`、各個 `b`。只保留前 4096 筆算百分位，筆數與 `b` 欄位不受限制。

| 行（`ev=`） | 由誰寫 | 內容 |
|---|---|---|
| `ble_rx_timing` | Linux 藍牙層 | 觸控封包從連線收進來的間隔。`packets` 為封包數，`same_ci` 為與前一包相隔 1 毫秒內的封包數（多半是同一個連線事件一起送到），其餘為間隔的 `n`、`p50_us` 等欄位 |
| `pointer_timing` | 接收端主程式（Windows 與 Linux 相同） | 一次滑動的總結：`packets`（收到的封包）、`moves`（其中的移動封包）、`frames`（播放用的畫面計時次數）、`idle`（沒有輸出任何移動的畫面計時次數）、`squeeze`（播放佇列被壓縮的次數）、`lag_us`（播放佇列最後採用的延遲上限，單位微秒；每個畫面約一個封包的連線是 20000，封包成批到達的連線會依到達週期升高，上限 60000）、`inj_max_us`（單次 `pointer_move` 呼叫最久花的時間）、`late_n`、`late_p99_us`、`late_max_us`（主程式的計時器比預定時間晚多少） |
| `pointer_timing_arr` | 接收端主程式 | 相鄰觸控封包到達的間隔 |
| `pointer_timing_dt` | 接收端主程式 | 手機回報每個移動封包涵蓋的時間（`dt`） |
| `pointer_timing_out` | 接收端主程式 | 播放佇列相鄰兩次輸出移動的間隔 |
| `portal_motion_timing` | Linux 注入層 | 桌面入口網站的移動呼叫：`moves_in`（收到的移動指令數）、`sends`（實際呼叫次數）、`call_p50_us`、`call_p99_us`、`call_max_us`（單次呼叫花的時間），以及相鄰兩次呼叫起點的間隔，欄位名稱加上 `send_` 前綴，例如 `send_n`、`send_p50_us`、`send_b20` |

主程式的時鐘以毫秒計，所以 `pointer_timing*` 的數值都是 1000 微秒的整數倍。

判讀方向（由手機往游標）：

1. `ble_rx_timing` 的間隔集中在 40 至 50 毫秒、`same_ci` 很高：封包受連線間隔影響，一批一批到。
2. `pointer_timing_out` 的間隔忽大忽小，或 `idle`、`squeeze` 很高：播放佇列沒有把一批批到的移動攤平。先看 `lag_us`：成批到達的連線（例如連線間隔 45 ms 的 Linux）應該約 50000；若仍停在 20000，表示到達週期沒有被量到。
3. `inj_max_us`、`call_p99_us`、`call_max_us` 很大，或 `late_max_us` 很大：卡在注入層或主程式的計時器。
4. `sends` 遠小於 `moves_in`，且 `send_` 間隔不均：120 Hz 合併或入口網站呼叫的節奏造成。

## 失敗種類

| 種類 | 出現位置 | 意思 | 下一步 |
|---|---|---|---|
| `unreachable` | retry、connect_failed | 連不到手機 | 手機鍵盤要在畫面上；靠近一點；等下一次重試 |
| `enosys` | retry | 藍牙堆疊暫時拒絕連線，會自動重試 | 連續出現很多次時，關閉再開啟電腦的藍牙 |
| `abort_by_local` | retry、connect_failed | 這一端中止了連線 | 通常是重試造成，單獨出現不用處理 |
| `att_error` | connect_failed、write_failed | 讀取服務或寫入時被拒絕 | 手機重新叫出鍵盤；仍失敗就在手機刪除這台電腦後重新配對 |
| `timeout` | auth、disconnected | 握手逾時，手機沒有回應 | 確認手機的 Remote Keyboard 已開啟「允許完整取用」並在前景 |
| `not_selected` | auth | 手機選的不是這台電腦 | 在手機的電腦清單選這台 |
| `auth_failed` | auth | 驗證失敗 | 刪除這台電腦後重新配對 |
| `unsupported_version` | auth | 手機與接收端版本不相容 | 兩邊更新到同一版 |
| `local` | disconnected | 這一端主動結束連線（例如結束接收端） | 正常 |
| `peer_bye`、`remote` | disconnected | 手機端結束連線 | 正常，例如收起鍵盤 |
| `link_lost` | disconnected、write_failed | 連線中斷（距離、干擾、手機休眠） | 靠近一點，確認手機沒鎖定 |
| `stale_advert` | disconnected | 手機重新廣播，舊連線被換掉 | 正常，隨後會自動重連 |
| `hold`（事件，沒有 `kind`） | hold | 同一支手機連續失敗，暫停數秒再試 | 等待；一直出現就看上面各種失敗 |

## 接收開關

系統匣選單的「停止接收」會中斷目前連線並停止掃描，直到按「開始接收」或重新啟動接收端才恢復；「已停止」不寫入設定檔。手機連不上時，先看系統匣狀態行是不是「已停止接收」。log 只有兩種事件：

| 事件 | 意思 |
|---|---|
| `receiving_stopped`（`by=user`） | 使用者按了「停止接收」 |
| `receiving_started`（`by=user`） | 使用者按了「開始接收」；接收端剛啟動時不記這個事件，記的是 `start` |
| `scan_stop` | 停止接收時沒有任何連線，掃描直接停止 |
| `link_refused`（`why=stopped`） | 停止的瞬間剛好有連線完成，接收端不理它、直接掛斷；沒有 `hello`，手機會看到連線被結束 |
| `connect_cancelled`（`why=stopped`） | 停止時正在連線的嘗試被放棄；它不算連線失敗，不會觸發暫停重試 |

在 Linux 上更換藍牙卡（選單的「藍牙卡」）會讓接收端重新啟動，重新啟動後一律回到「接收中」，即使更換前是「已停止」。

## Linux

- 打字需要桌面入口網站授權：第一次執行會跳出遠端桌面授權視窗，按「允許」。授權記錄在接收端；沒有授權就不能注入按鍵。
- 接收端只使用外接藍牙卡 hci1。不要動內建的 hci0，也不要重啟 bluetoothd。
- 不需要 sudo。

### 藍牙卡自動重設

藍牙卡用久了偶爾會「聽不到」：核心照常下掃描指令、回報都成功，但晶片完全沒有回傳任何裝置的廣播；之前通常先出現連線逾時或 `att_error`。把藍牙卡關掉再開（BlueZ 的 `Powered` 關再開）就會恢復。接收端會自動做這件事，不需要 sudo，也不針對特定廠牌或型號，任何 Linux 電腦、任何藍牙卡都適用。

| 觸發條件 | log 的 `reason` |
|---|---|
| 接收中、沒有連線，且 60 秒內沒有聽到任何裝置的廣播（不限手機） | `no_adverts` |
| 連續 3 次連線嘗試失敗（`unreachable`、`enosys`、`abort_by_local`、`att_error`、`timeout`） | `connect_failures` |

下列情況不會重設：連線中、使用者按了「停止接收」、藍牙卡被使用者自己關掉（接收端不會替使用者開啟）。`not_selected`、`auth_failed`、`unsupported_version` 表示無線電本身正常，不算失敗，還會讓連續失敗的計數歸零；因接收開關而取消的連線嘗試也不算。

兩次重設至少相隔 120 秒；重設之後如果沒有聽到任何廣播也沒有連上，下一次的間隔加倍（120、240、480 秒……最長 30 分鐘），聽到廣播或連上之後恢復 120 秒。附近完全沒有任何藍牙裝置廣播時，也會被當成聽不到而重設，但有上述間隔限制，不會連續重設。

| 事件 | 意思 | 下一步 |
|---|---|---|
| `adapter_reset`（`reason`、`hci`） | 接收端正要把藍牙卡關掉再開 | 掃描會自動恢復；重設後還是連不上就看上面的失敗種類 |
| `adapter_reset_failed`（`kind`） | 重設做不到；30 分鐘內不再嘗試 | 看下表 |

| `kind` | 意思 |
|---|---|
| `unavailable` | 找不到 BlueZ 或指定的藍牙卡 |
| `power_off` | 關閉藍牙卡被拒絕（多半是權限政策） |
| `power_on` | 重新開啟失敗；接收端已再試一次，仍失敗就手動開啟藍牙卡 |
| `timeout` | BlueZ 10 秒沒有回應 |

## Windows

- 第一次執行 SmartScreen 會警告：「更多資訊」→「仍要執行」。
- 以系統管理員身分開啟的視窗收不到打字；把接收端與該視窗用同一個權限執行，或在一般權限的視窗操作。
