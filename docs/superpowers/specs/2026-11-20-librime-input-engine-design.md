# librime 中文輸入引擎（D31）

**日期**：2026-11-20｜**狀態**：APPROVED（使用者 2026-11-20 批准）｜**前身**：`docs/superpowers/research/2026-11-20-hk-tw-keyboards-and-import.md`（PR #151，第 9 節記錄使用者選擇方向 C）

## 1. 目的

使用者要求「先列出現時香港及台灣常用的鍵盤，研究如何能統一及自訂匯入鍵盤」。研究結論是：港台常用的中文輸入法（速成、倉頡、注音、粵拼、拼音）可以分成表格型與拼音型，用一個組字引擎處理；使用者也應該能匯入自己的方案與鍵位。

使用者選擇以 librime（RIME 輸入法引擎）作為這個組字引擎，理由是將來可能推出 Android 版，引擎、輸入方案與鍵位描述要能跨平台共用；自寫 Swift 引擎無法在 Android 直接使用。

本設計涵蓋四步：C1 技術驗證、C2 內建輸入法、C3 匯入、C4 鍵位。實作計畫一次只做一步，每步是獨立的 Task。

## 2. 目標、非目標、反目標

| 類別 | 內容 |
|---|---|
| 目標 | iPhone 鍵盤的中文頁由 librime 處理速成、倉頡、注音、粵拼、拼音；手寫維持 Google ML Kit |
| 目標 | 使用者可以在主 App 匯入 RIME 方案與 `.cin` 碼表（C3），以及 JSON 鍵位檔（C4） |
| 目標 | 引擎原始碼、輸入方案、詞典來源與鍵位檔都不綁定 iOS，將來可給 Android 使用 |
| 非目標 | Android 鍵盤本身；Mac、Windows、Linux 接收端的任何改動（接收端只收已提交文字） |
| 非目標 | 聯想字、雲端輸入、Lua 外掛、OpenCC 繁簡轉換功能、使用者學習（見 M4） |
| 反目標 | 鍵盤被系統終止的次數比現在多 |
| 反目標 | 按鍵到候選字出現明顯比現在的速成慢 |
| 反目標 | App 大到 SideStore 無法安裝或更新 |
| 反目標 | 任何打過的文字寫進 log、檔案或網路（使用者匯入的方案除外） |

## 3. 前提（查證結果）

詳細來源見研究檔；以下只列影響本設計的部分。

| 前提 | 內容 | 研究檔章節 |
|---|---|---|
| librime 可上 iOS | 「仓输入法」以 librime 做 iOS 鍵盤並已上架 App Store | 3.2、9.2 |
| 官方沒有 iOS 建置 | librime 官方的建置說明與 CI 只有 Linux、macOS、Windows | 9.2 |
| 依賴 | librime 需要 Boost、LevelDB、marisa、OpenCC、yaml-cpp（CMake 中 OpenCC 為 REQUIRED）；記錄 log 用 spdlog，可用 `ENABLE_LOGGING=OFF` 關閉 | 3.2、本文 §12 |
| 資料夾 | librime 的 `RimeTraits` 有 `shared_data_dir`、`user_data_dir`、`prebuilt_data_dir`（預設 `shared_data_dir/build`）、`staging_dir`（預設 `user_data_dir/build`） | 本文 §12 |
| 詞典讀取 | librime 把編譯後的 `.table.bin`、`.prism.bin` 以記憶體映射讀取，不計入 footprint 的 dirty 記憶體 | 3.3、5.1 |
| 記憶體 | 鍵盤上限依機型而不同；iPhone 17 Pro 約 177 MB，手寫峰值 85.8 MB | 5.1 |
| 完整取用 | 沒有完整取用時，鍵盤只能寫自己的容器；能否讀 App Group，Apple 新舊文件矛盾，本專案未實測 | 5.3 |
| App Review | 4.4.1 要求沒有完整取用也能當鍵盤用；2.5.2 不得下載執行程式碼（不執行匯入的 Lua） | 5.1、5.4 |
| 匯入安全 | 有 iOS RIME 鍵盤為匯入方案修改 librime：方案若寫 `dictionary: ../x` 或絕對路徑，會讀寫資料夾以外的檔案 | 本文 §12 |
| 可內建的資料 | libcangjie（Public Domain）、小麥注音資料（MIT）、words.hk 字詞表（公有領域）、Unihan（Unicode License v3）；rime-cantonese 要先取得許可 | 4.3 |

