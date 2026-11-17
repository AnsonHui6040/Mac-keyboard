# 代碼庫優化驗收報告（2026-11-17）

Branch `codebase-optimize`，基準 main `a6d30f6`。範圍由使用者選定：衛生清理加 Mac 測試提速；死碼保留不刪。行為不變，沒有改任何產品程式（`macOS/MacReceiver/`、`iOS/`、`Packages/*/Sources`、`receiver/` 皆未改）。

## 現況審查（改動前）

| 項目 | 數字 |
|---|---|
| 產品碼行數 | iOS App 2,331、鍵盤 Extension 6,912、iOS Shared 641、Core 7,864、Mac Receiver 4,830、Rust 接收端 28,524（含檔內測試）、video/src 12,068 |
| 重複碼（8 行窗口比對，不含測試） | 整體 0.7%（282／38,660 行）；Swift 0.3%、Rust 0.3%、TS 1.7%、shell 4.2% |
| 自家警告 | 4 個，全在測試檔；Pods 6 個（Google 第三方，不改）；Rust 0 |
| 未用依賴 | Rust 每個 crate 的依賴都有用到；video 直接 import `@kinetographdev/core` 但未宣告 |
| 死碼 | `MinimalKeyboardView.swift` 零引用；Core `Measurement/` 只剩 Debug 量測工具與測試使用。依使用者決定保留 |
| 冷建置／測試 | Core 13 s、cargo test 14 s、clippy 3 s、iOS build 22 s、Mac test 37 s（執行 16.2 s）、video 1 s、e2e 0.1 s |

## 改動

| 檔案 | 內容 |
|---|---|
| `CounterChannelTests.swift`、`ReplayWindowTests.swift` | 清除 2 個編譯警告，斷言不變 |
| `macOS/MacReceiverTests/` 8 檔 | 移除每個測試約 0.1 s 的 async `setUp`（改為屬性預設值）；固定 sleep 改為等條件或 semaphore；FocusMonitor 慢讀取 2 s → 0.8 s；重建限速測試 0.4 s／2 s → 0.2 s／1 s（比例與上下限不變）；清除 2 個警告 |
| `video/package.json`、`package-lock.json` | 直接宣告 `@kinetographdev/core` 0.3.0；lock 只多 root 一行 |
| `scripts/lib/check-report.sh`（新） | `validate-ipa.sh` 與 `validate-mac-app.sh` 共用的報告與檢查函式；兩支腳本 259 → 197 行、214 → 156 行 |
| `scripts/test-all.sh`（新） | 一個指令跑全部自動化測試並印摘要；`--only`、`--skip`；log 在 `build/test-all/` |
| `docs/DEVELOPMENT.md` | 腳本表加一行 |

未做：`e2e/scripts/measure-reconnect.sh` 與 `measure-trackpad.sh` 的重複部分，需要實機才能驗證，這次不改。

## 自動驗證

| 項目 | 結果 |
|---|---|
| `scripts/test-all.sh`（全部 7 個 suite） | 全部 PASS：core 1,228、receiver 747、clippy 0 警告、ios BUILD SUCCEEDED、mac 409、video 270、e2e 57 |
| 冷建置警告（新 scratch 目錄） | Core 0；Mac 與 iOS 的 `.swift` 編譯警告 0（剩 Pods 第三方與 1 個執行期 Keychain 提示，基準已有） |
| Mac 測試時間 | 執行 16.2 s → 6.3 s；冷建置加測試 37 s → 24 s |
| Mac 測試穩定性 | 子代理連跑 5 次全過（6.08–6.54 s）；18 個 CPU 滿載下改動過的 9 個類別連跑 10 次全過（171 測試）；主代理再跑 2 次全過 |
| `validate-*.sh` 行為不變 | v0.2.0 IPA、v0.2.0 Mac zip、兩個不存在檔案共 4 份報告與舊腳本逐 byte 相同；結束碼 0／0／1／1 相同 |
| 觸控板手感 | `TrackpadFeelBaselineTests`、`PointerReceiverFeelBaselineTests` 未改，皆通過 |

## 獨立審查

結論 APPROVE：0 HIGH，1 MEDIUM，2 LOW。

- MEDIUM（已修）：`ReceiverGoodbyeTests` 的後備取消改成等條件後，上限由 0.7 s 放寬到約 1.75 s。已加回由 `stopReceiving()` 起算的 700 ms 期限，與 `prepareForTermination()` 最多等 0.7 s 一致。修正後主代理重跑該類別 3 次、全部 suite 1 次，皆全過。
- LOW（不改）：`testAuthenticatedLinkIsNotTimedOut` 的否定等待由 300 ms 改成 150 ms，仍是逾時 50 ms 的 3 倍；FocusMonitor 若退化成在主執行緒同步讀取，會以 crash 而非單一測試失敗的形式被抓到。

## 實機驗證

不需要：沒有改任何會進 App、Mac Receiver 或接收端的程式。
