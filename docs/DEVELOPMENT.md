# 開發者文件

iPhone 第三方鍵盤 Extension，透過自訂 BLE GATT 將英文、符號、繁體中文手寫與語音文字送到 Mac 目前的可編輯焦點。Mac 端需安裝 menu-bar Receiver。

## 狀態

| 項目 | 狀態 |
|---|---|
| 設計規格 | v1.3 APPROVED（2026-10-30，D14–D17：三頁鍵盤、中文輸入法介面、手寫採 Google ML Kit、速成、頂部區、即時／草稿） |
| 實作計劃 | v1.3 APPROVED（2026-10-30，細化 T07–T16，新增 T12b 速成） |
| 程式碼 | T01–T06 完成：iPhone 鍵盤遠端模式打字經 BLE 送到 Mac 目前焦點（焦點守衛、自動切 ABC、ACK），鍵盤重開後約 0.2–0.7 秒自動重連；T07 協定分幀（v2 信封、多 frame notify、Mac 重組）完成；T08 ACK、去重與排序完成；T09 配對、雙向驗證與加密完成；T10 原生風格英文鍵盤、頁面切換、三行頂部區與即時／草稿完成（實機自動測試通過）；T12 手寫（Google ML Kit，主 App 下載模型）已完成自動驗證，手寫頁改為原生式版面；T13 語音聽寫同步探測（DEBUG）實機可行 |
| 驗收 | 11/17 PASS（T01–T10、T13）；T11、T12、T12b、T13b、T14、T15、T16 自動通過，實機延至 T16 總清單 |
| 下一步 | T01–T16 程式與自動驗證已全部完成；使用者依 `e2e/E2E-T16-RC.md` 做實機總測試（176 項，約 6 小時 15 分鐘），結果填回驗收報告 |

最後更新：2026-10-31

## 建置

```
xcodegen generate && LANG=en_US.UTF-8 pod install
xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet
xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -quiet
swift test --package-path Packages/RemoteKeyboardCore
```

`pod install` 必須帶 `LANG=en_US.UTF-8`（終端機不是 UTF-8 時 CocoaPods 會當掉）。手寫使用 Google ML Kit（CocoaPods）。ML Kit 沒有 arm64 模擬器版本，`Podfile` 讓 App 與 Extension 只在真機連結它；模擬器 build 使用替身辨識器，手寫在模擬器不會產生候選字。

### 安裝 Mac Receiver

```
scripts/install-mac-receiver.sh
```

預設建置 Debug 版並安裝到 `/Applications/Remote Keyboard Receiver.app`，之後可從 Launchpad 或 Spotlight 開啟。`--configuration Release` 改建 Release，`--no-build` 只複製已建置的產物。

## 文件

| 文件 | 路徑 |
|---|---|
| 設計規格 | [docs/superpowers/specs/2026-10-29-remote-keyboard-design.md](superpowers/specs/2026-10-29-remote-keyboard-design.md) |
| 研究摘要 | [docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md](superpowers/research/2026-10-29-remote-keyboard-research-summary.md) |
| 實作計劃 | [docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md](superpowers/plans/2026-10-29-remote-keyboard-implementation.md) |
| 驗收報告 | [docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md](superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md) |
| v1.0 原始交付包 | [docs/archive/planning-package-v1.0/](archive/planning-package-v1.0/) |

## 發佈與 SideStore 腳本

| 腳本 | 用途 |
|---|---|
| `scripts/build-sidestore-ipa.sh` | 建置給 SideStore 用的 IPA：Release、無發佈簽章，只用 ad-hoc 簽章寫入 entitlements；輸出到 `release/sidestore/` |
| `scripts/build-mac-receiver-release.sh` | 建置 Mac Receiver 的發佈 zip：Release、ad-hoc 簽章，沒有 Developer ID，也沒有公證 |
| `scripts/validate-ipa.sh` | 檢查 IPA 的結構，每項輸出 PASS、FAIL 或 BLOCKED；不代表能在 SideStore 安裝 |
| `scripts/validate-mac-app.sh` | 檢查 Mac Receiver zip 的結構；不代表能通過 Gatekeeper，也不是啟動測試 |
| `scripts/prerelease-check.sh` | 發佈前自動檢查，結果寫入 `release/prerelease-report.md`；真機項目不在其中 |

發佈前人手檢查見 [distribution/prerelease-manual-checklist.md](distribution/prerelease-manual-checklist.md)，測試者使用手冊見 [manual/README.md](manual/README.md)。