## 4. 做法

### 4.1 組字引擎（使用者已選）

| 做法 | 內容 | 結果 |
|---|---|---|
| A | 只做通用表格引擎加 `.cin` 匯入 | 不選：沒有注音與粵拼 |
| B | 自寫 Swift 兩層引擎（表格型與拼音型） | 不選：Android 不能直接用 |
| C | 內嵌 librime | **選用**（使用者 2026-11-20，理由：Android 通用性） |

### 4.2 librime 建置方式（使用者已選）

| 做法 | 內容 | 結果 |
|---|---|---|
| 1 | 建置腳本以固定版本的原始碼編譯 xcframework，包成本地 SwiftPM 套件 | **選用**（使用者 2026-11-20）：版本與 patch 自己控制，有模擬器版，將來可用同一套原始碼建 Android 版 |
| 2 | 使用其他專案編譯好的 xcframework | 不選：出處與授權不清，不能修改，可能消失 |
| 3 | SwiftPM 直接從原始碼編譯 librime 與依賴 | 不選：Boost 與 CMake 產生的標頭檔要手動維持，編譯很慢 |

## 5. 決定

U 開頭為使用者決定；M 開頭為主代理決定，使用者可在批准時更改。

| 編號 | 決定 |
|---|---|
| U1 | 組字引擎採用 librime（方向 C） |
| U2 | 次序：C1 技術驗證、C2 內建輸入法、C3 匯入、C4 鍵位 |
| U3 | C2 內建倉頡（第五代）、注音、粵拼、漢語拼音；速成在 C1 完成 |
| U4 | C1 實機量測通過後刪除現有 Swift 速成引擎（`QuickInputMethod`、`QuickDictionary`、`quick-table.txt`；`make-quick-table.swift` 由新的速成詞典產生腳本取代）；刪除後 librime 失敗時不再有 Swift 後備 |
| U5 | librime 以建置腳本從原始碼編譯成 xcframework |
| U6 | C1 的自動驗收通過就 merge，C2 接著做，不等實機量測。在實機量測通過之前，Swift 速成保留作後備，並有 DEBUG 開關切換兩個引擎做比較；實機通過後依 U4 刪除。實機不通過時，C2 可能要重做（使用者已接受） |
| U7 | 倉頡與速成收 Big5 加香港增補字符集（HKSCS）的字。Big5 字沿用 libcangjie 的次序；HKSCS 字（libcangjie 排序值為 0）依 words.hk 字頻表排序，排在同碼的 Big5 字之後。速成在 C2 一併擴充；C1 的對照測試仍以現有的 Big5 速成表為準 |
| M1 | librime 包成一個 `ChineseInputMethod` 實作，接在現有速成的位置；手寫維持 ML Kit 與現有流程 |
| M2 | 內建方案、詞典原始檔與預先編譯好的 `.bin` 放在鍵盤擴充程式的 bundle（`shared_data_dir`、`prebuilt_data_dir`）；`user_data_dir` 設在鍵盤自己的容器。鍵盤執行時不編譯詞典 |
| M3 | 不編入 librime-lua 與任何外掛；`ENABLE_LOGGING=OFF`，librime 不寫 log 檔 |
| M4 | 第一版關閉使用者學習（方案設定 `enable_user_dict: false`）。理由：本專案不保留打過的文字；學習紀錄會留在鍵盤容器，而主 App 讀不到那裡，使用者無法在 App 內清除 |
| M5 | xcframework 含三個 slice：iOS 實機（arm64）、iOS 模擬器（arm64）、macOS（arm64）。macOS slice 供 `swift test` 與在 Mac 上預先編譯詞典 |
| M6 | xcframework 不提交進 repo；建置腳本、版本鎖定檔、patch 提交。產物放在 git 忽略的資料夾，建置時以 checksum 檢查 |
| M7 | 輸入法選擇沿用主 App 設定頁單選（D15），選項為手寫、速成、倉頡、注音、粵拼、拼音；鍵盤以 `select_schema` 切換。若 C1 確認沒有完整取用時讀不到 App Group，C2 加鍵盤內的切換方式 |
| M8 | Swift 速成刪除前，librime 初始化失敗時自動改用 Swift 速成。刪除後，中文頁顯示「中文輸入暫時無法使用，請到 App 改用手寫」，不另加鍵盤內的切換 UI；英文與符號頁不受影響 |
| M9 | C1 的記憶體門檻沿用 O7 的先例：峰值至少留 20% 上限餘量 |
| M10 | 鍵位描述 JSON 在 C2 就定義（注音標準鍵位需要），C4 再加使用者匯入與更多內建版面 |
| M11 | 輸入方案、詞典原始檔與鍵位 JSON 放在不屬於 iOS 目錄的共用資料夾，產生腳本也放在 `scripts/`，以便 Android 共用 |
| M12 | 匯入（C3）只在主 App 處理：驗證、限制路徑、以 librime 編譯，再把結果寫入 App Group；鍵盤只讀 |
| M13 | 「可重現」指：鎖定檔記錄每份原始碼壓縮檔的 checksum，下載後核對；在 Mac 的新 clone 或新 worktree 執行腳本能重建 xcframework。不要求產物逐位元相同，也不新增 iOS 的 CI |
| M14 | 內建的 `default.yaml`、標點、按鍵設定由我們自寫（授權寬鬆），結構與 rime-prelude 相容，讓引用 prelude 的匯入方案也能用。C3 接受 zip 或資料夾形式的多檔方案（含 `import_tables`）；方案中用到 OpenCC 的濾鏡會被移除並提示使用者 |
| M15 | 鍵位 JSON 在 C2 預留「一個鍵送出多個碼」與長按、滑動的欄位；注音九宮格與拼音 10 鍵採用「引擎判斷」或「點選確切符號」，到 C4 再決定 |

