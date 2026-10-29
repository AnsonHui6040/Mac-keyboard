# E2E-T03B-LINK：Mac Receiver BLE Central 真機驗收

執行者：使用者。每一步完成後填寫「結果」，全部為 PASS 才算 T03b 通過。

通過標準：Notes、Safari 各 10 次中 10 次進入 `BLE: connected` 與 `Link: ready`，且 host App 不在前景。若失敗，依 D8 啟動 LAN WebSocket 限時 PoC，暫停 UI 工作。

前置條件：iPhone 已安裝最新的 Remote Keyboard；Mac 已用 Xcode 建置並執行最新的 MacReceiver；兩台裝置藍牙皆開啟，Mac 已允許 MacReceiver 使用藍牙。

選單狀態對照（Mac 選單列）：

| 項目 | 顯示 |
|---|---|
| 連線狀態 | `Link: idle`、`Link: scanning`、`Link: connecting`、`Link: discovering`、`Link: ready (N ms)` |
| 接收時間 | 啟用中顯示「剩餘接收時間 mm:ss」，待命時顯示「待命」 |

## 步驟

### 1. 啟動 Receiver 並確認登入項目
1. 啟動 MacReceiver，選單列出現鍵盤圖示。
2. 開啟選單，確認「登入時啟動」已打勾；若出現「需在系統設定 › 登入項目 允許」，到 系統設定 › 一般 › 登入項目 允許後再開啟選單確認。
3. 確認選單顯示 `Link: idle` 與「待命」。
4. 按「開始接收」，確認顯示 `Link: scanning` 與「剩餘接收時間 30:00」附近的倒數。

結果：TBD

### 2. 強制關閉 host App
1. 在 iPhone 的 App 切換器中，把 Remote Keyboard 主 App 往上滑掉。
2. 之後的步驟都不要再開啟主 App。

結果：TBD

### 3. Notes 連線 10 次
1. 開啟 Notes 的輸入框，切換到 Remote Keyboard。
2. 記錄鍵盤狀態列是否為 `BLE: connected`，以及 Mac 是否為 `Link: ready (N ms)`，並記下 N。
3. 收起鍵盤後重複，共 10 次。

| 次 | 鍵盤 `BLE: connected` | Mac `Link: ready (N ms)` 的 N |
|---|---|---|
| 1 | TBD | TBD |
| 2 | TBD | TBD |
| 3 | TBD | TBD |
| 4 | TBD | TBD |
| 5 | TBD | TBD |
| 6 | TBD | TBD |
| 7 | TBD | TBD |
| 8 | TBD | TBD |
| 9 | TBD | TBD |
| 10 | TBD | TBD |

結果：TBD

### 4. Safari 連線 10 次
1. 開啟 Safari 的網址列或網頁輸入框，切換到 Remote Keyboard。
2. 與步驟 3 相同，記錄 10 次。

| 次 | 鍵盤 `BLE: connected` | Mac `Link: ready (N ms)` 的 N |
|---|---|---|
| 1 | TBD | TBD |
| 2 | TBD | TBD |
| 3 | TBD | TBD |
| 4 | TBD | TBD |
| 5 | TBD | TBD |
| 6 | TBD | TBD |
| 7 | TBD | TBD |
| 8 | TBD | TBD |
| 9 | TBD | TBD |
| 10 | TBD | TBD |

結果：TBD

### 5. 收起鍵盤後 Mac 回到掃描
1. 在 Notes 叫出鍵盤並確認 Mac 為 `Link: ready (N ms)`。
2. 收起鍵盤。
3. 確認 Mac 在數秒內回到 `Link: scanning`。

結果：TBD

### 6. 停止接收
1. 按「停止接收」。
2. 確認 Mac 顯示 `Link: idle` 與「待命」。
3. 在 iPhone 叫出鍵盤，確認鍵盤狀態列維持 `BLE: advertising`，沒有進入 `BLE: connected`。

結果：TBD

### 7. 閒置逾時
1. 在 Mac 終端機執行：`defaults write com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds 60`
2. 結束並重新啟動 MacReceiver（此設定只在啟動時讀取）。
3. 按「開始接收」，確認倒數從約 01:00 開始。
4. 不要在 iPhone 輸入，等候 60 秒。
5. 確認 Mac 自動回到 `Link: idle` 與「待命」。
6. 測試完成後執行：`defaults delete com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds`，並重新啟動 MacReceiver 恢復 30 分鐘。

結果：TBD
