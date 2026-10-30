# E2E-T14-MATRIX：跨 App 相容性與焦點安全矩陣

執行者：使用者。依使用者 2026-10-30 決定，實機項目延至 T16；本檔所有格子目前為 TBD，使用者親手測完才算 PASS。結果同步填入 `docs/superpowers/verification/evidence/T14-matrix.csv`。

前置條件：iPhone 與 Mac 均為最新 build；Mac 執行 MacReceiver，已允許藍牙與輔助使用；iPhone 已開啟「允許完整取用」並配對。

## 每格記錄的四項

| 欄位 | 判定 |
|---|---|
| 字元一致 | 送出的字串與 Mac 欄位內容逐字相同（測試字串：`Hello`、`香港`、`café`、一個 emoji） |
| 組字取消 | 送出前若欄位有未確認的組字，已被取消且沒有殘留 |
| 切回輸入法 | 送完後 Mac 輸入法回到送出前的輸入法；若失敗，Mac 面板須顯示「輸入法未能切回，請手動切換」 |
| 錯誤焦點 | 送出期間切換視窗或欄位，字元打入錯誤欄位的次數，必須為 0 |

## A. Mac 輸入法 × Mac App（5 × 8 = 40 格）

每格先把 Mac 切到該輸入法，在該 App 的輸入欄位用 iPhone 遠端模式送出測試字串。

| Mac 輸入法 | TextEdit | Notes | Safari 網址列 | Safari 網頁輸入框 | Chrome | VS Code | Word | Messages |
|---|---|---|---|---|---|---|---|---|
| ABC | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 注音 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 倉頡 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 速成 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 粵拼 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

## B. iPhone 端（2 × 4 = 8 格）

| iPhone 模式 | 英文 | 手寫 | 速成 | 符號 |
|---|---|---|---|---|
| 本機 | TBD | TBD | TBD | TBD |
| 遠端 | TBD | TBD | TBD | TBD |

## C. 阻擋第三方鍵盤的欄位

| iPhone 欄位 | 預期 | 結果 |
|---|---|---|
| 密碼欄位 | 自動回到系統鍵盤，Remote Keyboard 不送出任何字元 | TBD |
| 電話欄位 | 自動回到系統鍵盤，Remote Keyboard 不送出任何字元 | TBD |

## D. 焦點安全專項

| 項目 | 做法 | 預期 | 結果 |
|---|---|---|---|
| Mac 測試插入的 gate 等待 | 連按兩次測試插入，第一次進行中切換視窗 | 第二次顯示「未插入：焦點已改變」，沒有字元打入新視窗 | TBD |
| 前景 App 卡住 | 讓前景 App 無回應（例如暫停其行程）後從 iPhone 送字 | 藍牙連線與 Mac 面板不凍結；字元不送出或晚到但不入錯誤欄位 | TBD |
| 輸入法切回失敗 | 在切回目標輸入法被系統拒絕的情況下送字 | iPhone 收到「Mac 已輸入」，Mac 面板顯示「輸入法未能切回，請手動切換」 | TBD |

## 紀錄方式

測完一格就在上表與 CSV 填 PASS 或 FAIL，FAIL 要在 CSV 的 `note` 寫現象與 Mac log 的時間。log 不含文字內容，只看事件種類、長度、時間與結果。
