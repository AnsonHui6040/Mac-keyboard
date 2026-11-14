# e2e 腳本

測試時用來配對 iPhone 與接收端、切換目前電腦的輔助工具。

| 檔案 | 作用 |
|---|---|
| `win-confirm-pairing.ps1` | 等 Windows 接收端的配對視窗（標題 Remote Keyboard），把 6 位數寫入結果檔，按「是」。`-ExpectSas` 不符時按「否」。結束碼：0 是、3 否、2 逾時沒視窗、1 錯誤 |
| `linux-confirm-pairing.sh` | 經 AT-SPI 找 zenity 配對視窗，行為同上，結束碼 0、3、2、4（找不到按鈕） |
| `iOS/RemoteKeyboardUITests/PairingUITests.swift` | `testPairNewComputer` 在 iPhone 上新增電腦並按確認、完成；`testSelectComputer` 切換目前電腦 |

## 執行方式

Windows：OpenSSH 工作階段沒有桌面，要用排程工作加 `/IT` 在使用者桌面執行。

    schtasks /Create /TN rkpair /SC ONCE /ST 00:00 /IT /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<user>\win-confirm-pairing.ps1 -TimeoutSeconds 120 -ResultPath C:\Users\<user>\pair.txt"
    schtasks /Run /TN rkpair

結果在 `-ResultPath`（`sas=` 與 `answer=`）。腳本只用 ASCII，避免 Windows PowerShell 5.1 誤讀編碼。

Linux：用 `systemd-run --user` 帶桌面環境，不用 sudo。

    systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 \
      /path/linux-confirm-pairing.sh 120 /tmp/pair.txt

首次執行時若無障礙功能未開，腳本會只在這個登入期間開啟（`org.a11y.Status IsEnabled`）。這之後才開啟的 zenity 才看得到，所以要先執行腳本，再在接收端按「配對新手機」。

iPhone（實機，需藍牙權限；不在模擬器）：

    xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
      -destination 'id=<UDID>' -only-testing:RemoteKeyboardUITests/PairingUITests/testPairNewComputer \
      TEST_RUNNER_RK_EXPECT_HOST=<電腦名稱>
    # 切換電腦：-only-testing:.../testSelectComputer TEST_RUNNER_RK_SELECT_HOST=<電腦名稱>

輸出含一行 `RKPAIR sas=<數字> host=<名稱>`，可與接收端腳本的結果檔比對。
