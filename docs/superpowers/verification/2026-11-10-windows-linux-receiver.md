# Windows／Linux 接收端與多主機（D28）驗收報告

- 設計：`docs/superpowers/specs/2026-11-10-windows-linux-receiver-design.md`
- 計畫：`docs/superpowers/plans/2026-11-10-windows-linux-receiver-implementation.md`

## 總表

| Task | 自動驗證 | 實機驗證 | 結論 |
|---|---|---|---|
| WL0（S8、S8b 廣播 UUID 切換） | iOS Debug 與 Release 建置成功；Release 產物不含測試畫面 | 2026-11-11 量測完成 | 三個平台皆通過。Windows 需用系統原生監看介面；Linux 需定時重啟探索並清除裝置快取 |
| WL2（協定文件 `docs/protocol/v4.md`） | 舊欄位名稱搜尋 0 筆；18 個 JSON 範例全部可解析；文件內的範例值以獨立腳本重算相符，加密範例以 CryptoKit 與現有程式解開相符 | 不適用（只有文件） | 文件完成；16 項待確認於 2026-11-11 定案，補充細節 A–G 於 2026-11-13 批准，已寫入文件、設計與計畫 |
| WL3（Core 協定 v4） | `swift test` 1102 個測試 0 失敗；測試向量檔與協定文件的範例值 95／95 相符 | 不適用（純邏輯） | 完成。iOS 與 Mac 的轉接層在 WL4、WL5 修復 |

## WL0：S8 廣播 UUID 切換（2026-11-11）

### 環境

| 項目 | 內容 |
|---|---|
| iPhone | iPhone 17 Pro，Debug 版（commit 99848c2）的「廣播測試」畫面，輪流廣播 UUID A `11111111-2222-4333-8444-555555555555` 與 B `AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE` |
| Mac | CoreBluetooth 掃描，不帶 service 過濾，允許重複回報 |
| Windows | Windows 11 家用版 build 26300（預覽版），Intel AX201，btleplug 0.11.8 |
| Linux | Ubuntu 26.04.1，BlueZ 5.85，btleplug 0.11.8 |
| 時鐘 | Mac 與 Linux 和標準時間相差約 0.001 秒；Windows 快 1.66 秒，計算時已扣除；iPhone 的時鐘誤差未量測 |
| 操作 | 使用者在 iPhone 上切換 22 次，間隔約 10 秒；其中第 9、10 次相隔 0.12 秒（連按） |

掃描程式是用完即丟的 spike，不在 repo 內。

### 自動驗證

| 項目 | 結果 |
|---|---|
| iOS 模擬器 Debug 建置 | BUILD SUCCEEDED |
| iOS 模擬器 Release 建置 | BUILD SUCCEEDED |
| Debug 產物含 `AdvertProbe` 字串 | 10 處 |
| Release 產物含 `AdvertProbe` 字串 | 0 處 |
| 實機 Debug 建置並安裝 | 成功 |

### 量測結果

| 平台 | 看到新 UUID 的延遲 | 舊 UUID 殘留 | 判定 |
|---|---|---|---|
| Mac | 19 次可對時的切換：中位數 0.05 秒，最大 0.24 秒 | 0 筆。每筆廣播只帶當下的 UUID | 通過 |
| Windows（btleplug） | 第一次出現 B：0.00 秒（只有 1 個樣本） | 之後所有事件都同時帶 A 與 B，再也分不出目前是哪一個 | 不通過 |
| Linux（btleplug／BlueZ） | 第一次出現 B：1.0 秒（只有 1 個樣本） | 同上，A 與 B 一直並存 | 不通過 |

補充觀察：

- Windows 與 Linux 的清單裡還帶著鍵盤的 Link service UUID（`706AA642-…`），是量測開始前留下的，同樣沒有被清掉。Mac 的每筆廣播裡沒有它。
- Windows 整段量測只收到 2 筆「廣播帶有哪些 service」的事件，Linux 也是 2 筆：只有清單「新增」了 UUID 才會有事件，UUID 消失不會有任何通知。
- Mac 第 10 次切換算出 −0.07 秒，是第 9、10 次連按造成的對時誤差，不是實際延遲。

### 解讀

Windows 與 Linux 的無線電都收得到新的廣播（新 UUID 在 0 到 1 秒內出現），問題在掃描這一層：btleplug（以及 Linux 的 BlueZ 裝置快取）把同一個裝置看過的 service UUID 累加起來，只增不減。照設計 §5.3 的做法，iPhone 選過的每一台主機都會一直以為自己被選中。

