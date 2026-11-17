# v0.2 宣傳影片實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal：** 新增 `PromoFilm`。一支 iPhone 依序打字到 Mac、Windows、Linux 再回到 Mac，配 ElevenLabs 旁白，長度不超過 65 秒。

**Architecture：** 新模組 `video/src/promo/` 有自己的時間表、動作表與狀態，演算法照 `film/` 的寫法另寫一份。`film/` 的畫面元件只加選用參數，預設值等於現在的行為，所以 `ProductFilm` 的輸出完全不變。時間表由已批准的旁白秒數算出。

**Tech Stack：** TypeScript、React、`kinetograph` 0.3.0（`@kinetographdev/core`、`@kinetographdev/audio`）、`node --test`、ffmpeg／ffprobe、curl（ElevenLabs API）。

**Spec：** `docs/superpowers/specs/2026-11-17-promo-film-v0.2-design.md`（2026-11-18 批准）

## Global Constraints

- 一個 Task 一個 worktree、一條 branch、一個 PR。子代理不得 commit 或 push；每個 Task 的 Commit 步驟由主代理在自己重跑驗證之後做。
- 所有指令在 `video/` 下執行；worktree 第一次要先跑 `npm ci` 與 `bash scripts/setup-fonts.sh`。需要網絡之前，先跑 preflight：`curl -sI https://registry.npmjs.org/ | head -1` 與 `node -v`。
- 1920×1080、30 fps；`FRAMES` 不超過 1950。
- 電腦名稱只有 `Mac`、`Windows`、`Linux`，順序 Mac → Windows → Linux → Mac。
- 標題用台灣繁體中文，字級至少 76，每秒少於 7 字（`captionLength`），不得含 `film/timeline.ts` 的 `FORBIDDEN`。
- 旁白檔 `public/voice/promo/01.mp3`–`10.mp3` 都已批准，除非旁白稿再改，否則不得重新生成。
- 生成參數：voice `r6qgCCGI7RWKXCagm158`、model `eleven_v4`、`stability 0.5`、`similarity_boost 0.75`、`style 0.2`、`use_speaker_boost true`、`language_code "zh"`、`output_format mp3_44100_128`。
- API key 只能用 `security find-generic-password -s ELEVENLABS_API_KEY -w` 讀出，經 stdin 交給 `curl -H @-`；不得出現在命令列參數、log、輸出或 repo。Node 的 `fetch` 連 api.elevenlabs.io 會出現 EBADF，所以 HTTP 一律用 curl。
- 顏色：綠 `#30d158` 表示已連接，藍 `#0a84ff` 表示傳送；系統外框用灰階，不畫任何公司標誌或官方桌布。
- `ProductFilm`、`ProductIntro`、`Main` 的抽幀與 `audio analyze` 結果必須與 main 逐位元相同（Task 2 的指紋腳本）。
- log 與 `requests.log` 只記編號、時間、request-id、雜湊，不記 key。
- 音樂檔放 `public/audio/`（已被 git 忽略），不提交。

## Review Focus

1. `PromoFilm` 的長度剛好等於另一個 composition：音效登記是全域的，靠長度分辨，撞長度就會把按鍵聲混進別的片。測試在 Task 1。
2. 已批准的旁白檔被覆寫或重新生成：使用者聽過的版本不見了。測試在 Task 1（mp3 的 sha256 要等於 `requests.log`）。
3. 狀態格放不下電腦名稱：`Windows` 在 22 px、140 px 寬的格子內被截斷或溢出。測試在 Task 2。
4. 改了時間表後 SRT 沒有跟著更新：YouTube 字幕與旁白錯開。測試在 Task 1（檔案內容等於 `toSrt()`）。
5. API key 漏進 repo 或 log。測試在 Task 1（`git grep` 掃描）。

---

### Task 1: 旁白資料與時間表

**Files：**
- Create: `video/src/promo/narration.ts`、`video/src/promo/timeline.ts`、`video/src/promo/srt.ts`
- Create: `video/scripts/gen-promo-voice.mjs`、`video/scripts/gen-promo-srt.mjs`
- Create（腳本產生）：`video/src/promo/voice-manifest.json`、`docs/video/promo-v0.2.srt`
- Test: `video/src/promo/narration.test.ts`、`video/src/promo/timeline.test.ts`

