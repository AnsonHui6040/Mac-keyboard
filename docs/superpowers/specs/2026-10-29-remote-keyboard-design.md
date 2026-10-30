# iPhone → Mac Remote Keyboard — 設計規格

**版本**：v1.4 | **日期**：2026-10-31 | **狀態**：APPROVED（使用者於 2026-10-31 批准 v1.4）；T01–T06 已實作

**v1.4 變更**：T13 語音 Gate 實機 PASS（2026-10-31）後，聽寫同步正式化（D18）；底列改為「符號」在左、「中英」在右（D19，修訂 D14 的鍵序）。

**v1.3 變更**：M2 規劃（2026-10-30 brainstorming）。鍵盤分為中文、英文、符號三頁，底列改為「中英／符號」（D14）；中文輸入法採統一介面，先做手寫（先測 Apple 原生、未過才用 Google ML Kit）、後做速成，主 App 設定頁選擇（D15、D16）；符號頁由中文頁進入時先顯示全形標點（D14）；頂部區三行配置（D17）；草稿列改為鍵盤上可切換的「即時／草稿」，並加左右鍵（D6 修訂）。改寫 §2、§3、§4、§7、§12。

**v1.2 變更**：依 D11 改為角色對調，iPhone Keyboard Extension 為 GATT Peripheral、Mac Receiver 為 Central；改寫 §2、§3、§4、§5、§9，新增 D12 協定方向、D13 Mac 常駐與接收時段與 §13 實機資訊。

**v1.1 變更**：納入 2026-10-29 設計審問的決定，涵蓋 Remote 模式行為、草稿列、配對備案、Mac 輸入法、語音流程、BLE 備案與開發環境。決定總表見 §12。

## 1. 產品意圖

在 Mac 使用者點選可編輯文字框之後，Mac Receiver 顯示「準備接收」。使用者於 iPhone 任一**容許第三方鍵盤**的 App 打開文字欄位、切換到 Remote Keyboard，即可透過自製鍵盤將英文、數字／符號或繁體中文手寫的已提交文字遠端送往 Mac 的**目前有效焦點**。iPhone 不需每次打開主 App。此流程不會令 iPhone 自動從鎖屏／其他 App 彈出鍵盤。

## 2. 已定義功能

- iOS 第三方 Keyboard Extension，分三頁（D14）：
  - 中文頁：使用主 App 設定頁選定的中文輸入法（D15）。先做繁體中文手寫，後做速成（D16）；兩者皆有候選字列。手寫引擎採用 Google ML Kit Digital Ink（語言 `zh-Hani-TW`，使用者 2026-10-30 決定：鍵盤本來就需完整取用，直接採用，Apple 原生辨識日後再評估）。手寫模型由主 App 下載後放入 App Group，鍵盤自動匯入；未下載時手寫頁顯示「請先在 App 下載手寫模型」。未開 Full Access 時中文頁改用速成（速成完成前改為英文頁）。手寫頁版面（使用者 2026-10-30 選定）：書寫區佔按鍵區左邊大部分，右邊直排「⌫」與「重寫」；底列照舊（中英、符號、空白、換行）；候選字在頂部第三行，每寫完一筆即時更新，只列中文字；按空白送出第一個候選字，點選候選字送出該字；手寫頁比英文頁高 60 pt（書寫區 210 pt；鍵盤總高 344 pt，顯示草稿列時 380 pt；使用者 2026-10-30 實機後決定）。
  - 英文頁：QWERTY，Shift／Caps Lock／長按、刪除、Space、Return。
  - 符號頁：由英文頁進入時同 Apple 原生，第一層數字 `123`、第二層特殊符號 `#+=`，皆為半形；由中文頁進入時，第一層為數字加全形中文標點（`，。？！、：；「」『』…`），半形符號在下一層。
  - 底列由左至右為 `中英`、`符號`、空白鍵、Return。`中英` 在中文頁與英文頁之間切換；`符號` 進入符號頁，再按一次回到進入前的頁面。系統 globe 與麥克風由 iOS 顯示在鍵盤下方。
  - 語音輸入入口見 §6。
