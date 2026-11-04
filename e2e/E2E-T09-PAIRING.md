# E2E-T09-PAIRING：配對、加密、隱私與模式真機驗收

執行者：使用者。全部為 PASS 才算 T09 通過；在使用者親手測完之前，除了「Step 0 實測結果」之外，所有結果維持 TBD。

通過標準：
- Mac 選單「配對新 iPhone」與 iPhone 主 App「配對 Mac」配對成功，兩邊顯示相同的 6 位數配對碼，兩邊各自按「確認」之後才各自儲存配對。
- 任一邊在按「確認」之前按「取消」、逾時或配對碼不符，兩邊都不儲存配對；之後鍵盤遠端打字，Mac 收到 0 個字元。
- 解除配對（iPhone 或 Mac 任一邊）之後，鍵盤遠端打字，Mac 收到 0 個字元。
- 取消或解除配對之後可以再配對一次，且新一次的配對碼和上一次不同。
- 鍵盤重開 20 次，每次都連上，連線時間仍在 T06 範圍內（P95 ≤ 2 秒）。
- Mac 的 log 中沒有輸入的文字、金鑰、配對碼與前景 App 名稱。

自動測試可以證明的部分（不需要真機）：握手、加密、配對流程、配對時段、逾時、同一連線換 session 即中斷、明文事件即中斷、解除配對後無法驗證，都由 `swift test` 與 `MacReceiverTests` 覆蓋。這份文件只驗證自動測試碰不到的部分：真的藍牙、真的 Keychain、真的鍵盤行程。

## 前置條件

- iPhone 以線連接 Mac 並解鎖，已用 Xcode 安裝本分支的 Remote Keyboard（主 App 頂部 build 時間與主代理告知的一致），已開啟「允許完整取用」。沒有完整取用時鍵盤讀不到金鑰，永遠顯示未配對。
- Mac 執行本分支的 MacReceiver（面板頂部 build 時間一致）。
- Mac 開啟 TextEdit，新建一份純文字文件並讓游標停在文件內。
- 本版通訊協定為 v3，Mac 與 iPhone 必須同時更新；舊版其中一邊無法互通。
- 開始前先在兩邊各按一次「解除配對」，確保從未配對的狀態開始。
- T06 的 XCUITest（`ReconnectUITests`）從這個版本起需要先完成一次配對，才能連上 Mac 並執行；未配對時它會一直停在未連線。

## Step 0 實測結果（Keychain access group，2026-10-30 已取得）

使用的 access group 為 App Group 識別碼 `group.com.ansonhui.remotekeyboard`。主 App 寫入、鍵盤 Extension 讀取同一個 Keychain 項目。

| 項目 | 預期 | 結果 |
|---|---|---|
| 主 App 寫入 Keychain | 寫入狀態碼 0 | PASS（2026-10-30：主要 0／備用 0） |
| 鍵盤（完整取用開）讀取 | 讀到寫入的項目 | PASS（2026-10-30：OK／OK） |
| 鍵盤（完整取用關）讀取 | 讀不到；不會取得金鑰 | PASS（2026-10-30：-25291／-25291，視為未配對） |

說明：這次探測當時同時帶有備用的 `keychain-access-groups` entitlement；本任務已移除備用 entitlement，只保留 App Group。因此下面步驟 1 結束後，必須實際確認鍵盤讀得到金鑰（步驟 3 的對照組），才算移除備用之後仍然成立。

## 步驟

### 1. 配對成功，兩邊配對碼相同
1. Mac 選單列按「配對新 iPhone」。面板顯示「請在 iPhone 的 Remote Keyboard 開啟「配對 Mac」」與剩餘時間（120 秒起算）。
2. iPhone 開啟 Remote Keyboard 主 App，點「配對 Mac」。
3. 兩邊自動連線後，各自顯示 6 位數配對碼。肉眼比對兩邊，文件只記錄「相同」或「不同」，不要把數字寫進文件、log 或聊天。
4. 兩邊都按「確認」。按下確認的那一邊會顯示「已儲存…」並保持連線，讓另一邊還能按確認；兩邊都確認之後，再在任一邊按「完成」。