**Interfaces：**
- Produces：
  - `type LineId = '01' | … | '10'`；`type SegId = '1' | … | '10'`
  - `NARRATION: readonly { id: LineId; seg: SegId; caption: string; spoken: string }[]`：`caption` 照 spec 旁白表逐字抄，`spoken` 與 `caption` 相同，只有 `10` 寫「零點二」。
  - `voice-manifest.json`：`{ [id]: { seconds: number; sha256: string; firstPause: number | null } }`
  - `timeline.ts`：`FPS = 30`、`WIDTH`、`HEIGHT`、`PAD = 0.2`、`SEG_MIN: Record<SegId, number>`、`SEGMENTS: readonly { id: SegId; from: number; to: number }[]`、`seg(id): { from; to }`、`VOICE: readonly { id: LineId; from: number; to: number }[]`、`FRAMES`、`TITLES: readonly Title[]`（`Title` 型別取自 `film/timeline.ts`）、`END_CARD: readonly CardLine[]`、`PAD_SHIFT`
  - `srt.ts`：`toSrt(): string`

- [ ] **Step 1：寫 `gen-promo-voice.mjs`**

兩個指令：
- `measure`：對每個 `public/voice/promo/NN.mp3` 量出 `seconds`（ffprobe）、`sha256`，以及 `firstPause`。`firstPause` 用 `silencedetect=noise=-35dB:d=0.08`，取 0.3 秒之後第一個 `silence_start`，只有 `03`、`05`、`07` 需要，其他寫 `null`。結果寫入 `src/promo/voice-manifest.json`，key 依編號排序，數字取到小數 3 位。
- `generate <id>`：照 Global Constraints 的參數，以 `previous_text`／`next_text` 帶入前後句的 `spoken`；用 `curl -H @-` 由 stdin 帶 key；寫出 `NN.mp3`；在 `requests.log` 加一行，欄位同現有 header；最後自動跑一次 `measure`。沒有 key 時以非 0 結束，訊息不含任何 key 內容。

- [ ] **Step 2：執行 `node scripts/gen-promo-voice.mjs measure`**

預期：產生 `voice-manifest.json`，`seconds` 依序約為 3.04、9.12、2.72、7.52、2.80、6.64、2.40、12.80、2.32、6.32；`03`、`05`、`07` 的 `firstPause` 不是 `null`。

- [ ] **Step 3：寫失敗的測試 `narration.test.ts`**

```ts
test('ten lines, captions verbatim from the spec, spoken differs only in line 10', …)
  // NARRATION.length === 10；ids 01..10；seg 依序為 '1'..'10'
  // NARRATION[9].spoken.includes('零點二') && NARRATION[9].caption.includes('v0.2')
  // 其餘九句 spoken === caption
test('no banned words in the narration', …)
  // 每句 caption 與 spoken 都不含 '密碼' '零延遲' 'Wi-Fi' '香港'
test('approved takes are untouched', …)
  // 讀 public/voice/promo/requests.log：每個 id 的 sha256 === manifest[id].sha256 === 檔案的實際 sha256
test('manifest durations match the files', …)
  // execFileSync('ffprobe', …) 量到的秒數與 manifest[id].seconds 相差 ≤ 0.01
test('no API key in the repo', …)
  // execFileSync('git', ['grep', '-nE', 'sk_[0-9a-f]{20,}', '--', '.', ':!Pods']) 以狀態 1 結束（沒有符合）
```

- [ ] **Step 4：跑 `node --test src/promo/narration.test.ts`**

預期：FAIL，因為找不到 `narration.ts`。

- [ ] **Step 5：寫 `narration.ts`**

- [ ] **Step 6：寫失敗的測試 `timeline.test.ts`**

