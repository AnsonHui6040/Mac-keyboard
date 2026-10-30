# Mac-keyboard

iPhone 第三方鍵盤 Extension，透過自訂 BLE GATT 將英文、符號、繁體中文手寫與語音文字送到 Mac 目前的可編輯焦點。Mac 端需安裝 menu-bar Receiver。

## 狀態

| 項目 | 狀態 |
|---|---|
| 設計規格 | v1.3 APPROVED（2026-10-30，D14–D17：三頁鍵盤、中文輸入法介面、手寫先試 Apple 原生、速成、頂部區、即時／草稿） |
| 實作計劃 | v1.3 APPROVED（2026-10-30，細化 T07–T16，新增 T12b 速成） |
| 程式碼 | T01–T06 完成：iPhone 鍵盤遠端模式打字經 BLE 送到 Mac 目前焦點（焦點守衛、自動切 ABC、ACK），鍵盤重開後約 0.2–0.7 秒自動重連；T07 協定分幀（v2 信封、多 frame notify、Mac 重組）完成；T08 ACK、去重與排序完成；T09 配對、雙向驗證與加密完成；T10 原生風格英文鍵盤、頁面切換、三行頂部區與即時／草稿完成（實機自動測試通過） |
| 驗收 | 10/17 PASS（T01–T10，M1 Gate 通過；部分實機逐項紀錄延至 T16） |
| 下一步 | T12 手寫可行性（O7 Gate：先測 Apple 原生手寫辨識），之後 T13 語音 Gate；非重大實機測試集中於 T16 |

最後更新：2026-10-30

## 建置

```
xcodegen generate && LANG=en_US.UTF-8 pod install
xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet
xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -quiet
swift test --package-path Packages/RemoteKeyboardCore
```

`pod install` 必須帶 `LANG=en_US.UTF-8`（終端機不是 UTF-8 時 CocoaPods 會當掉）。手寫使用 Google ML Kit（CocoaPods）。ML Kit 沒有 arm64 模擬器版本，`Podfile` 讓 App 與 Extension 只在真機連結它；模擬器 build 使用替身辨識器，手寫在模擬器不會產生候選字。

## 文件

| 文件 | 路徑 |
|---|---|
| 設計規格 | [docs/superpowers/specs/2026-10-29-remote-keyboard-design.md](docs/superpowers/specs/2026-10-29-remote-keyboard-design.md) |
| 研究摘要 | [docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md](docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md) |
| 實作計劃 | [docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md](docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md) |
| 驗收報告 | [docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md](docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md) |
| v1.0 原始交付包 | [docs/archive/planning-package-v1.0/](docs/archive/planning-package-v1.0/) |
