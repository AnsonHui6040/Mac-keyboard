# 安裝教學動畫全片實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把第 16 場的做法抽成場景引擎，做完其餘 20 場，合成約 5 分 10 秒的完整無聲 MP4。

**Architecture:** 每場一份資料（`SceneSpec`），描述每拍的畫面、裝置、指向步驟與標示；`SceneRunner` 依資料畫出場景，驗證腳本也讀同一份資料。畫面元件只負責畫圖，按鈕座標都在 `geometry`。

**Tech Stack:** Kinetograph 0.3.0、Node 26、Noto Sans TC。

**Spec:** `docs/superpowers/specs/2026-11-04-install-tutorial-video-design.md`

## Global Constraints

- 子代理不得 commit 或 push；主代理重跑驗證後 commit。
- 使用者已指示全片做完才看，階段之間不停下。不上傳、不發布、不放進 Release。
- 全片無音軌，1920×1080、30fps。字幕只來自 `script.json`，不手寫。
- 文字用台灣繁體中文系統字串；不可出現「強制開啟」、「移至垃圾桶」、「私隱」、「軟件」、「全權取用」、廣東話字、` · `、真實帳號、真實裝置名、使用者路徑。截圖是香港繁體中文，只參考版面。
- 虛構內容：帳號 `your.name@example.com`，裝置「我的 iPhone」、「我的 Mac」，配對碼 `482915`，路徑 `~/Downloads`。SHA-256 與檔名不是虛構：用設計文件列的完整 64 碼，是 v0.1.0-b2 Release 頁面上的真實公開值。
- 不需操作的內文用灰色線條。不用霓虹、紫藍漸變、粒子、3D、抖動、製作備註、場景編號、裝飾性箭嘴。品牌圖示用向量近似，不嵌入原圖。
- 每拍字幕最多兩行、每行最多 30 字；顯示不短於 2.5 秒與「字數 ÷ 5」。
- `npm test` 要涵蓋全部場景資料；`node --test <資料夾>` 在 Node 26 不能用。

## Review Focus

1. 畫面操作和字幕講的不是同一件事：每拍的目標要對應該拍字幕，由 reviewer 對照 `docs/manual/01–05`。→ 各場景 Task
2. 裝置標籤和實際要操作的裝置不一致，尤其兩部同框的第 1、5、18、20 場。→ Task 1 測試、各場景 Task
3. 一拍多個點按時間不夠，點按被吃掉：`SceneSpec` 驗證要丟錯。→ Task 1
4. 畫面出現真實資料或香港字眼：grep 涵蓋 `video/src`。→ 各 Task
5. 手機橫看字太小：iPhone 畫面內可讀文字不小於 24 px。→ Task 2 起的主代理檢查

---

### Task 1：場景引擎與第 16 場遷移

**Files:**
- Create: `video/src/lib/sceneSpec.ts`、`video/src/lib/sceneSpec.test.ts`
- Create: `video/src/scenes/SceneRunner.tsx`、`video/src/screens/registry.tsx`
- Create: `video/src/components/IPhoneFrame.tsx`、`TapDot.tsx`
- Create: `video/src/data/scenes/index.ts`、`scene16.ts`
- Create: `video/scripts/verify-scenes.mjs`
- Modify: `video/src/screens/geometry.ts`、`video/src/index.tsx`
- Delete: `video/src/scenes/Scene16.tsx`、`video/src/data/scene16.ts`、`scene16.test.ts`、`video/scripts/verify-scene16.mjs`（內容移到新檔）

**Interfaces:**
```ts
type Device = 'mac' | 'iphone';
type Step = { target: string; press?: boolean };
type Label = { target: string; kind: 'good' | 'bad'; head?: string };
type BeatSpec = { screen: string; device?: Device; steps?: Step[]; labels?: Label[]; minSeconds?: number };
type SceneSpec = { n: number; beats: BeatSpec[]; };
function compileScene(spec: SceneSpec, caption: string, seconds: number, fps: number): CompiledScene;
// CompiledScene: { beats: string[]; timeline: Span[]; cues: PointerCue[]; deviceAt(frame): Device | undefined }
```
- `SCREENS` 的鍵改為 `string`；`registry.tsx` 匯出 `SCREEN_VIEWS: Record<string, (props: { active?: Device; frame: number; localFrame: number }) => ReactNode>`。
- `<SceneRunner spec={...} />` 依目前幀畫出裝置標籤、畫面、標示、指向、字幕。Mac 用 `MacCursor`，iPhone 用 `TapDot`；游標型態跟著該拍的 `device`。
- `Label.head` 預設 good 為「按這個」、bad 為「不要按」。
- `IPhoneFrame`：邏輯畫面 390×844，外框含動態島，畫面高度在畫布上不超過 800 px，整支不壓到 y=884。匯出把邏輯座標轉畫布座標的 `phoneRect`。

