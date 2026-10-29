# iPhone → Mac Remote Keyboard — 設計規格（待批准）

**版本**：v1.0 | **日期**：2026-10-29 | **狀態**：DRAFT / 待使用者審核；非已實作產品

## 1. 產品意圖

在 Mac 使用者點選可編輯文字框之後，Mac Receiver 顯示「準備接收」。使用者於 iPhone 任一**容許第三方鍵盤**的 App 打開文字欄位、切換到 Remote Keyboard，即可透過自製鍵盤將英文、數字／符號或繁體中文手寫的已提交文字遠端送往 Mac 的**目前有效焦點**。iPhone 不需每次打開主 App。此流程不會令 iPhone 自動從鎖屏／其他 App 彈出鍵盤。

## 2. 已定義功能

- iOS 第三方 Keyboard Extension：英文 QWERTY，Shift／Caps Lock／長按、刪除、Space、Return；數字 `123` 和特殊符號 `#+=` 兩層；繁體中文手寫頁、候選字；系統 globe／語言切換；語音輸入入口。
- 英文外觀及使用習慣參考 Apple 原生鍵盤，但不複製 Apple 私有資產、預測字詞引擎或私有系統鍵盤 View。關鍵動作應原生風格而非假裝能重用 Apple keyboard。
- Mac 具 menu-bar Receiver、首次配對、連線狀態、焦點狀態、接收暫停／解除配對。
- 預設 Local Mode：iPhone 本地正常輸入，毋須 Full Access；Remote Mode 必須由使用者明確啟用並授權，且有持續可見狀態；不能暗地將其他 App 的文字複製到 Mac。
- 優先 BLE 自訂 GATT：Mac Peripheral/Server，iPhone Keyboard Extension Central/Client；Mac 使用 AX 聚焦與 CGEvent Unicode 注入；純 Wi-Fi fallback 留到核心 BLE 路徑驗證後才評估。**不以 BLE HID 作主路徑**。
- iPhone 主 App：安裝教學、Full Access 提示、初次配對、管理配對 Mac、顯示診斷及語音方案說明。主 App **不假設**能長期代 Extension 維持 BLE 連線。

## 3. 最重要的平台限制

1. Apple App Review 4.4.1：必須能在未開 Full Access 時正常作為鍵盤；須提供切換下一個鍵盤的控制；不能自行啟動 Settings 以外其他 App；鍵盤活動只能收集作合法鍵盤功能用途。
2. Apple `hasDictationKey` 是表示鍵盤有沒有自己的語音按鍵，不是一個可供 Extension 取得系統 Dictation 完整文字流的公開 callback；語音由獨立實機 Gate 驗證；失敗時不得以非公開 API／越權跳 App 方案作正式產品主線。
3. `UIInputViewController` 在獨立 Extension process 運作；會被殺死或重新建立，不能依賴常駐單例或無限制記憶體；部分 secure/password、phone keypad、禁止第三方鍵盤的 App 會回到 Apple 系統鍵盤。
4. Mac Accessibility 只能證明有可用的焦點與可發送事件，不等同文字已呈現在任意第三方 App；輸入框切換／睡眠／桌面切換需重新驗證。
5. BLE ACK 只能確認 Receiver 端協定狀態／注入動作，不保證目標軟體已經顯示文字。對無法觀察結果的 CGEvent，斷線重試可能出現語義不確定狀態；**不可宣稱任意 App 都具備端到端 exactly-once。**
6. 若 iPhone 用戶在其他 App 打開鍵盤，遠端模式只發送由本鍵盤**直接產生**並明確選擇發往 Mac 的事件；不收集 host App 既有文字或複製通用打字紀錄。
7. `PencilKit PKStrokeRecognizer` 支援與部署最低版本、繁體中文辨識語言及 Extension 記憶體佔用須實機查證；未通過則用 ML Kit Digital Ink `zh-Hani-TW` 或 `zh-Hani-HK` 評估回退。

## 4. 架構

```text
[iPhone host App: Notes, Safari, Messages...]
             │ iOS 揀選第三方鍵盤
             ▼
[Keyboard Extension, UIKit/UIInputViewController]
  ├─ Local mode (textDocumentProxy -> iPhone current field)
  └─ Remote mode (English / Symbols / Handwriting -> SemanticEvent queue)
             │ CoreBluetooth Central：scan/connect/write/notify
             ▼
[Mac Receiver CBPeripheralManager custom GATT service]
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
- 先以 `writeWithResponse` 及 notify/indicate 的可驗證流程做 PoC；由實際 MTU/`maximumWriteValueLength` 分 chunk，勿寫死 20 bytes。
- 針對 ACK lost：Receiver 保留短期事件 ID 去重；若是否已發往目標 App 無法證明，回報 `AMBIGUOUS` 狀態，禁止無提示的跨焦點重播。

## 6. 語音的預定設計決策

- 首先測 `system dictation visible / actually commits to host App / extension sees textDidChange / extension can know exact diff / remote receives exact diff`，**每項需獨立記錄**。
- 若僅能見到按鈕或有限 context diff，不能宣稱語音支援 Mac 同步。若無穩定公開方法，將語音改為明確受限功能（主 App 手動開啟輸入、或標為未支援），不走自動跳 App hack；此設計變更要用戶確認才交付正式版。

## 7. 不做的事（v1.0）

- 不製作觸控板、鍵盤 HID 配對、Mac 無 Receiver 模式、通用鍵盤事件側錄、跨 App 靜默同步、遠端任意系統快捷鍵、雲端中繼、強制喚醒 iPhone 鍵盤。
- 不保證模仿 Apple 私有自動修正、滑動輸入、iOS 系統語音 API 的內部操作。

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
| Extension -> BLE GATT -> Mac Receiver | 離線、Unicode 語義文字、不依賴 HID；易控 ACK | Extension 生命周期與授權待實測 | **首選（PoC 後方確立）** |
| Extension -> LAN WebSocket -> Mac Receiver | 協定傳輸可靠、debug 簡單 | Full Access + local-network permission、網段限制 | BLE 不穩時 fallback PoC |
| Main iOS App -> BLE/LAN | 易處理 Native TextInput、語音 | 不符合任何 App 中直接開鍵盤的目標 | 診斷與語音降級方案 |
| iPhone Bluetooth HID | Mac 免安裝 Receiver | 既有配對體驗差，Unicode/CJK 問題 | 不採納主線 |

## 10. 設計文件狀態

本設計是將已選定的產品方向與研究發現編成**供使用者審核的規格草案**。未宣稱任何真機測試已通過。下一文件 `docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md` 是對應的候選執行計劃，只有本設計獲批准後才開始執行。

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
- ML Kit Digital Ink: https://developers.google.com/ml-kit/vision/digital-ink-recognition/ios
