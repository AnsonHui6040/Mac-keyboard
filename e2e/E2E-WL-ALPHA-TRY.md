# Windows／Linux 接收端 Alpha 試用清單

狀態欄：PASS／FAIL／TBD。實機項目全部 TBD，你親手試過才改。有問題時用系統匣「匯出診斷資料」，把 zip 給我。

## 已裝好的東西

| 裝置 | 位置 | 開機自動啟動 |
|---|---|---|
| Windows（TUF） | `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-receiver.exe` | 是（`HKCU\…\Run\RemoteKeyboard`） |
| Linux（Ubuntu） | `~/.local/bin/rk-receiver`，藍牙控制器 hci1 | 是（`~/.config/autostart/remote-keyboard.desktop`） |
| iPhone 17 Pro | Remote Keyboard（main 最新建置） | — |
| Mac | `/Applications/Remote Keyboard Receiver.app` | 照舊 |

## 配對

已配對的電腦不必再配對。要重新配對時：

1. 電腦：系統匣圖示 →「配對新手機」（120 秒內有效）。
2. iPhone：Remote Keyboard App →「已配對電腦」→「新增電腦」。
3. 兩邊的 6 位數相同時，電腦按「是」，iPhone 按「確認」再按「完成」。
4. Linux 第一次啟動時，螢幕會跳出「遠端桌面」授權視窗，按「允許」一次；之後重開機不會再問。

## 切換電腦

鍵盤頂端的電腦名稱格點一下，會輪到下一台。

## 要試的項目

| # | 項目 | Windows | Linux |
|---|---|---|---|
| 1 | 叫出鍵盤後幾秒內顯示「已連接」 | TBD | TBD |
| 2 | 英文、數字、符號 | TBD | TBD |
| 3 | 中文（手寫、快速輸入） | TBD | TBD |
| 4 | 表情符號 | TBD | TBD |
| 5 | Backspace、換行 | TBD | TBD |
| 6 | 語音聽寫的長句 | TBD | TBD |
| 7 | 觸控板：移動、點一下、按住拖曳、兩指捲動 | TBD | TBD |
| 8 | 系統匣：狀態、改名、刪除手機、觸控板開關、結束 | TBD | TBD |
| 9 | 重開機後自動啟動並可直接打字 | TBD | TBD |
| 10 | 瀏覽器、Office 類、終端機各試一次 | TBD | TBD |

## 已知限制

- Windows：以系統管理員身分執行的視窗、UAC 與鎖定畫面收不到輸入，而且不會顯示錯誤。第一次執行可能出現 SmartScreen 警告。
- Linux：中文與表情符號用貼上送出，剪貼簿會短暫被借用再還原；終端機要用 Ctrl+Shift+V，所以中文貼不進終端機；剪貼簿管理工具會留下紀錄。
- 兩者都沒有 Mac 的焦點與密碼欄保護：字會送到目前有焦點的視窗，等同一把實體鍵盤。
- 同一時間只有目前選定的電腦會連線；Mac Receiver 開著而鍵盤選的是 Mac 時，Windows 與 Linux 不會連。
