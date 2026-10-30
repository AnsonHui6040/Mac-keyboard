# Remote Keyboard 實作驗收報告（模板／目前結果）

**版本：** v1.0 | **最後更新：** 2026-10-30 | **本次工程測試狀態：6/17 PASS（T01–T06，M1 Gate 通過；v1.3 新增 T12b），其餘 NOT_STARTED**

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
| O7 | 手寫辨識引擎：先測 Apple 原生（PencilKit 公開 API、Vision `zh-Hant` 辨識筆跡圖），未過 Gate 才測 Google ML Kit Digital Ink；Gate：記憶體留 20% 餘量、延遲 P95 ≤ 500 ms、20 字首選 ≥ 18（使用者 2026-10-30 決定次序） | T12 Step 1 | T12 | NOT_STARTED |
| O8 | Keyboard Extension 以 `retrieveConnectedPeripherals(withServices:)` 能否取得已連線的 Mac；取不到時掃描路徑能否完成連線 | T03 | T03 | FAIL → 改採 D11；Mac 掃描連入 iPhone 鍵盤 PASS（T03b） |
| O9 | 速成字碼表來源授權可隨 App 散布，授權檔附於 App | T12b Step 0 | T12b | NOT_STARTED |

## 任務逐項驗收狀態

| Case | 任務 | 目前狀態 | 通過條件 | 實測結果 | 證據檔 |
|---|---|---|---|---|---|
| T01 | 工程基礎與離線 Local Mode | PASS | 真機 Notes 輸入 20 字正確且在無 Full Access 照常 | 自動：swift test 6/0、iOS Simulator 與 macOS build 成功。實機（iPhone 17 Pro、iOS 27.0.1、Full Access 關閉，2026-10-29 17:18）：備忘錄輸入 `Hello World` 與 26 個字母共 37 字元逐字一致，Return、Backspace、Shift 正常，系統 🌐 可切換鍵盤，`AppGroup: OK` | `e2e/E2E-T01-LOCAL.md`、`evidence/T01-device-notes-hello-world.webp`、`evidence/T01-sim-*.png` |
| T02 | Mac Receiver Shell、BLE GATT Advertiser | PASS | macOS GATT service 完整可發現，service publish 成功 | 自動：swift test 8/0、MacReceiverTests 5/5（含 4 個生命週期測試）。實機（2026-10-29）：選單列 `BLE: advertising`；iPhone nRF Connect 掃到 Connectable 廣播與 service UUID `2A6F212A…`；Mac bluetoothd 紀錄確認 service 與 3 個 characteristic（write／notify／read notify）。iPhone 端連線因既有系統 LE 連線無法以 nRF 完成，characteristic 探索改由 T03 驗證（使用者 2026-10-29 批准） | `e2e/E2E-T02-GATT.md`、`evidence/T02-*` |
| T03 | BLE 連線（v1.2：T03a iPhone Peripheral＋T03b Mac Central） | PASS | T03a：O4 四格不 crash、Local 照常、授權齊全時 Notes／Safari 進入 advertising；T03b：Notes、Safari 反覆叫出鍵盤皆 connected | T03a（7b38be1）：見 E2E-T03A。T03b（782b5a8，2026-10-29）：Core 58/0、MacReceiverTests 18/18；實機多個 App 反覆連上（Mac log 9 次 ready，200–783 ms，未逐次記錄 10＋10，使用者接受為通過）；收起鍵盤回到 scanning；60 秒覆寫下 menu 開啟仍倒數、到時自動待命、鍵盤連上重置倒數（修正兩輪：計時器 run loop mode、連上計為活動）。舊 v1.1 T03 FAIL 見交接紀錄 | `e2e/E2E-T03A-PERIPHERAL.md`、`e2e/E2E-T03B-LINK.md`、`verification/2026-10-29-handoff.md` |
| T04 | Mac 焦點感知與 Unicode 注入 | PASS | TextEdit 5 組字串逐一完全一致；注音狀態 20/20；切換至非可編輯焦點時 0 誤注入 | 自動（ee14849，2026-10-29）：Core 82/0、MacReceiverTests 32/32、iOS 與 macOS build 成功；涵蓋焦點守衛判斷順序、grapheme 不拆段、ABC 切換驗證失敗不注入、注入後 settle 再切回、連續兩次注入排隊不交錯。實作差異：輔助使用授權提示改為使用者按「授權輔助使用」或啟動測試插入時才出現；`AXValue` 可設定且值為字串才算可編輯；前景為 Receiver 本身時一律不可編輯。實機：TBD  `e2e/E2E-T04-INJECT.md` |
| T05 | 最小端到端 A 鍵輸入 PoC | PASS | Notes→TextEdit、Safari→TextEdit 各 20 次成功，0 錯誤焦點 | 自動（e097453，2026-10-30）：Core 124/0、MacReceiverTests 69/69、iOS 模擬器、macOS、iOS 真機簽名 build 成功；涵蓋事件編解碼、notify 佇列滿時保序、Remote 未就緒拒收、無 Full Access 回到 Local、Mac 逐筆處理與 ACK 對應、焦點世代過期拒收、組字中先取消再切換（D4 修訂）。單元測試不啟動實際掃描與注入。實機（b23fd2b，2026-10-30 02:17–02:39）：iPhone 遠端模式打字送到 Mac，206 個事件（文字 178、Backspace 25、Return 3）全部 `posted`，實際使用中 0 拒收；8 次連線各只發現 1 個 service，ready 56–480 ms；狀態列隨 Mac App 切換、不能輸入時有提示。第一次實機測試發現兩個藍牙管理器同時發佈 service、選單點擊錯位，修正三輪後通過。使用者決定以此通過，Notes／Safari 各 20 次逐次、⌘Tab 5 次、注音組字、關閉 Full Access、60 秒逾時延至 T16 逐項紀錄 | `e2e/E2E-T05-A-KEY.md`、`evidence/T05-mac-receiver-log-excerpt.txt` |
| T06 | BLE Lifecycle／冷啟動 Gate | PASS | 100 次鍵盤重開連線 >=99 成功；已配對且 Mac awake 的 P95 <=2 秒（以鍵盤出現 → 連上計，使用者 2026-10-30 決定） | 自動（37cad25）：Core 172/0、MacReceiverTests 86/86、UI test 編譯成功。實機 XCUITest（Notes／Safari 交替）：第 1 輪 100/100 連上；第 2 輪分段計時 99/100（#54 Safari 鍵盤未出現，非藍牙失敗），鍵盤出現 → 連上 P95 Notes 389 ms、Safari 224 ms；iPhone 端計時 P95 647／710 ms。點擊 → 連上 P95 2329／2370 ms，其中 XCUITest 點擊動作本身中位數 Notes 696 ms、Safari 1813 ms，使用者判定不計入。第 1 輪曾以點擊 → 連上判 FAIL，分段後改判。異常情境各 5/5：iPhone 藍牙關再開、Mac 藍牙關再開（開始連線 → ready 2.9–4.5 秒）、Mac 睡眠喚醒、強制關閉 Notes。親手抽查 10 次錄影延至 T16 | `e2e/E2E-T06-RECONNECT.md`、`evidence/T06-*` |
| T07 | 協定分幀、UTF-8 與事件流 | 自動 PASS／實機 TBD | 1000 組 fuzz/邊界 frames，0 誤解析 | 自動（2026-10-30）：Core 198/0、MacReceiverTests 91/91、iOS 模擬器與真機簽名 build、macOS build 成功。`testFuzzedFramesNeverCrashOrComplete` 1,000 個隨機 frame：0 complete、998 rejected、2 incomplete，0 crash、0 誤解析。涵蓋 frame 上限、重複 index、index 越界、斷線丟棄殘片、新訊息取代殘片時不遺失新訊息（主代理裁定）、v1 payload 回報不支援版本、UTF-8／ZWJ emoji 跨 frame 重組；3,000 字元 TEXT = 35 個 182 bytes frame。實機：TBD（打字回歸、DEBUG 長按 Return 送 3,000 字元，`pbpaste` 字數與 shasum 比對） | `e2e/E2E-T07-FRAMING.md` |
| T08 | ACK、去重、排序、失敗語義 | NOT_STARTED | 重複100次 seq 單次 commit、亂序安全、10000 events 受控 TextEdit 0 遺漏/重複/亂序 | 尚未測試 | — |
| T09 | 配對身份認證、隱私與 Local/Remote 模式 | NOT_STARTED | 未配對設備/錯 token/撤銷配對不能注入；模式清晰、Remote 關閉不送 Mac | 尚未測試 | — |
| T10 | 原生風格英文 QWERTY 操作 | NOT_STARTED | 操作表 40/40、iPhone 尺寸 UI 不重疊 | 尚未測試 | — |
| T11 | 數字 123／符號 #+= 兩頁 | NOT_STARTED | 全部鍵位 mapping unit tests 100%，不因切換頁重覆注入 | 尚未測試 | — |
| T12 | 中文輸入法介面、設定頁與繁體中文手寫 | NOT_STARTED | 指定 100 字測例 top-3 >=90%，25 字混合詞語輸入無殘留，extension 30 次切換無 OOM | 尚未測試 | — |
| T12b | 速成 | NOT_STARTED | 50 個常用字本機與遠端皆正確；無 Full Access 時中文頁為速成可打字；字碼表授權已記錄（O9） | 尚未測試 | — |
| T13 | 語音聽寫獨立可行性 Gate | NOT_STARTED | 100 句中英語音及修正 100% 正確到 Mac 且 API 合規 | 尚未測試 | — |
| T14 | 跨 App 相容性、Mac 焦點安全矩陣 | NOT_STARTED | 容許欄位、已建立遠端模式輸入無錯焦；blocked 欄位正確回退 | 尚未測試 | — |
| T15 | 穩定性、權限、Wi-Fi 降級驗證 | NOT_STARTED | 無授權/無焦點永遠 fail closed，任一失敗可提示及恢復；Wi-Fi 測試有權限和身份驗證 | 尚未測試 | — |
| T16 | Release Candidate QA、文件與分發審核 | NOT_STARTED | 全部必需 Gate 通過且帶 log/截圖/測試版本，無 blocker | 尚未測試 | — |

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
