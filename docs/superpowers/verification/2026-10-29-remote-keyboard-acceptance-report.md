# Remote Keyboard 實作驗收報告（模板／目前結果）

**版本：** v1.0 | **最後更新：** 2026-10-31 | **本次工程測試狀態：11/17 PASS（T01–T10、T13，M1 Gate 通過；v1.3 新增 T12b），其餘 NOT_STARTED**

> **證據規則：**只有實際執行測試、保存完整輸出並核對結果後才可填 PASS；文獻研究不算 PASS。不可事後推測 log 或填虛構時間。

## 狀態概覽

| 指標 | 結果 |
|---|---|
| Product spec | v1.3 APPROVED 2026-10-30（含設計決定 D1–D17） |
| Research/source review | 深度研究已有報告；未執行 code 實測 |
| Xcode build | iOS Simulator 與 macOS build 成功（commit c78b6ea，2026-10-29） |
| `swift test` | 6 tests，0 failures（commit c78b6ea） |
| 實機連線 Gate | PASS（T06：100 次重開 99–100 次連上，鍵盤出現 → 連上 P95 ≤ 389 ms，2026-10-30） |
| Mac AX 注入 Gate | PASS（T04／T05 實機，2026-10-30；未逐項記錄項目於 T16 補測） |
| Security Gate | NOT_RUN |
| Dictation Gate | NOT_RUN |
| Release / App Review | NOT_STARTED |

## 開工前待解決事項（2026-10-29）

| # | 事項 | 負責 | 何時需要 | 狀態 |
|---|---|---|---|---|
| O1 | 實體 iPhone 以 USB 連接 Mac、信任此電腦、開啟 Developer Mode | 使用者 | T03 前 | PASS（iPhone 17 Pro、iOS 27.0.1、wired、Developer Mode Enabled） |
| O2 | Xcode 登入 Apple ID 取得 Personal Team 簽名身分（目前 0 個） | 使用者 | T01 真機驗收前 | PASS（Personal Team 4YN34HPX6F，1 個 Apple Development 身分） |
| O3 | Personal Team 下 App Group 是否可用，決定 D3 配對路徑 | T01 | T01 | PASS（簽名含 `group.com.ansonhui.remotekeyboard`，Extension 讀到主 App 寫入值；T09 可走主 App 配對，D3 備案保留） |
| O4 | Keyboard Extension 內 CoreBluetooth 權限與 Full Access 組合 | T03a | T03a | PASS（授權＋Full Access → advertising；無 Full Access → no-full-access；拒絕授權 → unavailable；四格 Local 正常、無 crash） |
| O5 | `CGEventKeyboardSetUnicodeString` 單一事件長度上限 | T04 | T16 | 延後：使用者 2026-10-30 決定於最後測試（T16）以選單「O5 長度測試」量測；目前以每段 20 UTF-16 切段 |
| O6 | XCUITest 能否在真機切換到第三方鍵盤（D9） | T06 | T06 | PASS（真機讀到鍵盤 `rk.status`；需先在 Xcode 圖形介面 Build For Testing 一次建立描述檔；iPhone 為繁體中文，按鍵以中英文名稱比對） |
| O7 | 手寫辨識引擎：先測 Apple 原生（PencilKit 公開 API、Vision `zh-Hant` 辨識筆跡圖），未過 Gate 才測 Google ML Kit Digital Ink；Gate：記憶體留 20% 餘量、延遲 P95 ≤ 500 ms、20 字首選 ≥ 18（使用者 2026-10-30 決定次序） | T12 Step 1 | T12 | PASS（使用者 2026-10-30 決定採 Google ML Kit；Apple 原生實機未達標，日後再評估；見 `evidence/T12-o7-result.md`） |
| O8 | Keyboard Extension 以 `retrieveConnectedPeripherals(withServices:)` 能否取得已連線的 Mac；取不到時掃描路徑能否完成連線 | T03 | T03 | FAIL → 改採 D11；Mac 掃描連入 iPhone 鍵盤 PASS（T03b） |
| O9 | 速成字碼表來源授權可隨 App 散布，授權檔附於 App | T12b Step 0 | T12b | PASS（2026-10-31：libcangjie `data/table.txt`，Public Domain；比較見 `evidence/T12b-o9-license.md`） |

## 任務逐項驗收狀態

