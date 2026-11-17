# v0.2 宣傳片：驗收（第一階段，尚無音樂）

日期：2026-11-18
Composition：`PromoFilm`，程式在 `video/src/promo/`，分鏡在 `docs/video/promo-v0.2-storyboard.md`，YouTube 資料在 `docs/video/promo-v0.2-youtube.md`，字幕在 `docs/video/promo-v0.2.srt`。
成品不提交：`video/out/renders/promo-v0.2.mp4`。

目前是第一階段：畫面、旁白、音效完成，音樂是空的（`PROMO_MUSIC` 為空陣列），等使用者從 YouTube 音效庫選檔後進第二階段（Task 7）。所以下面的響度只是參考，不算 PASS。

## 重新輸出

```bash
cd video
bash scripts/render-promo.sh
```

腳本先確認十個旁白檔與 `PROMO_MUSIC` 列出的音樂檔都存在（缺檔就報錯並列出檔名），輸出 `promo-v0.2-raw.mp4`，再做增益與限幅，視訊串流不重新編碼。`FRAMES` 由 `src/promo/timeline.ts` 讀取。

## 自動驗證

| 項目 | 結果 |
|---|---|
| `npm test` | 327 項全部通過（原 322 項，新增 `mix.test.ts` 5 項） |
| `mix.test.ts` 先紅後綠 | 先寫測試，`mix.ts` 與 `music.ts` 不存在時整檔失敗；實作後第一次跑 4 通過 1 失敗（`musicGainDb` 在旁白外回傳 -0，`assert.equal(-0, 0)` 不成立），改成加 0 後 5 項全過 |
| `kinetograph check` | 沒有型別錯誤 |
| `kinetograph doctor --comp PromoFilm` | 1938 幀全部可完整繪製 |
| `kinetograph lint`（0 到 1935 每 15 幀，加第 1937 幀，共 131 幀） | 0 個 error，1861 個 warning：`text-overlap` 1628、`off-canvas` 227、`text-overflow-canvas` 6 |
| `ffprobe`（成品） | 視訊 H.264、1920×1080、30 fps、1938 幀；音訊 AAC、48 kHz；64.600 秒；40,348,757 位元組 |
| 響度（`render-promo.sh` 的 `ebur128`，成品） | -14.1 LUFS，true peak -1.4 dBTP，限幅一輪收斂；母帶前 -17.9 LUFS、-0.9 dBTP |
| `kinetograph audio analyze --comp PromoFilm`（母帶前） | -17.9 LUFS，true peak -0.9 dBTP，沒有削波樣本；無聲段 11 處（旁白與音效之間的空檔，沒有音樂） |
| 舊片不變 | `old-films-fingerprint.sh` 在加入 `./promo/register.ts` 之後輸出的 `fingerprint.txt`（`ProductFilm` 9 幀、`ProductIntro` 3 幀、`Main` 2 幀的 sha256，三部片的 `audio analyze` 雜湊）與 main 的基準 `diff` 結果為空 |
| 內容檢查 | `mix.test.ts` 掃 `src/promo/*.ts(x)`，沒有任何廣東話專用字；標題、字卡、旁白與字幕不含禁用字（逗號除外，旁白可用） |
| 文件檢查 | 三份文件 `grep -E '[nN]\s*=\s*\d'` 為 0，廣東話專用字的字元類 grep 也是 0 |

### 混音設計

| 項目 | 設定 |
|---|---|
| 旁白 | 十個 mp3 依 `VOICE` 的幀放入，未改動 |
| 音效 | 沿用 `film/sounds.ts`；每個事件乘上 `10 ** (sfxGainDb(frame) / 20)`，旁白時壓低 6 dB，前後 0.25 秒（8 幀）線性漸變；換電腦的點一下用輕點聲 |
| 音樂 | `musicGainDb` 旁白時 -10 dB，同樣的漸變；`PROMO_MUSIC` 空，沒有聲音，第二階段只需填資料 |
| 只在整片長度的音訊 context 播音效 | `isPromoContext`：長度等於 64.6 秒（容許 1 個 sample）；舊片的長度（`ProductFilm`、`ProductIntro`、`Main`）測試確認不會觸發。`--range` 輸出沒有音效，與 `ProductFilm` 相同 |

## 親自看過的畫面

控制者另外看第 60、300、440、700、830、1050、1160、1400、1650、1760、1900 幀（`.superpowers/sdd/2026-11-18-promo-film-v0.2/stills-t6/`）。第一階段我自己看了第 60、830、1050、1650、1900 幀：字卡文字、位置、免責聲明正常，沒有 Windows、Ubuntu 或 Apple 的標誌，標題沒有被切到，沒有廣東話用字。

## 使用者看過才算 PASS（TBD）

| 項目 | 狀態 |
|---|---|
| 整片節奏與切換是否看得懂 | TBD |
| 旁白的發音與語氣（iPhone、Mac、Windows、Linux、SideStore、Remote Keyboard、零點二、速成） | TBD |
| 音效與旁白的混音（Claude 聽不到聲音，只能報數字） | TBD |
| 音樂 | TBD，第二階段；選檔後要重新對拍、混音、量響度（旁白比音樂高至少 12 dB） |
| 母帶響度 -14 LUFS ± 0.4（含音樂） | TBD，目前沒有音樂，只是參考 |
| YouTube 說明欄的安裝教學連結 | TBD，v0.2 教學上傳後換掉 |

## 與設計的差異

| 項目 | 做法 | 原因 |
|---|---|---|
| 旁白與音效的混音量測 | 第二階段做 | 沒有音樂時沒有可比的對象 |