- 英文外觀及使用習慣參考 Apple 原生鍵盤，但不複製 Apple 私有資產、預測字詞引擎或私有系統鍵盤 View。關鍵動作應原生風格而非假裝能重用 Apple keyboard。
- Mac 具 menu-bar Receiver、首次配對、連線狀態、焦點狀態、接收暫停／解除配對。
- Mac 常駐與接收時段（D13）：Receiver 登入時自動啟動並常駐 menu bar，平時待命（不掃描、不連線）。使用者在 Mac 點擊可編輯輸入框時開始接收（掃描並連入 iPhone 鍵盤）；30 分鐘沒有活動即停止掃描並斷線回到待命。每收到一個鍵盤事件、iPhone 鍵盤連上 Mac，或再次點擊可編輯輸入框，30 分鐘重新計算（鍵盤連上計為活動：使用者 2026-10-29 於 T03b 實機後決定）。焦點離開輸入框時連線保留，只令注入 fail closed。menu 另有手動「開始接收／停止接收」。
- 預設 Local Mode：iPhone 本地正常輸入，毋須 Full Access；Remote Mode 必須由使用者明確啟用並授權，且有持續可見狀態；不能暗地將其他 App 的文字複製到 Mac。
- Remote Mode 行為：按鍵只送往 Mac，iPhone 目前欄位不出字；鍵盤收起或切換 App 後重新開啟，沿用上次模式。
- 鍵盤頂部區（D17），由上而下：
  1. 第一行：`本機｜遠端` 切換、狀態（例如「● Mac → TextEdit」、「未連接」）、`即時｜草稿` 切換。`即時｜草稿` 只在遠端模式顯示。
  2. 第二行：草稿列，由左至右為 `◀`、`▶`、草稿文字（含游標）、`傳送`。只在遠端模式且為草稿狀態時顯示；即時狀態收起。
  3. 第三行：中文輸入法的候選字列（輸入碼或手寫候選字），本機與遠端模式皆有。
  - 本機模式只顯示 `本機｜遠端` 與候選字列。
- 即時／草稿（D6 修訂）：
  - 即時：每個已提交的字即時送往 Mac（現行行為）。
  - 草稿：字先寫入草稿列，按 `傳送` 才一次送出。`◀ ▶` 每按一次移動游標一個字元（以 grapheme 計），新字插入游標處，刪除鍵刪除游標前一個字元。
  - 未就緒（BLE 未連線、或 Mac 沒有可編輯焦點）時一律寫入草稿列，`傳送` 為灰色不可按；就緒後 `傳送` 轉為可用，由使用者手動送出，不自動送出。
  - 由草稿切回即時時，草稿列若仍有文字則保留並維持顯示，直到送出或清空。
  - `◀ ▶` 只移動草稿內的游標，不送往 Mac。
  - `即時｜草稿` 的選擇與 `本機｜遠端` 一樣，重開鍵盤沿用上次選擇。
  - 草稿送出時使用當下的 `focusEpoch`。草稿只存在記憶體，Extension 被終止或切換 App 即消失，不寫入磁碟。
- v1.3 細節（主代理決定，2026-10-30 builder check 後補充；使用者可於批准時更改）：
  - 草稿列仍有文字時，所有按鍵（含刪除與 Return）都編輯草稿，直到送出或清空才恢復即時；避免文字或刪除送錯位置。
  - Return 在草稿中插入換行；送出時依換行切成 `TEXT` 與 `RETURN` 事件依序送出。草稿上限 1,000 個字元，超過時不再接受輸入。草稿送出依賴 T07 分幀。
  - 即時狀態但未就緒時，草稿列自動出現並保留，直到送出或清空。
  - 由遠端切到本機時，草稿隱藏並保留在記憶體，切回遠端再顯示；本機模式按鍵直接寫入 iPhone 欄位。
  - 重開鍵盤回到上次的中文或英文頁；欄位類型為 email、URL 時開在英文頁，數字類欄位開在符號頁。
  - 速成輸入碼最多兩碼，第三碼不接受；字碼表為繁體中文表，表內收錄的字皆可選，不另分台灣與香港字形。
  - 手寫頁版面與鍵盤總高度在 T12 開工前以示意圖交使用者選擇；T10 可視頂部三行需要調高鍵盤。
  - T10 尺寸：頂部每行 36 pt；按鍵區 4 行，每行 42 pt、行距 12 pt，上下共留 8 pt。鍵盤總高 = 按鍵區 212 pt + 可見頂部行數 × 36 pt，即本機或即時（兩行）284 pt、顯示草稿列（三行）320 pt；候選字列在 T12 前為空白占位。有完整取用時每次按鍵輕震一下。