## 6. 架構

### 6.1 元件

| 元件 | 位置（建議） | 內容 |
|---|---|---|
| 建置腳本 | `scripts/rime/` | 下載固定版本原始碼（版本與 checksum 寫在鎖定檔），套用 patch，以 CMake 編譯三個 slice，合成 xcframework；同時產生 macOS 上的 `rime_deployer` 供預先編譯詞典 |
| 引擎套件 | `Packages/RimeEngine` | SwiftPM：`binaryTarget` 指向 xcframework，加一層薄的 Swift 封裝（初始化、建立 session、送按鍵、讀輸入碼與候選字、讀已提交文字、選候選字、切換方案） |
| 資料來源與產生腳本 | `ime/`（共用資料夾）與 `scripts/` | 由上游資料產生 `.schema.yaml`、`.dict.yaml`；每個方案附授權檔 |
| 預先編譯 | 建置階段 | 用 macOS 的 `rime_deployer` 把方案編譯成 `.bin`，放入鍵盤 bundle |
| 鍵盤適配 | `RemoteKeyboardExtension/Chinese/` | `RimeInputMethod`：實作 `ChineseInputMethod`，把 `IMEInput` 轉成 librime 按鍵，把 librime 的狀態轉成 `IMEOutput` |
| 主 App 設定 | `ChineseInputSettingsView` | 新增方案選項；「關於」頁顯示所有新授權 |
| 鍵位描述 | `ime/layouts/` 與 Core | JSON 格式與解析（C2），鍵盤依 JSON 畫鍵 |
| 匯入 | 主 App（C3） | 選檔、驗證、編譯、寫入 App Group |

### 6.2 資料夾與資料流

