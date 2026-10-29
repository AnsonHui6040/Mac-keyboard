# E2E-T03A-PERIPHERAL：iPhone 鍵盤 BLE Peripheral 真機驗收

執行者：使用者。每一步完成後填寫「結果」，全部為 PASS 才算 T03a 通過。

說明：T03a 只驗證鍵盤本身會廣播。Mac Receiver 的 Central 端在 T03b 才實作，因此本次不會有任何 Mac 連線，狀態列不會出現 `BLE: connected`。

前置條件：iPhone 已安裝最新的 Remote Keyboard（用 Xcode 安裝到實機）；已在 設定 > 一般 > 鍵盤 加入 Remote Keyboard。

狀態列（鍵盤左上角，`rk.status`）的對照：

| 狀態 | 狀態列文字 |
|---|---|
| idle | `BLE: idle` |
| no-full-access | `BLE: no-full-access` |
| unavailable | `BLE: unavailable` |
| publishing | `BLE: publishing` |
| advertising | `BLE: advertising` |
| failed | `BLE: failed (addService)` 或 `BLE: failed (advertise)` |

## O4 矩陣

在 Notes 切換到 Remote Keyboard，記錄狀態列文字，並在 Local 模式輸入 `abc`、按退格、按換行，確認文字正常。

「主 App 藍牙授權」在 Remote Keyboard 主 App 按「允許藍牙」；拒絕時到 設定 > Remote Keyboard > 藍牙 關閉。「Full Access」在 設定 > 一般 > 鍵盤 > Remote Keyboard > 允許完整取用。

| 格 | 主 App 藍牙授權 | Full Access | 預期狀態列 | 實際狀態列 | Local 打字正常 | 有無 crash |
|---|---|---|---|---|---|---|
| A | 允許 | 開 | `BLE: advertising` | TBD | TBD | TBD |
| B | 允許 | 關 | `BLE: no-full-access` | TBD | TBD | TBD |
| C | 拒絕 | 開 | `BLE: unavailable` | TBD | TBD | TBD |
| D | 拒絕 | 關 | `BLE: no-full-access` | TBD | TBD | TBD |

結果：TBD

## 步驟

### 1. 主 App 藍牙授權
1. 開啟 Remote Keyboard 主 App，按「允許藍牙」。
2. 系統提示出現時選擇「允許」，確認主 App 顯示「已允許」。

結果：TBD

### 2. Notes 顯示 advertising（格 A）
1. Full Access 開、藍牙授權允許。
2. 開啟 Notes，點進新備忘錄，切換到 Remote Keyboard。
3. 確認狀態列在數秒內變成 `BLE: advertising`（accessibilityValue 為 `advertising`）。
4. 收起鍵盤，再叫出鍵盤，確認狀態列再次變成 `BLE: advertising`。

結果：TBD

### 3. Safari 顯示 advertising（格 A）
1. 開啟 Safari，點進網址列或任一文字欄位，切換到 Remote Keyboard。
2. 確認狀態列在數秒內變成 `BLE: advertising`。

結果：TBD

### 4. 其餘三格（B、C、D）
1. 依 O4 矩陣調整授權與 Full Access，逐格記錄狀態列與 Local 打字。
2. 每格都確認 Local 模式可以輸入 `abc`、退格、換行，且沒有 crash。

結果：TBD

### 5. 備註
1. 本次沒有 Mac Receiver Central，不需要也不會看到 `BLE: connected`。
2. 若狀態列顯示 `BLE: failed (...)`，請記錄括號內文字並回報。

結果：TBD
