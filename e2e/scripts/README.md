# e2e 腳本

測試時用來配對 iPhone 與接收端、切換目前電腦的輔助工具。

| 檔案 | 作用 |
|---|---|
| `win-confirm-pairing.ps1` | 等 Windows 接收端的配對視窗（標題 Remote Keyboard），把 6 位數寫入結果檔，按「是」。必須明確指定 `-ExpectSas <6 位數>`（不符時按「否」）或 `-AnyCode`，兩者都沒有就報錯；只處理有「是」「否」兩個按鈕、且只含一組獨立 6 位數的 Remote Keyboard 訊息視窗。結束碼：0 是、3 否、2 逾時沒視窗、1 錯誤 |
| `win-focus-target.ps1` | 在 Notepad 開一個專用的空白測試檔 `type-target.txt`（`-File` 檔名不是它就拒絕），帶到最前面，前景視窗標題必須剛好是 `type-target.txt - 記事本` 或 `- Notepad` 才寫 `focus=True`；結果檔只有 `focus=True／False`，不記錄任何標題。加 `-KeepContent` 時不清空檔案、也不開新的 Notepad：只把已開著且標題相符的視窗帶到最前面再檢查，沒有這個視窗就寫 `focus=False`。**任何 Windows 打字測試之前一定先跑，`focus=True` 才繼續** |
| `win-read-target.ps1` | 只在恰好一個 Notepad 視窗的標題剛好是 `type-target.txt - 記事本`／`- Notepad`、選取的分頁是 `type-target.txt`、讀完後標題與分頁沒變時才寫出內容；否則結果檔寫 `refused`、結束碼 2 |
| `linux-confirm-pairing.sh` | 經 AT-SPI 找 zenity 配對視窗，行為同上；三個參數都要給：`<逾時秒數> <結果檔> <6 位數或 --any>`。只處理同時有「相符」「不相符」按鈕、且只含一組獨立 6 位數的視窗。結束碼 0、3、2、4（AT-SPI 不能用或找不到按鈕）、1（參數錯誤） |
| `measure-reconnect.sh` | `measure-reconnect.sh <win\|linux> [N]`：在 Mac 上跑 iPhone 的 `ReconnectUITests`（叫出／收起鍵盤 N 次，預設 100），再經 SSH 在接收端跑 `rk-diag stats --since <開始時間>`，把 iPhone 的 RKTIMING 與接收端統計存到 `e2e/results/<日期>-<target>.txt`（不進 repo）。開始前先經 SSH 讀接收端的 UTC 時鐘，自動修正兩台電腦的時間差；接收端連線數不到 N 的一半時以結束碼 6 警告。接收端要先裝好 `rk-diag`（Windows `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe`，Linux `~/.local/bin/rk-diag`；建置與複製見 `docs/troubleshooting-receiver.md`）。次數用環境變數 `TEST_RUNNER_RK_REOPEN_COUNT` 傳入，寫在 `xcodebuild` 指令前面；放在指令尾端只會變成 build setting，測試讀不到而跑預設 100 次。腳本會核對實際跑的次數 |
| `measure-trackpad.sh` | `measure-trackpad.sh <win\|linux\|mac> [N]`：一個指令、不用手動操作量測觸控板時序（N 為劃線次數，預設 20）。先經 SSH 讀接收端 UTC 時鐘並修正時間差；結束 Mac 接收端 App（避免搶 iPhone 的連線），不論成功或失敗離開時都會重新開啟；用 `PairingUITests/testSelectComputer` 切到目標電腦（名稱取自 `RK_HOST_NAME`，linux 預設 `Linux`，win 必填）；再跑 `TrackpadSmokeUITests/testFixedStrokes`；等 2 秒後經 SSH 取接收端記錄中的 `pointer_timing*`、`ble_rx_timing`、`portal_motion_timing` 行，只留測試時間窗內的，交給 `timing_report.py` 彙整，存到 `e2e/results/<日期>-trackpad-<target>[-<RK_LABEL>].txt`（不進 repo，內容只有數字）。環境變數 `RK_WIFI_POINTER=on|off`：先跑 `WifiPointerSettingUITests/testSetWifiPointer` 設定 App 內「經 Wi-Fi 傳送游標」（並自動允許區域網路提示），on 時劃線前最多等 5 秒讓觸控板顯示 Wi-Fi；結果檔標頭記錄 `RKWIFI` 行與 `path_start`／`path_end`，`ble=`／`udp=` 計數會加總。結束碼 4 劃線沒跑完、5 SSH 失敗、6 接收端沒有時序行。`mac` 目標：量測這台 Mac 自己的接收端，不結束接收端 App、不用 SSH；電腦名稱預設 `scutil --get ComputerName`（可用 `RK_HOST_NAME` 覆寫）；結束後用 `/usr/bin/log show --info --start <選擇電腦步驟開始前的時間> --end <結束時間 + 10 秒>`（subsystem `com.ansonhui.remotekeyboard.receiver`、category `pointer`）讀接收端每 5 秒一組的 `pointer diag`／`pointer link` 行（連線期間有活動才寫），只留這兩種與 `pointer open`／`pointer closed`（只有數字），交給 `mac_pointer_report.py` 對每個欄位彙整行數、中位數與最大值 |
| `mac_pointer_report.py` | 從標準輸入讀 `log show --style compact` 的輸出：`--print-lines` 只印保留的 `pointer diag`／`link`／`open`／`closed` 行（去掉程序前綴，只留數字欄位）；不加參數則對 stalled、longest、squeezes、cb50、cb95、margin10、margin50、gain50、gain90、starve、starve95、starvemax、lag、jit、rate、p50、p95、interval、backlog 各印行數、中位數、最大值。只用 Python 標準函式庫。測試：`python3 -m unittest e2e/scripts/test_mac_pointer_report.py` |
| `timing_report.py` | 從標準輸入讀接收端時序行（每筆一次劃線），依事件名彙整：直方圖各桶加總、各桶占比與近似 p50／p90／p99（桶上限）、以 `_us` 結尾的欄位取各次劃線的中位數與最大值、其他整數欄位加總。只用 Python 標準函式庫；`--from/--to/--offset-s/--grace-s` 限定時間窗，`--print-lines` 只印保留的行。測試：`python3 -m unittest e2e/scripts/test_timing_report.py` |
| `linux-type-target.py` | Linux 打字測試用的視窗：標題 `rk-type-target`、一個多行文字框，每次內容變動就重寫 `/tmp/rk-wl11/target.txt`（資料夾權限 0700）。`--check-focus <結果檔>`：經 AT-SPI 只在「目前作用中的視窗恰好一個、標題剛好是 `rk-type-target`」時寫 `focus=True`，否則 `focus=False`，不記錄其他標題。所有輸出路徑都必須在 `/tmp/rk-wl11/` 內，否則拒絕。結束碼 0、1（參數或路徑錯誤）、2（AT-SPI 不能用）。測試：`python3 -m unittest e2e/scripts/test_linux_type_target.py`。第二種目標 GNOME Text Editor（專用檔 `/tmp/rk-wl11/rk-editor-target.txt`，由外部以 `gnome-text-editor --standalone` 開啟）：`--editor-check-focus <結果檔>` 只在作用中的視窗恰好一個、屬於 Text Editor、標題是 `rk-editor-target.txt (/tmp/rk-wl11)`（前面最多一個修改標記 `•` 或 `*` 加一個空格；後面可接 `―`、` - ` 或 ` — ` 加非空的應用程式名稱，實機 zh_TW 為 `…(/tmp/rk-wl11)―文字編輯器`）時寫 `focus=True`；`--editor-read <輸出檔>` 經 AT-SPI 讀該視窗唯一的多行文字框，不是恰好一個同名視窗與一個文字框就寫 `refused`（結束碼 3），輸出檔必須在 `/tmp/rk-wl11/` 內。標題格式已用 AT-SPI 在 zh_TW 實機核對 |
| `rotate-hosts.sh` | `rotate-hosts.sh [輪數]`：在 Mac 上一個指令、不用手動操作，輪流（奇數輪 Windows、偶數輪 Linux，預設 20 輪）用鍵盤頂端的電腦名稱格切換電腦、量測切換時間並打一個測試字串（`wl11r<輪數>`）。`RK_IPHONE_UDID` 必填；先 build-for-testing 一次，經 SSH 讀兩台接收端的 UTC 時鐘，Windows 以排程工作（`/IT`，用 `conhost.exe --headless powershell.exe` 啟動，避免 Windows 11 開出搶走焦點的終端機視窗）先不加 `-KeepContent` 跑一次 `win-focus-target.ps1`（空白檔與 Notepad），之後每輪都加 `-KeepContent`，Linux 以 `systemd-run --user` 開 `linux-type-target.py`。開始前先讀一次兩台測試檔的文字當基準（只讀 type-target.txt 分頁，內容不印出，報告只記長度）；每輪打字前和打字後，兩台電腦（目標與另一台）都必須回報 `focus=True`，打字後失敗記為 `focus_lost` 並以結束碼 7 中止，不打字或打完後失焦都不再繼續；全部跑完後各讀回一次文字，必須以基準開頭，其後恰好是自己那幾輪的字串（一行一個、依序、沒有其他內容），並取接收端 `rk-diag stats` 的連線數。切換經過 Mac 時不會打字，Mac 接收端不會被關閉。結果存到 `e2e/results/<日期>-rotation.txt`（不進 repo，只有數字與 PASS／FAIL）。結束碼 0 通過、2 用法、3 環境、4 UI 測試失敗、5 SSH 失敗、6 字串不符、7 沒有焦點。用 `bash -n` 檢查語法 |
| `linux-burst.sh` | `linux-burst.sh [COUNT] [gtk\|editor]`：在 Mac 上一個指令、不用手動操作，連打 COUNT 個字串（`b1` Return、`b2` Return…，預設 50、1..200）到 Linux，區分掉字原因：A 是打字途中連線中斷（UI test 在某個鍵之前看到狀態不是 `connected`，即 `RKBURST_GAP`），B? 是每個鍵都在已連線時送出、字串卻沒進目標視窗。`RK_IPHONE_UDID` 必填；先 build-for-testing 一次，用 `PairingUITests/testSelectComputer` 選 Linux，在 Linux 開目標（gtk 同 `rotate-hosts.sh`；editor 建空檔 `/tmp/rk-wl11/rk-editor-target.txt` 並以 `systemd-run --user --unit rk-burst-editor` 開 `gnome-text-editor --standalone`），打字前必須 `focus=True`，讀接收端時鐘差，跑 `testTypeBurst`（前綴 `b`），打完再查一次焦點（失去焦點只記一筆仍讀回），讀回後依 RKBURST 起訖時間（加時鐘差、前後各 3 秒）統計接收端 log：`event_in` 的 text／enter 數、`inject` ok 與非 ok 數、`auth` ok 數、每一筆 `disconnected` 的時間與原因。報告逐個列出缺的字串與分類，存到 `e2e/results/<日期>-linux-burst-<target>.txt`（不進 repo，只有數字、原因與 `b<i>` 字串）；結束 trap 會停掉 `rk-wl11-target` 與 `rk-burst-editor`。結束碼 0 全部都在、2 用法、3 環境或 editor 讀回被拒、4 UI 測試失敗、5 SSH 失敗、6 有缺字串、7 打字前沒有焦點。用 `bash -n` 檢查語法 |
| `iOS/RemoteKeyboardUITests/HostRotationUITests.swift` | `testRotateAndType`：在備忘錄新增一則備忘錄、切到遠端模式，點電腦名稱格直到名稱等於 `RK_TARGET_HOST`（最多 6 次；目標已是目前電腦時仍會轉一整圈），量測最後一次點擊到 `rk.status` 值為 `connected` 的時間（逾時 20 秒失敗），再打 `RK_TOKEN`（只能是小寫英文字母與數字）與 Return。兩個環境變數以 `TEST_RUNNER_` 前綴傳入。只印 `RKROT host=<名稱> taps=<次數> switch_ms=<毫秒>`。每次點鍵（字母、數字、Return；換頁鍵不算）之前先讀 `rk.status` 並記錄，最後多印一行 `RKKEYS total=<n> notConnected=<n> firstNotConnectedAt=<索引或 -1>`，不含打的內容。另有 `testTypeBurst`：不輪替，`RK_TARGET_HOST` 必須已是目前電腦（否則失敗、不點任何東西），`RK_TOKEN_PREFIX`（只能小寫 a-z）與 `RK_COUNT`（1..200，預設 50）；強制「即時」、只清除自己前綴或 wl11r 的草稿殘留，打 `<前綴><i>` 加 Return（i 從 1 到 count），印 `RKBURST count=<n> keys=<n> notConnected=<n> start=<UTC ISO> end=<UTC ISO>`，以及每個有按鍵時狀態不是 `connected` 的字串一行 `RKBURST_GAP token=<i>` |
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