設計 §12 對這個結果的規定是：回報使用者，不進 WL2。

### 尚未驗證

- Windows 改用 WinRT 的 `BluetoothLEAdvertisementWatcher`（每筆廣播各自回報內容）是否能分辨目前的 UUID。
- Linux 改用 BlueZ 的 AdvertisementMonitor 介面，或在斷線後移除裝置快取，是否能分辨目前的 UUID。
- 正式版 Windows 11 的行為是否與預覽版相同。
- iPhone 換了藍牙隨機位址之後，各平台是否把它當成新裝置。

## WL0：S8b 以原生介面重測（2026-11-11）

### 改動

| 項目 | 內容 |
|---|---|
| iPhone 測試畫面 | 一次自動切換 20 次（每 6 秒），開始時以 SNTP 對時，紀錄寫入 App 的 `Documents/advert-probe.log`；可用啟動參數 `-rkAdvertProbeAuto` 經傳輸線直接開始，不需手動操作 |
| Windows 掃描 | 改用 WinRT `BluetoothLEAdvertisementWatcher`（主動掃描），逐筆廣播回報 |
| Linux 掃描 | 試三種做法，見下表 |
| 對時 | 三端各自以 SNTP 量測與標準時間的差距並寫入紀錄；延遲以校正後的時間計算 |

### Windows

| 輪次 | 看到的切換 | 延遲中位數 | 延遲最大值 | 切換 1 秒後仍出現舊 UUID | 同時帶 A 與 B 的廣播 | 每 6 秒收到的廣播數（最少） |
|---|---|---|---|---|---|---|
| 第一輪 | 21／21 | 0.22 秒 | 1.06 秒 | 0 | 0 | 15 |
| 第二輪 | 21／21 | 0.25 秒 | 1.00 秒 | 0 | 0 | 12 |

Windows 時鐘比標準時間快 1.66 秒，已由程式自動校正。iPhone 的校正值為 +0.012 與 +0.016 秒。判定：通過（3 秒內看到新 UUID、無殘留）。系統為預覽版 build 26300，正式版未驗證。

### Linux

| 做法 | 結果 |
|---|---|
| BlueZ AdvertisementMonitor | 無法使用：這台機器的 `bluetoothd`（5.85）沒有以實驗模式啟動，`org.bluez.AdvertisementMonitorManager1` 介面不存在。未更動系統設定 |
| 原始 HCI socket | 無法使用：沒有 root 權限時核心會過濾掉 LE 廣播事件 |
| 一般探索，每次看到裝置就 `RemoveDevice` 清快取 | 不穩定，見下 |

「清快取」做法的三次執行：

| 執行 | 掃描與廣播的先後 | 結果 |
|---|---|---|
| 第一輪（200 秒） | 掃描先開始，6 秒後 iPhone 才開始廣播 | 0 筆 |
| 臨時試跑（約 15 秒） | iPhone 已在廣播時才開始掃描 | 收到 5 筆，A、B 交替，每筆只帶單一 UUID |
| 第二輪（200 秒） | 掃描開始時收到 2 筆前一次殘留的廣播，之後 iPhone App 重新啟動並廣播 | 之後 0 筆 |

另外以 `dbus-monitor` 側錄 BlueZ 的訊號，確認 BlueZ 的裝置物件會把 UUID 累加（先 A，之後變成 A 與 B）。這台機器有兩個藍牙控制器（hci0 為 Realtek USB，hci1 為預設控制器），側錄時裝置出現在 hci1，掃描程式用的是 hci0。

判定：未通過。「清快取」在收得到廣播時能分辨目前的 UUID，但有兩次整段收不到任何廣播，原因未查明（可能與控制器的重複過濾、兩個控制器並存有關，需要 root 權限的 `btmon` 才能確認）。

### 尚未驗證

- Linux 為何有時完全收不到廣播。
- 正式版 Windows 11 的行為。
- iPhone 更換藍牙隨機位址後各平台的行為。
- Windows 被動掃描模式。

## WL0：Linux 根本原因調查（2026-11-11）

### 環境補充

| 項目 | 內容 |
|---|---|
| hci0 | 內建 Realtek（USB `0bda:b85b`）。使用者表示它有問題；另有一個不屬於本專案的程式正在使用它 |
| hci1 | TP-Link UB500（RTL8761BU，USB `2357:0604`），2026-11-10 22:22 裝上，為系統預設控制器。之前的 Linux 量測用的都是 hci0 |