- [ ] **Step 1：寫失敗的測試（`sceneSpec.test.ts`）**

```ts
// 拍數要等於字幕拆出的拍數，否則丟錯，訊息含場次
assert.throws(() => compileScene({ n: 99, beats: [] }, '一句話。', 5, 30), /99/);
// 每個 step 的 target 要存在於該拍的 SCREENS[screen]
// 一拍多個 step：最小幀數 = 帶點按每步 41 幀、不帶點按每步 33 幀；放不下丟錯，不可吃掉點按
// 第一個指向由目標下方 120 px 移入；之後每步由目前位置移動；停點都用 restPoint
// 同一拍多個 step 在該拍內依序、平均分配；每個 press 都發生在該拍結束前
// deviceAt：回傳該拍 device；沒有 device 的場景回傳 undefined
// 第 16 場：compileScene 的 cues 與 timeline 和 V1 的結果相同（幀 261–269、401–409 點按）
// 全部已註冊場景：spec.n 不重複、都能 compile
```

- [ ] **Step 2：實作，遷移第 16 場，確認 `verify-scenes.mjs 16` 通過與 V1 相同的 35 項**

`verify-scenes.mjs [場次...]`：對每場每拍的最後第 5 幀，用 `kinetograph inspect --comp Scene<NN>` 檢查最後一個 step 的指標落在 `btn-<target>` 內、標示線中心 y 等於目標中心 y。不帶參數就跑全部已註冊場景。

- [ ] **Step 3：驗證**

Run: `cd video && npm test && npx kinetograph check src/index.tsx && node scripts/verify-scenes.mjs 16`
Expected: 全部通過。再把第 16 場一個 target 暫時改錯，Expected: 失敗；改回。

- [ ] **Step 4：Commit（主代理）**

`refactor(video): drive scenes from data with a shared runner`

---

### Task 2：第 1–9 場

**Files:** `video/src/data/scenes/scene01.ts`…`scene09.ts`、`video/src/screens/` 新畫面、`geometry.ts`、`registry.tsx`、`index.tsx`（註冊 `Scene01`…`Scene09`）

**Interfaces:** Consumes Task 1。每個可操作的元素有 `btn-<target>`。

- [ ] **Step 1：查字串**：讀 iOS 模擬器 runtime 的 `zh_TW.lproj`（`xcrun simctl list runtimes -j` 找 runtimeRoot）確認「信任這部電腦？」、「信任」、「允許並重新啟動」。App 自身字串看 `iOS/` 原始碼。查不到照手冊，列入報告。

- [ ] **Step 2：實作各場**（版面參考 `docs/manual/images/`，內容以腳本「操作重點」與手冊為準）

| 場 | 裝置 | 畫面 | 指向重點 |
|---|---|---|---|
| 1 | 兩部 | iPhone 鍵盤打字，文字逐字出現在 Mac 文字編輯 | 無；用 `localFrame` 逐字顯示 |
| 2 | 無 | 準備清單 5 項逐項出現 | 無 |
| 3 | 無 | 鎖頭圖示，兩條提醒逐條出現 | 無 |
| 4 | iPhone | App Store 的 LocalDevVPN → App 內連線 → 「允許」→ 已連線 | 連線、允許 |
| 5 | Mac 與 iPhone | USB 線連接 → iPhone「信任」→ iloader 的 Add Account + → Stable SideStore | 信任、Add Account +、Stable SideStore |
| 6 | iPhone | 設定 > 一般 > VPN與裝置管理 > 信任 > 允許並重新啟動；隱私權與安全性 > 開發者模式 | 依序點按 |
| 7 | iPhone | LocalDevVPN 已連線 → SideStore 登入 | 登入 |
| 8 | iPhone | My Apps，SideStore 的 7 DAYS；詢問時 Refresh Now | 7 DAYS、Refresh Now |
| 9 | iPhone | 錯誤 -80045 提示，加「手冊第 02 章」文字 | 無 |

- [ ] **Step 3：每場 strip**

Run: `cd video && npm test && npx kinetograph check src/index.tsx && node scripts/verify-scenes.mjs 1 2 3 4 5 6 7 8 9`，每場 `lint`、`strip -n 8`。子代理親自開圖看。把 strip 路徑列在報告。