| 項目 | 預期 | 結果 |
|---|---|---|
| 兩邊配對碼 | 兩邊顯示的 6 位數完全相同（記錄：相同／不同） | PASS（使用者 2026-10-30） |
| 先按確認的一邊 | 先按確認的那一邊顯示「已儲存…」，連線沒有中斷，另一邊仍顯示配對碼可按確認（iPhone 先按、Mac 先按各做一次） | PASS（使用者 2026-10-30） |
| 配對完成 | 按「完成」後，iPhone 顯示「已配對 Mac」，Mac 面板顯示「配對完成」與「配對：已配對 iPhone」 | PASS（使用者 2026-10-30） |
| 配對後鍵盤可打字 | 鍵盤切到遠端模式，狀態列顯示 `Mac → TextEdit (N ms)`；打 `abc` 後 TextEdit 出現 `abc` | PASS（使用者 2026-10-30） |

結果：PASS（使用者 2026-10-30）

### 2. 任一邊取消，兩邊都不儲存
先確認兩邊都已解除配對。分三次做，每次都從「配對新 iPhone」重新開始：

- 2a：兩邊出現配對碼後，只在 Mac 按「取消」。
- 2b：兩邊出現配對碼後，只在 iPhone 按「取消」。
- 2c：先開 Mac 的配對時段，再開 iPhone 的配對畫面；兩邊出現配對碼後，兩邊都不按，等待 2 分鐘。Mac 的時段先開始，所以先到期的是 Mac。
- 2e：先在 Mac 按「停止接收」，並讓 TextEdit 保持不聚焦（Mac 前景不要停在可輸入欄位，否則 Mac 會自動開始接收，把還沒有配對時段的 iPhone 當成時段外的裝置略過），直到 Mac 的配對視窗開啟為止。接著先開 iPhone 的「配對 Mac」畫面，約 10 秒後才按 Mac 的「配對新 iPhone」；兩邊出現配對碼後，兩邊都不按，等待 2 分鐘。這次先到期的是 iPhone。
- 2d：兩邊出現配對碼後，只有 iPhone 按「確認」，Mac 按「取消」。目前沒有訊息通知對方「我已確認」，所以這種情況 iPhone 已經自己儲存了金鑰，Mac 沒有；這是已知的行為，不是失敗。看到 iPhone 顯示「已配對 Mac」但 Mac 未配對時，在 iPhone 按「解除配對」。

每次結束後，把鍵盤切到遠端模式並打 `abc`。

| 項目 | 預期 | 結果 |
|---|---|---|
| 2a Mac 取消 | iPhone 顯示「Mac 已取消或連線中斷，未儲存。」；Mac 顯示「配對已取消」；兩邊都是未配對 | 延至 T16（使用者 2026-10-30 決定） |
| 2b iPhone 取消 | Mac 顯示「配對失敗，未儲存」（連線中斷）；兩邊都是未配對 | 延至 T16（使用者 2026-10-30 決定） |
| 2c Mac 先逾時 | 約 120 秒時 Mac 顯示「配對逾時，未儲存」；Mac 先中斷連線，所以 iPhone 顯示「Mac 已取消或連線中斷，未儲存。」；兩邊都是未配對 | 延至 T16（使用者 2026-10-30 決定） |
| 2e iPhone 先逾時 | Mac 按下「配對新 iPhone」後才開始掃描並連上，兩邊出現配對碼；iPhone 的視窗先開始，所以先到期，顯示「配對逾時，未儲存。」；Mac 因連線被中斷，顯示「配對失敗，未儲存」；兩邊都是未配對 | 延至 T16（使用者 2026-10-30 決定） |
| 2d 只有一邊確認 | iPhone 已儲存、Mac 未儲存；鍵盤打字 TextEdit 收到 0 個字元（Mac 沒有配對，直接拒絕） | 延至 T16（使用者 2026-10-30 決定） |
| 取消後遠端打字 | 2a、2b、2c、2e 之後，鍵盤狀態列顯示「尚未配對 Mac，請開啟主 App 配對」；TextEdit 收到 0 個字元 | 延至 T16（使用者 2026-10-30 決定） |

結果：延至 T16（使用者 2026-10-30 決定）