### 分層證據

| 層 | 方法 | 觀察 |
|---|---|---|
| BlueZ D-Bus | 唯讀 Python 腳本同時在兩個控制器探索一整輪（21 次切換，每 6 秒） | 兩個控制器表現相同：各約 40 筆回報，14／21 次切換在 6 秒內有回報，7 次完全沒有；最慢 5.2 秒 |
| HCI（晶片與核心之間） | 使用者以 `sudo btmon -w` 側錄 hci1 一整輪 | 核心送出的 LE Set Extended Scan Enable 帶 `filter_duplicates = 1`；核心每 10.8 秒重新啟動一次掃描（共 16 次）；晶片整輪只回報 19 筆含 A 或 B 的廣播，12／21 次切換有回報；每筆原始回報只帶當下的單一 UUID |
| 兩層比對 | 同一輪的 BlueZ 事件數與 HCI 回報數 | 一致，BlueZ 沒有丟失回報 |

### 根本原因

BlueZ 的探索讓晶片過濾重複廣播：同一個裝置回報過一次後，要到核心每 10.8 秒重新啟動掃描時才會再回報。iPhone 換了廣播內容也不會提前觸發回報。另外 BlueZ 的裝置物件會把看過的 UUID 累加。兩者與使用哪個控制器無關。

### 驗證（都在 hci1，不需 root、不改系統設定）

| 做法 | 切換後看到回報 | 延遲中位數 | 延遲最大值 | 切換 1.5 秒後仍為舊 UUID | 同時帶 A 與 B |
|---|---|---|---|---|---|
| 系統預設探索 | 12–14／21 | 2.6 秒 | 5.8 秒 | 無法判斷（UUID 累加） | 不適用 |
| 每 1.5 秒 `StopDiscovery`＋`StartDiscovery` | 21／21 | 0.85 秒 | 1.19 秒 | 無法判斷（UUID 累加） | 不適用 |
| 每 1.5 秒重啟探索，重啟時對該裝置 `RemoveDevice` | 21／21（UUID 正確） | 1.24 秒 | 1.56 秒 | 0 | 2 筆（都在切換後 1.5 秒內） |

判定：Linux 以最後一種做法通過 S8（3 秒內看到新 UUID、無殘留）。只跑了一輪。

### 對設計與計畫的影響（待使用者確認後修訂）

- 掃描不能用 btleplug：Windows 用 WinRT `BluetoothLEAdvertisementWatcher`，Linux 用 BlueZ D-Bus 並定時重啟探索與清除裝置快取。
- Linux 接收端需要可選擇藍牙控制器。
- 每 1.5 秒重啟探索對其他藍牙程式、耗電與連線中的行為的影響未量測。

### 尚未解釋

- 先前「看到裝置就 `RemoveDevice`」的 spike 程式有兩輪 200 秒完全沒有任何回報。依上述原因應該每 10.8 秒有一筆。推測是該程式只處理「裝置新增」事件，裝置已在清單內時不會觸發；未驗證。

## WL2：協定文件 v4（2026-11-11）

只新增 `docs/protocol/v4.md`，沒有更動任何程式。

### 完成條件的檢查

舊欄位名稱：

```
$ grep -n "macNonce\|macPublic\|macProof" docs/protocol/v4.md
$ echo "exit=$?"
exit=1
```

沒有任何輸出，`grep` 以 1 結束，表示 0 筆。

JSON 範例：

```
$ python3 - <<'EOF'
import re, subprocess
blocks = re.findall(r"```json\n(.*?)\n```", open("docs/protocol/v4.md", encoding="utf-8").read(), re.S)
failed = [i for i, b in enumerate(blocks, 1)
          if subprocess.run(["python3", "-m", "json.tool"], input=b.encode(), capture_output=True).returncode]
print(f"blocks={len(blocks)} ok={len(blocks) - len(failed)} failed={failed}")
EOF
blocks=18 ok=18 failed=[]
```

用字與格式（各樣式在文件中的出現次數）：

| 樣式 | 次數 |
|---|---|
| ` · ` 分隔符號 | 0 |
| 廣東話用字（`嘅唔咗喺嚟冇佢啲畀嗰咁噉乜嘢`） | 0 |
| 樣本數標記（`[nN]\s*=\s*\d`） | 0 |

