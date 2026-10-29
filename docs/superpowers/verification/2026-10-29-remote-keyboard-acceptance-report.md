# Remote Keyboard 實作驗收報告（模板／目前結果）

**版本：** v1.0 | **最後更新：** 2026-10-29 | **本次工程測試狀態：0/16 PASS，全部 NOT_STARTED**

> **證據規則：**只有實際執行測試、保存完整輸出並核對結果後才可填 PASS；文獻研究不算 PASS。不可事後推測 log 或填虛構時間。

## 狀態概覽

| 指標 | 結果 |
|---|---|
| Product spec | DRAFT v1.1 / 待批准（已納入設計決定 D1–D10） |
| Research/source review | 深度研究已有報告；未執行 code 實測 |
| Xcode build | NOT_RUN |
| `swift test` | NOT_RUN |
| 實機連線 Gate | NOT_RUN |
| Mac AX 注入 Gate | NOT_RUN |
| Security Gate | NOT_RUN |
| Dictation Gate | NOT_RUN |
| Release / App Review | NOT_STARTED |

## 開工前待解決事項（2026-10-29）

| # | 事項 | 負責 | 何時需要 | 狀態 |
|---|---|---|---|---|
| O1 | 實體 iPhone 以 USB 連接 Mac、信任此電腦、開啟 Developer Mode | 使用者 | T03 前 | NOT_STARTED |
| O2 | Xcode 登入 Apple ID 取得 Personal Team 簽名身分（目前 0 個） | 使用者 | T01 真機驗收前 | NOT_STARTED |
| O3 | Personal Team 下 App Group 是否可用，決定 D3 配對路徑 | T01 | T01 | NOT_STARTED |
| O4 | Keyboard Extension 內 CoreBluetooth 權限提示由哪個 process 顯示、主 App 是否需先取得授權 | T03 | T03 | NOT_STARTED |
| O5 | `CGEventKeyboardSetUnicodeString` 單一事件長度上限 | T04 | T04 | NOT_STARTED |
| O6 | XCUITest 能否在真機切換到第三方鍵盤（D9） | T06 | T06 | NOT_STARTED |
| O7 | `PKStrokeRecognizer` API 名稱、最低系統版本與繁體中文支援，以 Apple 官方文件核實 | T12 前查證 | T12 | NOT_STARTED |

## 任務逐項驗收狀態

| Case | 任務 | 目前狀態 | 通過條件 | 實測結果 | 證據檔 |
|---|---|---|---|---|---|
| T01 | 工程基礎與離線 Local Mode | NOT_STARTED | 真機 Notes 輸入 20 字正確且在無 Full Access 照常 | 尚未測試 | — |
| T02 | Mac Receiver Shell、BLE GATT Advertiser | NOT_STARTED | macOS GATT service 完整可發現，service publish 成功 | 尚未測試 | — |
| T03 | Extension BLE Central 冷連線 | NOT_STARTED | 在 Notes 與 Safari Extension 中都可連線 | 尚未測試 | — |
| T04 | Mac 焦點感知與 Unicode 注入 | NOT_STARTED | TextEdit 5 組字串逐一完全一致；切換至非可編輯焦點時 0 誤注入 | 尚未測試 | — |
| T05 | 最小端到端 A 鍵輸入 PoC | NOT_STARTED | Notes→TextEdit、Safari→TextEdit 各 20 次成功，0 錯誤焦點 | 尚未測試 | — |
| T06 | BLE Lifecycle／冷啟動 Gate | NOT_STARTED | 100 次鍵盤重開連線 >=99 成功；已配對且 Mac awake 的 P95 <=2 秒 | 尚未測試 | — |
| T07 | 協定分幀、UTF-8 與事件流 | NOT_STARTED | 1000 組 fuzz/邊界 frames，0 誤解析 | 尚未測試 | — |
| T08 | ACK、去重、排序、失敗語義 | NOT_STARTED | 重複100次 seq 單次 commit、亂序安全、10000 events 受控 TextEdit 0 遺漏/重複/亂序 | 尚未測試 | — |
| T09 | 配對身份認證、隱私與 Local/Remote 模式 | NOT_STARTED | 未配對設備/錯 token/撤銷配對不能注入；模式清晰、Remote 關閉不送 Mac | 尚未測試 | — |
| T10 | 原生風格英文 QWERTY 操作 | NOT_STARTED | 操作表 40/40、iPhone 尺寸 UI 不重疊 | 尚未測試 | — |
| T11 | 數字 123／符號 #+= 兩頁 | NOT_STARTED | 全部鍵位 mapping unit tests 100%，不因切換頁重覆注入 | 尚未測試 | — |
| T12 | 繁體中文手寫與候選字 | NOT_STARTED | 指定 100 字測例 top-3 >=90%，25 字混合詞語輸入無殘留，extension 30 次切換無 OOM | 尚未測試 | — |
| T13 | 語音聽寫獨立可行性 Gate | NOT_STARTED | 100 句中英語音及修正 100% 正確到 Mac 且 API 合規 | 尚未測試 | — |
| T14 | 跨 App 相容性、Mac 焦點安全矩陣 | NOT_STARTED | 容許欄位、已建立遠端模式輸入無錯焦；blocked 欄位正確回退 | 尚未測試 | — |
| T15 | 穩定性、權限、Wi-Fi 降級驗證 | NOT_STARTED | 無授權/無焦點永遠 fail closed，任一失敗可提示及恢復；Wi-Fi 測試有權限和身份驗證 | 尚未測試 | — |
| T16 | Release Candidate QA、文件與分發審核 | NOT_STARTED | 全部必需 Gate 通過且帶 log/截圖/測試版本，無 blocker | 尚未測試 | — |

## 每項驗收記錄格式（複製一份填 T01–T16）

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