```ts
test('segment length is the longer of the picture minimum and the voice plus pads', …)
  // SEG_MIN = { '1': 4.0, '2': 9.0, '3': 2.5, '4': 9.5, '5': 2.0, '6': 8.0, '7': 2.0, '8': 12.0, '9': 4.5, '10': 6.5 }
  // 每段長度 === Math.ceil(Math.max(SEG_MIN[id], seconds + 2 * PAD) * FPS)
test('segments are contiguous from 0 and FRAMES is at most 1950', …)
test('FRAMES differs from every other composition', …)
  // FRAMES 不等於 film/timeline FRAMES、intro/timeline FRAMES、data/scenes FILM_FRAMES，也不等於任一 sceneFrames(n)
test('every line sits inside its segment with PAD on both sides, lines at least 9 frames apart', …)
  // VOICE[i].from === seg.from + Math.round(PAD * FPS)；VOICE[i].to <= seg.to - Math.round(PAD * FPS)
test('titles: text, reading speed, forbidden strings', …)
  // 標題依序為 '一支 iPhone 打字到三部電腦' '即時模式每按一個鍵就送出' '草稿模式先改好再傳送' '點一下換電腦'
  //   '中文可以用手寫' '也可以在 App 改用速成' '一指移動游標' '輕點就是點按' '按住再拖曳' '兩指輕點是右鍵' '兩指滑動來捲動'
  // captionLength(text) / 秒數 < 7；不含 FORBIDDEN；size >= 76
test('end card lines', …)
  // seg('10').from 出現：'Remote Keyboard'(120) 'v0.2.0 Alpha'(56) '支援 macOS 15、Windows 11、Ubuntu 26.04'(52) '透過 SideStore 安裝 不是 App Store 版本'(52)
  // 再過 2 秒出現：'下載 github.com/AnsonHui6040/Mac-keyboard'(56) '與 Apple、Microsoft、Canonical 沒有關聯'(32)
test('the SRT file is generated from the narration and the timeline', …)
  // readFileSync('docs/video/promo-v0.2.srt') === toSrt()；10 條，時間 = VOICE 的 from/to，文字 = caption
```

- [ ] **Step 7：跑 `node --test src/promo/timeline.test.ts`**

預期：FAIL。

- [ ] **Step 8：寫 `timeline.ts` 與 `srt.ts`**

各標題的時間：第 2 段的兩個標題各佔一半。第 8 段的五個標題是 `film/timeline.ts` 的 t7–t11 加上 `PAD_SHIFT`，其中 `PAD_SHIFT = seg('8').from - 849`（849 是舊片第 21a 鏡的開始幀）。其他標題在該段開始後 0.2 秒出現，該段結束前 0.2 秒消失。位置沿用舊片的 `TOP` 與第 21 鏡的位置。SRT 時間格式為 `HH:MM:SS,mmm`，以幀換算毫秒。

- [ ] **Step 9：寫 `gen-promo-srt.mjs`，執行後再跑兩個測試檔**

Run：`node scripts/gen-promo-srt.mjs && node --test src/promo/narration.test.ts src/promo/timeline.test.ts`

預期：PASS；`FRAMES` 約 1937。

- [ ] **Step 10：`npm test` 全部通過，然後 Commit**

```bash
git add video/src/promo video/scripts/gen-promo-voice.mjs video/scripts/gen-promo-srt.mjs docs/video/promo-v0.2.srt
git commit -m "feat(video): narration data and timeline of the v0.2 promo"
```

---

### Task 2: 共用元件加選用參數（舊片零變化）

**Files：**
- Create: `video/scripts/old-films-fingerprint.sh`、`video/src/film/statusCell.ts`
- Modify: `video/src/film/state.ts`（`PhoneState`）、`video/src/film/PhoneScreen.tsx`（`Toolbar`、`PhoneScreen`）、`video/src/film/Fingers.tsx`（`PhoneRings`）、`video/src/film/MacScreen.tsx`（`MacScreen`）、`video/src/film/Stage.tsx`（export）、`video/src/film/layout.ts`
- Test: `video/src/film/statusCell.test.ts`

**Interfaces：**
- Produces：
  - `PhoneState.host?: string`：有值時，工具列畫兩行狀態格。
  - `STATUS_CELL = { x: 148, w: 140, h: 49, radius: 16, fill: '#7676803d', size: 22 }`（`film/layout.ts`）
  - `PhoneScreen({ state, f, ink? }: { …; ink?: { from: number; strokes: (f: number) => { x: number; y: number }[][] } })`：預設 `{ from: INK_FROM, strokes: inkAt }`
  - `PhoneRings({ f, size?, line?, dy?, finger?, pad? })`：`finger?: (f: number) => KeyFinger` 預設 `fingerAt`；`pad?: (f: number) => TrackState | null` 預設是現有的第 21 鏡判斷
  - `MacScreen({ f, stage?, state? })`：`state?: MacState` 預設 `macAt(f)`
  - `Stage.tsx` 加 export：`Pinned`、`Lights`、`Scene`、`Bodies`
  - `old-films-fingerprint.sh <outdir>`：輸出 `<outdir>/fingerprint.txt`

- [ ] **Step 1：寫 `old-films-fingerprint.sh`**

