# 港台常用鍵盤與自訂匯入研究

日期：2026-11-20。只做研究，沒有寫產品程式；實機項目一律標 TBD。

使用者決定（2026-11-20）：採用方向 C（內嵌 librime），理由是將來可能推出 Android 版，組字引擎要能跨平台共用。決定與其影響見第 9 節；第 6 節保留原本的比較與推薦，作為決策紀錄。

## 範圍與前提（使用者 2026-11-20 選定）

| 項目 | 決定 |
|---|---|
| 「鍵盤」的範圍 | 輸入法與鍵位都研究，以輸入法為主；鍵位見 2.4 節，鍵位描述格式併入 4.1 節 |
| 授權判斷前提 | 兩種分發都評估，以將來可能上 App Store 為準 |
| 授權判定的三個等級 | 可內建（隨 App 散布）、只限使用者自行匯入（我們不散布）、不可用 |

repo README 寫明「保留所有權利」，所以要求衍生作品以相同條款開源的授權（GPL、LGPL、CC BY-SA），即使技術上能用，也一律不內建。

## 結論摘要

1. 香港最常見的是形碼（速成、倉頡），其次是手寫與拼音類；台灣以注音為主。兩地都缺少近年具代表性的官方數據（第 2.2 節）。
2. iOS 已內建以上全部主流輸入法，所以本 App 的中文輸入法價值在於「同一個鍵盤直接送到電腦」，不在於補 iOS 缺的輸入法。唯一 iOS 沒有的是台灣的嘸蝦米、大易、行列（第 2.1 節）。
3. 現有的 `ChineseInputMethod` 介面（D15）已經可以容納表格型、拼音型、辨識型三類輸入法。要統一，主要缺的是：資料驅動的表格引擎、拼音型的組詞解碼器、鍵位描述檔，以及讀取匯入資料的方式（第 3 節）。
4. 不建議在鍵盤擴充程式內把匯入的碼表或詞庫解析成記憶體中的字典。在 Mac 上實測，13 萬多條粵拼字詞放進 Swift `Dictionary` 會多用約 31 MB，用記憶體映射讀取則幾乎不增加（第 5.2 節）。做法應該是由主 App 先編譯成唯讀的排序檔，放進 App Group，鍵盤以記憶體映射讀取。
5. 可以內建、授權乾淨的資料：倉頡與速成用 libcangjie（Public Domain，上游有殘餘風險），注音與拼音用小麥注音的資料（MIT），粵拼用 words.hk 字詞表（公有領域），單字讀音用 Unihan（Unicode License v3）。rime-cantonese（CC BY 4.0）詞庫最完整，但 CC 官方 FAQ 表示分享時不可加 DRM，隨 App Store 散布屬有條件可用，最穩妥是先取得維護者書面許可。RIME 官方方案、新酷音、教育部辭典、CC-CEDICT 等只限使用者自行匯入（第 4.3 節）。
6. 推薦方向 B：自寫 Swift 兩層引擎（表格型與拼音型），支援 `.cin` 與自帶完整編碼的 RIME `.dict.yaml` 匯入，鍵位用自訂 JSON 描述檔；分四步交付，第一步就是把速成改成通用表格引擎並加 `.cin` 匯入。拼音型要先過品質門檻才往下做（第 6 節）。

## 1. 現況：本專案的鍵盤擴充程式