- 優先 BLE 自訂 GATT（D11）：iPhone Keyboard Extension 為 Peripheral／GATT Server，鍵盤顯示期間廣播並以 notify 送出事件；Mac Receiver 為 Central／GATT Client，執行期間持續掃描並自動連入，以 write 回傳 ACK 與 Receiver 狀態。Mac 使用 AX 聚焦與 CGEvent Unicode 注入。LAN WebSocket 為後備（D8），目前不實作。**不以 BLE HID 作主路徑**。
- iPhone 主 App：安裝教學、Full Access 提示、初次配對、管理配對 Mac、顯示診斷及語音方案說明；設定頁選擇中文輸入法（目前為「手寫」或「速成」單選，D15）。主 App **不假設**能長期代 Extension 維持 BLE 連線；Remote 傳輸由 Extension 自己的 Peripheral 負責。

## 3. 最重要的平台限制

1. Apple App Review 4.4.1：必須能在未開 Full Access 時正常作為鍵盤；須提供切換下一個鍵盤的控制；不能自行啟動 Settings 以外其他 App；鍵盤活動只能收集作合法鍵盤功能用途。
2. Apple `hasDictationKey` 是表示鍵盤有沒有自己的語音按鍵，不是一個可供 Extension 取得系統 Dictation 完整文字流的公開 callback；語音由獨立實機 Gate 驗證；失敗時不得以非公開 API／越權跳 App 方案作正式產品主線。
3. `UIInputViewController` 在獨立 Extension process 運作；會被殺死或重新建立，不能依賴常駐單例或無限制記憶體；部分 secure/password、phone keypad、禁止第三方鍵盤的 App 會回到 Apple 系統鍵盤。
4. Mac Accessibility 只能證明有可用的焦點與可發送事件，不等同文字已呈現在任意第三方 App；輸入框切換／睡眠／桌面切換需重新驗證。
5. BLE ACK 只能確認 Receiver 端協定狀態／注入動作，不保證目標軟體已經顯示文字。對無法觀察結果的 CGEvent，斷線重試可能出現語義不確定狀態；**不可宣稱任意 App 都具備端到端 exactly-once。**
6. 若 iPhone 用戶在其他 App 打開鍵盤，遠端模式只發送由本鍵盤**直接產生**並明確選擇發往 Mac 的事件；不收集 host App 既有文字或複製通用打字紀錄。
7. 同一 iCloud 的 iPhone 與 Mac 已有系統 LE 連線，且第三方 App 無法經 `retrieveConnectedPeripherals` 取得；iPhone 主動連 Mac 的新連線在 link layer 即斷（reason 762），Mac 主動連 iPhone 可成功（實測 514–561 ms）。因此 iPhone 只能當 Peripheral（D11）。
8. Extension 只在鍵盤顯示期間存在：Peripheral 只在鍵盤可見且已開 Full Access 時廣播；鍵盤收起即停止廣播並斷線，下次叫出鍵盤由 Mac 重新連入。
9. 手寫辨識（O7，使用者 2026-10-30 決定次序）：先實機測 Apple 原生方案，包括 PencilKit 是否有公開的筆跡辨識 API，以及 Vision `RecognizeTextRequest`／`VNRecognizeTextRequest`（`zh-Hant`）辨識筆跡繪成的圖；可在 Extension 內離線運作且過 Gate 即採用，手寫不需 Full Access。未過 Gate 才改用 Google ML Kit Digital Ink（`zh-Hani-TW` 或 `zh-Hani-HK`），並查證其記憶體、模型下載與儲存位置。
10. 速成字碼表必須來自授權允許隨 App 散布的開源資料（含授權檔與出處），使用前查證授權並記錄（O9）；授權不明者不得放入 App。
11. Full Access 關閉時，Extension 能否讀取 App Group 中主 App 寫入的設定未實測（O3 僅證明可讀）；讀不到時中文頁使用速成（速成完成前為英文頁），不得因此無法打字。

## 4. 架構

