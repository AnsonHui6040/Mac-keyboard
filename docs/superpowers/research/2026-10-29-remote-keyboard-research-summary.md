# 技術研究報告 — 決策摘要與來源索引

**2026-10-29｜根據本對話深度研究報告整理**。研究為文獻與案例分析，**不是**已完成工程驗證。保留官方／開源／推論／待測四種證據層級。

## 調查結論

| 命題 | 證據級別 | 結論／下一步 |
|---|---|---|
| 第三方 Keyboard Extension 可在容許的 App 中出現 | Apple 官方 | `UIInputViewController`，需要 Xcode Keyboard target；secure/phone/app policy 除外 |
| Extension 本地文字輸入 | Apple 官方 | `textDocumentProxy.insertText()`、`deleteBackward()`；Local Mode 必須實作 |
| Full Access 網路權限和共享容器 | Apple 官方 | `RequestsOpenAccess` 且使用者自行開啟；需私隱揭露 |
| Keyboard Extension 不能任意開主 App | Apple App Review 4.4.1 | 禁止作正式語音主流程；只可讓用戶自行打開主 App |
| `hasDictationKey=true` 等於取得系統聽寫文字 | Apple 官方／否定 | 屬於 keyboard capability / button 顯示控制；非輸出事件 API |
| 系統語音結果能否被 Extension 無失真讀取 | 待實測 | 必須有 Dictation Gate，測文字差分、修正、跨 App |
| Extension 直接 BLE Central 到 Mac Peripheral | API 支持／端到端待測 | Core Bluetooth 有雙角色；extension 真機短壽命為首要風險 |
| Mac 接收 Unicode 到任意 app | Apple API＋實機待驗 | AX focused element + CGEvent Unicode 具官方接口，但 app compatibility 不保證 |
| Apple 風格英文鍵盤、123、#+= | API 及自製 UI | 可自製 layout/interaction，不能重用 Apple 私有 keyboard/IME |
| 繁中手寫辨識 | Apple PencilKit / ML Kit 官方 | 先查 API 和 `zh-Hant` support；需延伸記憶體與準確度測試 |

## 失敗案例與設計處置

1. **Bluetooth HID 配對失敗／連線無輸出／CJK 亂碼**：使用者已實際遭遇配對困難。BT Keys 產品描述對 CJK Unicode workaround 有明確提示；改用 Custom GATT 與 Mac Receiver，帶語義文字、身份驗證、ACK。https://apps.apple.com/tw/app/bt-keys-keyboard-trackpad/id6778806487
2. **Extension 消失後斷線**：Apple 明示 extension 獨立 process、有限記憶體，可能被終止；不得要求 permanent BLE singleton。每次顯示都可完整恢復，並測 100 次重新啟動。https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
3. **語音快捷鍵跳主 App**：開源 Muesli-iOS 有 handoff 流程，但 Apple 4.4.1 禁止鍵盤啟動其他 App，不能由 repo 有實作推論可公開上架；保留為設計參考，不納正式主線。https://github.com/Muesli-HQ/muesli-ios
4. **輸入 Mac 焦點錯誤**：AX observer/CGEvent 目標 app 異動；每事件驗 focusEpoch，遇焦點切換、睡眠或未授權直接暫停。https://developer.apple.com/documentation/applicationservices/axuielement_h
5. **CGEvent Unicode 在特定 App 被忽略**：Apple CGEvent Unicode API 有兼容限制；逐一測 TextEdit、Word、Safari、VS Code，AX 操作只作支援足夠的 text controls fallback。https://developer.apple.com/documentation/coregraphics/cgevent
6. **多位元組被切斷**：不能寫死 BLE 20 bytes，須依 write limit 分 chunk；協定需要 packet framing、UTF-8 validation。https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices
7. **Full Access 權限風險**：Remote Mode 要 opt-in，Local Mode 不要求 full access；不保留任意鍵盤輸入全文 log。https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard

8. **同一 iCloud 的 Mac 無法以新連線連上**（2026-10-29 T02 實測）：iPhone 將 Mac 廣播解析為已知裝置「Mac」，nRF Connect 停在 Connecting，Mac 端 150 秒抓取沒有任何連線要求；系統已有 iPhone 與 Mac 的 LE 連線並確認 Service Changed indication。處置：Central 先用 `retrieveConnectedPeripherals(withServices:)`。

## 可研究實例（沒有宣稱同構架構已完成）

- Apple BLE data transfer sample： https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices
- KeyboardKit： https://github.com/KeyboardKit/KeyboardKit （比較 layout/action engine，採納前審授權）
- Muesli iOS： https://github.com/Muesli-HQ/muesli-ios （研究 dictation handoff，非直接照搬）
- MacRemote iOS/Mac LAN： https://github.com/waiyan0x/MacRemote
- diy-mac-remote： https://github.com/amv/diy-mac-remote
- Google ML Kit Digital Ink： https://developers.google.com/ml-kit/vision/digital-ink-recognition/ios

## 高風險未知項（必須有實測數據）

- A：Extension 真正能否拿到 BLE 所需權限、正常掃描，使用者切換不同 host App 後重新連線而不崩潰。
- B：iOS system dictation 是否產生可由第三方 Extension 確定取得、可重送且不侵犯 host App 隱私的 committed events。
- C：Mac AX 前景焦點和 CGEvent 在不同編輯器下的一致性（特別是雙字節、中英文、emoji、快速換焦）。
- D：Mac distribution / Sandbox / Accessibility / Bluetooth 權限交互，須分開試驗。
- E：iOS handwriting model memory/cold start、zh-Hant recognition available languages。

**來源政策：**本索引將文獻支援與實際功能區分；每次 POC 將透過 `docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md` 填入測試證據及真實 PASS/FAIL。
