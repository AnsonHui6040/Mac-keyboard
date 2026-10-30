# E2E-T10-KEYBOARD：英文鍵盤、頂部區、即時／草稿真機驗收

執行者：使用者。全部為 PASS 才算 T10 通過；在使用者親手測完之前，所有結果維持 TBD。

通過標準：
- 英文頁的 Shift（單按一次大寫、雙按 Caps Lock）、刪除長按連續刪除、空白、換行都正確。
- 本機與遠端切換正確；本機模式下鍵盤頂部只有兩行（`本機｜遠端` 與候選字空白列）。
- 遠端模式的即時與草稿行為符合規格：未就緒或草稿有字時一律寫入草稿；`◀ ▶` 只動草稿游標、不動 Mac；`傳送` 在就緒且草稿非空時才是藍色。
- 草稿上限 1,000 字元，超過時有提示且草稿不變；草稿只在記憶體，不寫入磁碟。
- 欄位類型決定開啟的頁面；頁面、模式、即時／草稿重開後沿用。
- 每顆鍵都有台灣中文的無障礙標籤。
- 診斷紀錄不含任何輸入文字。

自動驗證（不需真機）：`swift test`（`DraftBufferTests`、`InputRouterTests`、`PageNavigatorTests`、`TopAreaStateTests`、`ShiftStateTests`、`KeyboardActionRouterTests`）與模擬器預覽截圖（402 pt、375 pt；見 `evidence/T10-*.png`）。這份文件只驗證自動驗證碰不到的部分：真的鍵盤行程、真的藍牙、觸控與長按手感、VoiceOver。

## 前置條件

- iPhone 以線連接 Mac 並解鎖，已用 Xcode 安裝本分支的 Remote Keyboard，已開啟「允許完整取用」，並已完成 Mac 配對（T09）。
- Mac 執行本分支的 MacReceiver，開啟 TextEdit 並新建純文字文件，讓游標停在文件內。
- 在 iPhone 的備忘錄或 Safari 開啟文字欄位，切換到 Remote Keyboard。

## 自動化執行

使用者決定把大部分手動步驟改為自動執行。自動化分兩部分：iPhone 上的 XCUITest（`KeyboardT10UITests`）操作備忘錄與鍵盤，檢查 iPhone 畫面上看得到的結果；Mac 上的腳本 `e2e/scripts/t10-device-run.sh` 檢查 TextEdit 實際收到的文字，最後再檢查 Receiver 紀錄沒有輸入的明文。下表「結果」欄在使用者確認前一律維持 TBD。

前置條件：
1. iPhone 以線連接 Mac 並解鎖，已完成 Mac 配對（T09）、開啟「允許完整取用」，且 Remote Keyboard 是目前使用的鍵盤。
2. Mac 執行本分支的 MacReceiver，已按「開始接收」。Receiver 閒置 30 分鐘會逾時，整個流程較長時請再按一次。
3. 備忘錄已關閉，或停在備忘錄清單。測試只會新增自己的備忘錄，且只點新備忘錄的空白內文；本機模式打的字會在案例結束前刪除。
4. 一次性設定：若 UI 測試的簽名需要，先在 Xcode 選擇 iPhone 為目的地，執行 Product > Build For Testing 一次。
5. 執行腳本的 App（例如 Terminal）要允許控制 TextEdit 與 System Events（系統設定 > 隱私權與安全性 > 自動操作、輔助使用）。
6. TextEdit 的「自動修正拼字」要關閉，否則輸入的字可能被改寫；也可以加上 `T10_DISABLE_AUTOCORRECT=1`，腳本會在執行期間關閉並於結束時還原。
7. 步驟 31 與步驟 32、33 已由使用者延後到 T16 手動測試，預設不執行（`testDraftCap`、`testFieldKinds` 仍可指定名稱執行）。
8. 若某個本機模式案例失敗，備忘錄裡可能留下一則測試用的備忘錄，請手動刪除。`testFieldKinds` 會在 Safari 目前的分頁開啟一個 `data:` 網址。

指令：

```
e2e/scripts/t10-device-run.sh                      # 建置一次，依序執行全部案例
e2e/scripts/t10-device-run.sh testDraftEditing     # 只執行指定案例
e2e/scripts/t10-device-run.sh --skip-build         # 沿用上次建置
e2e/scripts/t10-device-run.sh --list               # 列出案例與 Mac 端預期，不執行
```