```text
[iPhone host App: Notes, Safari, Messages...]
             │ iOS 揀選第三方鍵盤
             ▼
[Keyboard Extension, UIKit/UIInputViewController]
  ├─ Local mode (textDocumentProxy -> iPhone current field)
  ├─ Pages: 中文 (ChineseInputMethod: Handwriting | 速成 | future) / English / Symbols
  │    composition 與候選字在 iPhone 完成，只有已提交文字離開輸入法
  └─ Remote mode (committed text -> 即時 send | 草稿列 -> 傳送 -> SemanticEvent queue)
             │ CBPeripheralManager：廣播 service；event 以 notify 送出，control 收 write
             ▲ Mac 為 Central：scan → connect → subscribe event／write control
[Mac Receiver CBCentralManager]
  ├─ Pairing + authentication, session/sequence, queue/ACK
  ├─ AX focus guard, remote-enabled status
  └─ CGEvent Unicode / limited AX fallback
             ▼
[Mac frontmost editable field: TextEdit/Word/Safari/VS Code]

[Host iOS App] --App Group settings/Keychain config--> [Keyboard Extension]
```

## 5. 協定、權限及事件

- Cross-platform Swift Package：`RemoteKeyboardCore`，定義 `KeyboardEvent`、`Handshake`、`Ack`、`ConnectionState`、二進位/JSON 編碼與 schema 版本；自訂 GATT UUID 於程式中產生並固定，不採用文獻中的示意 UUID。
- 事件：`TEXT(UTF-8 committed string)`、`BACKSPACE(1)`、`RETURN`、`MOVE_CURSOR`（非 MVP）、`PING`；每事件有 `sessionId`、`seq`、`focusEpoch`、`eventId`。握手要版本與 capability negotiation；驗證字節長度、chunk 重組、UTF-8 有效性及 framing。
- Mac AX 每次 commit 前查詢前台程序和 focused editable UI element；沒有焦點、失去權限、焦點世代更換時 fail closed；不把舊輸入重播至新 App。remote mode 有使用者明確開關，狀態標識清楚。
- 透過 BLE 加密權限及應用層 challenge-response/Keychain secret 雙重驗證；禁止僅以 device name/BLE identifier 認定已配對 Mac；敏感文字不寫入一般診斷 log。
- T09 實作（主代理 2026-10-30 裁定）：以應用層加密取代 BLE characteristic 加密權限（避免系統配對對話框拖慢重連）。配對採 ECDH P256 加公鑰承諾（iPhone 先送公鑰雜湊，Mac 回公鑰後 iPhone 才公開）與 6 位數比對碼，兩端各自按確認才儲存；每次連線雙向 challenge-response 後，事件（iPhone → Mac）與 ACK／狀態（Mac → iPhone）分別以方向不同的 session key 經 ChaChaPoly 加密。
- 配對路徑：首選由主 App 配對，經 App Group／Keychain sharing 交給 Extension。若 T01 實測 Personal Team 無法使用 App Group，改為在鍵盤內輸入 Mac 顯示的 6 位配對碼，配對秘密存於 Extension 自身的 Keychain，主 App 只負責教學與診斷。
- Mac 輸入法：注入前若目前輸入法不是 ABC，以 TIS API 切換至 ABC，注入後切回原輸入法。若焦點元素的 `AXTextInputMarkedTextMarkerRange` 顯示正在組字，先在原輸入法下送 Escape 取消組字（刪除未完成文字），確認組字已清除才切換；仍在組字則 fail closed 拒收。App 不支援此屬性時視為未組字，照常切換，未完成文字可能被提交。切換後再驗證一次，仍不是 ABC 則 fail closed 拒收。需測試切換未生效即注入、連續事件之間反覆切換的 race。
- `CGEventKeyboardSetUnicodeString` 單一事件有長度上限，Receiver 須自行切段注入，目前每段 20 UTF-16；輸入法切回前等待 0.05 秒（可用 `rk.settleSeconds` 調整）。實際上限與注音狀態下的 settle 值延至 T16 實測後寫入本節（使用者 2026-10-30 決定）。
- GATT 方向（D12）：service 由 iPhone 發佈，UUID `706AA642-68A3-41FA-889D-24E30709B0D0`。`event` characteristic `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`（notify）：iPhone → Mac 的 `KeyboardEvent`。`control` characteristic `320468E2-53B6-4B6A-88EC-AE2752415818`（write with response）：Mac → iPhone 的 `Ack` 與 `ReceiverStatus`（含 `ready`、目前 App 名稱、`focusEpoch`）。T02 的 Mac service `2A6F212A-…` 停用，Receiver 不再廣播。
- 連線路徑：Mac 以 `scanForPeripherals(withServices: [service])` 掃描並連入；`retrieveConnectedPeripherals` 在 Mac 與 iPhone 兩端都取不到對方（實測），不作為路徑。T09 完成配對驗證前，Mac 連入任何廣播此 service 的 iPhone，僅供開發使用。
- 單一 notify 大小以 `CBCentral.maximumUpdateValueLength` 為上限，勿寫死 20 bytes；`updateValue` 回傳 `false` 時暫存事件，等 `peripheralManagerIsReady(toUpdateSubscribers:)` 再送，不得丟棄。
- 針對 ACK lost：Receiver 保留短期事件 ID 去重；若是否已發往目標 App 無法證明，回報 `AMBIGUOUS` 狀態，禁止無提示的跨焦點重播。