```text
鍵盤 bundle（唯讀）
  rime/shared/            內建 .schema.yaml、.dict.yaml、default.yaml
  rime/shared/build/      預先編譯的 .bin（prebuilt_data_dir）
鍵盤容器（可寫，沒有完整取用也可）
  rime/user/              user_data_dir；第一版不寫學習紀錄
App Group（C3 起）
  rime/imported/<id>/     主 App 編譯好的匯入方案與 .bin，加 manifest.json
```

C1、C2 只用前兩個位置，不依賴 App Group。C3 的匯入資料放在 App Group，能否在沒有完整取用時讀取由 C1 量測決定。

### 6.3 與現有程式的接駁

| 現有 | 改為 |
|---|---|
| `ChineseInputMethodID`：`handwriting`、`quick` | 加 `cangjie`、`zhuyin`、`jyutping`、`pinyin`（C2）；C3 加匯入方案的 ID |
| `KeyboardViewController.loadQuickIfNeeded` 與按鍵處理中的速成分支 | 改為建立 `RimeInputMethod`；中文頁出現時初始化，鍵盤消失時釋放 session（與手寫辨識器同一個時機） |
| `QuickPageView`（QWERTY 加倉頡字根鍵面） | C1 沿用；C2 改由鍵位 JSON 產生 |
| 候選字列與輸入碼顯示 | 沿用；輸入碼顯示 librime 的 preedit（倉頡、速成由方案顯示字根） |
| `ChineseMethodResolver` | 加入新方案；「沒有完整取用時退回速成」改為「退回 librime 的速成」 |
| `InputRouter`、草稿、遠端傳送 | 不變；只接收已提交文字 |

### 6.4 鍵位描述 JSON（C2 定義，C4 開放匯入）

最少要能表達：版面名稱與版本、適用的方案、每一行的鍵（送給引擎的按鍵、鍵面主字、角落小字、寬度比例）、功能鍵（Shift、刪除、切換）。第一版內建兩個：QWERTY 加字根或字母標示（速成、倉頡、粵拼、拼音），以及注音標準鍵位。欄位細節由實作者定，但格式不得依賴 iOS 專有型別。

## 7. 分步與驗收

驗收沿用專案規則：自動驗證與實機驗證分開列；實機項目標 TBD，使用者親手測完才算 PASS。實機量測要做到一次點擊或不用點擊，結果寫成文字 log（只記數值，不記文字）。

### 7.1 C1：技術驗證（librime 跑速成）

範圍：建置腳本與 xcframework；`RimeEngine` 套件；速成方案（由 libcangjie 第五代碼取首尾碼，規則與收字與現有 `make-quick-table.swift` 相同）；`RimeInputMethod` 成為速成的預設引擎，Swift 速成保留作後備；DEBUG 開關切換兩個引擎；DEBUG 量測模式。

| 類別 | 項目 |
|---|---|
| 自動 | 建置腳本在 Mac 的新 clone 或新 worktree 可重建，產生三個 slice；原始碼壓縮檔的 checksum 與鎖定檔相符（M13） |
| 自動 | macOS 上以 `swift test` 對每一個速成碼比對：librime 給出的候選字與次序，與現有 `quick-table.txt` 完全一致 |
| 自動 | 模擬器 UI 測試：在速成頁打數個碼並選字，結果與現在相同 |
| 自動 | 鍵盤執行時沒有編譯詞典（量測模式檢查 `staging_dir` 沒有新產生的 `.bin`） |
| 實機 TBD | 鍵盤 footprint：載入 librime 後、連續打字時、與手寫切換時的峰值，峰值至少留 20% 上限餘量（M9） |
| 實機 TBD | 按鍵到候選字更新的延遲 P95，與現有速成比較 |
| 實機 TBD | IPA 大小增加多少；SideStore 可安裝 |
| 實機 TBD | 沒有完整取用時，鍵盤能否讀 App Group 的檔案 |

通過條件分兩段（U6）：