### 範例值的核對

核對用的程式是用完即丟的腳本，不在 repo 內。

| 項目 | 方法 | 結果 |
|---|---|---|
| 現行訊息的 JSON 形狀、跳脫與鍵的順序 | 以現有的 `ControlCodec`、`PeripheralCodec` 實際編碼每一種訊息後對照 | `/` 輸出為 `\/`；鍵依位元組值排序；控制字元為小寫 `\u00xx` |
| v4 沒有改形狀的 7 個控制訊息範例 | 現有 `ControlCodec` 解碼後再編碼 | 7／7 逐位元組相同 |
| 表格中的 18 個範例值（公鑰、commitment、共享點、身分雜湊、`pairKey`、配對碼、兩個 proof、兩把 session 金鑰、選定 UUID 等） | Python 標準函式庫獨立重算後在文件中搜尋 | 18／18 相符 |
| `pairKey` 與配對碼 | CryptoKit 以同一組私鑰、salt `rk-pair-v2` 與 226 bytes 的 `info` 計算 | 與 Python 結果相同（`412eab3b…2b20`、`947102`） |
| 兩個 `sealed` 範例 | CryptoKit 以文件的金鑰解開 | 明文分別等於文件中的文字事件範例（186 bytes）與 `ack` 範例（83 bytes） |
| 指標封包範例 | 現有 `ChannelSet` 的 opener 解開；另以現有 sealer 重新封裝 | 解出的明文與文件相同；sealer 的輸出與文件的 41 bytes 逐位元組相同 |

### 16 項待確認定案後的修訂（2026-11-11）

使用者於 2026-11-11 批准 16 項待確認的處理方式。協定文件、設計（修訂 4）與計畫已依此更新，沒有更動任何程式。

修訂後重跑：

```
$ grep -n "macNonce\|macPublic\|macProof" docs/protocol/v4.md
$ echo "exit=$?"
exit=1
```

```
$ python3 - <<'EOF'
import re, subprocess
blocks = re.findall(r"```json\n(.*?)\n```", open("docs/protocol/v4.md", encoding="utf-8").read(), re.S)
failed = [i for i, b in enumerate(blocks, 1)
          if subprocess.run(["python3", "-m", "json.tool"], input=b.encode(), capture_output=True).returncode]
print(f"blocks={len(blocks)} ok={len(blocks) - len(failed)} failed={failed}")
EOF
blocks=18 ok=18 failed=[]
```

| 項目 | 方法 | 結果 |
|---|---|---|
| ` · `、廣東話用字、樣本數標記 | 同上 | 各 0 筆 |
| 協定文件、設計、計畫中殘留的「完整字元」「字素」說法 | `grep` | 協定文件 0 筆；設計與計畫的「完整字元」0 筆 |
| 表格中的 18 個範例值 | 同一支 Python 腳本重算 | 18／18 相符。名稱規則改為碼位後，範例用的兩個名稱（13 與 16 bytes）都不需要截斷，所有金鑰、配對碼、proof 與密文不變 |
| 兩個 `sealed` 範例、指標封包範例、7 個控制訊息範例 | 同一支 Swift 程式重跑 | 全部相符 |
| 名稱截斷的三個範例 | Python 逐碼位累加，另以「取前 32 bytes 再去掉不完整碼位」的等價做法比對；Swift 以 `unicodeScalars` 逐碼位累加並把結果的 UTF-8 解回字串 | 13 → 13、33 → 30、145 → 30（結尾為 U+1F468、U+200D、U+1F469）；兩種語言、兩種做法結果相同，UTF-8 可解回原字串 |

套用定案時另補了 7 處定案沒有講到的細節（PR #95 說明的 A–G），使用者於 2026-11-13 批准照目前寫法，其中 5 項記入設計 §16 第 24–28 項。另外 2 項維持原狀：版本不符時是否先送 `authFailed` 不作規定；配對時段開著時，驗證失敗的裝置不列入不再連線的名單。

### 尚未驗證

- v4 新增或改形狀的訊息（`pairAccept`、`hello`、`pairReveal`、`notSelected`）還沒有實作可以對照，範例由腳本依文件的規則產生。WL3 的測試向量完成後才有程式端的核對。
- 名稱截斷只以腳本核對，產品程式（`IdentityName.clamp`）要到 WL3 才有。
- 修訂加入的 Provisional 值沒有量測依據：Windows 與 Linux 驗證失敗後 60 秒不再連線、版本不符後 60 秒不再連線、Mac 帶過濾條件並允許重複回報的掃描。

