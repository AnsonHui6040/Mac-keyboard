# E2E-T13-DICTATION：系統聽寫可行性 Gate（快速版）

執行者：使用者。在使用者親手測完之前，所有結果維持 TBD。使用者決定先做快速可行性測試：中文 5 句、英文 5 句，共 10 句；計畫原訂的各 50 句延至 T16 完整執行。

這個 Gate 只回答一個問題：使用者按 iOS 自己的麥克風鍵說話時，我們的鍵盤擴充功能能否準確得知 iOS 寫進 iPhone 欄位的內容，並同步到 Mac（文字加上 Apple 修正詞語時的退格）。規格 §6 要求五項逐項獨立記錄為 PASS、FAIL 或 INCONCLUSIVE。

## 自動驗證（不需真機）

- `swift test --package-path Packages/RemoteKeyboardCore`：`ContextDiffTests`（差分以 `Character` 計，表情符號算一個退格）、`DictationMirrorTests`（游標移動不算編輯、本機自己打的字不重複計算、差分上限 50 個退格與 500 個字元、超過上限重設基準）。
- 真機簽名 build 與模擬器 build（Debug 與 Release）。
- 模擬器預覽 `-rkPreview dictationProbe`：檢查清單在 402 pt 與 375 pt 寬都完整顯示。

聽寫探測只存在於 Debug build，Release build 不含任何探測程式碼。

## 前置條件

- iPhone 以線連接 Mac 並解鎖，已用 Xcode 安裝本分支的 Debug 版 Remote Keyboard，已開啟「允許完整取用」，已完成 Mac 配對（T09）。
- iPhone 設定中已開啟聽寫（設定 > 一般 > 鍵盤 > 啟用聽寫），並加入繁體中文與英文兩種聽寫語言。
- Mac 執行本分支的 MacReceiver，開啟 TextEdit 並新建純文字文件，游標停在文件內。
- 在備忘錄新建一則空白備忘錄，切到 Remote Keyboard。

## 如何開啟探測

1. 鍵盤切到「遠端」，傳送方式選「即時」，等狀態列顯示 Mac 已就緒。
2. 長按頂部第一行的狀態文字（例如「Mac → TextEdit」那一行字）2 秒，放開前會自動觸發。成功時狀態列出現「聽寫探測已開啟」，第三行（原本顯示小字版本號的位置）改成兩行檢查清單。再長按 2 秒會關閉。本機模式下無法開啟，會提示「聽寫探測需在遠端模式開啟」。
3. 探測開啟後，鍵盤在遠端模式下會把 iPhone 欄位的變化當成輸入，經同一條路徑送到 Mac（草稿規則照舊：草稿有字、選了草稿或 Mac 未就緒時，差分進草稿）。本機模式只觀察，不送出。
4. 探測的開關與計數會存在鍵盤的偏好設定中，鍵盤被 iOS 重建後仍會顯示；只存數字，不存任何文字。再次開啟探測會把計數歸零。

## 檢查清單各項的意義

| 項目 | 畫面 | 衡量什麼 | 誰判斷 |
|---|---|---|---|
| ① 系統麥克風可見 | 「請確認下方有麥克風」 | 程式無法可靠偵測，`needsInputModeSwitchKey` 與 `hasDictationKey` 都不是答案。使用者用眼睛確認鍵盤下方有系統的麥克風鍵 | 使用者 |
| ② 確實寫入 iPhone 欄位 | 「寫入欄位 否」或「是 n」 | 探測開啟後，游標前文字變長，且不是我們自己的按鍵造成；n 為次數 | 畫面加備忘錄實際內容 |
| ③ 鍵盤收到變化 | `will` 與 `did` 次數，「隱」為鍵盤畫面被隱藏的次數 | `textWillChange` 與 `textDidChange` 各被呼叫幾次；隱藏次數可看出聽寫時鍵盤是否被系統收起 | 畫面 |
| ④ 能得知確切差分 | 「退 n 字 m」 | 最近一次變化相對於上一個快照，需要退格 n 個、新增 m 個字元（只記長度）。「重設 k」表示有 k 次差分超過上限（50 個退格或 500 個字元）而重設基準，沒有送出 | 畫面加與備忘錄比對 |
| ⑤ Mac 收到確切差分 | 「送 a 回 b」，有進草稿時加「稿 c」 | 探測送出 a 個事件，Receiver 回覆 b 個確認；`ACK` 只代表 Receiver 已處理，不代表輸出內容正確。是否準確以 TextEdit 的實際文字為準 | TextEdit 內容加畫面 |