內容：輸出 `ProductFilm` 第 0、114、430、660、760、950、1100、1300、1514 幀，`ProductIntro` 第 100、1000、1700 幀，`Main` 第 5000、9000 幀的 still（`npx kinetograph still src/index.tsx <frame> --comp <id> -o …`），取 sha256；再對三個 composition 跑 `npx kinetograph audio analyze src/index.tsx --comp <id> --json`，去掉 `entry` 欄位後取 sha256。全部寫進 `fingerprint.txt`，一行一項。

- [ ] **Step 2：在 main checkout 建基準**

Run：`cd /Users/ansonhui/Documents/GitHub/Mac-keyboard/video && bash <worktree>/video/scripts/old-films-fingerprint.sh <scratchpad>/base`

預期：17 行。

- [ ] **Step 3：寫失敗的測試 `statusCell.test.ts`**

```ts
test('every host name fits the status cell at 22 px', …)
  // for name of ['Mac', 'Windows', 'Linux']: textWidth(name, STATUS_CELL.size, 500) <= STATUS_CELL.w - 16
test('the status cell keeps the old one-line look without a host', …)
  // statusCellLabels(undefined, 24) 深等於 [{ text: '已連接', y: 24, h: 49, size: 22, color: '#30d158' }]
  // statusCellLabels('Windows', 24) 是兩行：[{ text: 'Windows', y: 24, h: 24.5, size: 22, color: '#ffffff' }, { text: '已連接', y: 48.5, h: 24.5, size: 22, color: '#30d158' }]
```

`statusCellLabels(host: string | undefined, toolbarY: number): { text: string; y: number; h: number; size: number; color: string }[]` 放在 `film/statusCell.ts`，`Toolbar` 用它來畫；沒有 `host` 時的結果與現在的「已連接」標籤完全一樣。

- [ ] **Step 4：跑測試，預期 FAIL；之後實作上面的參數與 `statusCell.ts`，再跑，預期 PASS**

- [ ] **Step 5：在 worktree 跑指紋並比對**

Run：`bash scripts/old-films-fingerprint.sh <scratchpad>/branch && diff <scratchpad>/base/fingerprint.txt <scratchpad>/branch/fingerprint.txt`

預期：`diff` 沒有輸出。

- [ ] **Step 6：`npm test`、`npx kinetograph check src/index.tsx` 都通過，然後 Commit**

```bash
git add video/src/film video/scripts/old-films-fingerprint.sh
git commit -m "refactor(video): optional state props on the film screens, no output change"
```

---

### Task 3: 動作表與狀態

**Files：**
- Create: `video/src/promo/events.ts`、`video/src/promo/state.ts`
- Test: `video/src/promo/events.test.ts`、`video/src/promo/state.test.ts`

**Interfaces：**
- Consumes：Task 1 的 `seg`、`VOICE`、`PAD_SHIFT`、`FRAMES`、manifest 的 `firstPause`；Task 2 的 `PhoneState.host`、`MacState`、`KeyFinger`；`film/layout.ts` 的鍵位函數；`film/state.ts` 的 `QUICK_CANDIDATES`、`QUICK_SCROLL_TOTAL`；`film/trackpad.ts` 的 `trackAt`；`intro/ink.ts` 的 `STROKES`、`strokeLength`、`partialStroke`、`strokePoint`
- Produces：
  - `type Host = 'Mac' | 'Windows' | 'Linux'`；`HOST_TAPS: readonly [number, number, number]`；`hostAt(frame): Host`
  - `PRESSES: readonly PromoPress[]`，其中 `PromoPress = { t; kb; key; label; snd: 'key' | 'tap'; fx: PromoFx; hold }`，`PromoFx = Fx | { k: 'host' } | { k: 'cut'; ime: 'quick' | 'en' }`
  - `INK: readonly { from: number; to: number }[]`、`SWIPES`、`PAD_EVENTS`（第 21 鏡的事件加上 `PAD_SHIFT`）
  - `soundEvents(): { frame: number; kind: SoundKind }[]`，另有 `kind: 'host'`，播放時用 tap 音
  - `docAt(host: Host, frame): { lines: string[]; caretOn: boolean }`
  - `promoPhoneAt(frame): PhoneState`（`host` 一律有值）、`promoFingerAt(frame): KeyFinger`、`promoInkAt(frame)`、`promoMacAt(frame): MacState`、`promoTrackAt(frame): TrackState | null`

- [ ] **Step 1：寫失敗的測試 `events.test.ts`**

