# E2E-T08-ACK：ACK、去重、排序與失敗語義真機驗收

執行者：使用者。全部為 PASS 才算 T08 通過；在使用者親手測完之前，所有結果維持 TBD。

通過標準：
- 連續打字約 3 分鐘，字母、空白、倒退、return 與 T07 行為相同，沒有漏字、重複或亂序，狀態列也沒有出現不該出現的錯誤提示。
- 打字途中關閉 iPhone 藍牙，狀態列出現「N 個按鍵未確認是否送達」；藍牙恢復並重新連線後，沒有任何按鍵被自動補送。
- Mac 的 log 中，ACK 只以代碼名稱出現（例如 `posted`、`pong`），沒有任何輸入的文字內容。

前置條件：
- iPhone 以線連接 Mac 並解鎖，已用 Xcode 安裝本分支的 Remote Keyboard，並已開啟「允許完整取用」。
- 主 App 頂部 build 時間與主代理告知的一致。
- Mac 執行本分支的 MacReceiver（面板頂部 build 時間一致），已按「開始接收」，30 分鐘內完成測試。
- Mac 開啟 TextEdit，新建一份純文字文件並讓游標停在文件內。
- 鍵盤切到遠端模式，狀態列顯示 `Mac → TextEdit (N ms)`。

本任務新增的狀態列提示（供對照）：

| 情況 | 狀態列提示 |
|---|---|
| Mac 已打出該鍵 | `Mac 已輸入` |
| Mac 打字時某個步驟失敗 | `Mac 輸入失敗` |
| 事件順序比已處理的舊 | `順序錯誤，未輸入` |
| 連線中斷時仍有按鍵沒收到回覆 | `N 個按鍵未確認是否送達` |
| 延遲測量（ping）的回覆 | 不顯示任何提示 |

「順序錯誤」與「Mac 輸入失敗」在正常打字時不應出現，也不容易人為觸發；它們由自動測試覆蓋，這裡只確認正常使用時不會誤報。

## 步驟

### 1. 一般打字回歸（約 3 分鐘）
1. 清空 TextEdit 文件，確認狀態列為 `Mac → TextEdit (N ms)`。
2. 以 iPhone 鍵盤連續打字約 3 分鐘：英文句子、空白、倒退、return 各自穿插，速度可忽快忽慢，中間至少有 3 次連續快速點按 10 個以上的鍵。
3. 結束時記下 TextEdit 的內容，並與自己輸入的內容逐項對照。

| 項目 | 預期 | 結果 |
|---|---|---|
| 字母與空白 | TextEdit 顯示與輸入一致，沒有漏字、重複、亂序 | PASS（2026-10-30） |
| 倒退與 return | 每次只刪一個字元、換行一次 | PASS（2026-10-30） |
| 狀態列提示 | 每個鍵之後顯示 `Mac 已輸入`；全程沒有出現 `Mac 輸入失敗`、`順序錯誤，未輸入`、`Mac 無法處理` | PASS（2026-10-30） |
| 延遲測量回覆 | 剛連線時沒有因為 ping 的回覆而出現額外提示 | PASS（2026-10-30） |
| 完整連線後狀態列 | 仍為 `Mac → TextEdit (N ms)`，沒有卡在中斷狀態 | PASS（2026-10-30） |

結果：PASS（使用者 2026-10-30 實測；未確認提示一列交由自動測試確認）

### 2. 打字途中關閉 iPhone 藍牙
1. 在 TextEdit 先打 `before`，確認它完整出現且狀態列顯示 `Mac 已輸入`。
2. 從 iPhone 螢幕右上角往下滑開啟控制中心，備好藍牙開關的位置。
3. 一邊用鍵盤連續快速點按字母（例如 `abcdefgh`），一邊按下控制中心的藍牙開關，把藍牙關掉。
4. 觀察鍵盤狀態列，約 2 秒內截圖或記下文字。若沒有出現 `N 個按鍵未確認是否送達`（代表中斷前的按鍵都已收到回覆），重複步驟 3；至少要有一次出現。
5. 記下當下 TextEdit 的內容（以 Command-A、Command-C 後在終端機執行 `pbpaste | LC_ALL=en_US.UTF-8 wc -m`，記錄字元數 A）。
6. 重新開啟藍牙，等狀態列回到 `Mac → TextEdit (N ms)`，之後什麼都不要按，等待 30 秒。
7. 再次全選拷貝，執行同一個指令，記錄字元數 B。
8. 輸入 `ok`，確認它出現，再次計算字元數 C。

