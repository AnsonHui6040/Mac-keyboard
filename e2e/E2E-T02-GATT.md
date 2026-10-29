# E2E-T02-GATT：Mac Receiver 廣播 GATT Service 真機驗收

執行者：使用者。每一步完成後填寫「結果」，全部為 PASS 才算 T02 通過。

前置條件：Mac 的藍牙已開啟；iPhone 已安裝 nRF Connect（App Store 免費）；`project.yml` 的 `DEVELOPMENT_TEAM` 已設定。

預期的 UUID 與屬性：

| 項目 | UUID | 預期屬性 |
|---|---|---|
| Service | `2A6F212A-3B7A-4293-87B4-FAD198077EFB` | Primary |
| Input | `92A59A91-80A0-4743-8E65-F297A9B05104` | Write |
| Ack | `6AEB18CE-45D1-47B8-9F18-96939C182189` | Notify |
| Status | `99FA0347-3B23-498D-A0F0-1EE6B0AAA76E` | Read、Notify |

## 步驟

### 1. 啟動 Receiver
1. 執行 `xcodegen generate`，開啟 `RemoteKeyboard.xcodeproj`。
2. 選擇 scheme `MacReceiver`，目的地選 My Mac，按 Run。
3. 確認選單列出現鍵盤圖示（Receiver 沒有 Dock 圖示）。

結果：PASS（2026-10-29，Personal Team 簽名版本，commit cec80c5）

### 2. 允許 macOS 藍牙權限
1. 首次啟動時，macOS 會跳出藍牙權限提示，選擇「允許」。
2. 若先前按過「不允許」，到 系統設定 > 隱私權與安全性 > 藍牙，開啟 Remote Keyboard Receiver，再重新啟動 App。

結果：PASS（藍牙授權後選單列進入 advertising）

### 3. 確認選單列顯示 advertising
1. 點選單列的鍵盤圖示。
2. 確認第一行顯示 `BLE: advertising`。
3. 若顯示 `waiting for Bluetooth` 或 `failed (...)`，請記下完整文字。

實際顯示：`BLE: advertising`；Start 為停用、Stop 可按
結果：PASS（照片 `evidence/T02-mac-menubar-advertising.jpg`）

### 4. 以 nRF Connect 掃描
1. 在 iPhone 開啟 nRF Connect，進入 Scanner 並開始掃描。
2. 找到名稱為 `RemoteKeyboard` 的裝置，截圖。

結果：PASS（iPhone 17 Pro、iOS 27.0.1；裝置名稱顯示為電腦名稱「Mac」，Connectable: Yes，RSSI -41 至 -49 dBm；截圖 `evidence/T02-device-nrf-advertisement.webp`）

### 5. 記錄 Service UUID
1. 點選該裝置的 CONNECT，展開 Services。
2. 記錄 Service UUID，並與上表比對。

實際 Service UUID：`2A6F212A-3B7A-4293-87B4-FAD198077EFB`（iPhone 廣播封包）
結果：PASS

### 6. 記錄三個 Characteristic 的屬性
1. 在該 Service 下，逐一記錄三個 Characteristic 的 UUID 與 Properties。
2. 與上表比對，並截圖。

| Characteristic | 實際 UUID | 實際屬性 |
|---|---|---|
| Input | write（extended, reliable-write） | Mac bluetoothd GATT 紀錄 |
| Ack | notify | Mac bluetoothd GATT 紀錄 |
| Status | read, notify | Mac bluetoothd GATT 紀錄 |

結果：PASS（以 Mac 端 GATT 資料庫確認，`evidence/T02-bluetoothd-excerpt.txt`）。iPhone 端 nRF Connect 連線停在 Connecting：同一 iCloud 的 iPhone 與 Mac 已有系統 LE 連線，新連線不會完成，詳見研究摘要失敗案例 8；iPhone 端 characteristic 探索改由 T03 以 `retrieveConnectedPeripherals` 驗證

### 7. 停止廣播
1. 在選單列點「Stop」，確認第一行變成 `BLE: idle`。
2. 在 nRF Connect 重新掃描，確認 `RemoteKeyboard` 已消失。
3. 點「Start」，確認回到 `BLE: advertising`。

結果：未實機測試；由 `GATTLifecycleTests.testStopThenStartReaddsServiceBeforeAdvertising` 覆蓋，T06 實機補測

### 8. 藍牙關閉再開啟
1. 在 Mac 關閉藍牙，再重新開啟。
2. 確認選單列第一行回到 `BLE: advertising`。
3. 在 iPhone 的 nRF Connect 重新掃描，確認仍可看到 `RemoteKeyboard` 服務。

結果：未實機測試；由 `GATTLifecycleTests.testPowerOffThenOnReaddsAndAdvertises` 覆蓋，T06 實機補測
