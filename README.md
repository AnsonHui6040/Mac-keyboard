# Mac-keyboard

iPhone 第三方鍵盤 Extension，透過自訂 BLE GATT 將英文、符號、繁體中文手寫與語音文字送到 Mac 目前的可編輯焦點。Mac 端需安裝 menu-bar Receiver。

## 狀態

| 項目 | 狀態 |
|---|---|
| 設計規格 | v1.2 APPROVED（2026-10-29，D11 角色對調、D13 Mac 常駐；D4 組字規則 2026-10-30 修訂） |
| 實作計劃 | v1.2 APPROVED（T03a、T03b、T05、T06 重寫） |
| 程式碼 | T01–T05 完成：iPhone 鍵盤遠端模式打字經 BLE 送到 Mac 目前焦點（焦點守衛、自動切 ABC、ACK） |
| 驗收 | 5/16 PASS（T01–T05；T04／T05 部分實機項目延至 T16） |
| 下一步 | T06 BLE 重連 Gate（見 `docs/superpowers/verification/2026-10-29-handoff.md`） |

最後更新：2026-10-30

## 文件

| 文件 | 路徑 |
|---|---|
| 設計規格 | [docs/superpowers/specs/2026-10-29-remote-keyboard-design.md](docs/superpowers/specs/2026-10-29-remote-keyboard-design.md) |
| 研究摘要 | [docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md](docs/superpowers/research/2026-10-29-remote-keyboard-research-summary.md) |
| 實作計劃 | [docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md](docs/superpowers/plans/2026-10-29-remote-keyboard-implementation.md) |
| 驗收報告 | [docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md](docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md) |
| v1.0 原始交付包 | [docs/archive/planning-package-v1.0/](docs/archive/planning-package-v1.0/) |