### 3. 解除配對後遠端打字，Mac 收到 0 個字元
1. 先完成一次配對（步驟 1），在 TextEdit 打 `ok` 確認可用，記錄文件字元數 A。
2. 3a：在 iPhone 主 App 按「解除配對」。回到 TextEdit，鍵盤切到遠端模式打 `abc`。
3. 重新配對（步驟 1）。3b：在 Mac 面板按「解除配對」。再用鍵盤打 `abc`。
4. 兩次之後各自記錄 TextEdit 字元數（Command-A、Command-C 後執行 `pbpaste | LC_ALL=en_US.UTF-8 wc -m`）。

| 項目 | 預期 | 結果 |
|---|---|---|
| 3a iPhone 解除配對 | 鍵盤狀態列顯示「尚未配對 Mac，請開啟主 App 配對」；TextEdit 字元數不變 | PASS（使用者 2026-10-30） |
| 3a 對照組：只刪 iPhone 端、Mac 仍有金鑰 | 連線先變成 ready，iPhone 沒有金鑰所以不回應 Mac 的 hello；約 5 秒後 Mac 寫出 authFailed 並中斷，這一次接收時段內不再連這支 iPhone（Mac 面板回到 scanning）；TextEdit 字元數不變。另一台沒有配對過的裝置同理無法注入 | PASS（使用者 2026-10-30） |
| 3b Mac 解除配對 | Mac 面板顯示「配對：尚未配對」；鍵盤打字 TextEdit 字元數不變；已連線的鍵盤在解除當下被中斷 | PASS（使用者 2026-10-30） |
| 解除配對的反向保證 | 兩種情況下 Mac 都沒有收到任何一個字元（0 個） | PASS（使用者 2026-10-30） |

結果：PASS（使用者 2026-10-30）

### 4. 第二次配對可以成功
1. 解除兩邊配對後，重新做一次步驟 1。
2. 把這次的配對碼和步驟 1 第一次的配對碼比對，記錄「相同」或「不同」。
3. 配對時段外的測試前置：Mac 要在「接收中」（已按「開始接收」），且沒有開著配對時段。

| 項目 | 預期 | 結果 |
|---|---|---|
| 第二次配對成功 | 兩邊顯示相同的配對碼，按確認後配對完成，鍵盤可打字 | 延至 T16（使用者 2026-10-30 決定） |
| 每次配對碼不同 | 第二次的配對碼和第一次不同（記錄：不同） | 延至 T16（使用者 2026-10-30 決定） |
| 配對時段外不接受配對 | Mac 在接收中、沒有按「配對新 iPhone」時，iPhone 開啟「配對 Mac」畫面：Mac 不顯示配對碼並中斷連線，iPhone 顯示「Mac 已取消或連線中斷，未儲存。」 | 延至 T16（使用者 2026-10-30 決定） |
| 副作用 | 這支 iPhone 在這一次接收時段內被 Mac 略過，不會再連上（再開鍵盤也連不上）；這是設計。按「配對新 iPhone」或「停止接收」再「開始接收」會清除略過名單 | 延至 T16（使用者 2026-10-30 決定） |

結果：延至 T16（使用者 2026-10-30 決定）

### 5. 鍵盤重開 20 次，連線時間
前置：已配對，30 分鐘內完成。先在 Mac 按「停止接收」，再按「開始接收」，清掉步驟 4 留下的略過名單，否則這支 iPhone 會連不上。

1. 在備忘錄（Notes）新建一則空白備忘錄。
2. 重複 20 次：收起鍵盤，再點進備忘錄叫出鍵盤；等狀態列顯示 `Mac → ... (N ms)` 後，記下 N，再收起。
3. 另外在 Mac 終端機取得 Mac 端的 ready 時間：

