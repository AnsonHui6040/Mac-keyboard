# ProductFilm 實作計畫

依據：`docs/video/product-film-storyboard.md`（已批准，內容不可改）。驗收結果：`docs/superpowers/verification/2026-11-06-product-film-video.md`。

新 composition `ProductFilm`：1920×1080、30 fps、1800 frames。程式全部放 `video/src/film/`。`ProductIntro`、`Main`、`Scene01–21` 的畫面與聲音不可改變。

## 架構

| 檔案 | 責任 | 純邏輯 |
|---|---|---|
| `timeline.ts` | `FPS`、`FRAMES`、鏡頭表（frame 由分鏡秒數 ×30）、標題表 | 是 |
| `events.ts` | 唯一的動作表：每次按鍵、滑動、點按的 frame、鍵名、聲音、效果。畫面、聲音、測試都由它推導 | 是 |
| `state.ts` | `phoneAt(f)`、`macAt(f)`：由事件表算出兩台裝置當幀的完整狀態 | 是 |
| `trackpad.ts` | 第 21 鏡的手指路徑，游標 = 起點 + GAIN × 手指位移，晚一幀 | 是 |
| `project.ts` | `project`、`planeCorners`、裝置世界座標 | 是 |
| `music.ts` | 音樂段落表、`musicGain(f)` | 是 |
| `sounds.ts` | 改調的 `good`、`bad`、`success`，加大音量的 `key`、`tap`、`click` | 否 |
| `register.ts` | `onFrame` 註冊，只在長度等於 60 秒（±1 sample）的 context 播放 | 否 |
| `PhoneScreen.tsx` | 手機畫面（720 寬座標），即時繪製，特寫與 3D 共用 | 否 |
| `MacScreen.tsx` | Mac 畫面（1280×800 座標），即時繪製，特寫與 3D 共用 | 否 |
| `Slab.tsx` | 斜角特寫：透視、六層景深、光區， | 否 |
| `Devices.tsx` | 3D 機身、倒影、燈光、`PinnedScreen` | 否 |
| `Headline.tsx` | 標題：去模糊並上升 22 幀後靜止，固定在畫面空間 | 否 |
| `shots.tsx` | 每一鏡的相機參數與內容 | 否 |
| `Film.tsx` | 依 frame 選鏡頭，全部硬切，加細顆粒 | 否 |

`video/src/index.tsx` 只加兩行：`import './film/register.ts'`、一個 `<Composition id="ProductFilm">`，再加 import 元件那一行。

## 鏡頭做法

全片共用同一份 `PhoneScreen` 與 `MacScreen`，相機只決定怎麼看，文件因此一路長大。

**特寫（第 2–20、22–28 鏡）**：用 `Slab`。基準取測試片：手機 `mag 2.5 pitch 40 roll -9 yaw 7 persp 1300 focusH 48`；Mac `mag 2.25 pitch 34 roll 7 yaw -5 persp 1350 focusH 42`。中特寫 mag 約 1.5、pitch 約 24；極特寫 mag 約 3.2。相鄰鏡頭斜向交替（手機 roll 負、Mac roll 正），鏡頭每幀等速漂移，不停。Slab 的 children 會畫六次，`TapDot` 這類有 id 的圓環放 `overlay`，只畫一次。

**真 3D（第 1、21、30 鏡）**：`Scene3D` 畫機身、倒影、地板；螢幕是 2D 圖層，用 `PinnedScreen` 貼到投影四角：

```tsx
<Layer layout={{ width: w, height: h }} effects={[cornerPin(planeCorners(cam, planeW, planeH, chain))]}>
  {/* 子圖層都要 layoutItem={{ position: 'absolute' }} */}
</Layer>
```

圖層在 warp 前會被畫布裁切，box 不可超出畫布。Mac box 1280×800。手機 box 498×1076，內容以 0.69 縮放（498/720），鍵盤貼底。第 21 鏡的相機與擺位，要用測試算到符合分鏡的同框規格（Mac 螢幕 x 120–1200、y 230–900；手機機身 x 1400–1860、底緣 y 約 1040，上半用畫面空間的漸層沉入黑）。允差 ±25 px。第 21 鏡相機全程等速，推近至多 3%、橫移至多 30 px、偏轉至多 1.5°。

