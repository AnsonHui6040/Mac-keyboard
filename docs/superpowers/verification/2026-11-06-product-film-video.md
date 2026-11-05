# 產品電影版影片：驗收

日期：2026-11-06
Composition：`ProductFilm`，程式在 `video/src/film/`，分鏡在 `docs/video/product-film-storyboard.md`。
成品不提交：`video/out/renders/product-film.mp4`。

## 重新輸出

先把兩條音樂放到 `video/public/audio/`（`Clean_Geometry.mp3`、`Soft_Geometry.mp3`）。授權未確認，檔案不進 git。

```bash
cd video
scripts/render-film.sh
```

腳本先輸出 `product-film-raw.mp4`，再做音量與限幅，視訊串流不重新編碼。

## 自動驗證

| 項目 | 結果 |
|---|---|
| `npm test` | 234 項全部通過 |
| `kinetograph check` | 沒有型別錯誤 |
| `kinetograph doctor` | 1800 幀全部可完整繪製 |
| `kinetograph lint` 預設 8 幀 | 90 個 error，全是 `text-overflow-canvas`：frame 771、1285 的 15 個邊緣鍵帽文字各畫 6 層景深 |
| `kinetograph lint` 每 15 幀 | 0 個 error，標題與字卡都沒有被標記 |
| `ffprobe` | H.264、AAC、1920×1080、30 fps、1800 幀、60.000 秒 |
| 響度（`ebur128`，成品） | -14.2 LUFS，峰值 -1.9 dBFS |
| 舊片不變 | `Main` frame 5000、9000，`ProductIntro` frame 100、1000、1700，`Scene16` frame 300 與 main `0dfd49a` 逐位元相同；三者 `audio analyze` 相同 |
| 沒有音樂檔 | 測試、型別檢查、其他 composition 不受影響 |

3D 螢幕對齊：螢幕下墊洋紅平面，鏡頭移動中邊緣誤差平均低於 1 px。

## 親自看過的畫面

從 MP4 抽 86 幀，涵蓋全部 31 鏡與第 21 鏡每個小段，並縮到 390 寬抽查 6 幀。文字、裁切正常，沒有真實帳號、裝置名稱或 UDID。

## 與分鏡的差異

| 項目 | 做法 | 原因 |
|---|---|---|
| 第 12 鏡 | 多點一下草稿列尾端，共 3 下 | 游標停在補上的 c 之後，直接按換行會把 ⏎ 插在字中間（`DraftBuffer.swift`） |
| 第 24–27 鏡 | 手機與 Mac 來回切，分 16、17、16、17 幀 | 分鏡只給一段總長 |
| 手寫段音樂 | 只降音量，沒有濾波 | `Audio` 沒有濾波功能 |
| 音樂 | 7–12.2 秒取 Clean Geometry 開頭，16–41 秒連續一段，來源能量上升落在片中 29 秒；51–59 秒取 Soft Geometry 尾段 | 依量到的 120 BPM 與相位對位 |
| 全部聲效 | `good` 改 C#5、G#5；`success` 改 F# 大調 | 配合音樂的調性 |

## 未達標

點按聲在 29–41 秒只高於音樂約 1 dB，目標是 6–8 dB。這段音樂已經到限幅上限，再加大點按聲也沒有空間。其餘中位數：按鍵聲 +7.5 dB，輕點聲 +8.6 dB。

## 待使用者親自確認

| 項目 | 狀態 |
|---|---|
| 聲音與音樂是否夾得來，尤其 29–41 秒的點按聲 | TBD |
| 連續播放的節奏 | TBD |
| 手機上的字幕 | TBD |
| Gemini 音樂的商用授權 | TBD，上載前要確認 |
| `ProductIntro` 去留 | TBD |