## 6. 語音的預定設計決策

- 目標流程：使用 iOS 系統的麥克風按鍵（`hasDictationKey = false`，由系統在鍵盤下方顯示）。聽寫文字由 iOS 直接寫入 host App 欄位，因此**文字會留在 iPhone 欄位**；Extension 觀察 `documentContextBeforeInput` 的變化計算差分，同步到草稿列與 Mac。Apple 修正詞語時，Mac 端以 `BACKSPACE × n` 加新文字對應。
- 首先測 `system dictation visible / actually commits to host App / extension sees textDidChange / extension can know exact diff / remote receives exact diff`，**每項需獨立記錄**。
- 若僅能見到按鈕或有限 context diff，不能宣稱語音支援 Mac 同步。T13 未通過時，改為主 App 手動語音頁：使用者自行開啟主 App，以 iPhone 麥克風辨識後由主 App 作為 Peripheral 經 BLE 送往 Mac。不走自動跳 App hack。

## 7. 不做的事（v1.0）

- 不製作觸控板、鍵盤 HID 配對、Mac 無 Receiver 模式、通用鍵盤事件側錄、跨 App 靜默同步、遠端任意系統快捷鍵、雲端中繼、強制喚醒 iPhone 鍵盤。
- 不保證模仿 Apple 私有自動修正、滑動輸入、iOS 系統語音 API 的內部操作。
- v1.3 不做：GIF 頁、emoji 頁、速成聯想字、候選字依字頻排序、學習使用者常用字、主 App「新增頁面」（英文與符號頁固定存在）、`◀ ▶` 遠端移動 Mac 游標。

## 8. 接受標準／非功能需求

- 工程 PoC：在真 iPhone 的第三方 Keyboard Extension 按 `A`，Mac TextEdit 同一焦點顯示 `A`；Notes→Safari 跨 App 能重開 Extension 並送達 Mac；不開 Full Access 時 Local Mode 仍可打字。
- Transport release gate：100 次鍵盤重開/連線 >=99 成功；首次可用時間 P95 <=2 秒（awake/已配對/同房環境；記錄測試環境）；在控制式 TextEdit 測 10,000 事件，0 遺漏/0 重複/0 亂序；這些是**預設驗收目標**，未做實測。
- Unicode：英文、符號、繁體中文、emoji（含 ZWJ）、accent、Return/Delete 在 TextEdit 試驗可重現預期結果；Word/Safari/VS Code 支援為個別矩陣結果，不由 TextEdit 推導。
- 重要安全測試：未配對/未授權/沒有 Mac 文字焦點/焦點切換/鎖屏/secure field/藍牙關閉，絕不把文字偷偷送往新位置；原則上 fail closed。
- 語音：Gate 結果必須明文寫為 `PASS / FAIL / INCONCLUSIVE`；若 FAIL，不可把語音當成已交付功能。
- 軟件可分發：Xcode target build+test、真機證據、手動驗收、版本化文檔、隱私權限說明；App Store 上架另設獨立審查。

## 9. 技術方案比較