第 1 鏡手機 yaw 由 -68 到 -24（`settle`），Mac 是另一個帶 `blur` 的遠處亮塊。第 30 鏡是全片唯一後拉。倒影亮度壓到 15% 以下並模糊。手機邊框不可過曝。

## 手機畫面

完全用 `intro/layout.ts` 量好的按鍵矩形即時重畫，不用截圖當底，這樣特寫才銳利。重畫結果要和 `public/images/kb-*.png` 同尺寸並排核對。狀態：`connected`、`draft`、`handwriting`、`quick`、`blocked`、`trackpad`。按鍵上方是空白深色區，不放任何裝置名稱或個人資料。

可 import 重用：`intro/layout.ts`、`intro/ink.ts` 的筆跡（時間要照本片重排，不可動 intro 的時間）、`components/TapDot.tsx`。`intro/` 內既有檔案不可修改。

## 動作時間表

分鏡的秒數是準則。下列是必須成立的因果（全部要有測試）：

| 動作 | 結果 |
|---|---|
| 按鍵 frame k | Mac 上的字在 k+2 出現，畫面與聲音來自同一筆事件 |
| 第 2–7 鏡打字 | shift、h、e、l、l、o、空白、from my iPhone 依序，Mac 打完 `Hello from my iPhone` |
| 第 8 鏡 | 換行，草稿 |
| 第 9–12 鏡 | 草稿 `Chek before sending`，Mac 沒有變化；圓環點 e 和 k 之間，游標移過去，按 c，變 `Check before sending`；按換行顯示 ⏎，按傳送 |
| 第 13 鏡 | 第二行整句同一幀落地，播 `good` |
| 第 14–17 鏡 | 中英，手寫香港，候選列寫完才出現：香港、一香港、手香港、木香港；點香港，換行，傳送；第三行香港 |
| 第 18–19 鏡 | 藍字竹日，候選白昏徇香舶筍箔箸稽；點香；藍字水山，向左滑到淹淘港湘溉湄滬澆澠；點港；傳送；第四行香港 |
| 第 20 鏡 | 按觸控板，鍵盤區變灰 |
| 第 21 鏡 | 依分鏡 21a–21f：移到檔案「行程」；輕點選取；按住 0.4 秒（12 幀）圓環變實心再拖進資料夾「香港」，放開落下；兩指輕點出右鍵選單；一指移到「打開」輕點，資料夾視窗由資料夾位置展開；兩指上滑，清單 1:1 捲動，沒有慣性；切點落在滑動中 |
| 第 22–27 鏡 | 硬切登入視窗，點密碼欄，外框；手機綠字轉紅「密碼不能輸入」；按鍵兩次，密碼欄都空白；Mac 無聲 |
| 第 28 鏡 | 視窗標題「遠端桌面」，內部密碼欄 ●●●● 逐個出現，第 4 顆即切 |
| 第 30 鏡 | Mac 空白文件逐字 `Remote Keyboard`，打完播 `success` |

輸入碼是字根「竹日」「水山」，不是英文字母。候選順序要由測試讀 `iOS/RemoteKeyboardExtension/Resources/quick-table.txt` 核對（`intro/timeline.test.ts` 有類似做法）。

## 標題

照分鏡的秒數與文字，字級至少 76，`Headline` 固定在畫面空間，白色 `#f5f5f7`，weight 700。擺在畫面黑區，不可蓋住焦點內容，也不可隨 3D 變形。第 29 鏡全黑置中，第 31 鏡依字卡表，靠左，硬切出現，不用動畫。

`Text` 沒有 `letterSpacing`；`Scene3D` 在 TSX 沒有 `fog`。

## 音樂