```ts
test('the three host taps land when 點一下 has been said', …)
  // HOST_TAPS[i] === VOICE[k].from + Math.round(manifest[k].firstPause * 30)，k 依序 '03' '05' '07'
test('hostAt goes Mac, Windows, Linux, Mac', …)
  // hostAt(0) 'Mac'；hostAt(HOST_TAPS[0]) 'Windows'；hostAt(HOST_TAPS[1]) 'Linux'；hostAt(HOST_TAPS[2]) 'Mac'；hostAt(FRAMES - 1) 'Mac'
test('each segment holds its own presses', …)
  // 第 2 段：打出 'Hello from my iPhone'、換行、草稿、'Chek before sending'、草稿游標點、'c'、游標點到尾、換行、傳送
  // 第 4 段：'中英'、手寫、選 '香港'、傳送；第 6 段：cut 到速成、h a 選香、e u、三次滑動、選港、傳送
  // 第 7 段：host 點擊後 0.4 秒內按觸控板；第 9 段：'Remote Keyboard'，每 4 幀一鍵
  // 每個 press 的 t 都在它的段落內，而且至少比段落結束早 0.6 秒
test('ink strokes fit inside segment 4 before the pick', …)
test('sounds: one per press, good after each send, success after the last letter of segment 9, tap for host', …)
```

- [ ] **Step 2：跑測試，預期 FAIL；寫 `events.ts`；再跑，預期 PASS**

按鍵時間用相對段落開始的秒數寫，例如 `at('2', 0.4)`。墨跡排程照 `film/events.ts` 的 `INK` 演算法另寫一份，範圍是第 4 段開始後 1.0 到 4.2 秒。觸控板的事件是第 21 鏡的事件加上 `PAD_SHIFT`。

- [ ] **Step 3：寫失敗的測試 `state.test.ts`**

```ts
test('text goes only to the host that was connected when it was sent', …)
  // docAt('Mac', FRAMES - 1).lines 深等於 ['Hello from my iPhone', 'Check before sending', 'Remote Keyboard']
  // docAt('Windows', FRAMES - 1).lines 深等於 ['香港']；docAt('Linux', FRAMES - 1).lines 深等於 ['香港']
  // HOST_TAPS[0] 之前 Windows 與 Linux 都是 ['']
test('Linux gets 香港 in one frame (paste)', …)
  // docAt('Linux', f) 由 '' 變成 '香港' 只發生在一個幀
test('the phone always shows the current host as connected', …)
  // 每一幀 promoPhoneAt(f).host === hostAt(f)，status === 'connected'
test('the Mac document does not change during the trackpad segment', …)
test('the trackpad is the old shot 21 moved by PAD_SHIFT', …)
  // 第 8 段每 5 幀抽一幀：promoTrackAt(f) 深等於 trackAt(f - PAD_SHIFT)
test('the finger is hidden outside the keyboard pages and on the pad', …)
```

- [ ] **Step 4：跑測試，預期 FAIL；寫 `state.ts`；再跑，預期 PASS**

手指路徑照 `film/state.ts` 的 `fingerAt` 演算法另寫：段落之間淡入淡出 6 幀，滑行 8 幀。`promoMacAt` 的 `screen` 一律是 `'doc'`，`lines` 取 `docAt('Mac', f)`，第 8 段的 `track` 取 `promoTrackAt`。

- [ ] **Step 5：`npm test` 全部通過，然後 Commit**

```bash
git add video/src/promo/events.ts video/src/promo/state.ts video/src/promo/events.test.ts video/src/promo/state.test.ts
git commit -m "feat(video): presses, host switching and screen state of the v0.2 promo"
```

---

### Task 4: 特寫鏡頭、Windows 與 Ubuntu 畫面

**Files：**
- Create: `video/src/promo/cuts.ts`、`video/src/promo/cameras.ts`、`video/src/promo/WinScreen.tsx`、`video/src/promo/LinuxScreen.tsx`、`video/src/promo/CloseShot.tsx`、`video/src/promo/Promo.tsx`（初版）
- Modify: `video/src/index.tsx`（註冊 `PromoFilm`）
- Test: `video/src/promo/cameras.test.ts`

**Interfaces：**
- Consumes：Task 1 的 `seg`、`TITLES`；Task 3 的 `PRESSES`、`docAt`、`promoPhoneAt`、`promoFingerAt`；Task 2 的參數；`film/Slab.tsx`、`film/slabMath.ts`（`projectSlab`、`SlabParams`）
- Produces：
  - `CUTS: readonly { id: string; from: number; to: number; dev: 'phone' | 'mac' | 'win' | 'linux' | 'stage' | 'wide' | 'hero' | 'card' }[]`：涵蓋 0 到 `FRAMES`，首尾相接
  - `cutAt(frame)`、`closeCam(id, frame): CloseCam`（`dev` 多了 `'win' | 'linux'`）
  - `WinScreen({ f, lines, caretOn }: { …; lines: string[]; caretOn: boolean })` 與 `LinuxScreen(同上)`：都是 1280×800
  - `CloseShot({ id, f })`

