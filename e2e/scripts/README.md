# e2e 腳本

測試時用來配對 iPhone 與接收端、切換目前電腦的輔助工具。

| 檔案 | 作用 |
|---|---|
| `win-confirm-pairing.ps1` | 等 Windows 接收端的配對視窗（標題 Remote Keyboard），把 6 位數寫入結果檔，按「是」。必須明確指定 `-ExpectSas <6 位數>`（不符時按「否」）或 `-AnyCode`，兩者都沒有就報錯；只處理有「是」「否」兩個按鈕、且只含一組獨立 6 位數的 Remote Keyboard 訊息視窗。結束碼：0 是、3 否、2 逾時沒視窗、1 錯誤 |
| `win-focus-target.ps1` | 在 Notepad 開一個專用的空白測試檔 `type-target.txt`（`-File` 檔名不是它就拒絕），帶到最前面，前景視窗標題必須剛好是 `type-target.txt - 記事本` 或 `- Notepad` 才寫 `focus=True`；結果檔只有 `focus=True／False`，不記錄任何標題。**任何 Windows 打字測試之前一定先跑，`focus=True` 才繼續** |
| `win-read-target.ps1` | 只在恰好一個 Notepad 視窗的標題剛好是 `type-target.txt - 記事本`／`- Notepad`、選取的分頁是 `type-target.txt`、讀完後標題與分頁沒變時才寫出內容；否則結果檔寫 `refused`、結束碼 2 |
| `linux-confirm-pairing.sh` | 經 AT-SPI 找 zenity 配對視窗，行為同上；三個參數都要給：`<逾時秒數> <結果檔> <6 位數或 --any>`。只處理同時有「相符」「不相符」按鈕、且只含一組獨立 6 位數的視窗。結束碼 0、3、2、4（AT-SPI 不能用或找不到按鈕）、1（參數錯誤） |
| `measure-reconnect.sh` | `measure-reconnect.sh <win\|linux> [N]`：在 Mac 上跑 iPhone 的 `ReconnectUITests`（叫出／收起鍵盤 N 次，預設 100），再經 SSH 在接收端跑 `rk-diag stats --since <開始時間>`，把 iPhone 的 RKTIMING 與接收端統計存到 `e2e/results/<日期>-<target>.txt`（不進 repo）。開始前先經 SSH 讀接收端的 UTC 時鐘，自動修正兩台電腦的時間差；接收端連線數不到 N 的一半時以結束碼 6 警告。接收端要先裝好 `rk-diag`（Windows `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe`，Linux `~/.local/bin/rk-diag`；建置與複製見 `docs/troubleshooting-receiver.md`）。次數用環境變數 `TEST_RUNNER_RK_REOPEN_COUNT` 傳入，寫在 `xcodebuild` 指令前面；放在指令尾端只會變成 build setting，測試讀不到而跑預設 100 次。腳本會核對實際跑的次數 |
| `measure-trackpad.sh` | `measure-trackpad.sh <win\|linux> [N]`：一個指令、不用手動操作量測觸控板時序（N 為劃線次數，預設 20）。先經 SSH 讀接收端 UTC 時鐘並修正時間差；結束 Mac 接收端 App（避免搶 iPhone 的連線），不論成功或失敗離開時都會重新開啟；用 `PairingUITests/testSelectComputer` 切到目標電腦（名稱取自 `RK_HOST_NAME`，linux 預設 `Linux`，win 必填）；再跑 `TrackpadSmokeUITests/testFixedStrokes`；等 2 秒後經 SSH 取接收端記錄中的 `pointer_timing*`、`ble_rx_timing`、`portal_motion_timing` 行，只留測試時間窗內的，交給 `timing_report.py` 彙整，存到 `e2e/results/<日期>-trackpad-<target>[-<RK_LABEL>].txt`（不進 repo，內容只有數字）。結束碼 4 劃線沒跑完、5 SSH 失敗、6 接收端沒有時序行 |
| `timing_report.py` | 從標準輸入讀接收端時序行（每筆一次劃線），依事件名彙整：直方圖各桶加總、各桶占比與近似 p50／p90／p99（桶上限）、以 `_us` 結尾的欄位取各次劃線的中位數與最大值、其他整數欄位加總。只用 Python 標準函式庫；`--from/--to/--offset-s/--grace-s` 限定時間窗，`--print-lines` 只印保留的行。測試：`python3 -m unittest e2e/scripts/test_timing_report.py` |
| `iOS/RemoteKeyboardUITests/TrackpadSmokeUITests.swift` | `testFixedStrokes`：開 Remote Keyboard、開觸控板、等 `ready` 後，在板面正中高度左右來回劃 N 次（環境變數 `RK_STROKE_COUNT`，預設 20；以 `TEST_RUNNER_` 前綴傳入），速度輪流 slow／default／fast，每次間隔 0.8 秒；不點擊、不捲動。只印 `RKTP strokes=<N> start=<UTC> end=<UTC>` |
| `iOS/RemoteKeyboardUITests/RemoteTypingUITests.swift` | 在 iPhone 備忘錄新增一則備忘錄，用 Remote Keyboard 打 `hello world`（含一次 Backspace）與換行，送到目前的電腦 |
| `iOS/RemoteKeyboardUITests/PairingUITests.swift` | `testPairNewComputer` 在 iPhone 上新增電腦並按確認、完成；`testSelectComputer` 切換目前電腦 |

## 執行方式

Windows：OpenSSH 工作階段沒有桌面，要用排程工作加 `/IT` 在使用者桌面執行。

    schtasks /Create /TN rkpair /SC ONCE /ST 00:00 /IT /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<user>\win-confirm-pairing.ps1 -TimeoutSeconds 120 -ResultPath C:\Users\<user>\pair.txt -AnyCode"
    schtasks /Run /TN rkpair

結果在 `-ResultPath`（`sas=` 與 `answer=`）。腳本只用 ASCII，避免 Windows PowerShell 5.1 誤讀編碼。

Linux：用 `systemd-run --user` 帶桌面環境，不用 sudo。

    systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 \
      /path/linux-confirm-pairing.sh 120 /tmp/pair.txt --any

首次執行時若無障礙功能未開，腳本會只在這個登入期間開啟（`org.a11y.Status IsEnabled`）。這之後才開啟的 zenity 才看得到，所以要先執行腳本，再在接收端按「配對新手機」。

iPhone（實機，需藍牙權限；不在模擬器）：

    xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
      -destination 'id=<UDID>' -only-testing:RemoteKeyboardUITests/PairingUITests/testPairNewComputer \
      TEST_RUNNER_RK_EXPECT_HOST=<電腦名稱>
    # 切換電腦：-only-testing:.../testSelectComputer TEST_RUNNER_RK_SELECT_HOST=<電腦名稱>

輸出含一行 `RKPAIR sas=<數字> host=<名稱>`，可與接收端腳本的結果檔比對。