| 項目 | 預期 | 結果 |
|---|---|---|
| 狀態列提示 | 出現 `N 個按鍵未確認是否送達`，N 為 1 以上的整數；約 2 秒後消失 | 未能實機觸發（2026-10-30）：Mac 約數十 ms 內即回覆 ACK，手動關藍牙無法在按鍵仍未確認時中斷；使用者判定此列交由自動測試確認。覆蓋：`EventSenderTests.testLinkLostReportsPendingAndNeverResends`、`StatusLineTests.testUnconfirmedText` |
| 提示後的畫面 | 沒有出現 `Mac 已輸入` 以外的錯誤文字；鍵盤沒有當掉 | PASS（2026-10-30） |
| 重新連線後不補送 | 字元數 B 等於字元數 A（重新連線與等待 30 秒期間 TextEdit 沒有多出任何字元） | PASS（2026-10-30：A = B = 198） |
| 之後可正常輸入 | 輸入 `ok` 後 TextEdit 只多出 `ok`，字元數 C 等於 B 加 2，狀態列顯示 `Mac 已輸入` | PASS（2026-10-30：`ok` 正常出現；字元數 C 未記錄） |
| 未確認的按鍵 | 提示中的 N 個按鍵可能已打出，也可能沒有；這正是「未確認」的意思，不算失敗。記錄 TextEdit 實際多出幾個字元供參考：TBD | 說明列，不判定 |

結果：PASS（使用者 2026-10-30 實測；未確認提示一列交由自動測試確認）

### 3. Mac log 檢查
在 Mac 終端機執行（時間範圍涵蓋步驟 1、2）：

```bash
log show --last 15m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep "event kind" | grep -oE "ack=[A-Za-z]+" | sort | uniq -c
```

再執行下面兩個指令，確認重新連線之後沒有事件被重送，以及 log 沒有輸入內容（第二個指令搜尋的字串請換成自己在步驟 1 實際輸入過的幾個英文單字）：

```bash
log show --last 15m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -E "event kind|state ready" | tail -20
log show --last 15m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -cE "before|abcdefgh|hello|world"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| ACK 只以代碼名稱出現 | 第一個指令的輸出只包含 `ack=posted`、`ack=pong`（以及 `ack=staleFocus` 等代碼名稱），每個代碼名稱後面沒有任何文字內容 | PASS（2026-10-30：只有 `ack=posted`、`ack=pong`，見 `docs/superpowers/verification/evidence/T08-mac-log-summary.txt`） |
| 正常打字的 ACK | 步驟 1 的按鍵皆為 `ack=posted`；沒有 `ack=injectFailed`、`ack=outOfOrder`、`ack=malformed` | PASS（2026-10-30：207 個文字、16 個倒退、7 個 return 皆 `ack=posted`；0 個 injectFailed／outOfOrder／malformed） |
| 延遲測量 | 每次鍵盤出現後的連線有一行 `kind=ping ... ack=pong` | PASS（2026-10-30：10 次 `kind=ping ... ack=pong`） |
| 重新連線後沒有補送 | 第二個指令中，最後一次 `state ready` 之後，第一行 `event kind` 是步驟 2 輸入 `ok` 之後的事件（`ping` 之外只有 `ok` 的兩個字母） | PASS（2026-10-30：每次重新 ready 後第一行皆為 ping，之後才是使用者新打的字） |
| log 內是否有輸入的文字內容 | 第三個指令輸出 0 | PASS（2026-10-30：0） |

結果：PASS（使用者 2026-10-30 實測；未確認提示一列交由自動測試確認）

### 備註
- 10,000 個事件的受控測試併入 T15，這裡不測。
- 重複事件（同一個 `eventId` 重送）與順序錯誤在 App 正常使用時不會發生，由自動測試覆蓋（`EventDeduplicatorTests`、`EventPipelineTests`）。
