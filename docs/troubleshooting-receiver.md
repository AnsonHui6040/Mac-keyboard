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

## Linux

- 打字需要桌面入口網站授權：第一次執行會跳出遠端桌面授權視窗，按「允許」。授權記錄在接收端；沒有授權就不能注入按鍵。
- 接收端只使用外接藍牙卡 hci1。不要動內建的 hci0，也不要重啟 bluetoothd。
- 不需要 sudo。

## Windows

- 第一次執行 SmartScreen 會警告：「更多資訊」→「仍要執行」。
- 以系統管理員身分開啟的視窗收不到打字；把接收端與該視窗用同一個權限執行，或在一般權限的視窗操作。