| Case | 任務 | 目前狀態 | 通過條件 | 實測結果 | 證據檔 |
|---|---|---|---|---|---|
| T01 | 工程基礎與離線 Local Mode | PASS | 真機 Notes 輸入 20 字正確且在無 Full Access 照常 | 自動：swift test 6/0、iOS Simulator 與 macOS build 成功。實機（iPhone 17 Pro、iOS 27.0.1、Full Access 關閉，2026-10-29 17:18）：備忘錄輸入 `Hello World` 與 26 個字母共 37 字元逐字一致，Return、Backspace、Shift 正常，系統 🌐 可切換鍵盤，`AppGroup: OK` | `e2e/E2E-T01-LOCAL.md`、`evidence/T01-device-notes-hello-world.webp`、`evidence/T01-sim-*.png` |
| T02 | Mac Receiver Shell、BLE GATT Advertiser | PASS | macOS GATT service 完整可發現，service publish 成功 | 自動：swift test 8/0、MacReceiverTests 5/5（含 4 個生命週期測試）。實機（2026-10-29）：選單列 `BLE: advertising`；iPhone nRF Connect 掃到 Connectable 廣播與 service UUID `2A6F212A…`；Mac bluetoothd 紀錄確認 service 與 3 個 characteristic（write／notify／read notify）。iPhone 端連線因既有系統 LE 連線無法以 nRF 完成，characteristic 探索改由 T03 驗證（使用者 2026-10-29 批准） | `e2e/E2E-T02-GATT.md`、`evidence/T02-*` |
| T03 | BLE 連線（v1.2：T03a iPhone Peripheral＋T03b Mac Central） | PASS | T03a：O4 四格不 crash、Local 照常、授權齊全時 Notes／Safari 進入 advertising；T03b：Notes、Safari 反覆叫出鍵盤皆 connected | T03a（7b38be1）：見 E2E-T03A。T03b（782b5a8，2026-10-29）：Core 58/0、MacReceiverTests 18/18；實機多個 App 反覆連上（Mac log 9 次 ready，200–783 ms，未逐次記錄 10＋10，使用者接受為通過）；收起鍵盤回到 scanning；60 秒覆寫下 menu 開啟仍倒數、到時自動待命、鍵盤連上重置倒數（修正兩輪：計時器 run loop mode、連上計為活動）。舊 v1.1 T03 FAIL 見交接紀錄 | `e2e/E2E-T03A-PERIPHERAL.md`、`e2e/E2E-T03B-LINK.md`、`verification/2026-10-29-handoff.md` |
| T04 | Mac 焦點感知與 Unicode 注入 | PASS | TextEdit 5 組字串逐一完全一致；注音狀態 20/20；切換至非可編輯焦點時 0 誤注入 | 自動（ee14849，2026-10-29）：Core 82/0、MacReceiverTests 32/32、iOS 與 macOS build 成功；涵蓋焦點守衛判斷順序、grapheme 不拆段、ABC 切換驗證失敗不注入、注入後 settle 再切回、連續兩次注入排隊不交錯。實作差異：輔助使用授權提示改為使用者按「授權輔助使用」或啟動測試插入時才出現；`AXValue` 可設定且值為字串才算可編輯；前景為 Receiver 本身時一律不可編輯。實機：TBD  `e2e/E2E-T04-INJECT.md` |
| T05 | 最小端到端 A 鍵輸入 PoC | PASS | Notes→TextEdit、Safari→TextEdit 各 20 次成功，0 錯誤焦點 | 自動（e097453，2026-10-30）：Core 124/0、MacReceiverTests 69/69、iOS 模擬器、macOS、iOS 真機簽名 build 成功；涵蓋事件編解碼、notify 佇列滿時保序、Remote 未就緒拒收、無 Full Access 回到 Local、Mac 逐筆處理與 ACK 對應、焦點世代過期拒收、組字中先取消再切換（D4 修訂）。單元測試不啟動實際掃描與注入。實機（b23fd2b，2026-10-30 02:17–02:39）：iPhone 遠端模式打字送到 Mac，206 個事件（文字 178、Backspace 25、Return 3）全部 `posted`，實際使用中 0 拒收；8 次連線各只發現 1 個 service，ready 56–480 ms；狀態列隨 Mac App 切換、不能輸入時有提示。第一次實機測試發現兩個藍牙管理器同時發佈 service、選單點擊錯位，修正三輪後通過。使用者決定以此通過，Notes／Safari 各 20 次逐次、⌘Tab 5 次、注音組字、關閉 Full Access、60 秒逾時延至 T16 逐項紀錄 | `e2e/E2E-T05-A-KEY.md`、`evidence/T05-mac-receiver-log-excerpt.txt` |
| T06 | BLE Lifecycle／冷啟動 Gate | PASS | 100 次鍵盤重開連線 >=99 成功；已配對且 Mac awake 的 P95 <=2 秒（以鍵盤出現 → 連上計，使用者 2026-10-30 決定） | 自動（37cad25）：Core 172/0、MacReceiverTests 86/86、UI test 編譯成功。實機 XCUITest（Notes／Safari 交替）：第 1 輪 100/100 連上；第 2 輪分段計時 99/100（#54 Safari 鍵盤未出現，非藍牙失敗），鍵盤出現 → 連上 P95 Notes 389 ms、Safari 224 ms；iPhone 端計時 P95 647／710 ms。點擊 → 連上 P95 2329／2370 ms，其中 XCUITest 點擊動作本身中位數 Notes 696 ms、Safari 1813 ms，使用者判定不計入。第 1 輪曾以點擊 → 連上判 FAIL，分段後改判。異常情境各 5/5：iPhone 藍牙關再開、Mac 藍牙關再開（開始連線 → ready 2.9–4.5 秒）、Mac 睡眠喚醒、強制關閉 Notes。親手抽查 10 次錄影延至 T16 | `e2e/E2E-T06-RECONNECT.md`、`evidence/T06-*` |
| T07 | 協定分幀、UTF-8 與事件流 | PASS | 1000 組 fuzz/邊界 frames，0 誤解析 | 自動（2026-10-30）：Core 198/0、MacReceiverTests 91/91、iOS 模擬器與真機簽名 build、macOS build 成功。`testFuzzedFramesNeverCrashOrComplete` 1,000 個隨機 frame：0 complete、998 rejected、2 incomplete，0 crash、0 誤解析。涵蓋 frame 上限、重複 index、index 越界、斷線丟棄殘片、新訊息取代殘片時不遺失新訊息（主代理裁定）、v1 payload 回報不支援版本、UTF-8／ZWJ emoji 跨 frame 重組；3,000 字元 TEXT = 35 個 182 bytes frame。實機（使用者 2026-10-30）：3,000 字元 TEXT 收到 3000 字、shasum 與預期字串相同（`cfb204f9…`）、放開長按不多出換行；一般打字回歸（字母、空白、倒退、Return）、長訊息後再打字、長訊息中收起鍵盤再重連打 `ok` 皆正常；Mac log 0 筆輸入文字、0 次 frame 拒收，重連 ready 416／525 ms | `e2e/E2E-T07-FRAMING.md`、`evidence/T07-mac-log-summary.txt` |
| T08 | ACK、去重、排序、失敗語義 | PASS | 重複100次 seq 單次 commit、亂序安全、10000 events 受控 TextEdit 0 遺漏/重複/亂序（10,000 事件併入 T15） | 自動（2026-10-30）：Core 222/0、MacReceiverTests 104/104、iOS 模擬器與真機簽名 build、macOS build 成功。同一事件送 100 次只注入 1 次、ACK 100 次皆為原結果；同 session 較小 seq 回 `outOfOrder` 不注入；拒收或失敗的事件重送不會改為注入；ping 回 `pong` 且不經去重；注入失敗回 `injectFailed`；斷線不清空去重紀錄；iPhone 斷線時回報未確認按鍵數且不重送；coordinator 從點擊輸入框到事件 ACK 的接線測試。實機（使用者 2026-10-30）：約 3 分鐘打字（含快速連按）內容與輸入一致；打字途中關 iPhone 藍牙再開、等 30 秒，TextEdit 字數 A = B = 198，沒有自動補送，之後 `ok` 正常；Mac log 207 文字、16 倒退、7 return 皆 `posted`，10 次 ping 皆 `pong`，0 筆輸入文字。「N 個按鍵未確認」提示因 Mac 數十 ms 內即回覆而無法手動觸發，由自動測試確認（使用者同意） | `e2e/E2E-T08-ACK.md`、`evidence/T08-mac-log-summary.txt` |
| T09 | 配對身份認證、隱私與 Local/Remote 模式 | PASS | 未配對設備/錯 token/撤銷配對不能注入；模式清晰、Remote 關閉不送 Mac | 自動（2026-10-30）：Core 326/0、MacReceiverTests 149/149、iOS 模擬器與真機簽名 build、macOS build 成功。配對：ECDH（P256）＋公鑰承諾（pairOffer 只帶雜湊、Mac 回金鑰後才公開）＋6 位數比對碼，每次配對新金鑰，各自按確認才儲存；連線：雙向 challenge-response，iPhone 驗證 Mac 前不送事件，Mac 驗證 iPhone 前不送 App 名稱；事件與 Mac 回覆皆以方向不同的 session key（ChaChaPoly）加密，明文事件即中斷並略過該 iPhone；同一連線換 session 即中斷；iPhone 只接受已訂閱的 Mac 寫入；藍牙斷電時釋放綁定。兩輪獨立安全審查（含公鑰承諾、控制通道加密、DoS 綁定）全部修正。Step 0 實機：主 App 寫入 0/0、鍵盤有 Full Access 讀取 OK/OK、無 Full Access -25291。規格差異：以應用層加密取代 BLE 加密權限（主代理裁定）。實機（使用者 2026-10-30）：配對兩邊比對碼相同、配對後可打字；iPhone 或 Mac 解除配對後 Mac 收到 0 字元；重開 20 次皆連上（Mac 端 ready 182–1491 ms）；藍牙關再開自動重連；Mac 停止再開始接收、結束再重開 App、強制結束 App 後，收起再叫出鍵盤或鍵盤一直在畫面上皆自動重連，不必按地球鍵（此項首次實測失敗，根因為同一 iCloud 的系統藍牙連線讓 iOS 收不到取消訂閱，以 Mac 加密「再見」訊息與鍵盤出現時探測修正，PR #19）；Mac log 0 筆輸入文字與 App 名稱。延至 T16：取消／逾時不儲存、第二次配對、iPhone 端 log、鍵盤開著時配對只發佈一份服務、閒置逾時與解除配對的重連（使用者決定） | `e2e/E2E-T09-PAIRING.md`、`evidence/T09-mac-log-summary.txt` |
| T10 | 原生風格英文 QWERTY 操作 | PASS | 操作表 40/40、iPhone 尺寸 UI 不重疊 | 自動（2026-10-30）：Core 412/0、MacReceiverTests 164/0、iOS 模擬器 build 與 UI test build 成功。鍵盤改為三頁導覽（中英鍵在 T12 前停用）、英文 QWERTY（Shift 單按一次大寫、0.3 秒內雙按為大寫鎖定）、刪除長按 0.5 秒後每 0.1 秒連續刪除；頂部區：本機模式只顯示本機／遠端與候選字占位，遠端模式加狀態與即時／草稿；草稿列在草稿狀態、草稿非空或未就緒時出現，傳送只在就緒且草稿非空時可按。遠端模式下草稿非空、草稿狀態或未就緒時所有按鍵（含刪除、換行）只編輯草稿，左右鍵不送 Mac；草稿上限 1,000 字元，送出時依換行切成 TEXT 與 RETURN，每個 TEXT 不超過 2,000 bytes 且不切開字形；本機模式不動草稿。email、URL 欄位開英文頁，數字欄位開符號頁（T11 前為臨時符號頁）。模擬器預覽截圖：402 pt（iPhone 18 Pro，與使用者的 iPhone 17 Pro 同寬）與 375 pt（iPhone SE 3），本機、遠端即時、遠端草稿、未就緒、符號頁、大寫鎖定六種狀態皆不重疊、不截字；鍵盤高 284 pt（兩行頂部）、320 pt（三行頂部），按鍵高 42 pt、行距 12 pt、按鍵區 212 pt。獨立審查一輪修正（重連 UI 測試改由測試自行切到遠端、空草稿按傳送不再顯示未就緒、鍵離開視窗即停止連續刪除、被拒的字不消耗一次大寫）。有完整取用時每次按鍵輕震一下。實機（2026-10-30，iPhone 17 Pro）：自動實機測試 10 個案例 PASS（Shift／大寫鎖定、即時送出、長按刪除、本機模式、草稿編輯與中段插入、草稿有字時刪除只改草稿、未就緒寫草稿再手動送出、遠端與本機切換保留草稿、符號頁、無障礙標籤、重開沿用），並以 Mac Receiver 紀錄逐案核對事件數一致；地球鍵與整體操作由使用者手測 PASS；使用者回饋字母鍵過高、無震動，已改為 42 pt 與輕震（PR #22）。延至 T16（使用者決定）：草稿上限、email 與數字欄位、42 pt 與震動手感、VoiceOver 朗讀、375 pt 實機外觀、iPhone 端紀錄 | `e2e/E2E-T10-KEYBOARD.md`、`evidence/T10-402-*.png`、`evidence/T10-375-*.png`、`e2e/scripts/t10-device-run.sh` |
| T11 | 數字 123／符號 #+= 兩頁 | 自動通過，實機延至 T16 | 全部鍵位 mapping unit tests 100%，不因切換頁重覆注入 | 自動（2026-10-31）：Core 551/0、iOS 模擬器與真機 build、UI 測試 build-for-testing 成功。`SymbolLayouts` 依計劃：英文兩層（同 Apple）、中文三層（第 1 層數字加全形標點，第 2、3 層同英文），換層鍵 `#+=`／`123`、`半形`／`#+=`／`全形`；每次進入回第 1 層；按鍵與英文頁同一路徑、刪除長按連刪；高度不變。402 與 375 pt 預覽五種狀態無截字。獨立審查通過。實機：延至 T16（`e2e/E2E-T11-SYMBOLS.md`） | `e2e/E2E-T11-SYMBOLS.md`、`evidence/T11-402-english1.png`、`evidence/T11-375-chinese1.png` |
| T12 | 中文輸入法介面、設定頁與繁體中文手寫 | 自動通過，實機 TBD | 指定 100 字測例 top-3 >=90%，25 字混合詞語輸入無殘留，extension 30 次切換無 OOM | 自動（2026-10-30）：Core 471/0、iOS 真機與模擬器 workspace build 成功；手寫採 Google ML Kit（`zh-Hani-TW`，CocoaPods），主 App 下載模型後放入 App Group，鍵盤自動匯入（先複製到暫存資料夾再一次替換）；候選字只列中文字、最多 9 個，每寫完一筆即時辨識，傳入真實筆跡時間與前文；空白等待最新一筆辨識（最多 1 秒）再送出；送出經 InputRouter，遵守即時／草稿規則；無完整取用時只有英文頁。模擬器截圖 402 與 375 pt。獨立審查兩輪修正後通過。使用者實機回饋手寫板不夠高，手寫頁加高 60 pt（書寫區 210 pt，鍵盤 344／380 pt；Core 472/0，PR #26）。手寫頁改為原生式版面（使用者 2026-10-31）：刪除鍵移到候選字列最右（只在中文頁）、書寫區全寬（高度不變）、「重寫」移到底列空白與換行之間；底列位置不變；候選字列捲動區關閉 iOS 26 邊緣效果並固定 36 pt（使用者實機見候選字上半截被裁，根因未在模擬器重現，待實機確認）；Core 482/0、模擬器與真機 build 成功，獨立審查通過（PR #27）。實機（2026-10-31 02:14–02:17，使用者截圖，DEBUG 診斷版）：備忘錄與 Spotlight、本機與遠端（即時、草稿）共 5 次，候選字完整不被裁、模型就緒、辨識 24–116 ms、9 個候選字；安裝 PR #27 後曾有一次本機模式完全沒有候選字且空白不出字（Spotlight，02:01），之後 5 次未能重現，原因未明（診斷分支 `t12c-candidate-diag` 只在本機保留）；刪除鍵與重寫的實機行為延至 T16。實機：TBD；100 字測例、30 次切換、OOM 延至 T16 | `e2e/E2E-T12-HANDWRITING.md`、`evidence/T12-o7-result.md`、`evidence/T12-402-handwriting.png`、`evidence/T12-375-handwriting.png`、`evidence/T12c-*.png`、`evidence/T12c-device-local-diag.webp` |
| T12b | 速成 | 自動通過，實機延至 T16 | 50 個常用字本機與遠端皆正確；無 Full Access 時中文頁為速成可打字；字碼表授權已記錄（O9） | 自動（2026-10-31）：Core 579/0、iOS 模擬器與真機 build、UI 測試 build-for-testing 成功。字碼表由 libcangjie（Public Domain）產生，只收 Big5 中文字 13,980 行，速成碼取倉頡五代碼首尾（五代為 NA 時用三代），同碼依 Big5 次序（非字頻，已知限制）；表載入約 14 ms。速成頁沿用英文頁版面，鍵面字根加角落字母；最多 2 碼、空白送第一候選、Return 清碼、⇧ 單次大寫且亮燈跟輸入法狀態；有輸入碼時刪除不連刪；無完整取用時中文頁為速成；設定頁可選速成並有「授權」頁。獨立審查兩輪後通過。實機：延至 T16（`e2e/E2E-T12B-QUICK.md`） | `e2e/E2E-T12B-QUICK.md`、`evidence/T12b-o9-license.md` |
| T13 | 語音聽寫獨立可行性 Gate | PASS（使用者實機 2026-10-31） | 中英各 5 句（使用者 2026-10-30 決定）五項全部 PASS 且 API 合規 | 自動（2026-10-31）：Core 525/0、iOS 模擬器、真機與 Release build 成功。新增 `ContextDiff`（共同前綴，刪除以 Character 計退格）與 `DictationMirror`（只在遠端模式且 DEBUG 探測開啟時把 iPhone 欄位的變化轉成差分送 Mac；換文件、截斷窗口、過大差分只重設基準不送出；探測開關 30 分鐘後不再自動還原）；探測面板在英文頁蓋住字母鍵區顯示五項計數；正式（非 DEBUG）行為與 main 相同；log 只記種類與長度。獨立審查兩輪修正後接受。使用者實機（2026-10-31，iPhone 17 Pro，DEBUG 探測）：即時模式中文一句「測試1234你好，香港5678」聽寫中途的自動修正同步到 Mac，TextEdit 與備忘錄逐字相同；草稿模式中英混合聽寫的差分進入草稿列（面板：did 4、基準 0、稿 13），可用 ◀ ▶ 編輯後傳送；英文聽寫同步。使用者判定五項 PASS，語音 Gate PASS。觀察：草稿列顯示「吃法 good good day」而欄位為「…吃法 good day」，可能與使用者在草稿中移動游標編輯有關，未查明，正式化時再驗；探測面板蓋住字母區的刪除鍵（只限 DEBUG 探測）。中英各 50 句完整版延至 T16。T13b（2026-10-31，spec v1.4 D18、D19）：聽寫同步正式化，遠端模式自動同步（主 App 設定「聽寫同步到 Mac」，預設開），Release 沒有探測面板；草稿模式帶退格的修正先比對草稿游標前文字，不符則整個差分略過並提示（單元測試重現「聽寫中途移動草稿游標」會錯位，為實機「good good」的可能成因）；底列改為符號在中英前。Core 541/0、模擬器、真機 Debug 與 Release build 成功，獨立審查兩輪後通過。安裝 PR #32 後鍵盤一出現即閃退（`textDocumentProxy.documentIdentifier` 在部分欄位回 nil，Swift UUID 轉換中止），PR #33 改為先確認再經 Objective-C 讀取，使用者 2026-10-31 實機確認不再閃退。其餘實機：TBD（`e2e/E2E-T13B-DICTATION-SYNC.md`） | `e2e/E2E-T13-DICTATION.md`、`evidence/T13-402-probe.png`、`evidence/T13-device-iphone-instant.webp`、`evidence/T13-device-mac-textedit.png`、`e2e/E2E-T13B-DICTATION-SYNC.md` |
| T14 | 跨 App 相容性、Mac 焦點安全矩陣 | 自動通過，矩陣延至 T16 | 容許欄位、已建立遠端模式輸入無錯焦；blocked 欄位正確回退 | 自動（2026-10-31）：Core 590/0、Mac 180/0、iOS 真機與 Mac Release build 成功。Mac 焦點讀取移到背景，讀完重查前景 App，不同即不送（fail closed）；舊讀取不覆蓋新結果；測試插入在等待後與送出前各重查焦點；輸入法切回失敗回報 `injectedRestoreFailed`（仍回 ACK，不宣稱 exactly-once），Mac 面板顯示「輸入法未能切回，請手動切換」，直到目前輸入法不是 ABC 才清除。已知限制：組字取消（AXCompositionAdapter）仍在主執行緒。獨立審查兩輪後通過。矩陣：延至 T16（`e2e/E2E-T14-MATRIX.md`、`evidence/T14-matrix.csv`） | `e2e/E2E-T14-MATRIX.md`、`evidence/T14-matrix.csv` |
| T15 | 穩定性、權限、Wi-Fi 降級驗證 | 自動通過，實機延至 T16 | 無授權/無焦點永遠 fail closed，任一失敗可提示及恢復；Wi-Fi 測試有權限和身份驗證 | 自動（2026-10-31）：Core 588/0、Mac 168/0、iOS 模擬器、真機與 Release build 成功。`BurstFormat`（每行 `#n`）與驗證（遺漏、重複、亂序）；DEBUG 壓力測試：遠端模式長按「換行」超過 4 秒，經正常路徑送 10,000 行（每行文字加換行鍵，未確認最多 16 個），Mac 面板 DEBUG「驗證 burst」以 AX 讀 TextEdit 並只顯示數字；Release 不含兩個 DEBUG 檔的符號。Wi-Fi 項目 N/A（D8，見 T06）。獨立審查通過。實機（10,000 行、權限撤銷各 3 次）：延至 T16（`e2e/E2E-T15-STABILITY.md`） | `e2e/E2E-T15-STABILITY.md` |
| T16 | Release Candidate QA、文件與分發審核 | 自動通過，實機總清單 TBD | 全部必需 Gate 通過且帶 log/截圖/測試版本，無 blocker | 自動（2026-10-31）：Core 597/0、Mac 187/0、iOS 真機 build 與 UI 測試 build-for-testing 成功。Mac 未授權輔助使用時鍵盤顯示「Mac 未授權輔助使用」（ReceiverStatus 新增 `trusted`，只在未授權時寫入，已授權時位元組與舊版相同）；Receiver 面板顯示不可用原因；central 接線測試；UI 測試清理。實機總清單 `e2e/E2E-T16-RC.md`：145 項（必要 129、可選 16），約 5 小時 20 分鐘，結果 TBD。獨立審查一輪修正後接受 | `e2e/E2E-T16-RC.md` |
| D20 | 按鍵觸及範圍外擴（使用者 2026-10-31 回報空隙按不到） | 自動通過，實機 TBD | 鍵、行之間與鍵區邊緣的空白送出最近的鍵；不搶候選字列、頂部區與手寫書寫區；手寫提示訊息時點擊不送字 | 自動（2026-10-31）：Core 606/0（`KeyHitResolverTests` 9 項）、iOS 真機 build 與 UI 測試 build-for-testing 成功；獨立審查 1 項 Important（手寫提示區）已修。實機見 `E2E-T16-RC.md` B23–B28 |
| D21 | 按鍵聲音與震動開關 | 自動通過，實機 TBD | 兩開關各自生效；預設開；靜音時無聲；無完整取用時無震動 | 自動（2026-10-31）：Core 611/0（`KeyFeedbackSettingsTests` 5 項）、iOS 模擬器／真機 build 與 UI 測試 build-for-testing 成功；設定頁截圖確認預設開。實機見 `E2E-T16-RC.md` B29–B34 |
| D22 | 收起鍵盤鍵與按鍵聲修正 | 自動通過，實機 TBD | 收起鍵在即時／草稿左邊，按下收起且草稿保留；按鍵有聲 | 自動（2026-10-31）：Core 617/0（新增 `testDismissKeyboardOnlyReportsDismissAndKeepsTheDraft`，先 RED 後 GREEN）、iOS 模擬器／真機 build 與 UI 測試 build-for-testing 成功；預覽截圖（402、375 pt，本機與遠端）確認收起鍵位置與鍵盤高度不變。實機 TBD（見 E2E-T16-RC B29、B35） |
| D23 | 按鍵音量與震動強度 | 自動通過，實機 TBD | 預設聲音比系統按鍵聲大約 40%；音量、震動強度滑桿拖動即時試聽試震；0% 無聲／不震；開關關閉時滑桿停用；無完整取用時退回系統按鍵聲；靜音鍵靜音時無聲；不打斷音樂 | 自動（2026-10-31）：Core 628/0（基線 617，新增 `KeyFeedbackLevelTests` 11 項：預設、夾範圍、非數字／NaN／Bool、0、1.0、1.4、2.0 換算；先 RED（編譯失敗）後 GREEN）；iOS 模擬器／真機 build、UI 測試 build-for-testing、Mac build 成功；模擬器：設定頁截圖確認兩條滑桿（預設 140%、70%，拖到 200%，關閉開關後滑桿變灰）、播放器啟動不崩潰（log：`click engine started, source bundled`，拖動 5 次試聽 `played true`）；模擬器 runtime 內 `key_press_click.caf` 存在（1 聲道、44.1 kHz、Int16、約 4.5 ms、峰值約 0.38），但模擬器 App 讀的是 Mac 的 `/System`，所以走合成檔；系統檔路徑能否在實機 Extension 讀到、100% 是否約等於系統聲、無完整取用時退回系統聲，皆實機 TBD（見 E2E-T16-RC B36–B42） |
| D24 | 觸及範圍 v2（整塊分區、觸點校正、連按） | 自動通過，實機 TBD | 鍵間、行間、左右邊緣、底列上下的空白都送出最近的鍵（行距內略偏下才算下一行）；不搶候選字列與手寫區；快速雙手連按 20 字無漏字、無錯序 | 自動（2026-10-31）：Core 646/0（基線 628，新增 `KeyRolloverTrackerTests` 11 項、`KeyHitResolverTests` 新增 7 項並改 1 項；先 RED（編譯失敗：找不到 `KeyRolloverTracker`、`touchYOffset`）後 GREEN）；模擬器 UI 測試 `HitAreaUITests`：修正前 13 項中對照項 PASS、12 項空隙 FAIL（證實根因是透明像素收不到觸控），修正後 13/13 PASS；iOS 模擬器與真機 build-for-testing 成功。實機自動（2026-10-31，iPhone 17 Pro，iOS 27.0.1，背景 alpha 0.01）：`HitAreaUITests` 13/13 PASS；手感與連按見 `E2E-T16-RC.md` B23–B28、B43 |
| TP1 | 觸控板決策關卡：加密量測通道（D25 修訂 2，branch `tp1-measurement`） | 自動通過；第一輪實機（未設定偏好）僅參考；主要驗收（`.low`、無長文字）TBD | 觸控到游標可見 E2E P95 < 60 ms 且 M5 沒有積壓（決策關卡）；所有量測封包與回覆經 AEAD；Release 不含量測程式 | 自動（2026-11-01）：Core 697/0（基線 646，新增 51 項：`CounterChannelTests` 18、`ReplayWindowTests` 10、`MeasurePayloadTests` 6、`LatencyStatsTests` 5、`VideoFrameStatsTests` 5、`ReceiverStatusTests` 3、`AuthHandshakeTests` 4；先 RED（編譯失敗：找不到 `ReplayWindow`、`ChannelSet` 等）後 GREEN）；Mac 214/0（基線 187，新增 27 項：`FirstByteRoutingTests` 6、`MeasurementEchoTests` 與 `MeasureFlashWindowTests` 共 18、`ReceiverCoordinatorTests` 3；先 RED 後 GREEN）；iOS 模擬器 build、模擬器與真機 build-for-testing（含 `MeasurementUITests`）成功；Mac Release 與 iOS Release（generic iOS device）build 成功；Release 的 MacReceiver、RemoteKeyboardApp、RemoteKeyboardExtension 對 `MeasurePayload`、`MeasureEchoPayload`、`measureP2M`、`measureM2P`、`MeasurementEcho`、`MeasurementRunner` 執行 `nm -a` 與 `strings -a`，全部 0 筆（Debug 產物同樣檢查有命中，確認檢查有效）；`grep` 101 處（含 `measureMode`）全部在 `#if DEBUG` 內；Release 的 status 不帶 `measure`（`FocusTransition.status(for:measure:)`、`ReceiverCoordinator.measureMode` 只在 Debug）。信封：`magic ‖ counter(8) ‖ ChaCha20 ‖ tag(16)`，每種 Kind 獨立 HKDF 金鑰與 nonce 前綴，AAD 為前 9 bytes；逐 byte 逐 bit 竄改 41 與 182 bytes 版本全部被拒；64 位元重播視窗在驗證後才更新；每條連線只取一次 `ChannelSet`，同一 sealer 跨量測重跑與模式開關沿用。`HitAreaUITests` 13/13（iPhone 18 Pro 模擬器；真機未重跑）。`scripts/tp1-m4-stats.swift` 以自行產生的範例 CSV 跑過（輸出與 `LatencyStats` 的 1…100 測例相符）。實機（2026-11-01，主代理以 `MeasurementUITests` 跑，連線延遲偏好未設定）：M2 系統佇列每輪只接受 1 個封包，排空 P95 21–25 ms；M3 RTT P50 53.2／P95 83.2／P99 119.4 ms（10,001 樣本，略過 73.5%）；M5 長文字期間 RTT P95 421.1 ms、恢復段 0 樣本（工具缺陷）；M6 Mac 收到心跳 > 350 ms：一般 4／5,999、長文字 532／5,999。2026-11-01 使用者修訂：長文字併發（M5、M6-L）改為健壯性測試，主要驗收以 `.low`、無長文字的 M4、M6（30 分鐘）、M7、M8 為準，尚未量測。第二輪（要求 `.low`，生效未確認，04:00–05:14）：M3c 估計單程 P95 51.8 ms（± 34.2）；M6 30 分鐘模擬誤釋放 1／17,999（未通過）；M7 長文字完整 20／20、切換後首封包 ≤ baseline P99×2 只有 14／20（未通過）；M8 估計單程 P95 64.1 ms（± 34.6）、模擬誤釋放 0（通過）；M5 recovery 有效。M1、M4 與 M6-X TBD（使用者）。詳見 `2026-11-01-tp1-decision.md` | `e2e/E2E-TP1-MEASURE.md`、`scripts/tp1-m4-stats.swift` |
| 觸控板順滑（branch `trackpad-smooth`） | 自動通過；實機：可用但有輕微抖動（使用者接受，2026-11-01） | 自動傳輸模式、Mac 播放平滑；點擊、拖曳、捲動、加密、心跳、看門狗不變 | 自動（2026-11-01）：Core 896/0、Mac 268/0；iOS 模擬器、真機 build-for-testing、Mac 與 iOS Release build 成功；Release 量測符號 0。實機取樣：內建觸控板移動中靜止幀 2.5%，iPhone 自動 18.1% 與 36.9%。抖動判斷來自 BLE 連線事件時序，未解決，備用方案見 `research/2026-11-01-trackpad-wifi-fallback.md` | `e2e/E2E-TRACKPAD-MVP.md` |

