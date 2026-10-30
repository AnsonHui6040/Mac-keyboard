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
| 字母與空白 | TextEdit 顯示與輸入一致 | TBD |
| 倒退 5 次 | 刪除 5 個字元 | TBD |
| return | 換行一次 | TBD |
| 狀態列 | 每個鍵之後顯示 `Mac 已輸入` | TBD |

結果：TBD

### 2. 3,000 字元 TEXT
1. 清空 TextEdit 文件，游標停在文件內。
2. 確認狀態列為 `Mac → TextEdit (N ms)`。
3. 在 iPhone 鍵盤長按 `return` 2 秒後放開。

| 項目 | 預期 | 結果 |
|---|---|---|
| 放開後 TextEdit 是否多出換行 | 沒有（長按只觸發測試入口，不送 return） | TBD |
| TextEdit 收到的字數 | 3,000（TextEdit 選單：格式 › 顯示字數，或全選後看字數統計） | TBD |
| 內容 | 「一二三四五六七八九十ABCDEFGHIJ」連續 150 次，沒有缺字、重複、亂序 | TBD |
| 輸入完成後狀態列 | 顯示 `Mac 已輸入` | TBD |
| 輸入完成後再打一個字母 | 仍然正常輸入（連線與重組狀態沒有卡住） | TBD |

結果：TBD

### 3. 長按後的中斷
1. 長按 `return` 2 秒送出 3,000 字元，在 TextEdit 還在輸入時收起鍵盤。
2. 等 10 秒後重新叫出鍵盤，狀態列回到 `Mac → TextEdit (N ms)`。
3. 輸入 `ok`。

| 項目 | 預期 | 結果 |
|---|---|---|
| 重新連線後輸入 `ok` | TextEdit 收到 `ok`，沒有殘留的上一則訊息片段 | TBD |

結果：TBD

### 4. Log 檢查
在 Mac 終端機執行：

```bash
log show --last 5m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -E "frame rejected|event kind"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| `event kind=text length=6000` | 步驟 2 出現一行，`ack=posted` | TBD |
| `frame rejected` | 步驟 1、2 沒有出現；步驟 3 若出現，只含種類與 bytes 長度 | TBD |
| log 內是否有輸入的文字內容 | 沒有 | TBD |

結果：TBD