| 方案 | 優點 | 限制 | 決策 |
|---|---|---|---|
| Extension（Central）-> Mac Receiver（Peripheral） | 離線、Unicode 語義文字 | 同一 iCloud 實機連線失敗（T03） | 不採用 |
| Mac Receiver（Central）-> Extension（Peripheral） | 離線、Unicode 語義文字、不依賴 HID；易控 ACK；實測 0.5 秒連上 | 只在鍵盤可見時可連；需 Full Access | **首選（D11）** |
| Extension -> LAN WebSocket -> Mac Receiver | 協定傳輸可靠、debug 簡單 | Full Access + local-network permission、網段限制 | D11 路徑若在 T05／T06 未達標才做限時 PoC（Bonjour + TLS WebSocket）；校園 Wi-Fi 隔離裝置時改用 iPhone 個人熱點測試 |
| Main iOS App -> BLE/LAN | 易處理 Native TextInput、語音 | 不符合任何 App 中直接開鍵盤的目標 | 診斷與語音降級方案 |
| iPhone Bluetooth HID | Mac 免安裝 Receiver | 既有配對體驗差，Unicode/CJK 問題 | 不採納主線 |

## 10. 設計文件狀態

本設計 v1.2 已於 2026-10-29 獲使用者批准；v1.3 已於 2026-10-30 獲使用者批准。T01–T06 已實機 PASS（見驗收報告）。下一文件 `docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md` 是對應的執行計劃，依其 v1.2 的 T03a、T03b、T04–T06 執行。

## 11. 核心證據鏈（Apple 官方）

- Custom Keyboard: https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- Open Access: https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- Text input: https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
- Dictation: https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey
- App Review 4.4.1: https://developer.apple.com/app-store/review/guidelines/
- BLE: https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices
- AX: https://developer.apple.com/documentation/applicationservices/axuielement_h
- Unicode injection: https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)
- Handwriting: https://developer.apple.com/documentation/pencilkit/recognizing-handwriting-and-converting-to-text
- Vision text recognition: https://developer.apple.com/documentation/vision/recognizetextrequest
- ML Kit Digital Ink: https://developers.google.com/ml-kit/vision/digital-ink-recognition/ios

## 12. 設計決定總表（v1.4，2026-10-31）