- [ ] **Step 1：寫失敗的測試 `cameras.test.ts`**

```ts
test('cuts cover the film with no gap and follow the segments', …)
  // 第 2 段：手機與 Mac 交替，即時與草稿各至少有一個 'mac' cut，在傳送後 2 幀以內開始
  // 第 3、5、7 段各一個 'phone' cut，鏡位對準狀態格（STATUS_CELL 中心在畫面中間 ±200 px）
  // 第 4 段最後是 'win'，第 6 段最後是 'linux'；第 8 段 'stage'、第 9 段 'wide'、第 10 段 'card'、第 1 段 'hero'
test('close-ups are locked: only mag grows (1.2% a second, at most 1.5%), or one constant pan', …)
test('rings stay 60 px from the edges, and below y 215 under a title', …)
  // 每個特寫 cut 的每一幀：projectSlab 算出的手指位置
test('the typed text is fully in frame on Mac, Windows and Linux cuts', …)
```

- [ ] **Step 2：跑測試，預期 FAIL；寫 `cuts.ts`、`cameras.ts`；再跑，預期 PASS**

鏡位類型照舊片的規則：打字與 Mac 斜向，草稿正面，手寫正上方加滾轉約 -8°，速成斜向加等速橫移。狀態格特寫用正面，放大約 2.4 倍。

- [ ] **Step 3：寫 `WinScreen.tsx` 與 `LinuxScreen.tsx`**

Windows：深灰桌面，底部置中工作列（48 px 高），上面放 5 個一般圓角方塊圖示，最左一個是無標誌的開始鍵；中間是記事本視窗，標題「未命名 - 記事本」，字級 52，字色白。Linux：頂欄 36 px（左邊「活動」、中間時間「10:24」），左側 dock 72 px 寬、4 個圓角圖示；中間是文字編輯器視窗，標題「未命名文件」。兩者游標閃爍規則同 `MacScreen`。

- [ ] **Step 4：寫 `CloseShot.tsx` 與初版 `Promo.tsx`，註冊 `PromoFilm`，用 still 檢查**

初版 `Promo.tsx` 只畫特寫 cut 與標題，其他 cut 先畫黑底，Task 5、6 再補。`index.tsx` 加 `<Composition id="PromoFilm" component={Promo} durationInFrames={FRAMES} fps={30} width={1920} height={1080} />`。

Run：`npx kinetograph still src/index.tsx <frame> --comp PromoFilm -o out/stills/promo-<frame>.png`，每個特寫 cut 取中間一幀。

預期：主代理親自看過；沒有標誌、沒有字被裁切、沒有香港用字。

- [ ] **Step 5：`npm test`、`kinetograph check` 通過，然後 Commit**

```bash
git add video/src/promo
git commit -m "feat(video): close-ups and the Windows and Linux screens of the v0.2 promo"
```

---

### Task 5: 3D 廣角（第 1、8、9 段）

**Files：**
- Create: `video/src/promo/project3.ts`、`video/src/promo/Bodies3.tsx`、`video/src/promo/Wide.tsx`
- Test: `video/src/promo/project3.test.ts`

**Interfaces：**
- Consumes：`film/project.ts`（`project`、`planeCorners`、`Cam`、`Stage`、`PHONE_PLANE`、`MAC_PLANE`、`STAGE`、`cam21`）；Task 2 export 的 `Pinned`、`Lights`、`Scene`、`Bodies`；Task 3 的狀態；Task 4 的 `WinScreen`、`LinuxScreen`
- Produces：
  - `WIDE: { mac: Placement; win: Placement; linux: Placement; phone: Placement }`，其中 `Placement = { pos: V3; rot: V3 }`
  - `heroCam3(frame): Cam`、`wideCam(frame): Cam`、`stageCam(frame): Cam`（第 8 段 = `cam21(frame - PAD_SHIFT)`）
  - `winPin`、`linuxPin`、`brightness(host: Host, segId: SegId): number`
  - `Hero3({ f })`、`StageShot8({ f })`、`Wide({ f })`

- [ ] **Step 1：寫失敗的測試 `project3.test.ts`**

