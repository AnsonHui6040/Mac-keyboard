# Mac-keyboard 專案守則

本檔與全域 `~/.claude/CLAUDE.md` 衝突時，以本檔為準。

## 開工前必讀（依序）

1. `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（§12 設計決定 D1–D10）
2. `docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md`
3. `docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md`
4. `docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md`（含開工前待解決事項 O1–O7）

## 分工

- 主代理只負責規劃、審查與合併；程式由 Sonnet 子代理撰寫，effort 依任務調整。
- 子代理不得 commit 或 push。每份 brief 寫明可改的檔案、驗收清單與需交付的證據。
- 主代理自行重跑 test／build，並經獨立 reviewer 審查後，可自行 merge PR 進 main（本專案例外於全域「PR 由使用者 merge」）。
- 一個 Task 一個 worktree、一條 branch、一個 PR。額外流程開新 session 完成後再回主 session。

## 流程

- Superpowers：設計批准後才寫產品程式；範圍變更走 writing-plans；每個 Task 走 TDD（RED → GREEN → Verify）；失敗走 systematic-debugging；完成前走 verification-before-completion。
- 每個 Task 完成即停下回報，不自行開始下一個 Task。
- 每個 Task 必須更新驗收報告，附實際證據；文獻研究不算 PASS。

## 建置

- Xcode project 由 XcodeGen 產生：改 `project.yml`，再執行 `xcodegen generate`，接著 `LANG=en_US.UTF-8 pod install`（手寫用 Google ML Kit，CocoaPods；沒有 `LANG` 時 `pod install` 會當掉）；build 一律用 `-workspace RemoteKeyboard.xcworkspace`。不要提交 `*.xcodeproj`、`*.xcworkspace`、`Pods/`；`Podfile` 與 `Podfile.lock` 要提交。
- 純邏輯：`swift test --package-path Packages/RemoteKeyboardCore`
- 模擬器沒有 CoreBluetooth：BLE 相關驗收（T03、T05、T06）只能在實體 iPhone 完成。
- 簽名使用免費 Personal Team，build 7 天到期。

## 驗收規則

- 自動驗證與實機驗證分開列；實機項目標 TBD，使用者親手測完才算 PASS。
- 不得把文字內容寫入 log；log 只記事件種類、長度、時間與結果。
- 不承諾任意 Mac App 的 exactly-once 送達；ACK 只代表 Receiver 已處理。
