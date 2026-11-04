# 安裝教學動畫 V1 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 `video/` 專案，並做出第 16 場完整的無聲動畫（26 秒 MP4），驗證視覺系統、字幕與指向流程。

**Architecture:** 字幕與指向由純函式產生時間軸，畫面元件只依幀數畫圖。字幕文字由腳本表格產生 `script.json`，不手寫第二份。按鈕座標集中在一個檔案，畫面、標示與驗收都讀同一份。

**Tech Stack:** Kinetograph 0.3.0（TSX，`@kinetographdev/core`）、Node 26（`node --test`，原生執行 `.ts`）、Noto Sans TC。

**Spec:** `docs/superpowers/specs/2026-11-04-install-tutorial-video-design.md`

## Global Constraints

- 子代理不得 commit 或 push；commit 步驟由主代理重跑驗證後執行。
- 一個 worktree、一條 branch（`video-v1`）、一個 PR。腳本與設計文件目前未追蹤，隨 Task 1 一起 commit。
- 1920×1080、30fps、無音軌。`kinetograph` 固定 `0.3.0`。
- 不入 git：`video/node_modules`、`video/out`、`video/public/fonts`。
- 畫面文字用台灣繁體中文系統字串，不可出現「強制開啟」、「移至垃圾桶」、「私隱」、「軟件」、廣東話字、` · `、真實帳號或裝置名。
- 不可有紫藍漸變、霓虹、粒子、3D、抖動、製作備註或場景編號。
- 每拍字幕最多兩行、每行最多 30 字；顯示時間不短於 2.5 秒與「字數 ÷ 5」。
- 全部動畫是幀數的純函式，不讀真實時間。
- 文字元件要包在 `<Layer>` 內，否則 `Text` 會佔版面流，把後面的元素往下推（樣板踩過）。
- 陰影顏色用含透明度的色碼，`dropShadow` 沒有 `opacity` 欄位。

## Review Focus

1. 腳本改了但 `script.json` 沒重新產生：字幕和腳本不一致時，`gen-script-data.mjs --check` 要失敗。→ Task 1
2. 指向或標示指錯按鈕，包括換畫面的那一拍：指向停留點要落在當前畫面的目標內。→ Task 2、Task 4
3. 字幕含長英文（Remote Keyboard Receiver.app、Touch ID）時排版溢出：`kinetograph lint` 全部拍都不可有 overflow。→ Task 4
4. 動畫裡字幕放不下：時間不足時 `beatTimeline` 要丟錯，不可默默壓縮閱讀時間。→ Task 2
5. 手機橫看字太小：把 still 縮到 844 寬，主代理親自看字幕與按鈕文字是否可讀。→ Task 4

---

### Task 1：專案骨架與字幕資料

**Files:**
- Create: `video/package.json`、`video/tsconfig.json`、`video/.gitignore`
- Create: `video/scripts/setup-fonts.sh`、`video/scripts/gen-script-data.mjs`、`video/scripts/gen-script-data.test.mjs`
- Create: `video/src/data/script.json`（產生物，要 commit）
- Add: `docs/video/install-tutorial-script.md`、設計文件、本計畫

**Interfaces:**
- Produces: `script.json` 為 `{ scenes: { n: number, seconds: number, focus: string, caption: string }[] }`，共 21 筆；`parseScript(md: string)` 由 `gen-script-data.mjs` 匯出。

- [ ] **Step 1：寫失敗的測試**

`gen-script-data.test.mjs` 讀真正的腳本，斷言：
```js
const { scenes } = parseScript(md);
assert.equal(scenes.length, 21);
assert.equal(scenes.reduce((a, s) => a + s.seconds, 0), 310);
assert.equal(scenes[15].n, 16);
assert.equal(scenes[15].seconds, 26);
assert.ok(scenes[15].caption.startsWith('這個版本沒有經過 Apple 公證'));
assert.ok(scenes[15].caption.includes('丟到垃圾桶'));
```
另一個測試：呼叫 `parseScript` 傳入缺欄位的列要丟錯，訊息含場次編號。

- [ ] **Step 2：執行確認失敗**

Run: `cd video && node --test scripts/`
Expected: FAIL，找不到 `parseScript`。

- [ ] **Step 3：實作**

`package.json`：`kinetograph` 固定 `0.3.0`、dev 依賴 `@types/react`；scripts：`test`（`node --test scripts/ src/`）、`data`、`check`（`kinetograph check src/index.tsx`）。

