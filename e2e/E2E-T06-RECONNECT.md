# E2E-T06-RECONNECT：鍵盤重開 100 次重連 Gate 真機驗收

執行者：使用者（自動測試由主代理從 Mac 啟動，使用者負責準備與抽查）。全部為 PASS 才算 T06 通過。

通過標準：100 次中至少 99 次 connected，P95 ≤ 2000 ms（Mac 醒著、同一房間）。P95 以「鍵盤出現 → connected」計（使用者 2026-10-30 決定）；XCUITest 的點擊動作本身耗時 0.7–1.8 秒，不屬產品延遲，只作參考。未達標不得宣稱「任何 App 叫出鍵盤即可連線」；先調整掃描與逾時，必要時依 D8 評估 LAN。

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
| 項目 | 第 1 輪（03:27–03:38） | 第 2 輪（04:16–04:28，分段計時） |
|---|---|---|
| O6：XCUITest 能否讀到鍵盤 `rk.status` | PASS | PASS |
| `reconnect-ui.csv` 成功次數 / 100 | 100 | 99（#54 Safari 點網址列後鍵盤未出現，Mac 無連線紀錄，非藍牙失敗） |
| 點擊 → connected P95（含 XCUITest 點擊耗時） | 2329 ms | 2370 ms |
| XCUITest 點擊動作耗時，中位數（Notes／Safari） | — | 696 ms／1813 ms |
| 鍵盤出現 → connected P95（Notes／Safari） | — | 389 ms／224 ms |
| iPhone 端計時（Mac CSV，扣除暖身）P95 | 647 ms | 710 ms |

前置：第一次執行因 Xcode 帳號只在圖形介面可用而無法建立 UI test 描述檔，由使用者在 Xcode 以 Product › Build For › Testing 建立一次；iPhone 為繁體中文，按鍵名稱以 `testProbeLabels` 讀取後改為中英文皆可比對（新增備忘錄、網址）。

結果：PASS（使用者 2026-10-30 依「鍵盤出現 → connected」判定）。證據：`docs/superpowers/verification/evidence/T06-run1-*.csv`、`T06-run2-*.csv`

### 2. 手動 100 次（僅 O6 FAIL 時）
Notes 與 Safari 交替：點文字欄位叫出鍵盤，等狀態列顯示 `BLE: connected (N ms)`，收起鍵盤。共 100 次。

| CSV 行數 / 100 | P95（ms） |
|---|---|
| 不需要 | 不需要 |

結果：不需要（O6 PASS，自動測試可用）

### 3. 抽查 10 次（錄影）
記錄每次狀態列的 `BLE: connected (N ms)`。

| 次 | N（ms） |
|---|---|
| 1–10 | 未記錄 |

結果：延至 T16 最後測試（使用者 2026-10-30 以自動測試分段數據判定）

### 4. 異常情境各 5 次
每項做完後叫出鍵盤，確認 10 秒內回到 `BLE: connected`。

| 情境 | 成功次數 / 5 |
|---|---|
| iPhone 藍牙關再開 | 5/5（重連 221–1040 ms） |
| Mac 藍牙關再開 | 5/5（5 次 `unavailable` 後皆在 10 秒內回到 ready；開始連線 → ready 2864–4461 ms，比一般重連慢，主要花在 Mac 藍牙剛開啟後的連線與 service 探索） |
| Mac 睡眠 1 分鐘後喚醒（喚醒後按「開始接收」或點輸入框） | 5/5（392–574 ms） |
| 鍵盤顯示中強制關閉 host App（Notes） | 5/5（319–557 ms） |

結果：PASS（使用者 2026-10-30 親手執行，Mac link log 佐證：`evidence/T06-abnormal-mac-link-log.txt`）