## WL3：Core 協定 v4（2026-11-13）

branch `protocol-v4`，commit `2ae2ac4`。只改 `Packages/RemoteKeyboardCore` 與新增 `receiver/testdata/swift-vectors-v4.json`。

### 自動驗證

RED：新測試寫好、尚未實作時，測試目標編譯失敗（27 個錯誤，例如找不到 `HostIdentity`、`PeripheralMessage` 沒有 `notSelected`、`Pairing` 沒有 `hostProof`）。

GREEN：

```
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1102 tests, with 0 failures (0 unexpected) in 0.467 (0.517) seconds
```

計畫 WL3 Step 1 列出的測試全部存在。`CentralBinding` 的四個測試放在 `CentralBindingTests.swift`，不在計畫寫的 `AuthHandshakeTests.swift`。

測試向量：`ProtocolVectorTests.testVectorsFileIsCurrent` 在不設 `RK_WRITE_VECTORS` 時通過，表示提交的向量檔與目前程式的輸出逐位元組相同。位元組一律寫成小寫十六進位字串。

向量檔與協定文件範例值的比對（一次性腳本，從 `docs/protocol/v4.md` 抽出範例值，不在 repo 內）：

```
$ python3 -I check_vectors.py | tail -1
TOTAL 95  OK 95  MISMATCH 0
```

| 比對範圍 | 項目 |
|---|---|
| 固定輸入 | `hostId`、`phoneId`、兩個 nonce、兩個名稱、兩個私鑰純量 |
| §1.2、§1.3 | 配對 UUID；選定 UUID、雜湊前 16 bytes、版本與變體位元 |
| §3.2–§3.4 | 18 個 JSON 範例逐位元組相同 |
| §4 | 截斷表三列（13→13、33→30、145→30） |
| §5.5 | 兩把公鑰、`commitment`、`Z`、兩個身分雜湊、`pairKey`、配對碼 |
| §6.1 | `phoneProof`、`hostProof` |
| §7.3 | `K_p2m`、`K_m2p`、兩則 `sealed` |
| §8.1 | `K_ptr`、指標封包 |
| §2.2 | 600 bytes 以 185 分段的四個標頭、資料長度與重組 |

舊名稱：

```
$ grep -rn "macNonce\|macPublic\|macProof\|macLabel\|rk-pair-v1" Packages/RemoteKeyboardCore
（0 筆）
```

### 與計畫的差異

| 項目 | 做法 | 原因 |
|---|---|---|
| `MacHandshake.init` 多一個 `route:`（預設 `.selected`） | 經配對 UUID 的連線傳 `.pairing`：不寫 `hello`；選定 UUID 連線上的配對訊息、配對 UUID 連線上的 `helloReply`、`sealed`、`notSelected` 一律驗證失敗 | 協定 §1.5、§6.2；設計 §16 第 30 項。計畫的簽名沒有地方表達連線來源 |
| `begin()` 在沒有任何手機時回驗證失敗 | 不寫 `hello` | 協定 §6.2；設計 §16 第 25 項 |
| `CentralBinding.helloDisposition` 多一個收整則 `hello` 的版本 | 格式錯誤的 `hello` 來自綁定的 central 時交給握手而失敗，來自其他 central 時不理會 | 協定 §6.3 第 1 列；設計 §16 第 24 項 |
| `MacHandshake` 逐把驗證時不提早停止 | 全部算完，第一個相符者為該手機 | 處理時間不透露手機在清單中的位置 |
| `SessionCrypto`、`ChannelSet`、`CounterChannel` 也改了 | 參數 `macNonce` 改名 `hostNonce`；`SessionCrypto` 另加只供測試的固定 nonce 封裝 | 舊名稱搜尋要 0 筆；向量需要可重現的 AEAD nonce，正式路徑仍用亂數 |
| `ReceiverLinkStateMachine` 用 `init(now:)` 注入時間 | 三個新事件只在 `.ready(id)` 時有效，回 `[.cancel(id)]` 並把該裝置放進同一份暫擋名單；`.stop` 清空名單 | 測試 10 秒與 60 秒不需真的等待 |

### 實機驗證

不適用。協定在實機上的行為由 WL4、WL5 的實機項目涵蓋。

