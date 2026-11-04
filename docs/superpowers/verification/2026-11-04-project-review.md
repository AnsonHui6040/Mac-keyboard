# 2026-11-04 全專案審查與修復

範圍：Core、Mac Receiver、iOS App 與鍵盤、配對與 BLE 安全、公開 Repository 內容。

## 已修復

| 項目 | 問題 | 修復 | 驗證 |
|---|---|---|---|
| 重新配對 | 配對視窗開啟時鍵盤還在畫面上，驗證失敗後該 iPhone 被略過，App 配對不到 | 視窗內失敗不略過裝置 | Mac 測試（RED → GREEN） |
| 配對視窗被佔用 | 不發配對請求的裝置可佔住唯一連線 120 秒 | 視窗等待中也套用 5 秒逾時 | Mac 測試（RED → GREEN） |
| 觸控板失效 | 連續 8 個壞封包後頻道關閉，iPhone 不知道 | 發新授權，iPhone 自動重開 | Mac 測試（RED → GREEN） |
| 游標凍結 | 手勢中螢幕休眠或拔除，畫面更新來源停止 | 200 ms 沒有畫面更新就重啟來源 | Mac 測試（RED → GREEN） |
| 文字截斷 | 單一字元超過 20 個 UTF-16 單位 | 這種字元改依 Unicode scalar 分段 | Core 測試（RED → GREEN） |
| 舊鍵盤實例 | 延遲的 `viewDidDisappear` 關掉新實例的觸控板頻道與按鍵音 | 依擁有權分流 | 僅 build |
| 觸控板狀態殘留 | 授權變更後傳輸模式與低延遲設定未還原 | 與關閉頻道相同的重設 | 僅 build |
| 手寫模型匯入失敗 | 顯示成「請先下載」 | 新增專用狀態文字 | 僅 build |
| 按鍵表成長 | `KeyRollover.keys` 不會縮小 | 超過 256 筆時清除失效項目 | 僅 build |
| 手寫模型重新命名 | 主 App 識別碼靠字尾推算 | 改讀外層 App 的識別碼 | 僅 build |
| iPhone 配對金鑰 | 可隨加密備份搬到另一部裝置 | 改用 `ThisDeviceOnly` | 僅 build |
| 公開內容 | 文件與腳本含裝置 UDID、本機路徑 | 改成預留位置；`T10_UDID` 改為必填 | `git grep` |
| 隱私說明 | 仍寫 Mac 金鑰存放在鑰匙圈 | 改寫為實際位置與風險 | 人工核對 |

## 自動驗證

| 項目 | 結果 |
|---|---|
| Core | 989 tests，0 failures |
| MacReceiver | 310 tests，0 failures |
| iOS 模擬器 build | BUILD SUCCEEDED |
| 公開截圖 62 張 | 主代理逐張目視，個人資料已遮蓋 |

## 實機驗證

建置：main `f08afb8`，Release。iPhone 以 SideStore 覆蓋安裝，開發者親手測試。

| 項目 | 狀態 |
|---|---|
| 覆蓋安裝後配對與設定保留（D8） | PASS（仍顯示已配對，設定值未變，打字送到 Mac） |
| 從鍵盤切到其他 App 再切回，按鍵音與觸控板正常 | PASS |
| 手寫模型在 SideStore 版匯入與辨識（D6） | PASS |
| 鍵盤留在畫面上開配對視窗，再從 App 配對 | PASS（測試時金鑰有效，沒有走到驗證失敗） |
| 重新配對後金鑰可用（`ThisDeviceOnly`） | PASS |
| 金鑰不一致時，配對視窗內不略過裝置 | 僅 Mac 自動測試，實機 TBD |

## 未修改

| 項目 | 原因 |
|---|---|
| 拖曳中斷線超過 350 ms 後不重新按下 | 規格 §10 的設計，避免舊封包重新按下按鍵 |
| 一方按確認、另一方取消時金鑰不一致 | 協定沒有確認訊息，需改協定；手冊已列重新配對的做法 |
| Mac 金鑰檔可被同帳號程式讀取 | 免費簽署沒有穩定身分；已寫入隱私說明 |
| 沒有 forward secrecy | 需改協定 |
| `GATTPeripheralServer.swift` 未使用 | 不可達，留待開發者決定是否刪除 |
| Git 歷史內的 UDID | 改寫歷史需要 force push，留待開發者決定 |
