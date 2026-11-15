# 多台電腦驗收清單（Windows、Linux）

狀態欄：PASS／FAIL／TBD。全部 TBD，跑完或親手試過才改。Mac 欄標「之後再做」。

## A. 自動：輪流切換並打字

指令（在這台 Mac 上，iPhone 解鎖並接上線）：

    RK_IPHONE_UDID=<UDID> e2e/scripts/rotate-hosts.sh 20

| # | 項目 | 狀態 |
|---|---|---|
| A1 | 20 輪全部跑完（奇數輪 Windows、偶數輪 Linux），結束碼 0 | FAIL（2026-11-16：20 輪都切換成功，Linux 掉字，結束碼 6） |
| A2 | 每一輪打字前，目標電腦的測試視窗回報 `focus=True`（否則結束碼 7，沒有打任何字） | PASS（打字前後都檢查） |
| A3 | Windows 只收到自己那幾輪的字串，沒有 Linux 的 | PASS（10／10） |
| A4 | Linux 只收到自己那幾輪的字串，沒有 Windows 的，順序正確 | FAIL（沒有收到 Windows 的字串；兩次各有字串不完整，見驗收報告） |
| A5 | 每輪切換時間（最後一次點擊到「已連接」）的 p50、p95 已記錄，不設門檻 | PASS |
| A6 | 結果檔 `e2e/results/<日期>-rotation.txt` 已產生，接收端的連線數每輪一次 | Windows PASS；Linux 多出輪替經過時的連線 |

## B. 手動：實機

| # | 項目 | Windows | Linux | Mac |
|---|---|---|---|---|
| B1 | 配對後輸入英文、數字、符號 | TBD | TBD | 之後再做 |
| B2 | 中文手寫 | TBD | TBD | 之後再做 |
| B3 | 快速輸入 | TBD | TBD | 之後再做 |
| B4 | 語音聽寫 | TBD | TBD | 之後再做 |
| B5 | 觸控板：移動、點一下、按住拖曳、兩指捲動 | TBD | TBD | 之後再做 |
| B6 | 在 iPhone 刪除其中一台電腦，另一台仍可打字 | TBD | TBD | 之後再做 |
| B7 | 兩支手機連同一台電腦（需要第二支 iPhone 或 iPad，沒有就維持 TBD） | TBD | TBD | 之後再做 |
| B8 | 開機登入後自動啟動並可直接打字 | TBD | TBD | 之後再做 |
| B9 | Linux 重新授權：重開機後「遠端桌面」授權視窗出現並按「允許」，之後可打字 | 不適用 | TBD | 不適用 |
| B10 | Windows 以系統管理員身分執行的視窗收不到輸入，且不顯示錯誤（手冊所述限制） | TBD | 不適用 | 不適用 |