`gen-script-data.mjs`：解析 `## 場景` 下的表格；欄位 `#`、`秒數`、`畫面`、`操作重點`、`字幕`；寫入 `src/data/script.json`。加 `--check`：產生結果與現有檔案不同就 exit 1，並印出差異的場次。

`setup-fonts.sh`：從 `~/Library/Fonts` 複製 `NotoSansTC-Regular.ttf`、`-Medium.ttf`、`-Bold.ttf` 到 `public/fonts/`；任何一個不存在就印出缺少的檔名並 exit 1。

- [ ] **Step 4：執行確認通過**

Run: `cd video && npm install && bash scripts/setup-fonts.sh && node scripts/gen-script-data.mjs && node scripts/gen-script-data.mjs --check && node --test scripts/`
Expected: 全部 PASS；`--check` exit 0。

- [ ] **Step 5：驗證 `--check` 真的會抓到差異**

暫時改 `script.json` 一個字，Run `--check`，Expected: exit 1 並印出該場次；改回。

- [ ] **Step 6：Commit（主代理）**

`feat(video): scaffold project and generate subtitle data from the script`

---

### Task 2：字幕與指向時間軸

**Files:**
- Create: `video/src/lib/captions.ts`、`video/src/lib/captions.test.ts`
- Create: `video/src/lib/pointer.ts`、`video/src/lib/pointer.test.ts`

**Interfaces:**
- Consumes: `script.json`
- Produces:
  - `displayLength(s: string): number`：全形字與中文算 1，半形算 0.5
  - `splitBeats(text: string, maxChars = 30): string[]`：先按「。！？」分句；超過 `maxChars` 的句子在「，；」處貪婪合併拆開
  - `wrapBeat(beat: string, maxChars = 30): string[]`：回傳行；超過兩行就丟錯
  - `minBeatFrames(beat: string, fps: number): number`：`ceil(max(2.5, displayLength / 5) * fps)`
  - `beatTimeline(beats: string[], minSeconds: (number | undefined)[], totalFrames: number, fps: number): { from: number; to: number }[]`
  - `pointerAt(frame: number, cues: PointerCue[], fps: number): PointerState`，其中 `PointerCue = { from: number; x: number; y: number; press: boolean }`，`PointerState = { x: number; y: number; visible: boolean; press: number }`（`press` 為 0 到 1）

- [ ] **Step 1：寫失敗的測試**

```ts
assert.deepEqual(splitBeats(scene16.caption), [
  '這個版本沒有經過 Apple 公證，第一次打開會被擋下，',
  '這是正常的。',
  '先按「完成」，到系統設定的「隱私權與安全性」，',
  '捲到最下方按「強制打開」。',
  '系統再問一次時，要按中間的「強制打開」。',
  '藍色那顆是丟到垃圾桶，不要按。',
  '最後用 Touch ID 或密碼確認。',
]);
assert.equal(splitBeats(scene16.caption).join(''), scene16.caption);
assert.equal(minBeatFrames('這是正常的。', 30), 75);
```
`beatTimeline`：區間首尾相接，第一段 `from` 為 0，最後一段 `to` 等於 `totalFrames`；每段不短於 `minBeatFrames` 與 `minSeconds`；放不下時 `assert.throws`，訊息含所需與實際幀數。全部 21 場的字幕用腳本秒數跑一次，都不可丟錯（這是 V2 之後的前提）。

`pointerAt`（30fps）：第一個 cue 之前 `visible` 為 false；`from` 後 18 幀（0.6 秒）抵達目標；抵達後 15 幀（0.5 秒）內 `press` 為 0；`press: true` 時接著 8 幀內 `press` 升到 1 再回 0；`press: false` 時恆為 0；下一個 cue 由當時位置開始移動。

- [ ] **Step 2：執行確認失敗**

Run: `cd video && node --test src/lib/`
Expected: FAIL，模組不存在。

- [ ] **Step 3：實作 `captions.ts`、`pointer.ts`**

不可 import `@kinetographdev/core`，保持純函式。`beatTimeline` 先給每段最小值，剩餘幀數按最小值比例分配；移動曲線用 ease-out cubic，自己算。

- [ ] **Step 4：執行確認通過**

Run: `cd video && node --test src/lib/`
Expected: 全部 PASS。若有場次放不下，回報給主代理，不要改閱讀速度規則。

- [ ] **Step 5：Commit（主代理）**

`feat(video): add subtitle beats and pointer timing`

---

### Task 3：視覺元件與第 16 場四個畫面