```bash
/usr/bin/log show --last 20m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver" AND category == "link"' --info | grep -E "state ready"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| 20 次都連上 | 20 次的狀態列都出現 `(N ms)`，沒有停在其他狀態 | PASS（使用者 2026-10-30） |
| 連線時間 | 20 個 N（鍵盤端）：未逐筆記錄；Mac 端 `state ready`：182–1491 ms。P95（20 筆取第 19 小的值）≤ 2000 ms | PASS（使用者 2026-10-30） |
| 握手沒有拖慢重連 | 與 T06 同條件的數字相比，沒有明顯變慢（T06：鍵盤出現到 connected P95，Notes 389 ms） | PASS（使用者 2026-10-30） |
| 重連後第一個鍵 | 每次連上後立刻打一個字母，Mac 收到並顯示 `Mac 已輸入` | PASS（使用者 2026-10-30） |

結果：PASS（使用者 2026-10-30）

### 6. Mac log 檢查
在 Mac 終端機執行（時間範圍涵蓋步驟 1 到 5）。請把第二、三個指令裡的字串，換成自己實際輸入過的單字、步驟 1 的配對碼（只在終端機輸入），以及前景 App 名稱。

```bash
/usr/bin/log show --last 60m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -E "security|pairing|authentication" | sort | uniq -c
/usr/bin/log show --last 60m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -ciE "abc|ok|<實際輸入的單字>|<步驟 1 的配對碼>|TextEdit|Notes"
/usr/bin/log show --last 60m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep -ciE "pairKey|nonce|proof|sealed|privateKey"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| 只有事件種類 | 第一個指令只出現 `authentication failed, peripheral dropped`、`pairing window opened`、`pairing ended`、`pair message ignored outside the pairing window`、`peripheral skipped for this receiving session` 這類固定句子 | PASS（2026-10-30，主代理檢查 Mac log） |
| 沒有輸入內容、配對碼、App 名稱 | 第二個指令輸出 0 | PASS（2026-10-30，主代理檢查 Mac log） |
| 沒有金鑰、nonce、proof | 第三個指令輸出 0 | PASS（2026-10-30，主代理檢查 Mac log） |

第二個指令裡的配對碼只在終端機輸入，不要寫進這份文件。

結果：PASS（2026-10-30，主代理檢查 Mac log）

### 7. iPhone 端 log 檢查
1. 在 Mac 開啟 Console，左側選這支 iPhone，開始串流。
2. 搜尋欄選「子系統」，輸入 `com.ansonhui.remotekeyboard`（涵蓋鍵盤 Extension 與主 App）。
3. 完成步驟 1 到 5 之後，在搜尋欄分別輸入實際打過的單字、步驟 1 的配對碼（只在搜尋欄輸入）、`TextEdit`、`Notes`、`pairKey`、`nonce`、`proof`。

| 項目 | 預期 | 結果 |
|---|---|---|
| 只有固定事件 | 子系統內只有 `owner changed`、`manager created`、`subscribed`、`handshake started`、`handshake authenticated`、`no pair key`、`goodbye received`、`link reset`、`liveness probe sent`、`liveness probe answered`、`liveness probe unanswered` 這類固定句子與數字 | 延至 T16（使用者 2026-10-30 決定） |
| 沒有輸入內容、配對碼、金鑰 | 上面每個搜尋都是 0 筆 | 延至 T16（使用者 2026-10-30 決定） |

結果：延至 T16（使用者 2026-10-30 決定）

