# e2e 腳本

測試時用來配對 iPhone 與接收端、切換目前電腦的輔助工具。

| 檔案 | 作用 |
|---|---|
| `win-confirm-pairing.ps1` | 等 Windows 接收端的配對視窗（標題 Remote Keyboard），把 6 位數寫入結果檔，按「是」。必須明確指定 `-ExpectSas <6 位數>`（不符時按「否」）或 `-AnyCode`，兩者都沒有就報錯；只處理有「是」「否」兩個按鈕、且只含一組獨立 6 位數的 Remote Keyboard 訊息視窗。結束碼：0 是、3 否、2 逾時沒視窗、1 錯誤 |
| `win-focus-target.ps1` | 在 Notepad 開一個專用的空白測試檔 `type-target.txt`（`-File` 檔名不是它就拒絕），帶到最前面，前景視窗標題必須剛好是 `type-target.txt - 記事本` 或 `- Notepad` 才寫 `focus=True`；結果檔只有 `focus=True／False`，不記錄任何標題。**任何 Windows 打字測試之前一定先跑，`focus=True` 才繼續** |
| `win-read-target.ps1` | 只在恰好一個 Notepad 視窗的標題剛好是 `type-target.txt - 記事本`／`- Notepad`、選取的分頁是 `type-target.txt`、讀完後標題與分頁沒變時才寫出內容；否則結果檔寫 `refused`、結束碼 2 |
| `linux-confirm-pairing.sh` | 經 AT-SPI 找 zenity 配對視窗，行為同上；三個參數都要給：`<逾時秒數> <結果檔> <6 位數或 --any>`。只處理同時有「相符」「不相符」按鈕、且只含一組獨立 6 位數的視窗。結束碼 0、3、2、4（AT-SPI 不能用或找不到按鈕）、1（參數錯誤） |
| `measure-reconnect.sh` | `measure-reconnect.sh <win\|linux> [N]`：在 Mac 上跑 iPhone 的 `ReconnectUITests`（叫出／收起鍵盤 N 次，預設 100），再經 SSH 在接收端跑 `rk-diag stats --since <開始時間>`，把 iPhone 的 RKTIMING 與接收端統計存到 `e2e/results/<日期>-<target>.txt`（不進 repo）。開始前先經 SSH 讀接收端的 UTC 時鐘，自動修正兩台電腦的時間差；接收端連線數不到 N 的一半時以結束碼 6 警告。接收端要先裝好 `rk-diag`（Windows `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe`，Linux `~/.local/bin/rk-diag`；建置與複製見 `docs/troubleshooting-receiver.md`）。次數用環境變數 `TEST_RUNNER_RK_REOPEN_COUNT` 傳入，寫在 `xcodebuild` 指令前面；放在指令尾端只會變成 build setting，測試讀不到而跑預設 100 次。腳本會核對實際跑的次數 |
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
