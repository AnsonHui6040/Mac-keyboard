# E2E-T01-LOCAL：離線 Local Mode 真機驗收

執行者：使用者。每一步完成後填寫「結果」，全部為 PASS 才算 T01 通過。

前置條件：iPhone 以線連接 Mac，已開啟開發者模式，Xcode 已登入 Apple ID（Personal Team）。

## 步驟

### 1. 設定 DEVELOPMENT_TEAM
1. 開啟 `project.yml`，將 `DEVELOPMENT_TEAM` 設為你的 Personal Team ID。
2. 執行 `xcodegen generate`。
3. 開啟 `RemoteKeyboard.xcodeproj`。

結果：PASS（2026-10-29，`project.yml` 的 `DEVELOPMENT_TEAM` 設為 `4YN34HPX6F`）

### 2. 安裝到 iPhone
1. 在 Xcode 選擇 scheme `RemoteKeyboardApp` 與你的 iPhone。
2. 按 Run，確認 App 成功安裝並開啟。
3. 若出現「不受信任的開發者」，到 設定 > 一般 > VPN 與裝置管理 信任該憑證。

結果：PASS（`devicectl device install app` exit 0；使用者於 VPN 與裝置管理信任開發者後可開啟）

### 3. 加入鍵盤（Allow Full Access 保持關閉）
1. 到 設定 > 一般 > 鍵盤 > 鍵盤 > 加入新鍵盤，選擇 Remote Keyboard。
2. 點進 Remote Keyboard，確認「允許完整取用」為關閉。

結果：PASS（使用者回報，允許完整取用保持關閉）

### 4. 在備忘錄輸入 20 個字元
1. 開啟備忘錄，新增一則備忘錄。
2. 切換到 Remote Keyboard，輸入 `Hello World`（11 個字元，含空白與大寫 H、W）。
3. 再輸入 9 個英文字母（例如 `abcdefghi`），使總數為 20 個字元。
4. 確認畫面文字與你輸入的內容逐字一致，並測試 Backspace 與 Return（換行）。

實際輸入內容：`Hello World`、換行、`qwertyuiopasdfghjklzxcvbnm`（共 37 字元，超過 20 字元要求）
結果：PASS（逐字一致；Return 換行、Backspace 正常；截圖 `docs/superpowers/verification/evidence/T01-device-notes-hello-world.webp`）

### 5. 地球鍵切換鍵盤
1. 確認鍵盤上的 🌐 鍵，或系統在鍵盤下方顯示的 🌐（Face ID 機型的 `needsInputModeSwitchKey` 為 false，自訂 🌐 依設計隱藏）。
2. 長按地球鍵，確認出現鍵盤清單並可切換到其他鍵盤。
3. 點一下地球鍵，確認可切換到下一個鍵盤。

結果：PASS（使用者回報；Face ID 機型使用系統 🌐）

### 6. App Group probe（O3）
1. 開啟 Remote Keyboard App，點「寫入 probe」，確認顯示「已寫入」。
2. 回到備忘錄，切換到 Remote Keyboard，讀取鍵盤右上角的文字。
3. 記錄顯示為 `AppGroup: OK` 或 `AppGroup: NIL`。

顯示內容：`AppGroup: OK`
O3 結果（OK／FAIL）：OK

### 7. Personal Team 因 App Group 簽名失敗時
適用於步驟 2 的建置出現 App Group entitlement 的簽名錯誤。

1. 在 `project.yml` 移除 `RemoteKeyboardApp` 與 `RemoteKeyboardExtension` 兩個 target 的 `entitlements` 區塊（App Group）。不要手動編輯產生出來的 `.entitlements` 檔，`xcodegen generate` 會覆寫。
2. 重新執行 `xcodegen generate`，再重新建置並安裝。
3. 重複步驟 3 至 5，Local Mode 必須仍可正常輸入。
4. 在此檔記錄 O3 = FAIL，後續改走 D3。

是否需要此步驟：否
結果：NOT_APPLICABLE

## 通過條件
- 備忘錄 20 個字元逐字正確
- Allow Full Access 關閉時照常輸入
- 地球鍵可切換鍵盤
- 已記錄 O3 結果