時間放不下時：可以提高腳本該場秒數並重新產生 `script.json`，幅度不超過 3 秒，並在報告列出。不可降低閱讀時間。

- [ ] **Step 4：Commit（主代理親自看 strip 後）**

`feat(video): add scenes 1 to 9`

---

### Task 3：第 10–15 場

規則同 Task 2。

| 場 | 裝置 | 畫面 | 指向與標示 |
|---|---|---|---|
| 10 | Mac 再到 iPhone | Release 頁下載 → 終端機 `shasum -a 256` 輸出與 Release 值對照（完整 64 碼）→ AirDrop → 存到「檔案」 | 下載項、存到檔案 |
| 11 | iPhone | My Apps「+」→ 檔案選擇 → App Contains Extensions 五個按鈕 | `+`；標示：good 第二個，bad Remove App Extensions |
| 12 | iPhone | 設定 > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤 > 第三方鍵盤 > Remote Keyboard > 回清單按該列 | 依序點按 |
| 13 | iPhone | 允許完整取用開關 → 警告 → 允許 | 開關、允許 |
| 14 | iPhone | 四頁引導 → 設定進度 > 藍牙 > 允許藍牙 > 允許 | 依序點按 |
| 15 | Mac | Release 下載 zip → 連按兩下解壓縮 → 拖到「應用程式」 | 游標拖曳：多個 step，無點按時用移動表現 |

第 11 場停留規則同第 16 場：兩個標示同時停留至少 3 秒。第二個按鈕文字用較小字級（實際畫面如此），Remove 用紅字。

Run: `node scripts/verify-scenes.mjs 10 11 12 13 14 15`，加 `npm test`、`check`、`lint`、`strip`。

Commit：`feat(video): add scenes 10 to 15`

---

### Task 4：第 17–21 場

| 場 | 裝置 | 畫面 | 指向 |
|---|---|---|---|
| 17 | Mac | 藍牙允許提示 → 選單列鍵盤圖示 → 面板「授權輔助使用」→ 輔助使用清單開啟 Remote Keyboard Receiver | 允許、圖示、授權、開關 |
| 18 | 兩部（左 Mac 右 iPhone） | 配對新 iPhone → 已配對 Mac → 配對 Mac → 兩邊 482915 → Mac 確認 → iPhone 確認 | 依序；切換時標籤與亮度跟著變 |
| 19 | 兩部 | 兩邊已儲存，先 Mac 再 iPhone 完成 | 完成 |
| 20 | 兩部 | Mac 文字編輯點一下 → iPhone 地球鍵選 Remote Keyboard → 遠端 → 綠色已連接 → 打字出現在 Mac | 文件、地球鍵、遠端 |
| 21 | 無 | 日曆標示 7 天，手冊連結文字 | 無 |

面板文字用「目前欄位：文字編輯（可輸入）」。不可出現 Claude2。

Run: `node scripts/verify-scenes.mjs 17 18 19 20 21`，加 `npm test`、`check`、`lint`、`strip`。

Commit：`feat(video): add scenes 17 to 21`

---

### Task 5：全片合成與驗收

**Files:** Modify `video/src/index.tsx`（`Main`）、`docs/superpowers/verification/2026-11-04-install-tutorial-video.md`

**Interfaces:** `Main` 用 `Series` 依序播 21 場，總幀數等於 `script.json` 秒數總和 × 30；場與場之間無額外幀，由各場開頭 8 幀淡入。

- [ ] **Step 1：驗證**

Run: `cd video && npm test && npx kinetograph check src/index.tsx && npx kinetograph lint src/index.tsx --comp Main --frames <每場中間一幀> && npx kinetograph doctor src/index.tsx --comp Main && node scripts/verify-scenes.mjs && npx kinetograph render src/index.tsx --comp Main --concurrency 4 && ffprobe out/renders/Main.mp4`
Expected: 全部通過；MP4 無音軌、1920×1080、30fps；長度等於腳本秒數總和。

- [ ] **Step 2：抽查 render 結果**

對 MP4 用 `ffmpeg` 抽第 11、16 場標示停留的幀，確認與 still 一致。

- [ ] **Step 3：更新驗收報告**：逐場列自動驗證結果；未對過實機的畫面、查不到的字串逐項列；使用者項目標 TBD。

- [ ] **Step 4：Commit，開 PR**

`feat(video): assemble the full install tutorial`
