# T12b Step 0（O9）速成字碼表來源授權查證

查證日期：2026-10-31。只做研究，未寫產品程式。速成碼 = 倉頡碼第一碼加最後一碼，所以只需要完整倉頡碼表。

## 結論

選 **libcangjie 的 `data/table.txt`**，授權為 **Public Domain（作者明文宣告）**。可散布、可商用、無署名義務。
為保險，仍隨 App 附上 Unicode License v3 全文與 Christian Wittern 原始表的授權句（見「需附上的授權檔」），因為該表自述資料部分來源是 Unihan 與 Wittern 的表，兩者都是寬鬆授權且要求保留聲明。
備案：Unicode Unihan kCangjie（Unicode License v3，明確可散布）。不選 rime-cangjie（授權標示互相矛盾）。

## 比較表

| 項目 | A. libcangjie `data/table.txt` | B. Unicode Unihan kCangjie | C. rime/rime-cangjie `cangjie5.*.dict.yaml` |
|---|---|---|---|
| 授權 | Public Domain（資料檔）；函式庫程式碼另為 LGPL-3.0 | Unicode License v3 | 互相矛盾：repo LICENSE 為 LGPL-3.0；字典檔標頭寫「License: GPL」；AUTHORS 寫字典衍生自 ibus-table（LGPL）、原作 Public Domain |
| 可否散布 | 可 | 可 | 不確定 |
| 可否商用 | 可 | 可（"sell copies" 明列） | 不確定 |
| 條件 | 無 | 所有副本須附版權與許可聲明（或放在文件中） | 若是 GPL/LGPL，須開源與保留聲明；且上游碼表（五倉世紀 chinesecj.com）授權未見明文 |
| 字數 | 約 74,663 個漢字列（含擴充區）；Big5 內字約 13,737 | 29,189 筆 kCangjie（主區 20,943，擴充區等 8,246）；Unicode 18.0.0（2026-07-31） | cangjie5.base 23,936 行，不重複字 21,470（一字可有多碼）；extended 另 55,352 行 |
| 倉頡版本 | 第三代與第五代各一欄 | 第三代為主（源自 1993 年表） | 第五代 |
| 次序資訊 | 有：第 15 欄為排序值，Big5 內字依 Big5 編碼次序（自述與常見倉頡輸入法排序一致）；Big5 外為 0 | 無：只依碼位排列，一字一碼，沒有常用度 | 無權重欄（base 只有 text、code），次序來自檔案順序；詞頻需另靠 rime-essay |
| 速成直接支援 | 無速成欄，需自行取首尾碼 | 需自行取首尾碼 | 另有速成方案但以倉頡五代詞碼為主 |
| 第一手來源 | https://gitlab.freedesktop.org/cangjie/libcangjie/-/raw/main/data/README.table.md | https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip 與 https://www.unicode.org/license.txt | https://github.com/rime/rime-cangjie（LICENSE、AUTHORS、cangjie5.base.dict.yaml 標頭） |

## 引用的原文

A. libcangjie `data/README.table.md`：
> The data in the ``table.txt`` file is hereby placed under the Public Domain, in the hope that is is useful.

同檔 Sources：資料來自 Unihan、Unicode 規格、Wan Leung Wong 的原版 libcangjie 與 libcangjie 團隊整理。`COPYING` 為 LGPL-3.0，只適用函式庫程式碼，我們只取 `table.txt` 資料，不連結、不複製其程式碼。倉庫在 2026-02-25 仍有提交，仍有維護。

B. Unihan_DictionaryLikeData.txt 標頭：
> For terms of use and license, see https://www.unicode.org/terms_of_use.html

Unicode License v3 條文：
> Permission is hereby granted, free of charge, to any person obtaining a copy of data files ... to deal in the Data Files or Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, and/or sell copies ...
> provided that either (a) this copyright and permission notice appear with all copies of the Data Files or Software, or (b) this copyright and permission notice appear in associated Documentation.

UAX #38（https://www.unicode.org/reports/tr38/）kCangjie：
> This incorporates data from the file cangjie-table.b5 by Christian Wittern.

C. rime-cangjie `cangjie5.base.dict.yaml` 標頭：
> 單字碼表《五倉世紀》來自 www.chinesecj.com ... License: GPL

AUTHORS：
> Derived from ibus-table by acevery (Yu Yuwei) : (LGPL) and based on original work by 朱邦復 / Chu Bong-Foo : (Public Domain)

repo LICENSE 為 LGPL-3.0（GitHub API 顯示 lgpl-3.0）。

## 2009 年 kCangjie 授權疑問的現況