```ts
test('the three computers are not a row of equals', …)
  // 第 9 段第一幀：三個螢幕投影寬度兩兩相差 >= 15%；Mac–Windows 與 Windows–Linux 的中心距離相差 >= 10%
test('the Mac is the bright one in shots 1 and 9', …)
  // brightness('Mac', '1') === 1 && brightness('Mac', '9') === 1；另外兩部 <= 0.5
test('shot 8 keeps the Mac and phone where shot 9 has them', …)
  // WIDE.mac 與 WIDE.phone 的相對位置等於 STAGE 的 macPos/phonePos 相對位置
test('every screen of shot 9 is fully in frame, rings and cursor 60 px from the edges', …)
test('shot 9 moves back at one speed only', …)
  // wideCam 的位置每幀變化量相同（±1e-9），方向是遠離 target
```

- [ ] **Step 2：跑測試，預期 FAIL；寫 `project3.ts`；再跑，預期 PASS**

Windows 是有底座的桌上型螢幕，螢幕 16:9；Linux 筆電外殼顏色比 Mac 深（`#3a3b40`），比例 16:10。第 1 段：三部電腦失焦在後方，手機在前景轉正，鏡位與 `film/project.ts` 的 `HERO` 相同。

- [ ] **Step 3：寫 `Bodies3.tsx`、`Wide.tsx`，接進 `Promo.tsx` 的 hero、stage、wide cut**

Run：`npx kinetograph still src/index.tsx <frame> --comp PromoFilm -o out/stills/promo-<frame>.png`，取第 1 段第 0、45、100 幀，第 8 段第一幀與中間幀，第 9 段第一幀與最後幀。

預期：主代理親自看過；三部電腦外形不同，看不到標誌，Mac 最亮。

- [ ] **Step 4：`npm test`、`kinetograph check` 通過，然後 Commit**

```bash
git add video/src/promo
git commit -m "feat(video): 3D shots with three computers for the v0.2 promo"
```

---

### Task 6: 組裝、聲音、輸出與文件（第一階段）

**Files：**
- Create: `video/src/promo/register.ts`、`video/src/promo/mix.ts`、`video/src/promo/music.ts`、`video/scripts/render-promo.sh`
- Modify: `video/src/promo/Promo.tsx`（補上 3D cut、字卡、旁白、grain）、`video/src/index.tsx`（import `./promo/register.ts`）
- Create: `docs/video/promo-v0.2-storyboard.md`、`docs/video/promo-v0.2-youtube.md`、`docs/superpowers/verification/2026-11-17-promo-film-v0.2.md`
- Test: `video/src/promo/mix.test.ts`

**Interfaces：**
- Consumes：所有前面的 Task
- Produces：
  - `isPromoContext(length, sampleRate): boolean`：長度等於 `FRAMES / 30` 秒（容許 1 個 sample）
  - `voiceDuck(frame): number`：0 到 1，旁白期間為 1，前後 0.25 秒線性漸變
  - `musicGainDb(frame) = -10 * voiceDuck(frame)`、`sfxGainDb(frame) = -6 * voiceDuck(frame)`
  - `PROMO_MUSIC: readonly MusicSegment[]`：本 Task 為空陣列

- [ ] **Step 1：寫失敗的測試 `mix.test.ts`**

```ts
test('voiceDuck is 1 inside a line, 0 well outside, and ramps over 0.25 s', …)
  // voiceDuck(VOICE[0].from) === 1；voiceDuck(VOICE[0].from - 8) === 0；voiceDuck(VOICE[0].from - 4) 介於 0 與 1
test('music is ducked 10 dB and effects 6 dB under the voice', …)
test('the promo sounds play only in a context of the promo length', …)
  // isPromoContext(Math.round(FRAMES / 30 * 48000), 48000) === true；用 1515、1830、10050 幀的長度都是 false
test('no music segments before the user picks a track', …)
  // PROMO_MUSIC.length === 0
```

- [ ] **Step 2：跑測試，預期 FAIL；實作；再跑，預期 PASS**

`Promo.tsx` 依 `cutAt(f)` 硬切，標題用 `film/Headline.tsx`，特寫上方加舊片的 scrim，最上層加 `grain(0.022)`。每句旁白一個 `<Sequence from={VOICE.from}>` 包 `<Audio src={staticFile('voice/promo/NN.mp3')} />`。`register.ts` 照 `film/register.ts` 的寫法登記音效，guard 用 `isPromoContext`，按鍵類音量乘上 `sfxGainDb` 換算的倍率。`render-promo.sh` 照 `render-film.sh` 的做法輸出 `out/renders/promo-v0.2.mp4`，母帶標準是 -14 LUFS ± 0.4、true peak ≤ -1.0 dBTP；`PROMO_MUSIC` 不是空的時候，先檢查每個音樂檔都存在，缺檔就報錯並列出檔名。