讀過的檔案：專案 `CLAUDE.md`、`docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（§2、§3、D14–D19）、`docs/superpowers/verification/evidence/T12-o7-result.md`、`T12b-o9-license.md`，以及 `RemoteKeyboardExtension` 與 `RemoteKeyboardCore` 的原始碼。

| 項目 | 現況 | 位置 |
|---|---|---|
| 頁面 | 中文、英文（QWERTY）、符號三頁；底列「符號、中英、空白、換行」 | 設計 §2、D14、D19 |
| 中文輸入法介面 | `ChineseInputMethod` protocol：輸入 `IMEInput`（按鍵、Shift、刪除、空白、換行、選候選字、辨識結果、清除），輸出 `IMEOutput`（已提交文字、輸入碼、候選字、未處理的按鍵） | `Chinese/ChineseInputMethod.swift` |
| 已實作的輸入法 | `ChineseInputMethodID` 只有 `handwriting`、`quick` 兩個 case，是封閉的 enum | 同上 |
| 手寫 | Google ML Kit Digital Ink，語言 `zh-Hani-TW`；模型由主 App 下載後放進 App Group，鍵盤匯入；需要完整取用 | 設計 §2、D16、`ChineseInputCoordinator.swift` |
| 速成 | 最多兩碼，空白鍵選第一個候選字；候選字次序就是字碼表次序；沒有聯想字、字頻、學習 | `QuickInputMethod.swift`、D16 |
| 速成字碼表 | `quick-table.txt`，每行 `碼<TAB>字`，13,980 行、97,834 bytes，由 libcangjie 倉頡碼取首尾碼產生；一次讀進記憶體成 `[String: [String]]` | `QuickDictionary.swift`、`scripts/make-quick-table.swift` |
| 鍵位 | 速成頁的 QWERTY 三行寫死在 `QuickPageView`，鍵面字根來自固定表 `CangjieRadicals`；符號頁的鍵由 Core 內的 `SymbolLayouts` 陣列定義 | `UI/QuickPageView.swift`、`Keyboard/SymbolLayouts.swift` |
| 輸入法選擇 | 主 App 設定頁單選，經 App Group 傳給鍵盤；讀不到設定時預設手寫，手寫無法使用（未安裝或沒有完整取用）時退回速成 | `ChineseMethodResolver.swift`、D15 |
| 文字送出 | 組字與候選字都在 iPhone 完成，只有已提交文字經 `InputRouter` 送往本機欄位、草稿或電腦 | 設計 §4、`InputRouter.swift` |
| 語音 | 鍵盤沒有自己的語音鍵；遠端模式把系統聽寫寫入欄位的變化轉成差分送到電腦 | D7、D18 |
| 記憶體 | 已有實機上限與手寫峰值的量測，見 5.1 | `T12-o7-result.md` |

對統一與匯入的意義：

- 接收端（Mac、Windows、Linux）只收 Unicode 已提交文字，Mac 注入前會切到 ABC（D4），所以新增任何中文輸入法都不需要改接收端。
- 要改的範圍集中在 iPhone：輸入法 ID 要能容納匯入的輸入法、字碼表格式要支援三碼以上與權重、鍵位要由資料描述。

## 2. 港台常用輸入法與鍵位

### 2.1 iOS 內建情況

Apple 的 iOS 功能適用頁面列出以下鍵盤（擷取日期 2026-11-20）[S1]：

| 語言 | iOS 內建的中文鍵盤 |
|---|---|
| 粵語（繁體） | 倉頡、手寫、Phonetic（粵語拼音）、筆劃、速成 |
| 中文（繁體） | 倉頡、手寫、拼音（10 鍵）、拼音（QWERTY）、雙拼、筆劃、速成、注音（Dynamic）、注音（Grid）、注音（Standard） |
| 聽寫 | 粵語（香港）、國語（台灣）等 |

Apple 的「Phonetic - Cantonese」說明以「neihou」「leihou」輸入「你好」為例，並寫明支援多種拼音標準，例如「ceotfaatlaa」與「cheutfaatla」都可以打出「出發啦」[S2]。這份是 Mac 版說明；iOS 的粵語 Phonetic 鍵盤是否接受同樣的拼法，屬推論，未在 iPhone 上確認。

### 2.2 普及程度

| 來源 | 對象與時間 | 結果 | 限制 |
|---|---|---|---|
| Siok 與 Liu，Scientific Reports，2018 [S3] | 香港大學 200 名母語為粵語的本科生 | 只用形碼 94 人（速成 72、倉頡 17、筆劃 3、手寫 2）；只用拼音或粵拼 97 人；兩類都用 9 人 | 研究為比較兩組而招募，兩組人數接近不代表全港比例；拼音與粵拼沒有分開計 |
| 香港政府統計處，主題性住戶統計調查第二十號報告書（2004 年調查）[S4] | 懂得使用中文輸入法的 10 歲及以上人士 | 最常用：鍵盤輸入 81.2%、手寫 18.4%、語音 0.5% | 電腦時代的數據；沒有倉頡、速成的細分；另外抽查第 27、32、73 號報告書（2006、2007、2021 年出版）[S39][S40][S41]，內文都沒有輸入法分類（只在附錄的舊報告書目錄提到），其餘年份未逐一查 |
| 十二年國民基本教育課程綱要 國語文 [S5] | 台灣國小第一學習階段 | 學習表現 3-Ⅰ-1「正確認念、拼讀及書寫注音符號」 | 證明注音是全體學生必學，不是使用率數據 |
| 波仕特線上市調，2011-12 [S6] | 台灣 | 注音約七成、嘸蝦米 10.7%、倉頡 9.9% | 原始報告已無法取得，只能經維基百科引用的存檔得知；屬二手來源 |

判斷：香港以速成為最多的形碼，台灣以注音為主。兩地都沒有找到 2020 年後具代表性的官方或學術調查，這一點列為資料缺口。

### 2.3 輸入法逐項

授權欄的判定以「將來可能上 App Store」為前提。

| 輸入法 | 主要地區 | iOS 內建 | 組字方法 | 需要的資料 | 可用資料來源與授權 | 判定 |
|---|---|---|---|---|---|---|
| 速成 | 香港 | 有 [S1] | 倉頡碼的首碼加尾碼，一或兩個字根，按空白選字 | 倉頡碼表、字序 | libcangjie `table.txt`，Public Domain [S13]（本專案已使用） | 可內建（已內建） |
| 倉頡 | 香港、台灣 | 有 [S1] | 依字形取一至五個字根 | 倉頡碼表、字序 | libcangjie（Public Domain，含第三代與第五代碼）[S13]；Unihan `kCangjie`（Unicode License v3）[S14]；rime-cangjie（LGPL-3.0）[S18] | libcangjie 可內建 |
| 筆劃 | 香港 | 有 [S1] | 依筆順輸入五種基本筆劃 | 每字筆順序列 | rime-stroke（LGPL-3.0）[S18]；寬鬆授權的筆順資料未找到 | 只限匯入，待查 |
| 手寫 | 香港、台灣 | 有 [S1] | 筆跡辨識，候選字 | 辨識模型 | Google ML Kit（本專案已使用） | 已內建 |
| 粵拼 | 香港 | 有（Phonetic）[S1][S2] | 粵語音節（可省聲調、可簡拼），整句組詞 | 字音表、詞庫、詞頻，懶音容錯規則 | rime-cantonese 主體 CC BY 4.0，`jyut6ping3.maps` 為 ODbL-1.0 [S17]；words.hk 字表、詞表、頻率表為公有領域 [S24]；Unihan `kCantonese`（每字一個最常用讀音）[S14]；OpenVanilla `jyutping.cin`（檔頭寫明可自由使用與再散布，但內容版權屬香港語言學學會，學會對第三方的許可沒有寫明）[S27] | words.hk、Unihan 可內建；rime-cantonese 有條件（見 4.3） |
| 注音 | 台灣 | 有（Standard、Grid、Dynamic）[S1] | 注音符號加聲調，整句自動選字 | 字音表、詞庫、詞頻 | 小麥注音 `Source/Data`（MIT，`BPMFBase.txt` 720 KB、`phrase.occ` 1.8 MB）[S15]；libchewing（LGPL-2.1）[S16]；rime-bopomofo、rime-essay（LGPL-3.0）[S18]；教育部辭典（CC BY-ND 3.0 TW，禁止改作）[S26] | 小麥注音資料可內建 |
| 漢語拼音 | 台灣、香港（少） | 有（QWERTY、10 鍵、雙拼）[S1] | 拼音音節，整句組詞 | 字音表、詞庫、詞頻 | 小麥注音的字音表含拼音欄（MIT）[S15]；Unihan `kMandarin`（Unicode License v3）[S14]；CC-CEDICT（CC BY-SA 4.0）[S25]；rime-luna-pinyin（LGPL-3.0）[S18] | 小麥注音、Unihan 可內建 |
| 嘸蝦米 | 台灣 | 沒有 | 依字形取英文字母字根 | 字根表 | 官方 iOS 版「蝦米鍵盤 2」寫明「此軟體為行易有限公司授權」提供 [S34]；由此推論字根表屬行易專有，沒有找到公開授權 | 不可內建；格式上可匯入，授權由使用者自行負責 |
| 大易 | 台灣 | 沒有 | 依字形取字根 | 碼表 | OpenVanilla `dayi3.cin`：太易資訊授權開放下載使用，不得改每字編碼後重新散布，可改格式 [S27] | 只限匯入（是否允許第三方隨 App 散布未寫明） |
| 行列 | 台灣 | 沒有 | 依字形取字根 | 碼表 | OpenVanilla `array30.cin`，出處 gontera/array30 [S27]；授權未查證 | 只限匯入 |
| 語音 | 香港、台灣 | 系統聽寫支援粵語（香港）與國語（台灣）[S1] | 語音辨識 | 不需要 | 沒有完整取用時鍵盤不能用麥克風 [S7]；有完整取用時的情況，現行文件沒有寫明（見 5.1）。維持 D18 的系統聽寫同步 | 不屬匯入範圍 |

### 2.4 鍵位

| 鍵位 | 用於 | iOS 內建 | 本專案現況 |
|---|---|---|---|
| QWERTY | 英文、拼音、粵拼 | 有 | 英文頁 |
| QWERTY 加倉頡字根鍵面 | 倉頡、速成 | 有 | 速成頁（字根大字、英文字母在角落） |
| 注音標準鍵位 | 注音 | 有（Zhuyin Standard）[S1] | 沒有 |
| 注音九宮格、動態 | 注音 | 有（Zhuyin Grid、Dynamic）[S1] | 沒有 |
| 拼音 10 鍵 | 拼音 | 有（Pinyin 10 Key）[S1] | 沒有 |
| 筆劃 | 筆劃 | 有（Stroke）[S1] | 沒有 |
| 手寫區 | 手寫 | 有 | 手寫頁 |

## 3. 統一：共用組字引擎

### 3.1 三類輸入法

| 類別 | 成員 | 引擎要做的事 | 資料形態 |
|---|---|---|---|
| 表格型 | 倉頡、速成、筆劃、大易、行列、嘸蝦米 | 輸入碼查表；限制碼長與可用鍵；候選字依權重或檔案次序；選字鍵 | 碼對字的表，可帶權重 |
| 拼音型 | 注音、拼音、粵拼 | 把連續輸入切成音節；在音節圖上組詞並以詞頻選出最佳句子；容錯（省聲調、簡拼、粵語懶音） | 字音表、詞庫、詞頻 |
| 辨識型 | 手寫、語音 | 交給辨識器 | 模型（手寫）；語音由系統處理 |

現有 `IMEInput` 已分開「按鍵」與「辨識結果」，`IMEOutput` 已有輸入碼、候選字、已提交文字，三類都可以用同一個介面（D15 的原意）。要補的是：

1. 一個資料驅動的 `TableInputMethod`，把現在的 `QuickInputMethod` 變成它的一種設定（碼長 2、碼表由倉頡表推導）。
2. 一個拼音型解碼器，供注音、拼音、粵拼共用；三者只差在音節表、鍵位與資料。
3. `ChineseInputMethodID` 由封閉 enum 改成「內建 ID 或匯入的資料包 ID」。
4. 候選字列已在速成頁存在，拼音型可以沿用，但候選字會變成詞，需要較寬的格子。

### 3.2 引擎選項

| 選項 | 內容 | 證據 | 優點 | 缺點 |
|---|---|---|---|---|
| 自寫 Swift 引擎 | 表格型與拼音型都自寫 | 本專案的速成已是自寫；粵拼輸入法（yuetyam/jyutping）用 Swift 寫 iOS 鍵盤，詞庫在建置時轉成 SQLite，以唯讀模式開啟 [S23] | 全 Swift，維持 XcodeGen 與 SwiftPM 建置；記憶體可控；授權最乾淨 | 拼音型的整句選詞品質要自己做和調 |
| 內嵌 librime | 用 RIME 引擎處理全部表格型與拼音型 | librime 為 BSD-3-Clause，依賴 Boost、LevelDB、marisa、OpenCC、yaml-cpp，授權都屬寬鬆型（marisa 為 BSD-2-Clause 或 LGPL-2.1 擇一）[S19][S35]；「仓输入法」以 librime 做 iOS 鍵盤並已上架 App Store，2026-11-20 查到版本 2.19.13、大小 73,332,736 bytes [S22] | 引擎成熟，可直接用 RIME 方案生態 | C++ 跨平台建置；App 變大；官方方案多為 LGPL-3.0，內建資料仍要另找；Lua 外掛不能用（見 5.4） |
| 借用小麥注音引擎 | 用小麥注音的組詞引擎處理注音與拼音 | 小麥注音整個 repo 為 MIT [S15] | 注音品質已被大量使用者驗證 | 只涵蓋國語；粵拼仍要另做；C++ 與 Swift 混合 |

### 3.3 資料的儲存與讀取

| 方式 | 適合 | 記憶體 |
|---|---|---|
| 全部讀進 Swift `Dictionary` | 小表（現在的速成表） | 條數越多用量越大，大詞庫不可行（實測見 5.2） |
| 唯讀 SQLite | 詞庫、要前綴查詢的表 | SQLite 預設不用記憶體映射，資料頁會讀進自己的快取（計入 footprint），要設 `PRAGMA mmap_size` 才改用映射 [S37]；yuetyam/jyutping 在 iOS 鍵盤以 `SQLITE_OPEN_READONLY` 開啟，沒有設定 `mmap_size` [S23] |
| 排序後的二進位檔或 trie，以記憶體映射讀取 | 大碼表 | librime 的 `.table.bin`、`.prism.bin` 就是編譯後以 `boost::interprocess::file_mapping` 映射 [S19][S20] |

## 4. 自訂與匯入

### 4.1 匯入格式比較

| 格式 | 內容 | 適合 | 限制 |
|---|---|---|---|
| `.cin` 碼表 | 純文字；`%ename`、`%cname`、`%encoding`、`%selkey`（選字鍵）、`%endkey`、`%keyname begin…end`（鍵名，即鍵面字根）、`%chardef begin…end`（每行「碼 空白 字」）[S27] | 表格型 | 沒有權重欄，候選次序只能靠檔案次序；沒有詞頻與容錯規則，不適合拼音型；檔頭多數沒有授權聲明 |
| RIME `.dict.yaml` | YAML 檔頭（`name`、`version`、`sort`、`columns`、`import_tables`）加 `...` 之後的表格，每行「字詞、碼、權重」[S20] | 表格型與拼音型的詞庫 | 碼與碼之間用空白分音節；有的詞庫只列詞不列碼，要靠其他字表推導讀音（例如 rime-cantonese 的 `jyut6ping3.phrase.dict.yaml`）；有的方案靠 `.schema.yaml` 的拼寫運算把詞庫的碼轉成另一種輸入碼，例如 rime-bopomofo 用 `terra_pinyin`（拼音）詞庫，再以 `pinyin_to_zhuyin` 等規則轉成注音 [S38]，只匯入詞庫打不出注音 |
| RIME `.schema.yaml` | 引擎設定：processors、segmentors、translators、filters，拼寫運算（正規表示式）等 [S20] | 只對 librime 有意義 | 自寫引擎無法完整重現；可含 Lua 腳本外掛（librime-lua）[S21] |
| 自訂 JSON 鍵位檔 | 每行的鍵、輸出、鍵面文字、寬度、長按、層 | 鍵位 | 要自己定義與維護版本 |
| Unicode LDML Keyboard 3.0（UTS #35 第 7 部分，CLDR 49）[S29] | XML；有觸控用的 `<layers formId="touch">`、`minDeviceWidth`、長按、`flicks`（滑動）、`transforms` | 鍵位的交換格式 | 規格自述為交換格式，預期轉成精簡格式再使用 [S29]；規格內容是按鍵到字元的對應與轉換，沒有候選字詞典的機制（推論，規格沒有明文排除） |

`.cin` 與現有字碼表的關係：本專案的 `quick-table.txt`（`碼<TAB>字`）與 `.cin` 的 `%chardef` 內容格式相近，但 `QuickDictionary` 只接受 TAB 分隔與一至兩個小寫字母的碼。改成 `.cin` 匯入時，解析要同時接受空白與 TAB，碼長上限要放寬，之後就可以取代現在的專用格式。`.cin` 的 `%keyname` 也提供鍵面字根，例如 `simplex.cin` 把 `a` 標為「日」[S27]，等於免費得到速成頁現在寫死的 `CangjieRadicals`。

### 4.2 iOS 上的匯入流程

| 步驟 | 在哪裡做 | 依據 |
|---|---|---|
| 1. 使用者在主 App 選檔（「檔案」App、AirDrop、Safari 下載後「以 App 開啟」） | 主 App | Keyman 的 iOS 版可以從 Safari 開啟 `.kmp` 鍵盤包，或在 App 內「Install From File」[S30] |
| 2. 驗證：UTF-8、碼只含允許的鍵、行數與檔案大小上限、重複項 | 主 App | 解析大檔會用大量記憶體（第 5.2 節），不能在鍵盤擴充程式做 |
| 3. 編譯成唯讀檔（排序二進位檔；若用 SQLite 要開 `mmap_size`），加一份 JSON 說明（名稱、類別、鍵位、來源、授權聲明） | 主 App | 與手寫模型同一個模式：主 App 準備，鍵盤匯入（`ModelImporter`）；記憶體見 3.3 |
| 4. 寫入 App Group | 主 App | 主 App 寫入沒有限制 |
| 5. 鍵盤以唯讀、記憶體映射方式開啟 | 鍵盤 | 沒有完整取用時能否讀 App Group，Apple 新舊文件說法不同，見 5.3 |
| 6. 內建輸入法的資料放在鍵盤擴充程式自己的 bundle | 鍵盤 | App Review 4.4.1 要求沒有完整取用也能正常作為鍵盤 [S11] |

### 4.3 資料來源授權總表

| 資料來源 | 授權 | 內建判定 | 條件或理由 |
|---|---|---|---|
| libcangjie `table.txt` | Public Domain [S13] | 可（有殘餘風險） | 已隨 App 附 Unicode License 與 Wittern 授權句（`quick-table-LICENSE.txt`）。殘餘風險：資料自述部分來自 Wan Leung Wong 原版 libcangjie，該部分的授權未查證；T12b 當時以「自用 demo」前提接受這個風險，改用 App Store 前提後要重新確認。後備來源：Unihan `kCangjie` |
| Unihan（`kCangjie`、`kCantonese`、`kMandarin`） | Unicode License v3 [S14] | 可 | 附版權與許可聲明 |
| 小麥注音 `Source/Data` | MIT [S15] | 可 | 附 MIT 聲明 |
| rime-cantonese | 主體 CC BY 4.0；`jyut6ping3.maps` 為 ODbL-1.0 [S17] | 有條件 | CC BY 4.0 要求署名、保留版權與授權聲明及連結、標明已修改（轉成二進位檔即屬修改）[S33]；另有「不得加附加條款或技術保護措施」的條款，見本節最後一段。ODbL 檔不用 |
| words.hk 字表、詞表、頻率表 | 公有領域，站方希望註明出處 [S24] | 可 | 只限分析頁列出的這幾份資料，不含字典釋義 |
| OpenCC | Apache-2.0 [S28] | 可 | 需要港台字形轉換時才用 |
| librime 與依賴 | BSD-3-Clause、BSL-1.0、MIT、BSD-2-Clause 等 [S19][S35] | 可 | 只在選方向 C 時需要 |
| RIME 官方方案（luna-pinyin、bopomofo、cangjie、quick、stroke、essay、prelude） | LGPL-3.0 [S18] | 只限匯入 | 與「保留所有權利」及 App Store 條款有衝突風險 |
| libchewing | LGPL-2.1 [S16] | 只限匯入 | 同上；repo 已遷往 Codeberg |
| CC-CEDICT | CC BY-SA 4.0 [S25] | 只限匯入 | 衍生資料須以相同授權釋出 |
| 教育部《重編國語辭典修訂本》等 | CC BY-ND 3.0 TW [S26] | 不可轉成詞庫 | 允許商業重製與散布，但不得修改；轉成詞頻表屬改作 |
| OpenVanilla `jyutping.cin` | 檔頭寫明可自由使用與再散布並保留聲明；內容版權屬香港語言學學會 [S27] | 只限匯入 | 學會對第三方的許可沒有寫明 |
| OpenVanilla `dayi3.cin` | 太易資訊授權開放下載使用 [S27] | 只限匯入 | 第三方隨 App 散布是否包含在內沒有寫明 |
| 嘸蝦米字根表 | 推論為行易有限公司專有（官方 iOS 版寫明由行易授權）[S34] | 不可 | 使用者自行匯入時，授權由使用者自行負責 |
| KeyboardKit | 目前為閉源授權，進階功能要付費授權 [S31] | 不採用 | 「仓输入法」README 的第三方套件清單仍把 KeyboardKit 標為 MIT [S22]，由此推論早期版本曾是 MIT（未核對 KeyboardKit 舊版的 LICENSE） |
| Keyman | MIT [S30] | 可參考 | 匯入流程的先例 |

App Store 與授權條款：

- FSF 在 2010 年指出 App Store 的使用條款對散布加上限制，與 GPLv2 第 6 條衝突 [S32]。GPL、LGPL、CC BY-SA 一律不內建。
- CC BY 4.0 第 2(a)(5)(B) 條：不得對收受者加上附加或不同的條款，也不得加上會限制收受者行使授權權利的技術保護措施 [S33]。CC 官方 FAQ 對「分享 CC 素材時可否使用技術保護措施（例如 DRM）」直接答「No」，並說明附加條款也不行；FAQ 同時說，只是轉成難以取用或只限某些平台的格式，不算違反 [S36]。
- 隨 App Store 散布的 App 受 Apple 的使用條款規範，與 FSF 指出的是同類問題；App Store 的加密是否涵蓋 App 內的資源檔，沒有找到一手來源。
- 因此 rime-cantonese 隨 App 內建屬有條件可用。三個做法：(a) 向 rime-cantonese 維護者（CanCLID）取得書面許可，FAQ 也說取得授權人明示許可即可；README 沒有寫明版權屬誰，要先確認 CanCLID 有權代表所有貢獻者授權，確認前用 (b)；(b) 內建只用 words.hk 與 Unihan，rime-cantonese 改為使用者在主 App 自行從上游下載或匯入，我們不散布；(c) 維持內建並列為已知法律風險。推薦 (a)，未取得許可前用 (b)。

## 5. iOS 鍵盤擴充程式的限制

### 5.1 一覽

| 限制 | 內容 | 來源 |
|---|---|---|
| 記憶體上限 | 鍵盤在獨立行程執行，有記憶體上限，超過即被系統終止；上限依機型而不同；收起鍵盤不一定結束行程 | Apple [S8] |
| 擴充程式的上限比 App 低 | 「Extensions have a much lower footprint」；計入上限的是 dirty 與 compressed 記憶體，唯讀的記憶體映射檔屬 clean，不計入 | WWDC18 Session 416 [S10] |
| 本專案實測 | iPhone 17 Pro（iOS 27.0.1）上限約 177 MB，手寫峰值 85.8 MB | `T12-o7-result.md` |
| 完整取用 | 沒有完整取用：不能上網、不能寫入共享容器（可以讀）、不能用麥克風與喇叭；開啟完整取用的作用是「Enable network access and write access to a shared group container」，並可與容器 App 共用容器 | Apple [S7] |
| 麥克風 | 現行文件只在「沒有完整取用」一欄列出不能用麥克風，有完整取用時沒有寫明 [S7]；iOS 8 時代的舊版指南寫鍵盤擴充程式完全不能用麥克風 [S9]。本專案不在鍵盤內做聽寫，沿用 D18 | Apple [S7][S9] |
| 必須能在沒有完整取用時運作 | 4.4.1：要提供鍵盤輸入、切換下一個鍵盤，不得要求完整取用 | App Review [S11] |
| 不得下載可執行程式碼 | 2.5.2：不得下載、安裝或執行會新增或改變功能的程式碼 | App Review [S11] |
| 補充詞彙 | `requestSupplementaryLexicon` 可取得通訊錄姓名、使用者在設定裡的文字替代、常用字 | Apple [S12] |

### 5.2 記憶體實測（Mac，不代表實機）

在 Mac（arm64，macOS 27.2.1）以 `swiftc -O` 編譯的小程式量 `phys_footprint`，同一組檔案量三次，最多相差 0.1 MB。程式與原始輸出見附錄 A。

| 資料 | 條數 | 方式 | 增加的 footprint |
|---|---|---|---|
| 本專案 `quick-table.txt` | 13,980 | 讀進 `[String: [String]]` | 1.9 MB |
| rime-cantonese `jyut6ping3.chars` 加 `words` | 137,439 | 讀進 `[String: [String]]` | 31.1 MB |
| 同上兩個檔，另加 `phrase`（約 8 MB 文字） | 468,242 行 | `Data(contentsOf:options: .alwaysMapped)` 並逐 byte 掃過 | 0.0 MB |

結論：大詞庫建議用記憶體映射的排序檔，或開了 `mmap_size` 的唯讀 SQLite。在 iPhone 17 Pro 上，手寫峰值加 31 MB 仍低於上限；但手寫已用掉約一半上限，而上限依機型而不同 [S8]，舊機型的餘裕可能不足；實機數字列為 TBD。

### 5.3 App Group 在沒有完整取用時是否可讀

- Apple 現行文件寫明沒有完整取用時，鍵盤對容器 App 的共享容器是唯讀 [S7]。
- Apple 舊版指南則寫預設情況下鍵盤「cannot share a container with its containing app」[S9]，與現行文件不一致。
- 本專案設計文件 §3 第 11 點寫「Full Access 關閉時，Extension 能否讀取 App Group 中主 App 寫入的設定未實測」；O3 證明鍵盤讀得到主 App 寫入的值，但沒有記錄當時完整取用是否關閉。Windows／Linux 接收端設計則寫「鍵盤在沒有 Full Access 時讀不到 Keychain 與 App Group」。
- Apple 新舊文件互相矛盾，本專案也沒有實測，這一項是匯入功能最先要做的實機確認（TBD）。結果決定匯入的輸入法在沒有完整取用時能不能用；讀不到時，退回 bundle 內的內建輸入法。

### 5.4 RIME 方案與 App Review 2.5.2

- `.dict.yaml` 是資料，匯入沒有 2.5.2 的問題。
- `.schema.yaml` 是設定；若方案用 librime-lua [S21] 的 Lua 腳本，匯入後執行就是執行下載的程式碼，屬 2.5.2 的風險。不論選哪個方向，都不執行匯入的腳本。

## 6. 方向

| | A：表格引擎加 `.cin` 匯入 | B：Swift 兩層引擎加資料匯入（推薦） | C：內嵌 librime |
|---|---|---|---|
| 內容 | 把速成改成通用表格引擎；內建倉頡、速成；匯入 `.cin`（大易、行列、倉頡五代等）；鍵面字根取自 `%keyname` | A 的全部，加上拼音型解碼器；內建注音與拼音（小麥注音資料）、粵拼（words.hk 加 Unihan，取得許可後加 rime-cantonese）；匯入 `.cin`、自帶完整編碼的 RIME `.dict.yaml`、自訂詞；JSON 鍵位檔（注音標準、九宮格等） | 以 librime 處理所有表格型與拼音型；匯入完整 RIME 方案（不含 Lua） |
| 涵蓋 | 香港形碼使用者、台灣形碼小眾 | 港台主流：速成、倉頡、注音、粵拼、拼音 | 同 B，另可直接用依賴拼寫運算的現成 RIME 方案（例如 rime-bopomofo） |
| 內建資料授權 | 乾淨（libcangjie 殘餘風險見 4.3） | 乾淨（MIT、公有領域、Unicode；libcangjie 殘餘風險同 A）；rime-cantonese 要先取得許可 | 官方方案多為 LGPL-3.0，內建資料仍要用 B 的來源 |
| 記憶體 | 低 | 中，靠記憶體映射控制 | 引擎加 OpenCC 的常駐用量要實機量 |
| 建置 | 不變 | 不變（全 Swift） | 要為 iOS 交叉編譯 C++ 與五個依賴 |
| 主要風險 | 對台灣主流（注音）沒有幫助 | 整句選詞品質要自己調 | 建置與體積；與現有 SwiftPM、CocoaPods 並存 |
| 工作量 | 小 | 大，可分步 | 中到大，建置不確定性最高 |

推薦 B，分四步，每步是獨立的 Task，並有一個品質門檻：

1. B1：通用表格引擎與 `.cin` 匯入（等於方向 A）。現有速成改為表格引擎的一種設定，加倉頡；主 App 匯入、編譯、寫入 App Group；`ChineseInputMethodID` 改為可容納匯入項目。第一個實機項目是 5.3 的 App Group 讀取。
2. B2：注音。拼音型解碼器、注音標準鍵位、小麥注音資料；台灣最大族群。
3. 品質門檻：B2 完成後，以固定測例量首選正確率，並與 iOS 內建注音比較；門檻數字由使用者在 spec 階段決定。未過門檻時先改解碼器，不開始 B3。
4. B3：粵拼。共用 B2 的解碼器，加省聲調、簡拼與懶音容錯；資料先用 words.hk 與 Unihan，取得許可後加 rime-cantonese（4.3）。
5. B4：JSON 鍵位檔與 RIME `.dict.yaml` 匯入；注音九宮格、拼音 10 鍵等版面。

理由：

- 內建資料不論選哪個方向都只能用寬鬆授權的來源，所以 C 的「現成方案生態」只對使用者自行匯入有幫助。B4 的 `.dict.yaml` 匯入只涵蓋自帶完整編碼的詞庫（例如 rime-cangjie、rime-cantonese 的單字與詞語表）；依賴 `.schema.yaml` 拼寫運算的方案（例如 rime-bopomofo）匯入詞庫也打不出來，這是 C 勝過 B 的地方。
- 全 Swift 符合現有 XcodeGen 加 SwiftPM 的建置，不必再加 C++ 交叉編譯。
- B1 本身就能交付，而且直接重用速成的測試與 UI。
- B 的主要風險是整句選詞品質；iOS 已內建注音與粵語拼音，使用者會直接拿來比較，所以把品質門檻放在 B2 與 B3 之間。若 B2 長期過不了門檻，再回頭評估 C 或借用小麥注音引擎（3.2）。

## 7. 驗收計畫（供之後的 spec 使用）

| 類別 | 項目 |
|---|---|
| 自動 | `.cin`、`.dict.yaml`、JSON 鍵位檔的解析器單元測試（含格式錯誤、超過上限）；表格引擎與現有速成行為一致；拼音型解碼器以固定測例量首選正確率；編譯後檔案的查詢結果與原始文字檔一致 |
| 自動 | 模擬器上量鍵盤 footprint（只作參考） |
| 實機 TBD | 沒有完整取用時讀取 App Group 匯入資料 |
| 實機 TBD | 匯入 10 萬條以上詞庫後的鍵盤 footprint，與手寫同時使用時的峰值 |
| 實機 TBD | 打字延遲 P95；舊機型（記憶體較小）上不被終止 |
| 實機 TBD | B2 品質門檻：iOS 內建注音與 B2 解碼器用同一組測例比較首選正確率（iOS 內建鍵盤無法自動量） |

## 8. 未解決事項

1. 港台近年具代表性的輸入法使用率數據沒有找到。
2. App Group 在沒有完整取用時是否可讀：Apple 新舊文件互相矛盾，本專案文件說未實測或不行（5.3）。
3. rime-cantonese 隨 App Store 散布：CC 官方 FAQ 表示分享時不可加 DRM 或附加條款；App Store 加密是否涵蓋資源檔沒有一手來源。要先向維護者取得許可（4.3）。
4. libcangjie 上游（Wan Leung Wong 原版）資料授權未查證；上 App Store 前要重新確認或改用 Unihan `kCangjie`（4.3）。
5. 大易、行列、香港語言學學會粵拼詞表能否由第三方隨 App 散布，條款不明。
6. 寬鬆授權的筆劃筆順資料未找到。
7. 拼音型解碼器的品質門檻要在 spec 階段由使用者決定（第 6 節）。

## 9. 使用者決定：方向 C（2026-11-20）

### 9.1 決定與理由

| 項目 | 內容 |
|---|---|
| 決定 | 方向 C：以 librime 作為所有表格型與拼音型輸入法的組字引擎 |
| 理由（使用者） | 將來可能推出 Android 版；方向 B 的 Swift 引擎不能直接在 Android 使用，會有通用性問題 |
| 第 6 節原本的評估 | 推薦 B 時沒有把 Android 列為條件；加入這個條件後，C 的跨平台優勢成為主要因素 |

### 9.2 Android 與 iOS 的證據

| 事實 | 來源 |
|---|---|
| librime 是跨平台 C++ 的輸入法引擎，授權 BSD-3-Clause | librime README [S19] |
| librime README 列出的前端包括 iOS 的 Hamster、Songyan，以及 Android 的 Trime、Songyan、YuyanIme | librime README 的 Frontends 一節 [S19] |
| librime 官方的建置說明只有 Linux、macOS、Windows，官方 CI 也只有這三個平台；iOS 與 Android 的版本由各前端自行交叉編譯 | librime README 與 `.github/workflows` [S19] |
| Trime（Android）以 JNI 包裝 librime，授權 GPL-3.0，只能參考做法，不能複製程式碼 | osfans/trime [S42] |
| YuyanIme（Android，以 librime 為基礎）授權 BSD-3-Clause | gurecn/YuyanIme [S43] |
| 「仓输入法」以 librime 做 iOS 鍵盤並已上架 App Store | [S22] |

### 9.3 方向 C 之下仍然成立的研究結論

| 結論 | 在方向 C 的做法 | 章節 |
|---|---|---|
| RIME 官方方案多為 LGPL-3.0，不內建 | 內建方案的 `.schema.yaml` 與 `.dict.yaml` 由我們用寬鬆授權資料自行編寫：倉頡與速成用 libcangjie，注音與拼音用小麥注音資料，粵拼用 words.hk 與 Unihan（rime-cantonese 待許可） | 4.3 |
| 不執行匯入方案中的 Lua | 不編入 librime-lua；匯入時拒絕或略過含 Lua 的設定 | 5.4 |
| 大詞庫要記憶體映射 | librime 本身已把編譯後的 `.table.bin`、`.prism.bin` 以記憶體映射讀取 | 3.3 |
| 方案編譯不放在鍵盤內 | RIME 會把文字詞典編譯成 `.bin` [S20]；由主 App 編譯後寫入 App Group，鍵盤只讀取 | 4.2 |
| App Group 在沒有完整取用時是否可讀 | 不變，仍是第一個實機確認項目 | 5.3 |
| 鍵位 | librime 不管鍵位，仍需要自訂 JSON 鍵位檔；同一份 JSON 可供 iOS 與 Android 共用 | 4.1 |

### 9.4 方向 C 新增、要在 spec 階段處理的事項

| 事項 | 說明 |
|---|---|
| iOS 建置 | 把 librime 與 Boost、LevelDB、marisa、OpenCC、yaml-cpp 交叉編譯成 xcframework，再接到現有的 XcodeGen、CocoaPods、SwiftPM 建置 |
| 記憶體 | librime 加上內建方案在鍵盤擴充程式內的 footprint，以及與手寫同時使用時的峰值（實機 TBD） |
| App 大小 | 加入 librime 後 IPA 增加多少；「仓输入法」整個 App 約 73 MB 可作參考 [S22] |
| 使用者詞庫 | librime 的使用者詞庫以 LevelDB 寫入；沒有完整取用時，鍵盤只能寫自己的沙盒容器 [S7]，所以學習紀錄放在鍵盤容器，不放 App Group（建議） |
| OpenCC | 是否需要港台字形轉換；不需要時可不編入，以減少大小 |
| 與現有介面的接法 | librime 包成一個 `ChineseInputMethod` 實作，手寫維持 ML Kit；確認 `IMEInput`、`IMEOutput` 是否足以表達 librime 的候選字分頁與輸入碼 |
| Android | 只做到「引擎、方案、鍵位 JSON 可共用」的設計；Android 鍵盤本身不在這次範圍 |

### 9.5 建議的分步（待 spec 確認）

1. C1 技術驗證：iOS 版 librime xcframework，鍵盤內載入一個內建方案（速成），量 footprint、延遲與 App 大小；同時確認 5.3 的 App Group 讀取。
2. C2 內建方案：倉頡、速成、注音、粵拼，資料只用 4.3 判定可內建的來源。
3. C3 匯入：主 App 匯入 RIME 方案（`.schema.yaml` 加 `.dict.yaml`，不含 Lua）與 `.cin`（轉成 RIME 詞典），編譯後寫入 App Group。
4. C4 鍵位：JSON 鍵位檔，注音標準、九宮格、拼音 10 鍵等版面。

## 來源

一手來源的擷取日期皆為 2026-11-20，除非另註。

- [S1] Apple，iOS & iPadOS Feature Availability（QuickType Keyboard: Language Support；Dictation）：https://www.apple.com/ios/feature-availability/
- [S2] Apple，Chinese and Cantonese Input Method User Guide，Enter Cantonese characters using Phonetic - Cantonese on Mac：https://support.apple.com/guide/chinese-input-method/cimcba750589/mac
- [S3] Siok W.T.、Liu C.Y.，Differential impacts of different keyboard inputting methods on reading and writing skills，Scientific Reports，2018，DOI 10.1038/s41598-018-35268-9；全文 PMC6249315：https://pmc.ncbi.nlm.nih.gov/articles/PMC6249315/
- [S4] 香港政府統計處，主題性住戶統計調查第二十號報告書（統計摘要第 5 頁）：https://www.censtatd.gov.hk/en/data/stat_report/product/B1130201/att/B11302202004XXXXB0100.pdf
- [S5] 國家教育研究院，十二年國民基本教育課程綱要 國民中小學暨普通型高級中等學校 語文領域－國語文（學習表現「標音符號與運用」）：https://www.naer.edu.tw/upload/1/16/doc/806/十二年國民基本教育課程綱要國民中小學暨普通型高級中等學校語文領域-國語文.odt
- [S6] 維基百科「倉頡輸入法」使用狀況一節，引用「Pollster波仕特線上市調：七成以上民眾使用注音輸入法」（2011-12-12，原頁只餘存檔）：https://zh.wikipedia.org/zh-tw/倉頡輸入法 （二手來源）
- [S7] Apple，Configuring open access for a custom keyboard：https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- [S8] Apple，Creating a custom keyboard（Manage memory）：https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- [S9] Apple，App Extension Programming Guide：Custom Keyboard（封存文件）：https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
- [S10] Apple，WWDC18 Session 416 iOS Memory Deep Dive：https://developer.apple.com/videos/play/wwdc2018/416/
- [S11] Apple，App Store Review Guidelines（2.5.2、4.4.1）：https://developer.apple.com/app-store/review/guidelines/
- [S12] Apple，UILexicon：https://developer.apple.com/documentation/uikit/uilexicon
- [S13] libcangjie，`data/README.table.md`：https://gitlab.freedesktop.org/cangjie/libcangjie/-/raw/main/data/README.table.md （本專案查證紀錄：`docs/superpowers/verification/evidence/T12b-o9-license.md`）
- [S14] Unicode，UAX #38 Unicode Han Database（Unicode 18.0.0；`kCantonese`、`kCangjie`、`kMandarin`）：https://www.unicode.org/reports/tr38/ ；Unicode License v3：https://www.unicode.org/license.txt
- [S15] openvanilla/McBopomofo（MIT；`Source/Data`）：https://github.com/openvanilla/McBopomofo
- [S16] chewing/libchewing（LGPL-2.1）：https://github.com/chewing/libchewing
- [S17] rime/rime-cantonese（README 授權段：主體 CC BY 4.0，`jyut6ping3.maps` 為 ODbL-1.0）：https://github.com/rime/rime-cantonese
- [S18] RIME 官方方案的授權欄（GitHub API）：https://github.com/rime/rime-luna-pinyin 、https://github.com/rime/rime-bopomofo 、https://github.com/rime/rime-cangjie 、https://github.com/rime/rime-quick 、https://github.com/rime/rime-stroke 、https://github.com/rime/rime-essay 、https://github.com/rime/rime-prelude
- [S19] rime/librime（BSD-3-Clause；README 的依賴清單；`src/rime/dict/mapped_file.cc`）：https://github.com/rime/librime
- [S20] RIME 官方 wiki，Rime 方案製作詳解：https://github.com/rime/home/wiki/RimeWithSchemata
- [S21] hchunhui/librime-lua：https://github.com/hchunhui/librime-lua
- [S22] imfuxiao/Hamster（README：v2.1.0 起改為 MIT，之後不再開源）：https://github.com/imfuxiao/Hamster ；App Store「仓输入法」：https://apps.apple.com/cn/app/id6446617683
- [S23] yuetyam/jyutping（CC0-1.0；詞庫來自 rime-cantonese；`Modules/CoreIME/Sources/CoreIME/Engine.swift`）：https://github.com/yuetyam/jyutping ；App Store：https://apps.apple.com/app/id1509367629
- [S24] words.hk 數據分析頁（Data License: public domain）：https://words.hk/faiman/analysis/
- [S25] MDBG，CC-CEDICT 下載頁（CC BY-SA 4.0）：https://www.mdbg.net/chinese/dictionary?page=cedict
- [S26] 教育部終身教育司，線上辭典簡介（第四點授權說明）：https://depart.moe.edu.tw/ed2400/cp.aspx?n=D509C3C9F6F496FD
- [S27] openvanilla/openvanilla `DataTables`（`simplex.cin`、`cj.cin`、`bpmf.cin`、`jyutping.cin`、`dayi3.cin`、`array30.cin` 檔頭）：https://github.com/openvanilla/openvanilla/tree/master/DataTables
- [S28] BYVoid/OpenCC（Apache-2.0）：https://github.com/BYVoid/OpenCC
- [S29] Unicode，UTS #35 Part 7 Keyboards（LDML Keyboard 3.0，CLDR 49）：https://www.unicode.org/reports/tr35/tr35-keyboards.html
- [S30] Keyman for iPhone and iPad，Installing Custom Keyboards/Dictionaries：https://help.keyman.com/products/iphone-and-ipad/18.0/basic/installing-custom-keyboards-dictionaries ；keymanapp/keyman（MIT）：https://github.com/keymanapp/keyman
- [S31] KeyboardKit LICENSE：https://github.com/KeyboardKit/KeyboardKit/blob/main/LICENSE
- [S32] FSF，GPL Enforcement in Apple's App Store（2010-05）：https://www.fsf.org/news/2010-05-app-store-compliance
- [S33] Creative Commons，CC BY 4.0 Legal Code（2(a)(4)、2(a)(5)(B)、3(a)(1)）：https://creativecommons.org/licenses/by/4.0/legalcode.en ；CC BY-SA 4.0 Legal Code：https://creativecommons.org/licenses/by-sa/4.0/legalcode.en
- [S34] 嘸蝦米官方網站，蝦米鍵盤 2 產品介紹：https://boshiamy.com/product_ixhiamy_2.php
- [S35] s-yata/marisa-trie COPYING（BSD-2-Clause OR LGPL-2.1-or-later）：https://github.com/s-yata/marisa-trie
- [S36] Creative Commons，Frequently Asked Questions（Can I use effective technological measures (such as DRM) when I share CC-licensed material?）：https://creativecommons.org/faq/
- [S37] SQLite，Memory-Mapped I/O：https://www.sqlite.org/mmap.html
- [S38] rime/rime-bopomofo `bopomofo.schema.yaml`（`dictionary: terra_pinyin`、`zhuyin:/pinyin_to_zhuyin`）：https://github.com/rime/rime-bopomofo/blob/master/bopomofo.schema.yaml
- [S39] 香港政府統計處，主題性住戶統計調查第二十七號報告書（2006 年出版）：https://www.censtatd.gov.hk/en/data/stat_report/product/C0000031/att/B11302272006XXXXB0100.pdf
- [S40] 香港政府統計處，主題性住戶統計調查第三十二號報告書（2007 年出版）：https://www.censtatd.gov.hk/en/data/stat_report/product/B1130201/att/B11302322007XXXXB0100.pdf
- [S41] 香港政府統計處，主題性住戶統計調查第 73 號報告書（2021 年出版）：https://www.censtatd.gov.hk/en/data/stat_report/product/C0000031/att/B11302732021XXXXB0100.pdf
- [S42] osfans/trime（GPL-3.0；`app/src/main/jni` 內含 librime 與 `librime_jni`）：https://github.com/osfans/trime
- [S43] gurecn/YuyanIme（BSD-3-Clause）：https://github.com/gurecn/YuyanIme

## 附錄 A：5.2 節記憶體量測

程式（`main.swift`，以 `swiftc -O main.swift -o measure` 編譯）：

```swift
import Darwin
import Foundation

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let args = CommandLine.arguments
let mode = args[1]
let files = Array(args.dropFirst(2))
let base = footprintMB()
var keep: Any = 0
var lines = 0
switch mode {
case "dict":
    // code -> [text], as a keyboard would hold a table fully in memory.
    var table: [String: [String]] = [:]
    for f in files {
        let text = try! String(contentsOfFile: f, encoding: .utf8)
        var body = !f.hasSuffix(".yaml")
        for line in text.split(separator: "\n") {
            if !body { if line == "..." { body = true }; continue }
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t")
            guard fields.count >= 2 else { continue }
            let code = String(fields[1]).replacingOccurrences(of: " ", with: "")
            let textField = f.hasSuffix(".yaml") ? fields[0] : fields[1]
            let key = f.hasSuffix(".yaml") ? code : String(fields[0])
            table[key, default: []].append(String(textField))
            lines += 1
        }
    }
    keep = table
case "mmap":
    var datas: [Data] = []
    for f in files {
        let d = try! Data(contentsOf: URL(fileURLWithPath: f), options: .alwaysMapped)
        // Touch every page by scanning for newlines, as a lookup scan would.
        lines += d.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        datas.append(d)
    }
    keep = datas
default: break
}
let after = footprintMB()
print(String(format: "%@ lines=%d base=%.1fMB after=%.1fMB delta=%.1fMB", mode, lines, base, after, after - base))
withExtendedLifetime(keep) {}
```

輸入檔：本專案 `iOS/RemoteKeyboardExtension/Resources/quick-table.txt`；rime-cantonese commit `259f0e48bba840c3a2e0d117539e96937f3d89bc`（2026-11-20 的 `main`）的 `jyut6ping3.chars.dict.yaml`（345,329 bytes）、`jyut6ping3.words.dict.yaml`（2,630,257 bytes）、`jyut6ping3.phrase.dict.yaml`（4,958,423 bytes）。`phrase` 檔只列詞、沒有碼欄，所以 `dict` 模式只用 `chars` 與 `words`。

原始輸出：

```text
dict lines=13980 base=1.8MB after=3.7MB delta=1.9MB
dict lines=137439 base=1.8MB after=32.9MB delta=31.1MB
dict lines=137439 base=1.8MB after=32.9MB delta=31.1MB
dict lines=137439 base=1.8MB after=32.9MB delta=31.2MB
mmap lines=137465 base=1.8MB after=1.8MB delta=0.0MB
mmap lines=468242 base=1.8MB after=1.8MB delta=0.0MB
```

第 2 至 4 行是同一組檔案的三次量測。第 5 行只映射 `chars` 與 `words`，第 6 行另加 `phrase`；兩者行數包含 YAML 檔頭。