1. 自動項目全部 PASS：C1 可以 merge，C2 開工。
2. 實機項目：記憶體符合 M9；延遲與大小由使用者看數字判斷可接受。通過後刪除 Swift 速成（U4，獨立的小 Task）。不通過時回報數字，由使用者決定調整或停止方向 C。

### 7.2 C2：內建輸入法

範圍：倉頡（第五代）、注音、粵拼、漢語拼音四個方案與詞典；鍵位 JSON 格式與兩個內建版面；主 App 設定選項；授權顯示。

| 方案 | 資料來源 | 備註 |
|---|---|---|
| 倉頡（第五代） | libcangjie 第五代碼欄，沒有時用第三代；收 Big5 加 HKSCS（U7） | 與速成同一份來源；速成同時擴充收字 |
| 注音 | 小麥注音 `Source/Data`（字音與詞頻） | 注音標準鍵位 |
| 漢語拼音 | 小麥注音字音表的拼音欄，或 Unihan `kMandarin` | 輸出繁體字 |
| 粵拼 | words.hk 字表與詞表、Unihan `kCantonese` | 取得許可後可加 rime-cantonese |

| 類別 | 項目 |
|---|---|
| 自動 | 詞典產生腳本可重現；每份產物附授權與出處 |
| 自動 | 倉頡與速成打得出「嘅、咗、啲、嘢、喺」；同碼時 Big5 字排在 HKSCS 字之前（U7） |
| 自動 | 每個方案以固定測例（字與常用詞）測首選與前五名，結果寫成報告 |
| 自動 | 鍵位 JSON 解析與錯誤處理的單元測試；模擬器 UI 測試每個方案打字並選字 |
| 實機 TBD | 詞典最大的方案（預期是注音或拼音）的 footprint 與延遲 |
| 實機 TBD | 使用者以各方案實際打字的感受 |

首選正確率的門檻由使用者看報告決定。

### 7.3 C3：匯入

範圍：主 App 匯入 RIME 方案（`.schema.yaml` 加 `.dict.yaml`）與 `.cin`（轉成 RIME 表格方案）；驗證、編譯、寫入 App Group；鍵盤列出並使用匯入方案。

| 類別 | 項目 |
|---|---|
| 自動 | 路徑限制：方案中任何資源 ID 為絕對路徑或含 `..`、反斜線、NUL 一律拒絕 |
| 自動 | 含 Lua 或需要未編入元件的方案拒絕並說明原因 |
| 自動 | 檔案大小、行數、YAML 巢狀深度上限；格式錯誤的檔案不會令主 App 當掉 |
| 自動 | `.cin` 轉換：`%keyname` 轉為鍵面標示，`%chardef` 轉為詞典，碼長與選字鍵依檔頭 |
| 自動 | 驗收用的匯入目標（由測試在 Mac 上下載或使用本機副本，不放進 repo）：rime-cantonese、rime-cangjie 的完整方案，以及 OpenVanilla 的 `cj.cin`、`simplex.cin`、`dayi3.cin`、`array30.cin`；引用 rime-prelude 的部分由我們的相容設定檔接住（M14） |
| 實機 TBD | 有與沒有完整取用時，鍵盤使用匯入方案的情況 |

### 7.4 C4：鍵位

範圍：使用者匯入 JSON 鍵位檔；內建注音九宮格、拼音 10 鍵等版面；版面與方案的配對。

| 類別 | 項目 |
|---|---|
| 自動 | 匯入鍵位檔的驗證（必要鍵、鍵數、寬度總和）與錯誤訊息 |
| 自動 | 每個內建版面在 375 pt 與 402 pt 寬的截圖 |
| 實機 TBD | 使用者以各版面打字的感受 |

## 8. 隱私、安全、授權