- [ ] **Step 3：自動驗證**

Run：
- `npm test`：預期全部通過
- `npx kinetograph check src/index.tsx`：預期沒有錯誤
- `npx kinetograph doctor src/index.tsx --comp PromoFilm`：預期每一幀都 clean
- `npx kinetograph lint src/index.tsx --comp PromoFilm --frames <0 到 FRAMES-1 每 15 幀>`：預期 0 error
- `bash scripts/render-promo.sh`：預期 `ffprobe` 為 H.264、AAC 48 kHz、1920×1080、30 fps，幀數等於 `FRAMES`；響度在目標範圍內（這時沒有音樂，結果只當參考）
- `bash scripts/old-films-fingerprint.sh <scratchpad>/t6 && diff <scratchpad>/base/fingerprint.txt <scratchpad>/t6/fingerprint.txt`：預期沒有輸出

- [ ] **Step 4：主代理親自看畫面**

每個 cut 看中間一幀；第 3、5、7 段的點擊前後各一幀；第 9 段看第一幀與最後一幀；字卡看一幀。檢查項目：模板感、標誌、裁切、文字、香港用字。

- [ ] **Step 5：寫文件**

- 分鏡稿：每段與每個 cut 的實際秒數、旁白秒數、標題。
- YouTube 文件：標題、說明欄。說明欄包括下載連結、安裝教學連結（v0.2 教學上傳前先寫 `youtu.be/dGhEuzRpAEg`，並註明上傳後要換）、需求、Alpha 說明、三家公司的免責聲明、字幕檔 `promo-v0.2.srt`。
- 驗收報告：自動驗證結果，以及使用者 TBD 項（節奏、旁白發音、混音）。

寫完 grep 一次：`[nN]\s*=\s*\d` 要 0 個，Cantonese 用字 `[嘅唔冇喺咗佢哋嚟啲]` 要 0 個。

- [ ] **Step 6：Commit，把 MP4 交給使用者看片**

```bash
git add video/src video/scripts/render-promo.sh docs/video docs/superpowers/verification/2026-11-17-promo-film-v0.2.md
git commit -m "feat(video): assemble the v0.2 promo with narration and sound effects"
```

---

### Task 7: 音樂（第二階段，要等使用者提供音檔）

**Files：**
- Modify: `video/src/promo/music.ts`、`video/src/promo/timeline.ts`（只在需要對拍點時改 `SEG_MIN`）、驗收報告、分鏡稿
- Test: `video/src/promo/music.test.ts`

**Interfaces：**
- Consumes：使用者放在 `video/public/audio/` 的檔案；Task 6 的 `PROMO_MUSIC`、`musicGainDb`
- Produces：一筆 `PROMO_MUSIC`：`{ id: 'promo', file: 'audio/<檔名>', from: 0, to, shift, trimBefore, base }`

- [ ] **Step 1：量測音檔**

用 ffprobe 量長度，確認至少 60 秒。用 `ebur128` 每 0.1 秒的短時響度找出約第 13 秒與第 37 秒的推進點，並記下 BPM 與第一拍的位置。全部寫進驗收報告。

- [ ] **Step 2：寫失敗的測試 `music.test.ts`**

```ts
test('one continuous take from frame 0, no cut or restart', …)
test('segment boundaries 3 and 8 sit on a beat, each moved at most 1 s from Task 1', …)
test('FRAMES still at most 1950 and every line still inside its segment', …)
```

- [ ] **Step 3：跑測試，預期 FAIL；實作；再跑，預期 PASS**

- [ ] **Step 4：輸出並量測混音**

方法同舊片驗收報告：分別輸出「只有音樂」與「只有旁白」的分軌，量每句旁白期間旁白比音樂高多少（目標至少 12 dB），以及沒有旁白時按鍵聲比音樂高多少（目標 6–8 dB）。成品要 -14 LUFS ± 0.4，true peak ≤ -1.0 dBTP。

- [ ] **Step 5：更新驗收報告與分鏡稿，舊片指紋再比對一次，然後 Commit**

```bash
git add video/src/promo docs/video docs/superpowers/verification/2026-11-17-promo-film-v0.2.md
git commit -m "feat(video): music for the v0.2 promo"
```