- 2009-06 Unicode 郵件列表（https://www.unicode.org/mail-arch/unicode-ml/y2009-m06/0087.html 等）討論的是：要不要把較新的倉頡第五代資料（cbflabs.com、馬來西亞 Friends of Cangjie、chinesecj.com）加入 Unihan，因為這些權利人是否願意用寬鬆授權有疑問。John H. Jenkins 的態度是取得許可並備文給 UTC 即可。該討論沒有質疑現有 kCangjie 的來源。
- 現行 UAX #38 仍只寫 kCangjie 納入 Wittern 的 cangjie-table.b5，沒有另附授權說明。
- Wittern 原檔（Emacs `leim/MISC-DIC/cangjie-table.b5`，https://raw.githubusercontent.com/emacs-mirror/emacs/master/leim/MISC-DIC/cangjie-table.b5）標頭：
  > Copyright 2001 Christian Wittern ... Permission to copy and distribute both modified and unmodified versions is granted without royalty provided this notice is preserved.
  > feel free to use it in any imaginable way :-)
- 判斷：Unihan 檔本身現在明確在 Unicode License v3 之下；其中 Wittern 部分的上游授權也是寬鬆（保留聲明即可）。但 Unihan 29,189 筆比 Wittern 的 Big5 表（約 1.3 萬字）多，多出部分的原始出處 UAX #38 沒有交代，所以「每一筆都有獨立授權證明」做不到，只能依賴 Unicode 對整個資料庫的授權。這是選 A 為主、B 為備案的原因之一。

## 建議與理由

1. 選 A（libcangjie table.txt）：唯一在資料檔旁明文寫 Public Domain 的來源；有第三代與第五代碼；有 Big5 次序可決定候選字先後（常用字在前的程度需實作時驗證，見下）；涵蓋 Big5 內約 1.37 萬字，足夠速成用。
2. 風險：A 自述部分來自 Unihan 與原版 libcangjie（Wan Leung Wong），Public Domain 宣告是否能完全涵蓋這些上游，嚴格講無法由第一手來源 100% 證明；Unihan 與 Wittern 部分已確認寬鬆，原版 libcangjie 的資料授權未查證。因此以附上 Unicode License 與 Wittern 授權句降低風險。個人免費 Personal Team 自用 demo，此風險可接受。
3. 不選 C：標頭 GPL、LICENSE 為 LGPL、AUTHORS 又寫 Public Domain，上游五倉世紀只見到對 Wiktionary 的個別許可，授權不明；且無常用度權重。
4. 若使用者不接受 A 的殘餘風險：改用 B，授權最清楚，但沒有次序資訊，候選字需另找字頻來源，並要處理一字一碼。

## 實作時需確認（不屬本次查證）

- table.txt 第 15 欄排序值方向（升冪或降冪）與是否真的常用字在前，需用 速、成、明 等字抽樣驗證（例：速=19338、成=22614、明=21764，我=22308，數值看起來是降冪的可能性高，但未確認）。
- 速成取碼用第三代或第五代：兩欄對常用字多數相同，需以抽樣決定。
- 一字多碼要去重；非漢字列（標點、符號）要過濾（第 3 欄為 1 才是漢字）。
- 簡體字（第 2 欄對應）不屬繁體速成，可忽略。

## 需附上的授權檔（隨 App 散布）

| 檔案 | 內容 | 文字來源 |
|---|---|---|
| libcangjie 資料聲明 | 「The data in the table.txt file is hereby placed under the Public Domain」及來源說明 | https://gitlab.freedesktop.org/cangjie/libcangjie/-/raw/main/data/README.table.md |
| Unicode License v3 | 全文 | https://www.unicode.org/license.txt |
| Wittern 授權句 | 「Copyright 2001 Christian Wittern ... Permission to copy and distribute both modified and unmodified versions is granted without royalty provided this notice is preserved.」 | Emacs 倉庫 `leim/MISC-DIC/cangjie-table.b5` 檔頭 |

放置位置建議：App 內「設定 > 授權」頁或 bundle 內 `THIRD_PARTY_LICENSES.txt`。

## 證據取得方式

下載檔皆放在 session scratchpad，未進入 repo：Unihan.zip（8.3 MB，Unicode 18.0.0）、rime-cangjie 各 dict.yaml、libcangjie table.txt（77,575 行）。字數由腳本統計：Unihan kCangjie 29,189；rime base 23,936 行 / 21,470 不重複字；libcangjie 漢字列 74,663、Big5 內 13,737、排序值非 0 的漢字 13,063。
