# E2E-T06-RECONNECT：鍵盤重開 100 次重連 Gate 真機驗收

執行者：使用者（自動測試由主代理從 Mac 啟動，使用者負責準備與抽查）。全部為 PASS 才算 T06 通過。

通過標準：100 次中至少 99 次 connected，P95 ≤ 2000 ms（Mac 醒著、同一房間）。未達標不得宣稱「任何 App 叫出鍵盤即可連線」；先調整掃描與逾時，必要時依 D8 評估 LAN。

前置條件：
- iPhone 以線連接 Mac 並解鎖，已安裝最新 Remote Keyboard（主 App 頂部 build 時間與主代理告知的一致），已開啟「允許完整取用」。
- Mac 執行最新 MacReceiver（面板頂部 build 時間一致），已按「開始接收」，30 分鐘內完成測試。
- Notes 有一則可輸入的備忘錄；Safari 可開啟。
- 測試前刪除舊紀錄：`rm -f ~/Library/Logs/RemoteKeyboard/reconnect.csv`

狀態列：本機模式顯示 `BLE: connected (N ms)`；遠端模式顯示 `Mac → TextEdit (N ms)`。N 即本次連線時間。

Notes 準備：開始前讓 Notes 停在備忘錄列表或關閉 Notes；自動測試會新建一則空白備忘錄並只在其中點擊，不會打字，也不會碰其他備忘錄。Safari 只點網址列。

紀錄來源：
- 自動測試（步驟 1）：以 UI test 附在 xcresult 的 `reconnect-ui.csv` 為準，每次重開一行，含成功或逾時；暖身（新建備忘錄、選鍵盤、Safari 網址列一次）不計入。Mac 的 `reconnect.csv` 只作交叉核對，因為暖身的連線也會寫入。
- 手動測試（步驟 2）：開始前刪除 `reconnect.csv`，不做暖身，直接數 100 次；每次連上後 iPhone 送一個 ping，Mac 寫一行 `shownAtMs,connectedAtMs,latencyMs`（只有數字，沒有文字）。失敗次數 = 100 − CSV 行數。

## 步驟

### 1. 自動 100 次（O6）
主代理執行：

```bash
xcodebuild test -project RemoteKeyboard.xcodeproj -scheme RemoteKeyboardApp -only-testing:RemoteKeyboardUITests/ReconnectUITests -destination "platform=iOS,id=00008150-000C65DA26C0401C" -allowProvisioningUpdates -resultBundlePath /private/tmp/claude-501/t06-uitests.xcresult
```

測試期間不要碰 iPhone。若結果為 `XCTSkip("O6: third-party keyboard not reachable")`，O6 FAIL，改做步驟 2。

| 項目 | 結果 |
|---|---|
| O6：XCUITest 能否讀到鍵盤 `rk.status` | TBD |
| `reconnect-ui.csv` 成功次數 / 100 | TBD |
| P95（ms） | TBD |

結果：TBD

### 2. 手動 100 次（僅 O6 FAIL 時）
Notes 與 Safari 交替：點文字欄位叫出鍵盤，等狀態列顯示 `BLE: connected (N ms)`，收起鍵盤。共 100 次。

| CSV 行數 / 100 | P95（ms） |
|---|---|
| TBD | TBD |

結果：TBD

### 3. 抽查 10 次（錄影）
記錄每次狀態列的 `BLE: connected (N ms)`。

| 次 | N（ms） |
|---|---|
| 1–10 | TBD |

結果：TBD

### 4. 異常情境各 5 次
每項做完後叫出鍵盤，確認 10 秒內回到 `BLE: connected`。

| 情境 | 成功次數 / 5 |
|---|---|
| iPhone 藍牙關再開 | TBD |
| Mac 藍牙關再開 | TBD |
| Mac 睡眠 1 分鐘後喚醒（喚醒後按「開始接收」或點輸入框） | TBD |
| 鍵盤顯示中強制關閉 host App（Notes） | TBD |

結果：TBD