| # | 範疇 | 決定 | 影響任務 |
|---|---|---|---|
| D1 | 受眾 | 自用與專題／比賽展示；M1–M4 只用開發簽名，App Store、TestFlight、Developer ID 公證留到 T16；App Review 4.4.1 規則照常遵守 | T16 |
| D2 | 簽名 | 免費 Personal Team；build 7 天到期需重裝；App Group 可用性於 T01 實測並記錄 | T01、T09 |
| D3 | 配對備案 | App Group 不可用時，鍵盤內輸入 6 位配對碼，秘密存於 Extension 自身 Keychain（§5） | T09 |
| D4 | Mac 輸入法 | 注入前自動切換至 ABC、注入後切回；Mac 正在組字時先取消組字（刪除未完成文字）再切換，App 不提供組字狀態時照常切換（未完成文字可能被提交）；切換後驗證失敗則 fail closed（§5；組字規則為使用者 2026-10-29 修訂） | T04、T05、T14 |
| D5 | Remote 行為 | 只送 Mac；重開沿用上次模式；常駐狀態列，一點切回 Local（§2） | T05、T09、T10 |
| D6 | 未就緒輸入與草稿（2026-10-30 修訂） | 遠端模式下鍵盤可切換「即時／草稿」；草稿以 `◀ ▶` 移游標、插入與刪除，按「傳送」送出；未就緒時一律草稿且「傳送」灰色；左右鍵不送 Mac；草稿只存記憶體（§2） | T08、T10 |
| D7 | 語音 | 系統麥克風加 context diff 同步；T13 未通過改用主 App 手動語音頁（§6） | T13 |
| D8 | BLE 備案 | 接受 LAN WebSocket 備案，僅在 BLE 證實不可行後做限時 PoC（§9） | T03、T05、T15 |
| D9 | 重連測試 | T06 的 100 次以 XCUITest 在真機自動執行，使用者親手抽查 10 次並錄影；XCUITest 無法切換第三方鍵盤時，改由使用者親手完成 100 次 | T06 |
| D10 | Xcode project | 使用 XcodeGen：`project.yml` 納入 git，`*.xcodeproj` 不納入；每次以 `xcodegen generate` 產生 | 全部 |
| D11 | 傳輸角色（2026-10-29 批准） | 角色對調：iPhone Keyboard Extension 為 GATT Peripheral、Mac Receiver 為 Central。原因：同一 iCloud 的 iPhone 主動連 Mac 在實機失敗（T03），Mac 主動連 iPhone 成功（spike）。v1.2 已改寫 §2–§5、§9；D8 LAN 保留為後備 | T03–T06 |
| D12 | GATT 方向 | iPhone 發佈 service；`event` notify 送事件、`control` 收 Mac 的 write（ACK、狀態）；Mac 只用掃描路徑；notify 受 `maximumUpdateValueLength` 限制並處理佇列滿（§5） | T03–T06 |
| D13 | Mac 常駐與接收時段 | 登入自動啟動、常駐 menu bar；點擊可編輯輸入框才開始掃描連線；30 分鐘無活動自動停止，收到事件、鍵盤連上或再點輸入框即延長；焦點離開輸入框不斷線（§2） | T03b、T05 |
| D14 | 頁面與底列（2026-10-30） | 中文、英文、符號三頁；底列 `中英`、`符號`、空白鍵、Return；`符號` 再按回到原頁；由中文頁進入符號頁時第一層為數字加全形中文標點（§2） | T10、T11 |
| D15 | 中文輸入法介面（2026-10-30） | 所有中文輸入法實作同一介面（按鍵或筆跡輸入 → 輸入碼／候選字 → 已提交文字），以後可加倉頡、注音、粵拼而不改鍵盤其他部分；主 App 設定頁單選，經 App Group 傳給 Extension；讀不到設定，或手寫採 ML Kit 而未開 Full Access 時用速成（§3） | T12、T12b |
| D16 | 中文輸入法次序與速成範圍（2026-10-30） | 先做手寫（T12；O7：Apple 原生實機未達標，使用者 2026-10-30 決定直接採用 Google ML Kit（需 Full Access），Apple 原生日後再評估），後做速成（T12b）。速成鍵面顯示倉頡字根；候選字依字碼表次序；空白鍵選第一個候選字；字碼表須授權清楚（O9）；聯想字、字頻、學習常用字不做 | T12、T12b |
| D17 | 頂部區（2026-10-30） | 三行：①本機／遠端、狀態、即時／草稿；②草稿列（`◀ ▶` 在左、`傳送` 在右）；③候選字列；即時狀態收起第二行，本機模式只有本機／遠端與候選字（§2） | T10 |
| D18 | 聽寫同步（2026-10-31） | 遠端模式下自動把系統聽寫寫入 iPhone 欄位的變化轉成差分送到 Mac（ContextDiff：退格＋文字），不需手動開啟；主 App 設定頁「聽寫同步到 Mac」開關，預設開，經 App Group 傳給 Extension。所有變化都送，包括只刪字的變化（使用者決定；App 自行清空欄位時可能刪到 Mac 的字，屬已知風險）。草稿模式下差分進草稿，位置跟草稿游標。換欄位（documentIdentifier 改變）、文字窗口不可信（共同前綴 0 且舊文字 ≥ 10 字）、差分過大、欄位內容未載入（nil）時只重設基準不送出。本機模式不同步。log 只記種類與長度。DEBUG build 保留長按狀態文字開啟的檢查面板 | T13b |
| D19 | 底列鍵序（2026-10-31） | 英文、符號頁：`符號`、`中英`、空白、換行；手寫頁：`符號`、`中英`、空白、`重寫`、換行。只互換 `符號` 與 `中英` 的位置，寬度與功能不變（修訂 D14 的鍵序） | T13b |

## 13. 開發環境（2026-10-29 實測）

| 項目 | 狀態 |
|---|---|
| Xcode／Swift | 27.1／6.4 |
| macOS | 27.2，Bluetooth 已開啟 |
| iOS 模擬器 | iPhone 18 Pro（iOS 27.0）；模擬器沒有 CoreBluetooth，只能用於 T01 的 UI 與 Local Mode |
| 實體 iPhone | iPhone 17 Pro，iOS 27.0.1，USB 配對、Developer Mode 已開；T03、T05、T06 必須使用實機 |
| 簽名身分 | Personal Team `4YN34HPX6F`（Apple Development），`project.yml` 已設定 |
| XcodeGen | 2.46.0 已安裝；三個 target 的空殼已於暫存資料夾驗證 iOS Simulator 與 macOS build 成功，Extension 的 `CFBundleVersion` 需與 host App 一致 |