**Files:**
- Create: `video/src/theme.ts`
- Create: `video/src/screens/geometry.ts`、`video/src/screens/geometry.test.ts`
- Create: `video/src/components/`：`DeviceTag.tsx`、`Subtitle.tsx`、`Callout.tsx`、`SkeletonLines.tsx`、`MacDialog.tsx`、`MacCursor.tsx`
- Create: `video/src/screens/`：`DialogBlocked.tsx`、`SettingsSecurity.tsx`、`DialogConfirm.tsx`、`DialogAuth.tsx`
- Create: `video/src/index.tsx`（註冊 `Stills16`，每個畫面一幀，供檢視）

**Interfaces:**
- Consumes: `script.json`
- Produces:
  - `theme`：設計文件「視覺系統」表的全部數值
  - `geometry.ts` 匯出 `SCREENS: Record<ScreenId, Record<TargetId, Rect>>`，`ScreenId = 'dialogBlocked' | 'settingsSecurity' | 'dialogConfirm' | 'auth'`，`Rect = { x, y, width, height }`（畫布座標）；`center(r: Rect): { x, y }`
  - `<Callout id targetRect color head />`：線由目標框右緣拉出，y 等於目標中心
  - `<MacCursor state={PointerState} />`，圖層 id 為 `pointer`，箭頭尖端在 `(x, y)`
  - 每個按鈕的圖層 id 用 `btn-<target>`

- [ ] **Step 1：查字串**

讀 `/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/Resources/Quarantine.loctable` 的 `zh_TW`（`python3 -I` 配 `plistlib`），找 key 以 `Q_HEADLINE_` 開頭、英文含 `Not Opened` 與 `Open “%@”` 的標題。查不到就用「「Remote Keyboard Receiver.app」未打開」、「要打開「Remote Keyboard Receiver.app」嗎？」，並回報為未確認。

已確認的字串：強制打開、丟到垃圾桶、完成、隱私權與安全性、安全性、已阻擋「Remote Keyboard Receiver.app」以保護你的Mac。、使用密碼⋯、取消、Touch ID。

- [ ] **Step 2：寫失敗的測試**

`geometry.test.ts`：
```ts
const c = SCREENS.dialogConfirm;
assert.deepEqual(Object.keys(c).sort(), ['done', 'open', 'trash']);
assert.ok(c.trash.y < c.open.y && c.open.y < c.done.y); // 由上到下：丟到垃圾桶、強制打開、完成
assert.ok(c.open.y - (c.trash.y + c.trash.height) >= 22); // 標示框不相碰
for (const screen of Object.values(SCREENS))
  for (const r of Object.values(screen)) {
    assert.ok(r.x >= 0 && r.x + r.width <= 1920);
    assert.ok(r.y >= 0 && r.y + r.height <= 884); // 不可壓到字幕分隔線
  }
```

- [ ] **Step 3：執行確認失敗**

Run: `cd video && node --test src/screens/`
Expected: FAIL。

- [ ] **Step 4：實作**

`dialogConfirm` 用樣板數值：對話框 `x=480, y=54, w=590, h=796`；按鈕相對對話框 `x=34, w=522, h=72, 圓角 36`，`trash y=502`、`open y=596`、`done y=690`；標示框外擴 6、線寬 5；標示線長 170，文字在線尾後 22 px，Bold 52。藍色按鈕是 `trash`。標題 Bold 32，內文用 `SkeletonLines`（寬 500、510、470、270）。

其他畫面：
- `dialogBlocked`：標題「未打開」、內文灰線、下方左右兩顆：`done`（完成，中性）、`trash`（丟到垃圾桶，藍）。
- `settingsSecurity`：系統設定視窗片段：側欄有「隱私權與安全性」為選取狀態，右側標題「安全性」，一列「已阻擋「Remote Keyboard Receiver.app」以保護你的Mac。」，右邊 `open`（強制打開）。其餘內容用灰線。
- `auth`：Touch ID 圖示、標題用灰線、下方 `password`（使用密碼⋯）與 `cancel`（取消）。

鎖頭圖示用向量繪製，不嵌入 Apple 原圖。

- [ ] **Step 5：執行確認通過並產生畫面**

Run: `cd video && node --test src/screens/ && npx kinetograph check src/index.tsx && npx kinetograph lint src/index.tsx --comp Stills16 --frames 0,1,2,3 && npx kinetograph strip src/index.tsx --comp Stills16 -n 4`
Expected: 測試 PASS；`no type errors`；`no issues`。把 strip 路徑交給主代理，由主代理親自看。

- [ ] **Step 6：Commit（主代理）**