## 步驟

| 步驟 | 方式 | 預期 | 結果 |
|---|---|---|---|
| 1 | 依上節開啟探測，記下清單初始值 | 全部為 0，②為「否」 | TBD |
| 2 | 確認鍵盤下方有系統麥克風鍵（項目①） | 看得到麥克風鍵：PASS；看不到：FAIL，停止測試並記錄 | TBD |
| 3 | 在備忘錄點麥克風，說第 1 句中文（約 10 個字），說完停 2 秒再點停止 | 備忘錄出現文字（項目②）；清單 ② 變「是」；TextEdit 出現同樣文字 | TBD |
| 4 | 記錄清單全部數字 | 記下 will、did、隱、退、字、送、回 | TBD |
| 5 | 逐字比對備忘錄、TextEdit 兩邊文字是否相同 | 完全相同：項目⑤ PASS | TBD |
| 6 | 重複步驟 3–5，共 5 句中文，每句內容不同 | 每句記錄一列結果（見下表） | TBD |
| 7 | 說 5 句英文，方式同上 | 每句記錄一列結果 | TBD |
| 8 | 說一句較長的話（約 30 字），中途停頓 1 到 2 秒讓 Apple 修正詞語 | 觀察清單「退」的數字是否出現，TextEdit 是否同步退格後換成修正後的詞 | TBD |
| 9 | 聽寫中途點鍵盤任何一個鍵或切換位置 | 不應造成 TextEdit 重複文字；若有異常記在備註 | TBD |
| 10 | 長按狀態文字 2 秒關閉探測，再聽寫一句 | 備忘錄有字，TextEdit 不再收到同步；清單消失 | TBD |
| 11 | 檢查 Mac 的 Console 或 Xcode 輸出，篩選 category `dictation` | 只有次數與長度（outcome、backspaces、characters），沒有任何聽寫文字 | TBD |

## 逐句紀錄

| 句 | 語言 | 備忘錄文字與 TextEdit 相同 | 退 | 字 | 送 | 回 | 隱 | 備註 |
|---|---|---|---|---|---|---|---|---|
| 1 | 中文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 2 | 中文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 3 | 中文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 4 | 中文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 5 | 中文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 6 | 英文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 7 | 英文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 8 | 英文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 9 | 英文 | TBD | TBD | TBD | TBD | TBD | TBD | |
| 10 | 英文 | TBD | TBD | TBD | TBD | TBD | TBD | |

## 五項結果

判定方式：10 句都符合為 PASS；有任何一句不符合為 FAIL；測試條件不足以判斷（例如聽寫時鍵盤被系統收起，無法確定是系統沒通知還是探測沒執行）為 INCONCLUSIVE。

| 項目 | 結果 | 依據 |
|---|---|---|
| ① 系統麥克風可見 | TBD | |
| ② 確實寫入 iPhone 欄位 | TBD | |
| ③ 鍵盤收到 `textDidChange` | TBD | |
| ④ 能得知確切差分 | TBD | |
| ⑤ Mac 收到確切差分 | TBD | |
| Apple 修正詞語後以退格加新文字同步到 Mac | TBD | 步驟 8 |

## 結論

- 五項全部 PASS：語音 Gate 記 PASS，完整版（中英各 50 句）延至 T16 執行，之後才把同步功能開放於正式設定。
- 任一項 FAIL 或 INCONCLUSIVE：語音 Gate 記 FAIL，停下回報；主 App 手動語音頁另以 writing-plans 規劃（D7），不宣稱語音支援 Mac 同步。

整體結果：TBD
