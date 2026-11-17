# 安裝教學影片 v0.2.0 更新 驗收報告

日期：2026-11-17
範圍：把安裝教學影片由 v0.1.0 Alpha 1 更新到 v0.2.0 Alpha 1。全片 21 場，346 秒（原 335 秒）、10380 幀、1920×1080、30 fps、AAC 音軌。
成品：`video/out/renders/Main.mp4`（7,566,036 位元組，`out/` 不提交）。YouTube 上傳資料：`docs/video/install-tutorial-youtube.md`。

## 一、改了什麼

| 場 | 改動 |
|---|---|
| 1 | 字幕改為支援 Mac、Windows 與 Linux 電腦，本片示範 Mac（10 秒改 12 秒） |
| 10、15 | 檔名、SHA-256、Release 網址與標題改為 v0.2.0-alpha.1 的公開值 |
| 14、18、19 | iPhone：「已配對 Mac」改「已配對電腦」，「配對 Mac」改「新增電腦」；配對碼頁加「要配對的電腦」；已儲存與完成頁的文字依 App |
| 17、18、19 | Mac 面板：開啟後即接收，第三行為「接收中」，「開始接收」為停用；配對區改為三行提示、等待文字、「手機：iPhone」、「已配對的手機」列與「刪除」；加入「電腦名稱」區 |
| 20 | 鍵盤狀態格兩行：電腦名稱「Mac」在綠色「已連接」上方 |
| 21 | 新增 Mac「區域網路」詢問的一拍（按「允許」），字幕加區域網路與手冊 04b、04c 章（12 秒改 21 秒） |

## 二、自動驗證（已完成）

| 指令 | 結果 |
|---|---|
| `cd video && npm test` | 270 項，270 通過，0 失敗 |
| `npx kinetograph check src/index.tsx` | no type errors |
| `node scripts/verify-scenes.mjs` | all 166 checks passed（含 MP4 10380 幀） |
| `ffprobe out/renders/Main.mp4` | h264 10380 幀，346.000 秒；AAC 346.000 秒 |
| 舊字串 grep（已配對 Mac、配對 Mac、待命、剩餘接收時間、尚未開始接收、0.1.0，排除測試、`src/film`、`src/intro`） | 0 筆 |
| `grep -E "[nN]\s*=\s*\d"` 腳本 | 0 筆 |
| 29 張改動場景的靜態畫面（`video/out/stills-v0.2/`） | 主代理逐張檢視：沒有裁切或重疊 |
| 獨立審查 | 所有畫面字串與 App 原始碼一致，兩個 SHA-256 與線上 `SHA256SUMS.txt` 相同；兩處過時數字已修正 |

## 三、未驗證（TBD）

| 項目 | 狀態 |
|---|---|
| 使用者觀看全片與聽音效 | TBD |
| 上傳 YouTube、更新 README 與手冊的影片連結 | TBD，等使用者上傳後提供新網址 |

已知差異：Mac 面板配對完成後沒有畫「目前連線：iPhone」與「配對於」日期行；App 在這兩項資料齊備時才顯示，影片省略不影響操作。
