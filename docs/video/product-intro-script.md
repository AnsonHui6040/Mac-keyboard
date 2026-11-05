# 產品介紹影片：分鏡與字幕

## 製作須知

| 項目 | 內容 |
|---|---|
| 目的 | 讓有 Mac 和 iPhone、不懂程式的一般使用者，看完知道這是什麼、能做什麼、到哪裡下載 |
| 版本 | v0.1.0 Alpha |
| 規格 | 1920×1080、30 fps、61 秒（1830 frames），Composition id：`ProductIntro` |
| 語言 | 字幕用台灣繁體中文，字級 60 |
| 內容依據 | `README.md`、`docs/manual/06`、`docs/manual/07`；內容有出入時，以手冊為準 |
| 聲音 | 沒有旁白，也沒有音樂，只有程式合成的動作聲效 |
| 風格 | 沿用安裝教學的深色舞台，整支片 Mac 和 iPhone 固定在同一個位置 |

### 內容規則

1. 只寫已實作的功能。不可宣稱零延遲、絕對安全、完全不漏字，也不可出現未量測的數字。
2. 密碼段落要同時講到「部分終端機與遠端桌面偵測不到」。
3. 要看得出這是 Alpha 版，透過 SideStore 安裝，不是 App Store 版本。
4. 字幕不用逗號，也不用 ` · ` 分隔字串。
5. 不可出現真實帳號、裝置名稱、UDID 或個人資料。不畫 Mac 選單列面板。
6. 先有手指動作，才有 Mac 上的結果：Mac 的文字比按鍵晚 2 frames 出現。

### 真實資料的來源

| 畫面 | 來源 |
|---|---|
| iPhone 鍵盤底圖 | `docs/manual/images/` 的真機截圖，頂部雜訊裁掉 |
| 按鍵按下的樣子 | 字母鍵變成功能鍵的深色，同 `iOS/RemoteKeyboardExtension/UI/KeyButton.swift` |
| 傳送鍵 | 草稿有字時藍底白字，空白時灰色，同 `TopAreaView.swift` |
| 草稿裡的換行 | 顯示為 ⏎，同 `TopAreaView.swift` |
| 手寫候選字 | `kb-handwriting.png`：香港、一香港、手香港、木香港 |
| 速成候選字 | `iOS/RemoteKeyboardExtension/Resources/quick-table.txt` 的順序；`eu` 第 14 個起正是 `kb-quickComposing.png` 的「淹淘港湘溉湄滬澆澠」 |
| 輸入碼 | 藍字在候選列最左邊，第一個候選字有淺色底，同手冊第 06 章與 `CandidateBarView.swift` |

## 場景

frame 是整支片的 frame。

| # | frames | 秒數 | 畫面 | 字幕 |
|---|---|---|---|---|
| 1 | 0–180 | 6 | 按 `shift`、Hello from my iPhone，文字逐字出現在「文字編輯」 | 用 iPhone 打字到 Mac |
| 2a | 180–330 | 5 | 換行，打 Each key is sent，逐字出現；再換行 | 即時模式每按一個鍵就送出 |
| 2b | 330–450 | 4 | 按「草稿」，打 Check before sending，只在鍵盤上出現，Mac 沒有變化 | 草稿模式先在鍵盤上編輯 |
| 2c | 450–540 | 3 | 按換行（草稿列出現 ⏎），按「傳送」，整句一次出現在 Mac | 按「傳送」才一次送出 |
| 3a | 540–720 | 6 | 按「中英」，手指寫「香港」，候選字出現，點選，傳送 | 中文可以用手寫 |
| 3b | 720–900 | 6 | 切到速成：竹、日，選「香」；水、山，滑動候選列，選「港」；傳送 | 也可以在 App 改用速成 |
| 4a | 900–955 | 1.8 | 按「觸控板」，鍵盤區變灰色觸控板，Mac 視窗縮小露出桌面 | 切換到觸控板 |
| 4b | 955–1025 | 2.3 | 一根手指滑動，Mac 游標跟著移動到檔案 | 一根手指移動游標 |
| 4c | 1025–1085 | 2 | 輕點一下，檔案被選取 | 輕點一下就是點按 |
| 4d | 1085–1170 | 2.8 | 按住不動再移動，檔案跟著游標走，放開手指落下 | 按住再移動就能拖曳 |
| 4e | 1170–1235 | 2.2 | 游標停在檔案上，兩指輕點，游標旁出現右鍵選單；再輕點一下關閉 | 兩指輕點就是右鍵 |
| 4f | 1235–1320 | 2.8 | 游標移到文件上，兩指向上滑，文件捲動 | 兩指滑動可以捲動 |
| 5a | 1320–1410 | 3 | 登入視窗。Mac 點密碼欄，鍵盤轉為紅字「密碼不能輸入」；手指按鍵，密碼欄維持空白 | 系統標示的密碼欄不會輸入文字 |
| 5b | 1410–1530 | 4 | 維持同一畫面 | 部分終端機與遠端桌面偵測不到（換行）請不要用這個鍵盤輸入密碼 |
| 6a | 1530–1680 | 5 | 打出 Remote Keyboard，再出現 Alpha 標示、兩個網址 | Alpha 版透過 SideStore 安裝 |
| 6b | 1680–1830 | 5 | 畫面停住 | 不是 App Store 版本 |

### 第 6 場的文字

| 項目 | 文字 |
|---|---|
| 產品名 | Remote Keyboard |
| 版本標示 | v0.1.0 Alpha |
| 下載 | github.com/AnsonHui6040/Mac-keyboard |
| 安裝教學 | youtu.be/dGhEuzRpAEg |

## 聲效

| 動作 | 聲音 |
|---|---|
| 字母與空白 | `key` |
| 功能鍵、候選字、切換模式、手指輕點、右鍵 | `tap` |
| Mac 上的點按、拖曳的拿起與放下 | `click` |
| 按「傳送」後文字到 Mac | `good` |
| 轉為「密碼不能輸入」 | `bad` |
| 產品名打完 | `success` |

聲效只在 `ProductIntro` 播放。安裝教學與各場景 composition 的聲音不變。

## 重新輸出

在 `video/` 執行。沒有字體時先跑 `scripts/setup-fonts.sh`。

```bash
npx kinetograph render src/index.tsx --comp ProductIntro -o out/renders/product-intro.mp4
```

截圖來自 `video/public/images`，這是指向 `docs/manual/images` 的 symlink。截圖更新後，鍵盤底圖會跟著變，要重新檢查 `src/intro/layout.ts` 的按鍵座標。