腳本每個案例都新建一份 TextEdit 文件並讓它取得焦點，同時每 0.3 秒記錄文件內容，案例結束後比對預期。每次執行的紀錄放在 `$T10_OUT/run.<時間>.<行程編號>/`（預設 `/tmp/t10-device-run`），摘要寫入該資料夾的 `summary.csv`，並複製一份到 `$T10_OUT/summary.csv`。腳本以視窗編號鎖定自己新建的 TextEdit 視窗，只對該視窗讀取、清空與關閉（不儲存）；該視窗不存在時什麼都不做，不會改用名稱去找其他文件。每個案例開始前會確認 TextEdit 在最前面且最前面的視窗就是它自己的，否則該案例判為失敗。

判定規則：略過（skip）除了 `testFieldKinds` 與 `testDraftCap` 以外一律算失敗；XCUITest 必須出現該案例的 passed 行且實際執行 1 個測試才算通過；Mac 端讀取 TextEdit 時只要出現讀不到、取樣間隔超過 3 秒或紀錄沒有正常結束，就判失敗；Receiver 紀錄為空或沒有任何 `event kind=` 行也判失敗，因為這樣的紀錄什麼都證明不了。

| 步驟 | 方式 | 說明 | 結果 |
|---|---|---|---|
| 1 | 自動（testAccessibilityLabels）加手動 | 自動檢查 `AppGroup: OK` 這行；本版 build 時間仍需人工核對 | TBD |
| 2 | 自動（testShiftAndInstant） | 檢查狀態列為 `Mac → …` 且頂部只有兩行 | TBD |
| 3 | 自動（testShiftAndInstant） | | TBD |
| 4 | 自動（testShiftAndInstant） | 以系統雙擊動作觸發 Caps Lock | TBD |
| 5 | 自動（testShiftAndInstant） | | TBD |
| 6 | 自動（testShiftAndInstant） | 兩次點擊間隔 0.6 秒 | TBD |
| 7 | 自動（testShiftAndInstant） | iPhone 備忘錄保持空白；Mac 端比對 `AABCde hello` 加換行 | TBD |
| 8 | 自動（testShiftAndInstant） | 同上 | TBD |
| 9 | 自動（testRemoteLongPressDelete） | 打 30 個字母後長按刪除 1 秒；Mac 端接受剩下 15 至 27 個字母 | TBD |
| 10 | 自動（testLocalModeAndLongPressDelete） | 本機長按刪除，備忘錄內文逐字減少至少 3 個 | TBD |
| 11 | 自動（testLocalModeAndLongPressDelete） | 本機打 `abc`，頂部沒有 `即時｜草稿` | TBD |
| 12 | 自動（testLocalModeAndLongPressDelete） | 回到遠端後狀態文字與 `即時｜草稿` 出現 | TBD |
| 13 | 自動（testLocalModeAndLongPressDelete） | | TBD |
| 14 | 自動（testDraftEditing） | 含鍵盤高度增加約 36 pt | TBD |
| 15 | 自動（testDraftEditing） | iPhone 備忘錄保持空白；Mac 端只確認途中沒有不屬於最終草稿的字，並要求第一個字在開始記錄 12 秒後才出現，無法證明送出前完全沒有字 | TBD |
| 16 | 自動（testDraftEditing） | | TBD |
| 17 | 自動（testDraftEditing） | | TBD |
| 18 | 自動（testDraftEditing） | iPhone 端確認草稿文字沒有變；Mac 端只確認最終文字正確，沒有逐一比對游標移動期間的內容 | TBD |
| 19 | 自動（testDraftEditing） | | TBD |
| 20 | 自動（testDraftEditing） | 草稿放 4 秒後才傳送；Mac 端確認最終文字完整且途中沒有多餘的字，沒有送出時間點可以對照 | TBD |
| 21 | 自動（testDraftEditing） | 草稿內含換行，Mac 端比對 `abXcab`、換行、`cdd` | TBD |
| 22 | 自動（testInstantWithDraftEditsDraft） | | TBD |
| 23 | 自動（testInstantWithDraftEditsDraft） | | TBD |
| 24 | 自動（testInstantWithDraftEditsDraft） | | TBD |
| 25 | 自動（testInstantWithDraftEditsDraft） | Mac 端比對最終文字 `xzq` 且途中沒有多餘的字 | TBD |
| 26 | 自動（testNotReadyGoesToDraft） | 腳本讓 TextEdit 失去焦點；Mac 端確認沒有任何字 | TBD |
| 27 | 自動（testNotReadyGoesToDraft） | 約 15 秒後焦點恢復，測試等待 `傳送` 變藍並確認不會自動送出，再按下傳送 | TBD |
| 28 | 自動（testPersistence） | 含收起鍵盤與切到 Safari 再回來；此案例不要求 Mac 就緒，TextEdit 為空只代表沒有字送達 | TBD |
| 29 | 自動（testModeSwitchKeepsDraft） | 含鍵盤高度減少約 36 pt；此案例保持 Mac 就緒，漏到 Mac 的字會被看到，TextEdit 必須全程為空 | TBD |
| 30 | 自動（testModeSwitchKeepsDraft） | 以再打一個字確認游標位置還在 | TBD |
| 31 | 延後至 T16 手動 | 填滿草稿的測試掛鉤只存在於 Debug 建置，且不會在 XCUITest 的長按下觸發，所以 `testDraftCap` 會直接略過。手動做法：用 Debug 建置，在遠端模式長按空白 2 秒即可把草稿填到 1,000 字，再打一個字確認出現上限提示，傳送後再次可打 | TBD |
| 32 | 延後至 T16 手動 | `testFieldKinds` 預設不執行，指定名稱才會跑 | TBD |
| 33 | 延後至 T16 手動 | 同上 | TBD |
| 34 | 自動（testSymbolsAndPages） | 遠端與本機各打一次 `1` 與 `@` | TBD |
| 35 | 自動（testSymbolsAndPages） | | TBD |
| 36 | 手動 | 地球鍵與長按選鍵盤需要人工操作 | TBD |
| 37 | 自動（testPersistence）加手動 | 自動部分不含重新啟動 App，該部分手動 | TBD |
| 38 | 自動（testAccessibilityLabels）加手動 | 自動檢查每顆鍵的標籤文字（此案例不要求 Mac 就緒，TextEdit 為空只代表沒有字送達）；VoiceOver 實際朗讀仍需手動 | TBD |
| 39 | 手動 | 需要 iPhone SE 3 或 mini | TBD |
| 40 | 自動（腳本）加手動 | 腳本檢查 Mac 端 Receiver 紀錄沒有任何輸入字串；iPhone 端診斷紀錄仍需手動 | TBD |