## 每項驗收記錄格式（複製一份填 T01–T16、T12b）

```text
CASE ID: T__
Task name:
Build/branch/commit SHA:
Test device: iPhone model / iOS exact version / Mac model / macOS exact version:
Xcode version / signing mode:
Time UTC+8:
Preconditions (permissions / host app / BLE / pairing / focus):
Test steps:
Expected result:
Actual result:
Console/log file (redacted):
Video/screenshot and hash:
Automated command and exit code:
Number of attempts / pass / fail:
Result: NOT_STARTED | RED | PASS | FAIL | BLOCKED | INCONCLUSIVE
Bug link / reproducer:
Fix / retry evidence:
Reviewer / verified timestamp:
```

## 最小 E2E 結果格式範例（非已執行）

```text
Case: T05-E2E-A-01
Mac frontmost app: TextEdit
Mac AX focused editable element: YES
Keyboard host: iPhone Notes
UI keyboard: RemoteKeyboard Extension
Action: Tap A once
Expected: Mac TextEdit contents change from "" to "A"
Actual: [NOT TESTED]
Result: NOT_STARTED
```

## Release Acceptance Final Checklist

- [ ] T01–T09 P0 全部 PASS，權限撤銷測試 PASS。
- [ ] T10 QWERTY + T11 Symbols + T12 Handwriting 全部 PASS。
- [ ] T13 語音 Gate 有真實結果；若 FAIL 已經使用者批准 scope change。
- [ ] T14 iPhone host + Mac target compatibility matrix 完整。
- [ ] T15 睡眠／重連／雙 Mac／Wi-Fi optional fallback 安全通過。
- [ ] T16 Xcode build/TestFlight/Developer ID notarization/隱私文案驗證。
- [ ] Apple App Review 4.4.1 規則逐項審查。
- [ ] 無遺留 Critical/High 安全問題、無未披露文字收集或錯焦點輸入。

## 缺陷分級與覆驗

- **P0 Critical**：未授權傳輸/錯 App 注入/語音使用 private API/無法 Local Mode -> Block release。
- **P1 High**：跨 App 經常斷線、重複輸入、CJK 亂碼、配對身份失效 -> Block MVP。
- **P2 Medium**：UI 錯位、輕微延遲、不關鍵候選字排序 -> 記 issue、排期修正。
- 修復後重新執行原始 failing case + 受影響範圍 regression；記 red-green 和 regression 證據。

**狀態聲明：**沒有在本次會話中存取 Xcode 專案、編譯、連接實機或運行測試。驗收欄全部為 `NOT_STARTED` 是事實，不是對技術可行性的否定。