`feat(video): add dark visual system and the four scene 16 screens`

---

### Task 4：第 16 場動畫與驗收

**Files:**
- Create: `video/src/data/scene16.ts`、`video/src/data/scene16.test.ts`
- Create: `video/src/scenes/Scene16.tsx`
- Create: `video/scripts/verify-scene16.mjs`
- Modify: `video/src/index.tsx`（註冊 `Scene16`，780 幀；移除 `Stills16`）
- Create: `docs/superpowers/verification/2026-11-04-install-tutorial-video.md`

**Interfaces:**
- Consumes: `splitBeats`、`beatTimeline`、`pointerAt`、`SCREENS`、全部元件
- Produces: `SCENE16_BEATS: { screen: ScreenId; target?: TargetId; press?: boolean; labels?: ('good' | 'bad')[]; minSeconds?: number }[]`；composition `Scene16`

- [ ] **Step 1：寫失敗的測試**

`scene16.test.ts` 斷言 `SCENE16_BEATS` 為下表，長度等於 `splitBeats` 的結果，且每個 `target` 存在於該拍的 `SCREENS[screen]`：

| 拍 | 畫面 | 目標 | 點按 | 標示 |
|---|---|---|---|---|
| 0 | dialogBlocked | | | |
| 1 | dialogBlocked | | | |
| 2 | dialogBlocked | done | 是 | |
| 3 | settingsSecurity | open | 是 | |
| 4 | dialogConfirm | open | | good |
| 5 | dialogConfirm | open | | good、bad，`minSeconds: 4` |
| 6 | auth | password | | |

第 5 拍指向停在 `open`，不移到藍色按鈕，避免觀眾以為要按那顆。第 4 拍不點按，第 6 拍前才換畫面。

- [ ] **Step 2：執行確認失敗**

Run: `cd video && node --test src/data/`
Expected: FAIL。

- [ ] **Step 3：實作 `scene16.ts` 與 `Scene16.tsx`**

畫面切換在該拍開始時做 8 幀淡入淡出；裝置標籤全程「在 Mac 上」；字幕用 `wrapBeat`，隨拍切換；標示框與線在該拍開始時用 `spring` 淡入，並保持到畫面切換。不做鏡頭推近（目標已夠大）。

- [ ] **Step 4：寫 `verify-scene16.mjs`**

用 `npx kinetograph inspect src/index.tsx --comp Scene16 --frame <n> --json`，在每拍的最後第 5 幀檢查，失敗即 exit 1，通過則逐條印出：
- 有 `labels` 時：`callout-open-line` 中心 y 等於 `btn-open` 中心 y，`callout-trash-line` 中心 y 等於 `btn-trash` 中心 y，誤差 1 px 內。
- 有 `target` 時：`pointer` 的位置落在 `btn-<target>` 的範圍內。
- 第 5 拍：`pointer` 不在 `btn-trash` 範圍內。

再 render 後用 `ffprobe` 確認無音軌、1920×1080、30fps、26 秒。

- [ ] **Step 5：執行全部檢查**

Run: `cd video && npm test && npx kinetograph check src/index.tsx && npx kinetograph lint src/index.tsx --comp Scene16 --frames 30,120,200,300,400,500,600,720 && npx kinetograph doctor src/index.tsx --comp Scene16 && npx kinetograph strip src/index.tsx --comp Scene16 -n 12 && npx kinetograph render src/index.tsx --comp Scene16 && node scripts/verify-scene16.mjs`
Expected: 全部通過；`doctor` 100% clean；MP4 在 `out/renders/Scene16.mp4`。

Run: `grep -rnE '強制開啟|移至垃圾桶|私隱|軟件|嘅|咗|冇|唔| · ' video/src docs/video`
Expected: 沒有輸出。

- [ ] **Step 6：主代理親自檢查**

看 12 格 strip 與第 5 拍的 still，並把 still 縮到 844 寬檢查字幕可讀。確認：第 3 拍指向在「強制打開」、第 4 拍綠框在中間那顆、第 5 拍紅框在藍色那顆。

- [ ] **Step 7：寫驗收報告**

自動驗證與使用者驗證分開列。使用者項目標 TBD：靜音看片是否清楚、有沒有 AI 味、在台灣繁體中文 Mac 對照按鈕。未確認的字串逐項列出。

- [ ] **Step 8：Commit、開 PR（主代理），停下給使用者看 MP4**

`feat(video): animate scene 16 with subtitles and pointer`

依專案守則經獨立 reviewer 審查。V2 要等使用者看過第 16 場才開始。