## 步驟

| 步驟 | 操作 | 預期 | 結果 |
|---|---|---|---|
| 1. 確認本版 | 鍵盤頂部顯示的版本時間與主代理告知的一致；欄位為一般文字欄位 | 底部小字顯示 `AppGroup: OK` 與本版 build 時間 | TBD |
| 2. Mac 就緒 | Mac 開啟 TextEdit 純文字文件；iPhone 鍵盤切到遠端（`遠端` 被選中） | 狀態列顯示 `Mac → TextEdit`；頂部為第一行加候選字空白列，共 2 行 | TBD |
| 3. Shift 單按 | 按一次 Shift，再按 `a` | Shift 變為實心箭頭，字母顯示大寫；打出 `A` 後自動回到小寫 | TBD |
| 4. Shift 雙按 | 快速連按兩次 Shift（0.3 秒內），打 `abc` | Shift 變為 Caps Lock 圖示，打出 `ABC`；打完後仍是大寫 | TBD |
| 5. Caps 關閉 | 在 Caps Lock 下再按一次 Shift | 字母恢復小寫，Shift 回到空心箭頭 | TBD |
| 6. 慢按兩次 Shift | 按一次 Shift，等超過 0.5 秒再按一次 | 第二次按下後回到小寫，不會進入 Caps Lock | TBD |
| 7. 即時送出 | 遠端、即時、Mac 就緒，打 `hello` | TextEdit 立即出現 `hello`；iPhone 欄位不出字；頂部維持 2 行 | TBD |
| 8. 空白與換行 | 按 `空白`，再按 `換行` | TextEdit 出現一個空白與一個換行 | TBD |
| 9. 遠端長按刪除 | 即時狀態下，TextEdit 先有一段文字，長按刪除鍵約 2 秒 | 按下立即刪 1 個字，0.5 秒後連續刪除（約每 0.1 秒一個），放開即停 | TBD |
| 10. 本機長按刪除 | 切到 `本機`，在 iPhone 欄位打一段文字後長按刪除鍵 | iPhone 欄位的字逐個連續刪除；Mac 不受影響 | TBD |
| 11. 本機打字 | 本機模式下打 `abc` | 字出現在 iPhone 欄位；頂部只有 `本機｜遠端` 與候選字空白列；狀態文字隱藏，沒有 `即時｜草稿` | TBD |
| 12. 本機到遠端 | 按 `遠端` | `遠端` 被選中，狀態文字與 `即時｜草稿` 出現；按鍵改送 Mac | TBD |
| 13. 遠端到本機 | 再按 `本機` | 狀態文字與 `即時｜草稿` 收起；按鍵回到寫入 iPhone 欄位 | TBD |
| 14. 切到草稿 | 遠端模式按 `草稿` | `草稿` 被選中；第二行草稿列出現（◀ ▶、文字區、傳送），鍵盤高度增加 36 pt | TBD |
| 15. 草稿打字 | 草稿狀態打 `abcd` | 字寫入草稿列，游標在最後；TextEdit 沒有任何新字；草稿為空時 `傳送` 為灰色 | TBD |
| 16. 游標左移 | 按 ◀ 兩次，再打 `X` | 草稿變為 `abXcd`，游標在 X 之後 | TBD |
| 17. 游標右移 | 按 ▶ 一次，再打 `Y` | 草稿變為 `abXcYd` | TBD |
| 18. 游標不動 Mac | 按 ◀ ▶ 多次，同時觀察 TextEdit 的游標 | TextEdit 的游標與內容完全不動 | TBD |
| 19. 草稿刪除 | 游標停在中段，按刪除 | 刪除游標前一個字元，TextEdit 不動 | TBD |
| 20. 傳送草稿 | Mac 就緒時按 `傳送`（藍色） | TextEdit 一次出現完整草稿；草稿列清空；`傳送` 變灰 | TBD |
| 21. 草稿換行 | 草稿打 `ab`，按 `換行`，再打 `cd`，按 `傳送` | 草稿內顯示換行記號；TextEdit 出現 `ab`、換行、`cd` | TBD |
| 22. 即時下刪除編輯草稿 | 草稿有字時切到 `即時`，按刪除 | 草稿被刪掉一個字，TextEdit 不動 | TBD |
| 23. 切回即時保留草稿 | 草稿有字時切到 `即時` | 草稿列仍然顯示並保留文字，直到送出或清空 | TBD |
| 24. 草稿有字時打字 | 即時狀態、草稿有字，打 `z` | `z` 進入草稿而不是 TextEdit | TBD |
| 25. 清空後恢復即時 | 草稿有字，先 `傳送` 清空，再打 `q` | 草稿列收起；`q` 直接出現在 TextEdit | TBD |
| 26. 未就緒寫草稿 | Mac 停止接收或讓 TextEdit 失去焦點，即時狀態打 `abc`，保持數秒 | 草稿列自動出現並寫入 `abc`；狀態顯示尚未就緒；`傳送` 為灰色；TextEdit 沒有任何字，也不會自動送出 | TBD |
| 27. 就緒後手動送出 | Mac 恢復接收並聚焦 TextEdit | `傳送` 轉為藍色；按下後才送出草稿 | TBD |
| 28. 草稿選擇沿用 | 選 `草稿` 後收起鍵盤、重新開啟，再切換 App 後回來 | `即時｜草稿` 沿用上次選擇 | TBD |
| 29. 遠端到本機草稿隱藏 | 草稿有字時切到 `本機` | 草稿列與 `即時｜草稿` 收起，鍵盤高度減少；打字進 iPhone 欄位 | TBD |
| 30. 本機到遠端草稿還原 | 再切回 `遠端` | 草稿列再度出現，文字與游標位置仍在 | TBD |
| 31. 草稿上限 | 草稿連續打滿 1,000 個字元後再打一個字 | 出現「草稿已達 1,000 字上限」，草稿不再增加；傳送後再次可打 | TBD |
| 32. email 欄位 | 在 Safari 或 Mail 的 email 欄位開啟鍵盤 | 開在英文頁（即使上次在符號頁） | TBD |
| 33. 數字欄位 | 在數字鍵盤的欄位開啟鍵盤 | 開在符號頁，數字列在最上面；`符號` 鍵顯示 `ABC` | TBD |
| 34. 符號回原頁 | 在英文頁按 `符號`，再按 `ABC` | 回到英文頁；符號頁的字元可正常輸入（遠端與本機各試一次） | TBD |
| 35. 中英停用 | 觀察 `中英` | 顯示為停用的淡色，按了沒有反應 | TBD |
| 36. 地球鍵 | 按 🌐（長按可選鍵盤） | 切到下一個鍵盤；🌐 只在系統需要時出現，位在 `中英` 左側 | TBD |
| 37. 重開沿用 | 收起鍵盤、重新開啟，並重新啟動 App | 模式、頁面（英文）、即時／草稿皆沿用 | TBD |
| 38. VoiceOver | 開啟 VoiceOver，逐一點選刪除、空白、換行、中英、符號、Shift、◀ ▶、傳送、本機｜遠端 | 每顆鍵都讀出台灣中文標籤（刪除、空白鍵、換行、中英切換、符號、大寫、游標左移、游標右移、傳送草稿）；字母鍵讀出字母 | TBD |
| 39. 375 pt 外觀 | 若有 iPhone SE 3 或 mini，開啟遠端草稿狀態（3 行） | 頂部三行、按鍵均不重疊、不截字；較長的提示（例如「3 個按鍵未確認是否送達」）可用兩行顯示 | TBD |
| 40. 紀錄不含明文 | 打完上述內容後，查看 Mac 與 iPhone 的診斷紀錄 | 紀錄只有事件種類、長度、時間與結果，找不到任何輸入的文字或草稿內容 | TBD |

結果：TBD