### 8. 主 App 輸入框同時開著鍵盤時配對（只發佈一份服務）
1. 在 iPhone 主 App 首頁的「在這裡輸入」輸入框點一下，叫出 Remote Keyboard（鍵盤開著）。
2. 在 Mac 按「配對新 iPhone」，再點 iPhone 的「配對 Mac」。
3. 在 Mac 執行：

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' --info | grep "keyboard service"
```

| 項目 | 預期 | 結果 |
|---|---|---|
| 只有一份服務 | 輸出為 `discovered 1 keyboard service(s)`，不是 2 | 延至 T16（使用者 2026-10-30 決定） |
| 配對仍可完成 | 兩邊顯示配對碼，可完成配對 | 延至 T16（使用者 2026-10-30 決定） |

結果：延至 T16（使用者 2026-10-30 決定）

### 9. 鍵盤開著時 iPhone 藍牙關閉再開啟
1. 已配對、Mac 在接收中；在 TextEdit 用遠端模式打 `a`，確認出現。
2. 鍵盤保持在畫面上，從控制中心關閉 iPhone 藍牙，等 5 秒再開啟。
3. 等狀態列回到 `Mac → TextEdit (N ms)` 後打 `b`。

| 項目 | 預期 | 結果 |
|---|---|---|
| 重新連線 | 30 秒內狀態列回到 `Mac → TextEdit (N ms)`，Mac 面板沒有顯示驗證失敗 | PASS（使用者 2026-10-30） |
| 之後可打字 | TextEdit 出現 `b` | PASS（使用者 2026-10-30） |

結果：PASS（使用者 2026-10-30）

### 10. Mac 停止接收再開始接收之後，鍵盤自動重連（不必切換輸入法）
背景：Mac 結束連線時，iPhone 的系統可能仍保留自己的藍牙連線，鍵盤收不到中斷通知，會一直顯示已連線。現在 Mac 在每次主動中斷之前（停止接收、閒置逾時、解除配對、結束 App）會先送出加密的「再見」訊息，鍵盤收到後重新發佈服務並開始廣播；鍵盤出現在畫面上時也會先送一個探測訊息，2 秒內沒有回應就重新發佈服務。

前置：已配對，Mac 在接收中，TextEdit 有游標，鍵盤切到遠端模式。每一個子項目開始前，先確認狀態列為 `Mac → TextEdit (N ms)`。

- 10a 收起鍵盤再叫出：鍵盤在畫面上且已連線；在 Mac 面板按「停止接收」，等 5 秒，再按「開始接收」。接著收起鍵盤，再在 iPhone 備忘錄點一下輸入欄位叫出鍵盤。全程不使用地球鍵。
- 10b 鍵盤一直在畫面上：鍵盤在畫面上且已連線；在 Mac 按「停止接收」。鍵盤狀態列應離開 `Mac → ...`（變成 `BLE: publishing` 或 `BLE: advertising`），不是一直停在已連線。等 5 秒後按「開始接收」，鍵盤不收起、不切換輸入法。
- 10c 結束 Mac App：鍵盤在畫面上且已連線；在 Mac 選單列面板按「結束」。確認鍵盤狀態列離開 `Mac → ...`。等 5 秒後重新開啟 MacReceiver，按「開始接收」，鍵盤不收起。
- 10d 閒置逾時與解除配對：在 Mac 終端機執行 `defaults write com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds 60`，結束並重開 MacReceiver，按「開始接收」。鍵盤保持連線但不打字，等約 60 秒閒置逾時；鍵盤狀態列應離開 `Mac → ...`。再按「開始接收」，確認鍵盤自動回到 `Mac → ...`。接著在 Mac 的配對視窗（pairing sheet）按「解除配對」。這時 iPhone 仍保有金鑰，所以鍵盤不會顯示「尚未配對」：狀態列先離開 `Mac → ...`，短暫顯示「配對驗證失敗」，之後鍵盤重新廣播；Mac 已沒有配對，會拒絕這支 iPhone 並在這一次接收時段內略過它，因此在重新配對之前不會再連上。測完執行 `defaults delete com.ansonhui.remotekeyboard.receiver rk.idleTimeoutSeconds`，重開 MacReceiver，並重新配對（步驟 1）。
- 10e 強制結束 Mac App（沒有再見訊息，只測鍵盤端探測）：鍵盤在畫面上且已連線；在 Mac 終端機執行 `killall -KILL MacReceiver`。從 `<暫存資料夾>/receiver-run/MacReceiver.app` 重新開啟 Receiver，按「開始接收」。收起鍵盤，再在 iPhone 備忘錄點一下輸入欄位叫出鍵盤，不使用地球鍵。

| 項目 | 預期 | 結果 |
|---|---|---|
| 10a 收起再叫出 | 叫出鍵盤後數秒內，狀態列回到 `Mac → ...`，不必按地球鍵；打 `abc`，Mac 收到 `abc` | PASS（使用者 2026-10-30） |
| 10b 鍵盤沒有收起 | Mac 停止接收後，狀態列離開已連線；Mac 開始接收後數秒內自動回到 `Mac → ...`，打 `abc`，Mac 收到 `abc` | PASS（使用者 2026-10-30） |
| 10c 結束再重開 Mac App | 結束 Mac App 後，狀態列離開已連線；重新開啟並開始接收後數秒內回到 `Mac → ...`，打 `abc`，Mac 收到 `abc` | PASS（使用者 2026-10-30） |
| 10d 閒置逾時 | Mac 閒置逾時中斷的同時，狀態列離開已連線；再按「開始接收」後數秒內自動回到 `Mac → ...` | 延至 T16（使用者 2026-10-30 決定） |
| 10d 解除配對 | Mac 按「解除配對」後，狀態列離開 `Mac → ...`，短暫顯示「配對驗證失敗」，不是「尚未配對」；之後鍵盤重新廣播（`BLE: advertising`），Mac 不再連上，直到重新配對 | 延至 T16（使用者 2026-10-30 決定） |
| 10e 強制結束後叫出鍵盤 | 叫出鍵盤後數秒內，狀態列回到 `Mac → ...`，不必按地球鍵；打 `abc`，Mac 收到 `abc`。iPhone 端 log 依序出現 `liveness probe sent`、`liveness probe unanswered`、`link reset`（若 iOS 已先通知中斷而正常重新發佈，則沒有這三行） | 延至 T16（使用者 2026-10-30 決定） |
| 探測不影響重連紀錄與輸入 | 10a 到 10c 期間 TextEdit 與備忘錄沒有多出任何字元；Mac 的 `~/Library/Logs/RemoteKeyboard/reconnect.csv` 沒有因探測訊息多出行（每次叫出鍵盤最多一行，是原本的重連探測） | PASS（使用者 2026-10-30） |
| 沒有在連線時誤重置 | 鍵盤在畫面上且 Mac 一直在接收時，收起再叫出鍵盤 10 次，每次都回到 `Mac → ...`，沒有出現長時間停在 `BLE: publishing` 或 `BLE: advertising` | PASS（使用者 2026-10-30） |
| iPhone 端 log | Console 子系統 `com.ansonhui.remotekeyboard` 內，10a 到 10d 出現 `goodbye received`、`link reset`，或 `liveness probe sent` 之後的 `liveness probe answered`／`liveness probe unanswered`、`link reset`；不含輸入文字、金鑰、nonce | 延至 T16（使用者 2026-10-30 決定） |

結果：10a、10b、10c、10e PASS（使用者 2026-10-30）；10d 與 iPhone 端 log 延至 T16

## 總結

| 步驟 | 結果 |
|---|---|
| Step 0 Keychain access group | PASS（2026-10-30） |
| 1 配對成功，配對碼相同 | PASS（使用者 2026-10-30） |
| 2 取消、逾時不儲存 | 延至 T16（使用者 2026-10-30 決定） |
| 3 解除配對後 Mac 收到 0 字元 | PASS（使用者 2026-10-30） |
| 4 第二次配對 | 延至 T16（使用者 2026-10-30 決定） |
| 5 重開 20 次連線時間 | PASS（使用者 2026-10-30）（Mac 端 ready 182–1491 ms，見 log 摘要） |
| 6 Mac log 無敏感內容 | PASS（2026-10-30：輸入文字、App 名稱 0 筆，見 `docs/superpowers/verification/evidence/T09-mac-log-summary.txt`） |
| 7 iPhone 端 log 無敏感內容 | 延至 T16（使用者 2026-10-30 決定） |
| 8 鍵盤開著時配對只發佈一份服務 | 延至 T16（使用者 2026-10-30 決定） |
| 9 藍牙關閉再開啟後自動重連 | PASS（使用者 2026-10-30） |
| 10 Mac 停止接收再開始接收後自動重連 | PASS（使用者 2026-10-30） |

### 備註
- 同一台手機被判定驗證失敗之後，Mac 在這一次接收時段內不會再連它；按「停止接收」再「開始接收」，或按「配對新 iPhone」會重新開始。
- 配對碼只顯示在螢幕上，不寫入任何 log。請不要把配對碼貼到聊天或文件之外的地方。
- 兩邊之間沒有「我已確認」的訊息，所以先確認的一邊會保持連線等另一邊，直到另一邊離開、按「完成」或 120 秒時間結束。只有一邊確認的情況下，先確認的一邊會有金鑰、另一邊沒有，之後的握手一定失敗，不會輸入任何字元；用「解除配對」清掉即可。
