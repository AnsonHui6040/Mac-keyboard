# 2026-11-03 SideStore 實機安裝與 Mac 配對修正

## SideStore 實機安裝

| 項目 | 結果 |
|---|---|
| 環境 | iPhone 17 Pro、iOS 27.2；iloader 2.4.1；SideStore 0.7.0 Stable；開發者自己的免費 Apple 帳號 |
| 安裝 SideStore | iloader 一次完成（下載、簽署安裝、放置配對檔） |
| 登入 | -80045。SideStore 已知問題，關閉 On-Device Anisette 並改用遠端 Anisette 後登入成功 |
| Refresh | 沒有錯誤 |
| 匯入 IPA | 成功。Extension 選項實際為「Keep App Extensions (Register App ID for Each Extension)」 |
| App Group | SideStore 改名為 `group.com.ansonhui.remotekeyboard.4YN34HPX6F`，App 與 Extension 都指派到同一個 |
| 3 個 App 上限 | 開發版、SideStore 版與 SideStore 同時存在時，再裝 UI 測試工具被拒（`MIFreeProfileValidatedAppTracker`） |

## Mac 配對失敗的根本原因

- Mac Receiver 把配對匙存在登入鑰匙圈，項目綁定建立者的簽名。
- 發佈版是 ad-hoc 簽署，每個版本簽名不同。新版刪不掉舊版的項目（`errSecInvalidOwnerEdit`，-25244），配對以 storeFailed 結束，Mac 一直使用 2026-10-30 建立的舊匙，iPhone 則存了新匙，每次連線都驗證失敗。
- 開放 ACL 不足以解決：macOS 依簽名加上 partition list，新版第一次讀取仍會彈出登入鑰匙圈密碼視窗，移除後也會被自動加回。

## 修正

- 配對匙改存 `~/Library/Application Support/RemoteKeyboardReceiver/pair-key`，資料夾 0700、檔案 0600，原子替換。舊鑰匙圈項目只嘗試刪除，不再讀取。
- 代價：同一個 macOS 使用者的其他 App 可讀取這個檔案（開發者選定）。
- 既有的 Mac 需要重新配對一次。

## 驗證

| 項目 | 結果 |
|---|---|
| 自動 | MacReceiver 304 個測試、Core 986 個測試，0 失敗 |
| 跨簽名 | 兩個簽名不同的程式互相存、讀、刪，沒有視窗 |
| 實機更新 | 發佈版配對後，換簽名安裝兩次，面板仍顯示「已配對 iPhone」，沒有鑰匙圈視窗 |
| 輸入 | 開發者確認修正前一版在刪除舊匙並重新配對後可以輸入 |

## 未完成

- D5、D6、D7、D8 未實測。
- 修正版本身的輸入（需要重新授權輔助使用）由開發者確認。