| 項目 | 規則 |
|---|---|
| log | librime 不寫 log（M3）；本專案的 log 只記事件種類、長度、時間與結果 |
| 學習 | 第一版不寫使用者詞典（M4） |
| 網路 | 引擎與匯入都不連網；匯入只接受使用者自己選的本機檔案 |
| 匯入安全 | 路徑限制、不執行 Lua、大小上限（7.3）；編譯只在主 App |
| 授權 | 主 App「關於」頁列出：librime（BSD-3-Clause）、Boost（BSL-1.0）、LevelDB（BSD-3-Clause）、marisa（選 BSD-2-Clause）、yaml-cpp（MIT）、OpenCC（Apache-2.0，附 NOTICE）；資料：libcangjie 聲明、Unicode License v3、Wittern 授權句、小麥注音 MIT、words.hk 出處 |
| 不內建 | GPL、LGPL、CC BY-SA、CC BY-ND 的資料；rime-cantonese 在取得許可前不內建 |

## 9. Android 預留

- 引擎原始碼與版本鎖定檔、方案、詞典原始檔、鍵位 JSON 都放在不屬於 iOS 的位置（M11）。
- 建置腳本的結構要能加一個 Android NDK 目標，但這次不實作。
- Android 前端可參考的授權寬鬆專案：YuyanIme（BSD-3-Clause）；Trime（GPL-3.0）只能參考做法。

## 10. 留給實作者決定

- 套件、資料夾、型別的確切名稱（6.1 的位置為建議）。
- librime 與各依賴的版本（以最新穩定版為原則，記在鎖定檔）。
- 每頁候選字數、候選字列能否捲動。
- 有輸入碼時按 Return 的行為（清除或送出原始輸入碼），要寫進測試並與使用者確認一次。
- Shift 的處理沿用現有速成的「單次 Shift 後下一個字母輸出英文大寫」，或交給方案設定。
- librime session 在哪個執行緒執行（不得阻塞主執行緒）。
- DEBUG 量測模式的觸發方式（沿用現有 `MeasurementRunner` 的做法）。

## 11. Provisional 與風險

| 項目 | 狀態 | 處理 |
|---|---|---|
| librime 能否在 iOS 建置成功 | Provisional，C1 驗證 | 失敗即回報，由使用者決定 |
| 鍵盤記憶體 | Provisional，C1、C2 實機量 | 不過 M9 門檻時停在該步 |
| App 大小 | Provisional | C1 量測；注音、拼音詞典較大，C2 再量 |
| App Group 在沒有完整取用時可讀 | 未知 | C1 量測；影響 M7 與 C3 |
| 拼音型首選品質 | 未知 | C2 報告，使用者決定門檻 |
| 刪除 Swift 速成後沒有後備 | 已接受（U4） | 實機通過前保留後備（U6）；刪除後中文頁顯示提示（M8） |
| C1 實機不通過，C2 要重做 | 已接受（U6） | 實機結果一出就回報 |
| HKSCS 字的候選次序 | 依 words.hk 字頻（U7） | C2 報告列出同碼字的次序樣本 |
| rime-cantonese 授權 | 待許可 | 未許可前粵拼只用 words.hk 與 Unihan |

## 12. 本文新增的來源

研究檔已列的來源不重複。以下為撰寫本設計時另外查證的一手來源，擷取日期 2026-11-20。

- librime `CMakeLists.txt`（`ENABLE_LOGGING` 預設開、以 spdlog 記錄；`find_package(Opencc REQUIRED)`）：https://github.com/rime/librime/blob/master/CMakeLists.txt
- librime `src/rime_api.h`（`RimeTraits` 的 `shared_data_dir`、`user_data_dir`、`prebuilt_data_dir`、`staging_dir`；`create_session`、`process_key`、`get_context`、`get_commit`、`select_candidate`、`select_schema`）：https://github.com/rime/librime/blob/master/src/rime_api.h
- librime `tools/rime_deployer.cc`（命令列預先編譯工具）：https://github.com/rime/librime/tree/master/tools
- Songyan iOS 的 `ARCHITECTURE.md`（GPL-3.0，只引用其所述事實：為匯入方案加入資源 ID 限制的 librime patch）：https://github.com/Suzukaa-a/songyan-ios/blob/main/ARCHITECTURE.md
