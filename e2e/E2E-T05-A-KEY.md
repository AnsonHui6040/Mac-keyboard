# E2E-T05-A-KEY：iPhone 鍵盤打字送到 Mac 真機驗收

執行者：使用者。每一步完成後填寫「結果」，全部為 PASS 才算 T05 通過。T04 的實機項目（`e2e/E2E-T04-INJECT.md`）與本檔一起測。

通過標準：Notes → TextEdit、Safari → TextEdit 各 20/20；錯誤焦點 0 次。失敗即停止 T10–T12 的完整 UI，改依 D8 驗證 LAN 傳輸。

前置條件：iPhone 已安裝最新的 Remote Keyboard，並已開啟「允許完整取用」；Mac 執行最新的 MacReceiver（由 `/private/tmp/claude-501/receiver-run/MacReceiver.app` 副本啟動），已允許藍牙與輔助使用；TextEdit 開一份新文件；Mac 輸入法為 ABC（注音另測）。

狀態對照：

| 位置 | 顯示 | 意思 |
|---|---|---|
| iPhone 鍵盤左下 | 「本機」／「遠端」 | 目前模式；按一下切換，下次叫出鍵盤會記住 |
| iPhone 狀態列 | `Mac → TextEdit` | 已連上，Mac 焦點在可輸入欄位 |
| iPhone 狀態列 | `Mac → Finder（無輸入欄位）` | 已連上，但 Mac 焦點不可輸入，按鍵不會送出 |
| iPhone 提示 | 「Mac 已輸入」「焦點已改變，未輸入」「Mac 沒有輸入欄位」「Mac 正在組字，未輸入」 | 最近一次 Mac 回覆 |
| Mac 選單 | `Link: ready (N ms)`、「剩餘接收時間 mm:ss」 | 已連線並在接收時段內 |

若 iPhone 一直顯示「（無輸入欄位）」而 Mac 焦點明明在 TextEdit，先確認 Mac 選單沒有「輔助使用未授權」；未授權時目前也顯示同一句（T16 再分開）。若 iPhone 顯示「事件過大，未送出」，記下 Console 中 `maximumUpdateValueLength` 的數值。

## 步驟

### 1. 點擊輸入框即開始接收（D13）
1. Mac 選單顯示「待命」時，點進 TextEdit 文件。
2. 確認選單變成「剩餘接收時間 30:00」附近並開始掃描。
3. iPhone 開 Notes，叫出 Remote Keyboard，按「本機」切到「遠端」。
4. 確認 iPhone 狀態列顯示 `Mac → TextEdit`，Mac 選單顯示 `Link: ready (N ms)`。

結果：TBD

### 2. Notes → TextEdit 按 `A` 20 次（T05-E2E-A-01）
每次：收起鍵盤，再叫出鍵盤，按一次 `A`，確認 TextEdit 多一個 `A`。錄影存證，不得用主 App 代打。

| 成功次數 / 20 | 錯誤或多出的字 | 錄影檔 |
|---|---|---|
| TBD | TBD | TBD |

結果：TBD

### 3. Safari → TextEdit 按 `A` 20 次（T05-E2E-A-02）
同步驟 2，iPhone 改在 Safari 網址列或網頁輸入框叫出鍵盤。

| 成功次數 / 20 | 錯誤或多出的字 | 錄影檔 |
|---|---|---|
| TBD | TBD | TBD |

結果：TBD

### 4. 一般打字
在遠端模式打 `Hello world`，再按 Backspace 2 次與 Return 1 次，確認 TextEdit 顯示 `Hello wor` 並換行。

結果：TBD

### 5. 按鍵前切走焦點 5 次
每次：在 Mac 按 ⌘Tab 切到 Finder，1 秒內在 iPhone 按 `A`。Mac 不得出現字元，iPhone 提示為「焦點已改變，未輸入」或「Mac 沒有輸入欄位」，或狀態列顯示「（無輸入欄位）」而未送出。

| 次 | Mac 是否出現字元 | iPhone 顯示 |
|---|---|---|
| 1 | TBD | TBD |
| 2 | TBD | TBD |
| 3 | TBD | TBD |
| 4 | TBD | TBD |
| 5 | TBD | TBD |

結果：TBD

### 6. Mac 注音組字中
1. Mac 切到注音，在 TextEdit 打 `ㄒㄧㄤ`，不要選字（候選字仍在組字中）。
2. 在 iPhone 遠端模式按 `A`。
3. 預期：TextEdit 未完成的注音被刪除、出現 `A`，輸入法切回注音。若注音被提交成中文字後才出現 `A`，記錄「組字未偵測到」（TextEdit 未提供組字狀態）。

結果：TBD

### 7. 沒有完整取用
1. iPhone 設定 › 一般 › 鍵盤 › Remote Keyboard，關閉「允許完整取用」。
2. 在 Notes 叫出鍵盤，確認顯示「本機」且可正常打字，按「遠端」時顯示「遠端需要開啟『允許完整取用』」。
3. 測完重新開啟「允許完整取用」。

結果：TBD

### 8. 60 秒逾時
1. 執行 `defaults write com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds 60`，結束並重開 Receiver。
2. 點進 TextEdit，連上後持續每 20 秒按一次 `A` 共 2 分鐘，確認不斷線。
3. 停止打字 60 秒，確認 Mac 選單回到「待命」並斷線。
4. 執行 `defaults delete com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds`，重開 Receiver。

結果：TBD
