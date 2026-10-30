# Mac-keyboard

iPhone 第三方鍵盤 Extension，透過自訂 BLE GATT 將英文、符號、繁體中文手寫與語音文字送到 Mac 目前的可編輯焦點。Mac 端需安裝 menu-bar Receiver。

## 狀態

| 項目 | 狀態 |
|---|---|
| 設計規格 | v1.3 APPROVED（2026-10-30，D14–D17：三頁鍵盤、中文輸入法介面、手寫先試 Apple 原生、速成、頂部區、即時／草稿） |
| 實作計劃 | v1.3 APPROVED（2026-10-30，細化 T07–T16，新增 T12b 速成） |
| 程式碼 | T01–T06 完成：iPhone 鍵盤遠端模式打字經 BLE 送到 Mac 目前焦點（焦點守衛、自動切 ABC、ACK），鍵盤重開後約 0.2–0.7 秒自動重連；T07 協定分幀（v2 信封、多 frame notify、Mac 重組）自動驗證通過 |
| 驗收 | 6/17 PASS（T01–T06，M1 Gate 通過；部分實機逐項紀錄延至 T16） |
| 下一步 | T07 實機驗收（使用者，見 `e2e/E2E-T07-FRAMING.md`）；之後 T08 ACK、去重與排序 |

最後更新：2026-10-30

## 文件

| 文件 | 路徑 |
|---|---|
| 設計規格 | [docs/superpowers/specs/2026-10-29-remote-keyboard-design.md](docs/superpowers/specs/2026-10-29-remote-keyboard-design.md) |
| 研究摘要 | [docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md](docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md) |
| 實作計劃 | [docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md](docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md) |
| 驗收報告 | [docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md](docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md) |
| v1.0 原始交付包 | [docs/archive/planning-package-v1.0/](docs/archive/planning-package-v1.0/) |
