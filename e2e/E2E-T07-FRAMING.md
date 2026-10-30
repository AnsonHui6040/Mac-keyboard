# E2E-T07-FRAMING：協定分幀與事件信封真機驗收

執行者：使用者。全部為 PASS 才算 T07 通過；在使用者親手測完之前，所有結果維持 TBD。

通過標準：
- 一般打字（字母、空白、倒退、return）與 T05 行為相同，沒有因為分幀而漏字、重複或亂序。
- 由 iPhone 送出一則 3,000 字元的 `TEXT`，TextEdit 收到的字數與送出的完全一致。
- 過程中 Mac 與 iPhone 的 log 只有事件種類、長度、代碼與時間，沒有任何輸入的文字內容。

前置條件：
- iPhone 以線連接 Mac 並解鎖，已用 Xcode 以 Debug 設定安裝本分支的 Remote Keyboard（長按 `return` 的測試入口只存在於 Debug build，Release build 沒有），並已開啟「允許完整取用」。
- 主 App 頂部 build 時間與主代理告知的一致。
- Mac 執行本分支的 MacReceiver（面板頂部 build 時間一致），已按「開始接收」，30 分鐘內完成測試。
- Mac 開啟 TextEdit，新建一份純文字文件並讓游標停在文件內。已知會在 TextEdit 的輸入法為注音時由 Receiver 自動切換為 ASCII 再還原，不需要手動切換。
- 鍵盤切到遠端模式，狀態列顯示 `Mac → TextEdit (N ms)`。

字數計算：3,000 字元的內容為「一二三四五六七八九十ABCDEFGHIJ」（20 字元）連續重複 150 次，UTF-8 共 6,000 bytes，在 iPhone 預設的 182 bytes 通知長度下約為 35 個 frame。

## 步驟

### 1. 一般打字回歸
在 TextEdit 以 iPhone 鍵盤依序輸入：`hello world`、倒退 5 次、`Ab`、return，各種鍵至少各一次。

| 項目 | 預期 | 結果 |
|---|---|---|
| 字母與空白 | TextEdit 顯示與輸入一致 | PASS（2026-10-30） |
| 倒退 5 次 | 刪除 5 個字元 | PASS（2026-10-30） |
| return | 換行一次 | PASS（2026-10-30） |
| 狀態列 | 每個鍵之後顯示 `Mac 已輸入` | PASS（2026-10-30） |

結果：PASS（使用者 2026-10-30 實測）

### 2. 3,000 字元 TEXT
1. 清空 TextEdit 文件（純文字格式），游標停在文件內。
2. 確認狀態列為 `Mac → TextEdit (N ms)`。
3. 在 iPhone 鍵盤長按 `return` 2 秒後放開（要在 4 秒內放開，否則會改為啟動 T15 的 burst），等狀態列顯示 `Mac 已輸入`。
4. 在 TextEdit 按 Command-A、Command-C，再到終端機執行下列三個指令（字數指令已指定 UTF-8 語系，不受終端機設定影響）。

```bash
pbpaste | LC_ALL=en_US.UTF-8 wc -m
pbpaste | shasum
printf '一二三四五六七八九十ABCDEFGHIJ%.0s' {1..150} | shasum
```

第一行必須輸出 3000；第二、三行的雜湊值必須相同。第三行是 DEBUG 長按入口實際送出的字串（`KeyboardViewController.sendDebugLongText()` 的 `"一二三四五六七八九十ABCDEFGHIJ"` 重複 150 次），在 zsh 下執行。

| 項目 | 預期 | 結果 |
|---|---|---|
| 放開後 TextEdit 是否多出換行 | 沒有（長按只觸發測試入口，不送 return） | PASS（2026-10-30：全選內容雜湊與預期字串完全相同，沒有多出換行） |
| TextEdit 收到的字數 | 全選後拷貝，在終端機執行 `pbpaste \| LC_ALL=en_US.UTF-8 wc -m`，輸出 3000 | PASS（2026-10-30：輸出 3000） |
| 內容 | `pbpaste \| shasum` 的雜湊值與上方第三行指令（預期字串）的 `shasum` 相同（`cfb204f94b4a99c3fe749628cd74c6fe23b53063`），即沒有缺字、重複、亂序 | PASS（2026-10-30：兩者皆為 `cfb204f94b4a99c3fe749628cd74c6fe23b53063`） |
| 輸入完成後狀態列 | 顯示 `Mac 已輸入` | PASS（2026-10-30） |
| 輸入完成後再打一個字母 | 仍然正常輸入（連線與重組狀態沒有卡住） | PASS（2026-10-30） |

結果：PASS（使用者 2026-10-30 實測）

### 3. 長按後的中斷
1. 長按 `return` 2 秒送出 3,000 字元，在 TextEdit 還在輸入時收起鍵盤。
2. 等 10 秒後重新叫出鍵盤，狀態列回到 `Mac → TextEdit (N ms)`。
3. 輸入 `ok`。

| 項目 | 預期 | 結果 |
|---|---|---|
| 重新連線後輸入 `ok` | TextEdit 收到 `ok`，沒有殘留的上一則訊息片段 | PASS（2026-10-30） |

結果：PASS（使用者 2026-10-30 實測）

### 4. Log 檢查
在 Mac 終端機執行：

```bash
log show --last 5m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -E "frame rejected|partial message dropped|event kind"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| `event kind=text length=6000` | 步驟 2 出現一行，`ack=posted` | PASS（2026-10-30：2 行，皆 `ack=posted`；第 2 行為步驟 3，訊息在收起鍵盤前已完整送達，Mac 照常輸入完畢） |
| `frame rejected`、`partial message dropped` | 步驟 1、2 沒有出現；步驟 3 若出現，只含種類、次數與 bytes 長度 | PASS（2026-10-30：0 次；步驟 3 未觸發殘片丟棄，因 35 個 frame 在收起鍵盤前已送完） |
| log 內是否有輸入的文字內容 | 沒有 | PASS（2026-10-30：搜尋 hello、world、一二三、ABCDEFGHIJ、ok 皆 0 筆，見 `docs/superpowers/verification/evidence/T07-mac-log-summary.txt`） |

結果：PASS（使用者 2026-10-30 實測）
