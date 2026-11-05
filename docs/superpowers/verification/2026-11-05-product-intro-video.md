# 產品介紹影片 驗收報告

日期：2026-11-05
範圍：`ProductIntro` composition，61 秒、1830 幀、1920×1080、30 fps。
分支：`product-intro-video`。成品：`video/out/renders/product-intro.mp4`（`out/` 已列入 `.gitignore`，不提交）。
分鏡：`docs/video/product-intro-script.md`。

## 一、自動驗證（已完成）

| 項目 | 指令 | 結果 |
|---|---|---|
| 單元測試 | `npm test` | 176 項，176 通過，0 失敗 |
| 型別 | `kinetograph check src/index.tsx` | no type errors |
| Lint | `kinetograph lint src/index.tsx --comp ProductIntro`，28 個 frame | 0 errors，1 warning |
| 不支援內容 | `kinetograph doctor src/index.tsx --comp ProductIntro` | 1830 幀全部 clean |
| 影片規格 | `ffprobe` | H.264、1920×1080、30/1、1830 幀、61.000 秒 |
| 音軌規格 | `ffprobe` | 一條 AAC，61.000 秒 |
| 音量 | `kinetograph audio analyze` | -19.4 LUFS、true peak -3.5 dBTP、clipped samples 0 |

Lint 的 warning 在第 1210 幀：右鍵選單的文字框和資料夾標籤重疊。選單是不透明面板，畫面上標籤被蓋住，和 macOS 的行為相同，因此保留。

### 聲音對位

從 MP4 解出音訊，量到的聲音起點與 `src/intro/sounds.ts` 的事件一致。例如按鍵 14、20、26；輕點 1030、1085、1206；Mac 點按 1358；密碼提示 1362；產品名打完 1606。手指移動、手寫筆劃與捲動沒有聲音。

### 現有影片沒有改變

和 `main` 的乾淨版本比對。

| 項目 | 比對的內容 | 結果 |
|---|---|---|
| 畫面 | Main 第 1500、7100 幀；Scene01 第 150 幀；Scene16 第 300 幀；Scene20 第 400 幀；Scene21 第 100 幀 | 逐位元相同 |
| 聲音 | Main、Scene16 的 `audio analyze` 輸出 | 完全相同 |

## 二、畫面檢查（已完成）

修正前後各從 MP4 抽幀（48 幀與 29 幀），逐張檢查文字、裁切與個人資料，涵蓋全部 16 段字幕。

| 檢查項目 | 結果 |
|---|---|
| 字幕與分鏡一字不差 | 符合 |
| 文字沒有被裁切或重疊（捲動時視窗內的文字除外） | 符合 |
| 按鍵疊加和截圖對齊 | 符合 |
| 先有手指動作，才有 Mac 上的結果 | 符合 |
| 真實帳號、裝置名稱、UDID、個人資料、「Claude2」 | 沒有出現；GitHub 網址是指定要放的 |
| 第 5 場的帳號欄 | 灰色線條，沒有文字 |
| 霓虹、紫藍漸變、粒子、三欄卡片、箭頭、` · ` | 沒有出現 |

## 三、待使用者確認

| 項目 | 狀態 |
|---|---|
| 聲效好不好聽、音量是否合適 | TBD，只量過數值，沒有人聽過 |
| 字幕在手機上是否看得清楚 | TBD，字級 60，沒有在手機上看過 |
| 整體節奏 | TBD，只看過單幀，沒有人連續看過 |

## 四、已知限制

| 項目 | 說明 |
|---|---|
| 色偏 | 深色區域經 H.264 8-bit 編碼後，和原色差 2 到 4 階，略為偏青。安裝教學也一樣 |
| 響度 | -19.4 LUFS，低於線上影片常見的 -14 LUFS。只有短促聲效，沒有持續聲音 |
| 手寫筆劃 | 依 `kb-handwriting.png` 重新描繪的向量線條，不是原圖像素 |
| 速成候選字 | 依手冊與 `CandidateBarView.swift` 顯示輸入碼與第一個候選字底色；捲動後的排列和 `kb-quickComposing.png` 相同 |