檔案未確認授權，已列入 `.gitignore`，不可提交。放在 `public/audio/`。用 `<Sequence from>` 內的 `<Audio trimBefore>`，每段頭尾 1 幀淡入淡出，防爆音。

| 片中秒數 | 來源 | 映射 | 用意 |
|---|---|---|---|
| 7.0–12.2 | Clean Geometry | s = t − 6.942 | 低能量段開頭，12.2 硬切 |
| 16.0–41.0 | Clean Geometry | s = t − 12.942 | 連續一段，來源 16.058 的能量上升正好落在片中 29.0，41 硬停 |
| 51.0–59.0 | Soft Geometry | s = t + 4 | 只用尾段，59 秒前到 0 |

`musicGain(f)`：手寫段（18.1–21.7 秒）壓到約 0.5 倍（`Audio` 沒有濾波，只降音量）；29–41 秒每次點按時壓低 2–3 dB，6 幀回復；來源峰值 +0.5 dB，整體要壓低。其餘時間完全靜音。

## 聲效與混音

`sounds.ts` 可 import `intro`、`audio/synth.ts` 的 `mixer`、`tap`、`key`、`click` 或自寫同形函式，不可修改 `synth.ts`。Clean Geometry 的音階是 C# 大調／A# 小調；Soft Geometry 是 F# 大調。

| 聲音 | 改法 |
|---|---|
| `good` | C#5 後接 G#5（原為 D5、A5） |
| `success` | 用 F# 大調和弦（原為 D 大調） |
| `bad` | 在靜音段，音高不變 |
| `key`、`tap`、`click` | 不改音色，音量加大，按鍵峰值高於同時段音樂 6–8 dB |

目標：全片約 -14 LUFS，true peak ≤ -1 dB，`clippedSamples` 為 0。

`register.ts` 的播放條件是 context 長度等於 60 秒（±1 sample）。要先查 `SCENES` 與其他 composition 沒有剛好 1800 frames 的；有的話回報，不要自行改別的 composition。

## 測試（`video/src/film/*.test.ts`，TDD，先 RED 再 GREEN）

1. 鏡頭表連續，涵蓋 0–1800，順序與分鏡一致。
2. 標題每秒不超過 7 字，字級至少 76；所有文字不含逗號、`·`、箭頭、`Claude`、`零延遲`、`絕對`。
3. 上表每一條因果，用 `macAt`、`phoneAt` 在前後 frame 比較。
4. 草稿送出前 Mac 第二行沒有字；密碼欄在第 24–27 鏡一直空白；第 28 鏡圓點數隨事件增加。
5. 候選字順序與 `quick-table.txt` 相符。
6. `project`：已知相機的解析案例；第 21 鏡投影符合同框規格；相機運動符合上限。
7. 游標位移 = GAIN × 手指位移，晚一幀；拖曳在按住滿 12 幀後才開始；捲動 1:1，手指停則捲動停。
8. `musicGain`：靜音段為 0，段落邊界正確，音樂映射在 29.0 秒對應來源 16.058。

## 驗收

```bash
cd video
npm test
npx kinetograph check src/index.tsx
npx kinetograph lint src/index.tsx --comp ProductFilm
npx kinetograph doctor src/index.tsx --comp ProductFilm
scripts/render-film.sh
npx kinetograph audio analyze src/index.tsx --comp ProductFilm
ffprobe out/renders/product-film.mp4
```

Lint 的 `text-overflow-canvas` 來自特寫放大，逐項分辨：真的切到要讀的字就要修；只是景深層超出畫布的，列出來說明。第 21、30 鏡的對齊用洋紅平面墊在螢幕下方檢查。

每鏡至少抽一幀親自看，第 21 鏡每個小段都要看，縮到 390 寬核對標題與圓環看得清楚。舊片比對：`Main`、`ProductIntro`、`Scene16` 的抽樣畫面與 `audio analyze` 要和 main 相同。

## 成品乾淨

不用霓虹、紫藍漸變、大量粒子、三欄卡片、Apple 標誌。不畫終端機畫面。不可出現真實帳號、裝置名稱、UDID。台灣繁體中文。
