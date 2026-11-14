# Windows／Linux 接收端與多主機（D28）驗收報告

- 設計：`docs/superpowers/specs/2026-11-10-windows-linux-receiver-design.md`
- 計畫：`docs/superpowers/plans/2026-11-10-windows-linux-receiver-implementation.md`

## 總表

| Task | 自動驗證 | 實機驗證 | 結論 |
|---|---|---|---|
| WL0（S8、S8b 廣播 UUID 切換） | iOS Debug 與 Release 建置成功；Release 產物不含測試畫面 | 2026-11-11 量測完成 | 三個平台皆通過。Windows 需用系統原生監看介面；Linux 需定時重啟探索並清除裝置快取 |
| WL2（協定文件 `docs/protocol/v4.md`） | 舊欄位名稱搜尋 0 筆；18 個 JSON 範例全部可解析；文件內的範例值以獨立腳本重算相符，加密範例以 CryptoKit 與現有程式解開相符 | 不適用（只有文件） | 文件完成；16 項待確認於 2026-11-11 定案，補充細節 A–G 於 2026-11-13 批准，已寫入文件、設計與計畫 |
| WL3（Core 協定 v4） | `swift test` 1102 個測試 0 失敗；測試向量檔與協定文件的範例值 95／95 相符 | 不適用（純邏輯） | 完成。iOS 與 Mac 的轉接層在 WL4、WL5 修復 |
| WL4（iPhone 多主機） | `swift test` 1111 個測試 0 失敗；iOS 模擬器建置成功；402 與 375 pt 截圖 4 張 | TBD | 程式完成；截圖待使用者確認，實機項目未測 |
| WL5（Mac Receiver v4 與多手機） | `MacReceiverTests` 349 個測試 0 失敗；Mac、iOS 模擬器建置成功；真機 build-for-testing 成功 | TBD | 程式完成；實機項目未測 |
| WL1（S1–S7、S9 連線與注入 spike） | 兩個 Rust spike 在測試機編譯通過；Windows 的 S1、S2、S7 與 Linux 的 S3、S4、S5、S6、S7、S9 已實測 | 2026-11-13 實測，全部項目已跑；S6 沒有量到「沒有 RustDesk」的對照 | S1 基準版不通過、調參版時間通過但 26% 的嘗試失敗；S3 不通過；S2 通過（記事本需要字元間隔）；S4 不通過（非 ASCII 全部丟失）、S5 通過（所以 Linux 的非 ASCII 改用貼上）；S9 在 120 次/秒以內通過；S6 在 RustDesk 連線中可注入。依設計 §12 停下回報 |
| WL6（`rk-core` 與 CI） | Mac 上 `cargo test --workspace` 246 個測試 0 失敗、`cargo clippy -D warnings` 無警告；`swift test` 1117 個測試 0 失敗；PR #98 上 Windows 與 Ubuntu 的 CI 皆成功 | 不適用（純邏輯） | 完成；`rk-win`、`rk-linux` 上的 `cargo test` 待測試機連線 |

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

## WL4：iPhone 多主機（2026-11-13）

branch `protocol-v4`，commit `50fbd08`。

### 自動驗證

RED：`StatusLineTests` 編譯失敗（`display` 還沒有 `host`、`hostCount` 參數；`StatusLine.Display` 沒有 `title`）。

GREEN：

```
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1111 tests, with 0 failures (0 unexpected) in 0.484 (0.536) seconds
```

計畫的 5 個 `StatusLine` 測試之外，另加標題條件、Windows 與 Linux 的用字、各平台不顯示已送出提示 3 個測試，以及 `InputRouter` 的 `.cycleHost` 路由測試 1 個。

```
$ xcodebuild -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
    -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
** BUILD SUCCEEDED **
```

App 與鍵盤延伸功能都建置成功，沒有錯誤。

### 截圖（`-rkPreview`）

| 狀態 | 402 pt（iPhone 18 Pro） | 375 pt（iPhone SE 3） |
|---|---|---|
| `twoHosts` | `evidence/WL4-twoHosts-402.png` | `evidence/WL4-twoHosts-375.png` |
| `twoHostsLongName`（名稱 32 bytes） | `evidence/WL4-twoHostsLongName-402.png` | `evidence/WL4-twoHostsLongName-375.png` |

狀態格兩行：第一行主機名稱，第二行短狀態。32 bytes 的名稱在 402 pt 顯示為「我的辦公室…」，在 375 pt 顯示為「我的辦公…」；第二行完整，其他按鍵的寬度不受影響。402 pt 的模擬器是深色模式。

### 與計畫的差異

| 項目 | 做法 |
|---|---|
| `InputRouter` 新增 `RouteOutcome.cycleHost` | 計畫只寫 `KeyAction.cycleHost`；控制器需要對應的路由結果才接得上 |
| 多主機時出現長提示（例如「2 個按鍵未確認是否送達」） | 長提示暫時佔滿整格、不顯示主機名稱，格子仍可點 |
| 兩行時的外觀 | 加淺灰圓角底色表示可點，第二行 11 pt |
| 綁定的 central 送來其他主機的 `hello` | 回 `notSelected` 後丟棄該連線的握手與 session 狀態，鍵盤回到廣播 |
| 刪除主機 | 左滑後再跳確認對話框，避免誤刪 |
| 用字 | 首頁、配對頁、連不上頁、Onboarding 配對頁改為「電腦」 |

### 未做

- `StatusLine` 的未配對、觸控板拒絕與離線提示仍寫「Mac」：沒有目前主機時不知道平台；觸控板文字屬 WL8。
- 教學頁與 Onboarding 前兩頁（在 Mac 安裝 Receiver）仍以 Mac 為主：Windows、Linux 的安裝說明在 WL12 才有。
- 首頁主機清單與新的配對畫面沒有截圖。

### 實機驗證（TBD）

| 項目 | 結果 |
|---|---|
| 點狀態格輪替後，廣播換成新主機的選定 UUID；舊主機不再連線，新主機連上並完成握手 | TBD |
| 沒有目前主機時不廣播 | TBD |
| 配對畫面廣播配對 UUID，只有配對時段開著的接收端連線 | TBD |
| 鍵盤延伸功能讀得到各主機的 Keychain 項目與 App Group 的主機清單 | TBD |
| 升級後第一次啟動刪除 v3 的舊金鑰 | TBD |
| 新增電腦：確認畫面顯示主機名稱與配對碼；確認後設為目前主機；8 台已滿時開始前就擋下 | TBD |
| 首頁主機清單：點選設為目前主機、左滑刪除 | TBD |
| 狀態格好不好點、切換的手感 | TBD |

## WL5：Mac Receiver v4 與多手機（2026-11-13）

branch `protocol-v4`，commit `436b115`（審查修正見下節）。

### 自動驗證

RED：測試先寫好時 `build-for-testing` 失敗，`ReceiverSecurity.swift` 仍用 WL3 之前的介面（`MacHandshake`、`MacPairing` 的建構子，`.authenticated` 的形狀，缺 `.notSelected`）；新測試用到的 `PairingStoring`、`loadHost` 等都不存在。

GREEN（主代理重跑）：

```
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1111 tests, with 0 failures (0 unexpected) in 0.478 (0.529) seconds

$ xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS'
Executed 349 tests, with 0 failures (0 unexpected) in 12.639 (12.729) seconds
** TEST SUCCEEDED **

$ xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS'
** BUILD SUCCEEDED **

$ xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
** BUILD SUCCEEDED **

$ xcodebuild build-for-testing -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'id=<iPhone 17 Pro>'
** TEST BUILD SUCCEEDED **
```

計畫 WL5 Step 1 的 15 個測試都存在且通過。掃描條件的 3 個測試放在 `CoreBluetoothDriverWiringTests`，以假的 `CBCentralManager` 檢查實際傳給 `scanForPeripherals` 的 UUID 與選項。

### 與計畫的差異

| 項目 | 做法 |
|---|---|
| 暫擋事件之後的 `.disconnected` | 狀態機收到 `.handshakeTimeout`、`.notSelected`、`.unsupportedVersion` 後停在 `.ready(id)` 等斷線；`cancel` 會先放掉連線，系統的斷線回呼因此被擋掉，所以轉接層在取消後自行補送一次 `.disconnected` |
| 介面 | `ReceiverBLECentral.init` 多了 `hostId:` 與 `uptime:`；`CentralDriving.startScan(services:)` 取代 `startScan()` |
| 判斷連線來源 | 只看這一筆廣播的 `ServiceUUIDs` 與 `OverflowServiceUUIDs`；兩個 UUID 都沒有時略過；配對時段已關閉時看到配對 UUID 也略過 |
| 允許重複回報 | `linkState` 只有真的改變時才更新，避免每筆廣播都觸發畫面更新 |
| 版本不符 | 面板顯示「請更新 iPhone App」，下次驗證成功時清除；配對時段開著時只中斷、不暫擋 |
| 刪除手機 | 刪除連線中的手機時先送 `bye` 再中斷；刪除時若選定路線的握手尚未完成也中斷，避免刪掉的金鑰之後才完成握手 |
| 8 支已滿 | 按「配對新 iPhone」時不開時段，面板顯示「已配對 8 支手機，請先刪除一支」 |
| 檔案 | `phones/<id>.json` 另存 `id` 與加入時間，用來維持順序；主機名稱為空時用「Mac」 |

### 實機驗證（TBD）

重新安裝 Mac Receiver 後，需要在「系統設定」重新授權「輔助使用」與「藍牙」。v3 的配對作廢，iPhone 也要安裝這一版 App 後重新配對。

| 項目 | 結果 |
|---|---|
| 升級後第一次啟動，舊配對消失，面板回到未配對 | TBD |
| iPhone 與 Mac 重新配對；確認框顯示手機名稱與配對碼 | TBD |
| 第二支手機配對後，兩支都能打字（一次一支） | TBD |
| 打字、觸控板、焦點行為與延遲和升級前相同 | TBD |
| 帶選定 UUID 過濾條件的掃描：iPhone 切換主機後 3 秒內跟上，且不會連上已改選其他主機的 iPhone（Provisional） | TBD |
| 面板手機清單、刪除、目前連線的手機名稱 | TBD |
| 握手逾時、`notSelected`、版本不符時的 10 秒與 60 秒暫擋 | TBD |

## 開 PR 前的獨立審查（2026-11-13）

reviewer 結論：沒有阻擋問題，可以開 PR；4 項建議修正、7 項細節。

| # | 問題 | 處理 |
|---|---|---|
| 1 | `host.json` 讀不到時產生新 `hostId` 並覆蓋，已配對的手機全部失聯而面板沒有錯誤 | 修正：只有檔案不存在才產生；其他讀取失敗時產生新身分並清空手機清單 |
| 2 | 開配對時段時剛被中斷的手機會經選定 UUID 搶先連回，另一支手機整個時段連不上 | 修正：配對時段開著時不連選定 UUID 的裝置 |
| 3 | Mac 的說明文字仍是 iOS 的舊按鈕名稱 | 修正 |
| 4 | Personal Team 簽名的 App 取不到裝置名稱，所有手機都叫「iPhone」 | 已知限制。Mac 清單加註配對日期以便分辨，刪除加確認 |
| 5–10 | 退避中重新掃描、換手時沿用舊主機、舊金鑰刪除次數、Mac 刪除沒有確認、暫擋名單清理、重複通知 | 5–9 修正；10 未改（目前的觀察者不受重複通知影響） |
| 11 | 驗收報告未 commit | 隨 PR 提交 |

修正後主代理重跑：

```
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1113 tests, with 0 failures (0 unexpected) in 0.470 (0.520) seconds
$ xcodebuild test … -scheme MacReceiver -destination 'platform=macOS'
Executed 357 tests, with 0 failures (0 unexpected) in 13.085 (13.183) seconds
** TEST SUCCEEDED **
$ xcodebuild build … -scheme MacReceiver                 → ** BUILD SUCCEEDED **
$ xcodebuild build … -scheme RemoteKeyboardApp（模擬器）  → ** BUILD SUCCEEDED **
$ xcodebuild build-for-testing …（iPhone 17 Pro 真機）   → ** TEST BUILD SUCCEEDED **
```

新增的測試：壞掉或為 symlink 的 `host.json` 會清空手機清單、配對時段開著時不連選定 UUID 的裝置、退避中切換配對掃描不重新開始掃描、換主機時重設連線、暫擋名單清掉已到期項目、配對日期的讀寫。Mac 的刪除確認框與 iOS 換手時的重設只有建置驗證，實機 TBD。

鍵盤未配對時的提示依使用者要求改為「尚未配對」（2026-11-13），不再提到 Mac。

## 狀態格永遠顯示主機名稱與預設名稱（2026-11-13）

branch `host-name-always`。使用者於 2026-11-13 實機試用後決定：狀態格永遠顯示目前主機名稱；預設名稱改為系統名，可在接收端改名（設計 §16 第 34 項）。

### 自動驗證

RED：`StatusLineTests` 編譯失敗（`extra argument 'switchesHost'`）；`MacPairingStoreTests` 編譯失敗（`MacPairingStore` 沒有 `renameHost`）。

GREEN（主代理重跑）：

```
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1115 tests, with 0 failures (0 unexpected)

$ xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS'
Executed 361 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **

$ xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS'
** BUILD SUCCEEDED **

$ xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
** BUILD SUCCEEDED **
```

### 改動

| 項目 | 做法 |
|---|---|
| 狀態格 | 有目前主機且已配對時一律兩行（名稱加短狀態）；`Display.switchesHost` 只有配對兩台以上才為 true。一台時沒有底色、點擊回饋、按鈕角色，點擊不輪替；未配對維持單行「尚未配對」 |
| Mac 預設名稱 | 新建的 `host.json` 名稱為「Mac」，不再取電腦名稱；既有 `host.json` 不改 |
| 改名 | 面板新增「電腦名稱」欄位與「儲存」；去空白、32 bytes 截斷、清空改回「Mac」；id 與手機清單不變 |
| 改名的影響 | 握手只用 `hostId` 與配對金鑰，名稱只在配對時綁進金鑰，所以改名不會讓已配對的 iPhone 斷線；iPhone 要重新配對才顯示新名稱 |
| 文件 | 設計 §5.1、§6、§7、§10、§16 第 34 項；協定 §4；計畫 WL4、WL5、WL7、WL10 |

### 截圖（`-rkPreview`）

| 狀態 | 402 pt（iPhone 18 Pro） | 375 pt（iPhone SE 3） |
|---|---|---|
| `oneHost`（名稱「Mac」，無底色） | `evidence/HN-oneHost-402.png` | `evidence/HN-oneHost-375.png` |
| `twoHosts`（有底色，可點） | `evidence/HN-twoHosts-402.png` | `evidence/HN-twoHosts-375.png` |
| `twoHostsLongName`（32 bytes） | `evidence/HN-twoHostsLongName-402.png` | `evidence/HN-twoHostsLongName-375.png` |

### 獨立審查

reviewer 結論：沒有阻擋問題。已修正：`refreshPairedState` 先讀主機再讀手機清單；改名欄位儲存後同步顯示實際存入的名稱、輸入時清除錯誤、按鈕以去空白後的內容判斷；`StatusCell` 無名稱時清掉舊的 label 與 identifier；計畫文件兩處過時敘述。

### 未驗證（TBD）

| 項目 | 結果 |
|---|---|
| 面板「電腦名稱」欄位實機操作（儲存、清空、超長） | TBD |
| 只配一台時點擊狀態格沒有反應也沒有觸感 | TBD |
| 既有 UI 測試（`KeyboardT10UITests`、`MeasurementUITests`）未執行，審查認為 `label.contains` 仍會通過 | TBD |

## WL6：`rk-core`（Rust 協定核心）與 CI（2026-11-13）

### 內容

| 項目 | 說明 |
|---|---|
| `receiver/` | cargo workspace，目前只有 `rk-core`。`rk-core` 沒有 IO、時鐘、亂數與平台相依，`#![forbid(unsafe_code)]`；`cargo tree -i getrandom -p rk-core` 找不到 getrandom |
| 模組 | `json`、`select_uuid`、`identity`、`frame`、`message`、`pairing`、`handshake`、`session`、`channel`、`dedup`、`pointer`，另有 `binding`（協定 §6.3 第 5、6 列）、`secret`（金鑰型別，`Debug` 遮蔽） |
| 向量 | `receiver/testdata/swift-vectors-v4.json`（Swift 產生）由 `tests/swift_vectors.rs` 逐項比對；`receiver/testdata/rust-vectors-v4.json`（Rust 產生）由 `RustVectorTests` 在 Swift 端解開 |
| CI | `.github/workflows/receiver.yml`：`pull_request`（路徑 `receiver/**`）在 `windows-latest` 與 `ubuntu-latest` 跑 build、test、clippy |

### 自動驗證（主代理在 Mac 上重跑）

```
$ cd receiver && cargo test --workspace
test result: ok. 230 passed; 0 failed; 1 ignored   （unit；ignored 是 write_rust_vectors）
test result: ok. 7 passed; 0 failed                 （tests/loopback.rs）
test result: ok. 9 passed; 0 failed                 （tests/swift_vectors.rs）
$ cargo clippy --workspace --all-targets -- -D warnings   → Finished，無警告
$ cargo test -p rk-core write_rust_vectors -- --ignored   → 1 passed；檔案重新產生後 rust_vectors_file_is_current 仍通過（輸出確定）
$ swift test --package-path Packages/RemoteKeyboardCore
Executed 1117 tests, with 0 failures (0 unexpected)
```

TDD：先寫 `swift_vectors.rs` 與 `loopback.rs`，以 `todo!()` 空殼跑出 16 個失敗（全是 `not yet implemented`），再實作到全綠。Rust 輸出與 Swift 向量逐位元組相同：18 則訊息（含 4 則帶 `\/`）、`pairKey` 與配對碼 `947102`、兩個 proof、兩個方向的 session 密文、指標封包、600 bytes 分段、4 個選定 UUID、3 個名稱截斷範例。反向：`RustVectorTests.testSwiftOpensRustVectors` 以 Swift 的 `SessionCrypto`、`CounterChannel`、`FrameCodec`、`FrameReassembler` 解開 Rust 封裝的 sealed（含 `/`、多位元組字元、跳脫字元）、2 個指標封包（含計數器 2^40+5）、2 組分段（`F` 為 185 與 23）。

### CI（PR #98，GitHub Actions run 43358896962，2026-11-13）

| 平台 | build | test | clippy |
|---|---|---|---|
| `windows-latest` | 成功 | 230 + 7 + 9 通過，0 失敗，1 ignored | 成功 |
| `ubuntu-latest`（先安裝 `libdbus-1-dev`、`pkg-config`） | 成功 | 同上 | 成功 |

Windows 上的 `rust_vectors_file_is_current` 通過，即 I1 的換行修正有效。

### 開 PR 前的獨立審查

reviewer（Opus，唯讀，另在複本上做 40 個突變測試）結論：沒有 Critical；1 個阻擋問題與 1 個 Important，12 項 Minor。

| # | 問題 | 處理 |
|---|---|---|
| I1 | Windows 的 checkout 預設把檔案轉成 CRLF，`rust_vectors_file_is_current` 在 Windows 必定失敗（macOS、Ubuntu 看不出來） | 修正：`.gitattributes` 加 `receiver/testdata/*.json text eol=lf`；測試比較前也容忍 CRLF，並有測試證明 CRLF 版本通過、內容不同仍失敗 |
| I2 | proof、commitment 只比前 31 bytes 的突變沒有被任何測試抓到 | 修正：加測試（最後與第一個 byte 翻轉必須失敗，覆蓋配對、握手兩邊）；在複本上重做突變，3 個新測試變紅 |
| m2 | 點擊 `arg` bit2–3 非零沒有測試 | 修正 |
| m3 | 指標型別的 `Debug` 會印出位移 | 修正三個被點名的型別；`PointerEngine`、`PointerPlayout`、`PlayoutShare` 仍是 derive 的 `Debug`（內含位移），Windows／Linux 外殼不得以 `{:?}` 寫 log |
| m7 | `chacha20poly1305` 的預設 feature 拉進 getrandom | 修正 |
| m10、m11 | 缺鍵序（UTF-8 位元組序）與 `\b \f \r`、DEL、U+2028／2029 的回歸測試 | 修正；Swift 的期望值同步更新 |
| m1、m4、m5、m6、m8、m9、m12 | 主機端 `ChannelSet` 帶有 sealer、`binding` 第 2 與第 6 列要由外殼對齊、`pairReveal` 的 `phoneId` 長度走 `HostPairing` 而不是握手、`protocolVersion` 超過 `i64::MAX` 回 Malformed、金鑰不在 drop 時清零、JSON 重複鍵取最後一個、格式 | 未改，留給 WL7 前後處理；m12：本機沒有 rustfmt，CI 不檢查格式 |

### 偏離計畫與協定文件

1. `HostHandshake::new(host_id, phones, host_nonce, route)` 多一個 `Route`（選定 UUID 或配對 UUID，協定 §1.5），`HostOutput` 多 `TimedOut`，`PairOffer`、`PairReveal` 帶具名欄位。
2. `PairedPhone.pair_key` 是 `PairKey`（`SecretBytes<32>`），不是 `[u8; 32]`。
3. 函式放在子模組（`rk_core::select_uuid::select_uuid`、`rk_core::identity::clamp_name`），`lib.rs` 沒有 `pub use`。
4. `rk-core` 另含 `PointerReceiver`（開關、grant、open／close、連續 8 個失敗）與觸控板速度曲線（沿用 Mac 的常數；Windows 與 Linux 是否用同一條待決定，不在協定文件內）。
5. 協定文件沒寫、實作自行決定：`notSelected` 在 `hello` 寫出前收到視為 `NotSelected`；JSON 重複鍵取最後一個；移動、按鍵狀態、心跳的 `arg` 與保留的 `actionId` 不檢查。這些都不影響與 Swift 的位元組一致。

### 未驗證

- `rk-win`、`rk-linux` 上的 `cargo test -p rk-core`（測試機未連線，延後）。
- 時間與指標手感：watchdog 與 playout 只用模擬的微秒驗證，常數仍是 Provisional。
- 常數時間只靠 `subtle` 與 `hmac` 的 `verify_slice`，沒有量過時間。
- 沒有 fuzz、沒有壓力測試。

## WL1：連線與注入 spike（2026-11-13）

spike 程式是用完即丟的，不進 repo。Windows 的 S1、S2、S7 與 Linux 的 S3、S4、S5、S6、S7、S9 都已實測。

### 環境

| 項目 | 內容 |
|---|---|
| iPhone | iPhone 17 Pro，用線接 Mac。UI 測試重新安裝了 App 與鍵盤延伸功能，內容是 main 在 `5dbf87a` 的建置（含 PR #96、#97、#98），所以 iPhone 上現在是這一版，不再是 PR #96 的版本。既有配對沒有受影響 |
| Windows | Windows 11 家用版 build 26300（預覽版），Intel AX201，只接 Wi-Fi；`windows` crate 0.61.3，release 建置 |
| Linux | Ubuntu 26.04，BlueZ 5.85，藍牙控制器 hci1（TP-Link UB500）；`bluer` 0.17.4、`ashpd` 0.13.13 |
| 通訊協定 | v4。鍵盤的目前主機是 Mac，所以 spike 從 Mac 的 `host.json` 取 `hostId`，依協定 §1.3 算出 Mac 的選定 UUID 去掃描，連上後寫 v4 的 `hello`，iPhone 回 `helloReply`（proof 不驗證）。不需要改 iOS 程式 |
| iPhone 端自動化 | `ReconnectUITests` 的拋棄式副本（不要求真的連上，固定停留 8 秒），在 Notes 與 Safari 輪流叫出與收起鍵盤，共 24 次；放在 repo 外的獨立 worktree，沒有 commit |
| 計時 | 全部在主機端用單調時鐘量：從掃描到目標廣播，到收到 `helloReply`。不需要與 iPhone 對時 |
| 掃描 | Windows 用 WinRT `BluetoothLEAdvertisementWatcher`（主動掃描，逐筆比對）；Linux 用 bluer，每 1.5 秒重啟探索並 `RemoveDevice`。都沒有用 btleplug |

### 做 spike 時遇到、會影響實作的問題

| 問題 | 原因與處理 | 對實作的影響 |
|---|---|---|
| iPhone 完全不回 `hello` | 測試的當下 Mac Receiver 還在執行（從 DerivedData 啟動，行程名稱是 `MacReceiver`），鍵盤已和它完成驗證並鎖定連線，依協定 §6.3 對其他 central 的 `hello` 一律忽略；同時鍵盤連線中不廣播，掃描不到。結束 Mac Receiver 後才正常 | 與設計一致。多台主機同時在旁邊時，只有被選定的那台連得上，這正是設計要的行為 |
| Linux 寫入後 iPhone 沒有任何反應 | bluer 的 `write()` 預設是 Write Command（不等回應），而 `control` 只支援有回應的寫入，iOS 會直接丟掉。改成明確指定 `WriteOp::Request` 後才有回覆 | WL10 的 `rk-ble` 寫 `control` 一律要用有回應的寫入 |
| Windows 的 BLE 行程在 SSH 結束時被一起終止 | OpenSSH 的工作物件會殺掉子行程 | 只影響測試方式，接收端本身是常駐程式 |
| bluer 的 AcquireNotify 在連線結束後回傳長度為 0 的讀取 | 不是錯誤，是串流結束 | WL10 讀取迴圈要把長度 0 當成結束 |

### S1：Windows 連線（WinRT）

做法：看到廣播，開 `BluetoothLEDevice`，探索 service，訂閱 `event`，寫 `hello`，等 `helloReply`。UI 測試共叫出鍵盤 24 次。

| 版本 | 嘗試 | 成功 | 失敗 | 從看到廣播到收到 `helloReply` | 3 秒內 |
|---|---|---|---|---|---|
| 基準（不調參數） | 22 | 20 | 2（服務探索回報 Unreachable） | 最小 0.17 秒、中位數 3.21 秒、第 95 百分位 3.82 秒、最大 4.01 秒 | 5／20 |
| 調參（探索前呼叫 `RequestPreferredConnectionParameters(ThroughputOptimized)`） | 27 | 20 | 7（同為 Unreachable） | 最小 0.27 秒、中位數 1.04 秒、第 95 百分位 1.98 秒、最大 2.12 秒 | 20／20 |

協商後的 ATT MTU 為 527（`GattSession.MaxPduSize`）。時間主要花在 GATT 服務探索（基準的中位數 3.03 秒；調參後 0.92 秒）；連線本身只要 10 到 30 毫秒（最大一次 125 毫秒）。

基準版 20 次成功的原始數字（毫秒，依發生順序）：3188、3816、359、409、166、3168、2897、3045、3768、3045、3198、3502、4010、3211、3356、3545、3223、3678、3328、2807。其中 3 次（359、409、166）很快，探索只花 54 到 196 毫秒，原因未查。

調參版 20 次成功的原始數字（毫秒）：905、1775、354、1035、2115、344、1183、270、464、380、1563、337、1865、1978、699、1415、1841、935、1715、299。

判定：通過條件是「連續 20 次都在 3 秒內重連」。基準版不通過（只有 5 次在 3 秒內）。調參版的成功次數全部在 3 秒內，但 27 次嘗試有 7 次失敗（26%），基準版是 22 次有 2 次（9%），兩者的失敗率是否有差別沒有足夠的次數判斷。接收端失敗時會在下一次看到廣播重試，使用者感受到的是多等一次叫出鍵盤的時間，這一點需要使用者決定是否接受。

### S3：Linux 連線（BlueZ，bluer，hci1）

| 項目 | 結果 |
|---|---|
| 嘗試與成功 | 28 次嘗試，19 次成功，9 次失敗（8 次 `le-connection-abort-by-local`，1 次 ATT 錯誤 0x01） |
| 從看到廣播到收到 `helloReply` | 最小 5.77 秒、中位數 6.31 秒、第 95 百分位 10.30 秒、最大 12.14 秒；3 秒內 0／19 |
| 協商後的 MTU | 251 |
| 時間分布 | 連線本身中位數 0.34 秒（最大 6.24 秒）；連線後到服務探索完成的中位數 5.5 秒，是主要耗時 |

成功的 19 次原始數字（毫秒）：8080、12141、8305、6446、10299、6596、6474、6521、6136、6075、6230、6206、5943、6382、5995、6060、6307、5880、5768。

同一支程式在 portal 授權後又跑了一次（同時量 S7，每次成功連線就呼叫 portal 注入）：37 次嘗試，13 次成功，24 次失敗（18 次 `le-connection-abort-by-local`、4 次 ATT 錯誤 0x01、2 次服務尚未解析）；成功的從看到廣播到收到 `helloReply` 最小 5.58 秒、中位數 5.98 秒、最大 6.29 秒，3 秒內 0／13；連線中位數 0.22 秒、服務探索完成中位數 5.50 秒。失敗率比第一次（9／28）高，是否與同時開著 portal 工作階段有關沒有驗證。

判定：不通過。BlueZ 的服務探索穩定要 5 秒以上，遠超 3 秒。這與 Windows 基準版同一類原因（iPhone 的連線間隔較長時每個探索請求都要等一個間隔），Windows 用調參把它壓到 1 秒。Linux 沒有對應的不需 root 的做法：BlueZ 的連線參數預設值要改 `/etc/bluetooth/main.conf` 並重啟 bluetoothd（會影響 hci0 與使用者的 musegadget 程式），或寫 debugfs 的 `conn_min_interval`（需要 root，重開機後失效）。這兩項都沒有試，也不會在沒有使用者同意時試。

### S2：Windows 的 `SendInput` 與 `KEYEVENTF_UNICODE`

測試文字 200 個字元（212 個 UTF-16 單位）：英文、繁體中文、表情符號（含 ZWJ 組成的家庭表情符號）。送完後在目標內全選、複製，由程式讀剪貼簿比對；記事本另存檔比對。輸入語言切換用 `WM_INPUTLANGCHANGEREQUEST`，實際確認作用中的語言是 0404（注音）。

| 目標 | 字元間隔 0 毫秒（每個單位的呼叫約 0.5 毫秒，全部送完約 2.2 秒） | 字元間隔 10 毫秒 |
|---|---|---|
| Edge 網址列，注音關 | 通過 | 通過 |
| Edge 網址列，注音開 | 通過 | 通過 |
| Edge 網頁文字框，注音關 | 通過 | 通過 |
| Edge 網頁文字框，注音開 | 通過 | 通過 |
| 記事本，注音關 | 不通過：在第 78 個單位（家庭表情符號中第二個代理對的開頭）之後全部丟失，或整段是空的 | 通過（存檔內容逐字相同） |
| 記事本，注音開 | 不通過：同上 | 通過（剪貼簿與存檔都逐字相同） |

Edge 的項目每個重複 4 次以上，結果一致。記事本在 0 毫秒時三次結果不同（停在第 78 個單位、整段空白、停在第 78 個單位），所以是時序問題，不是固定的壞字元。這台機器沒有 WordPad 與 Word，用 Edge 網頁文字框代替。

判定：通過條件是「每個目標 200 字無漏字、無亂序」。注音輸入法開著不影響結果（四種組合的 Edge 與加了間隔的記事本都通過）。記事本在不加間隔時不通過，加 10 毫秒後通過，所以 Windows 注入需要可設定的字元間隔。10 毫秒是否為最小值沒有量。

### S7：通知處理到注入呼叫返回

在通知處理函式內，一收到 `helloReply` 就呼叫注入，量到呼叫返回的時間（Windows：`SendInput` 送 F24 的按下與放開，不會打出字；每次成功連線一筆）。這個量法不含解密與 JSON 解析（Rust 內是微秒等級）。

| 平台 | 按下返回（微秒） | 按下與放開都返回（微秒） | 系統收到通知到處理函式開始（微秒） |
|---|---|---|---|
| Windows 基準，20 筆 | 中位數 1486、第 95 百分位 1705、最大 1782 | 中位數 2211、第 95 百分位 2492、最大 2578 | 中位數 516、最大 1394 |
| Windows 調參，20 筆 | 中位數 1450、第 95 百分位 1582、最大 5795 | 中位數 2128、第 95 百分位 2374、最大 6063 | 中位數 573、最大 1670 |
| Linux，13 筆（portal 的 `NotifyKeyboardKeysym` 送 F24 按下與放開） | 中位數 1379、第 95 百分位 2717、最大 2893 | 中位數 2822、第 95 百分位 3997、最大 4873 | 不適用 |

有幾筆的按下返回只要約 0.35 毫秒（320 到 396 微秒），都是那次連線很快的情況，原因未查。

### S4：Linux 的 portal `NotifyKeyboardKeysym`

做法：RemoteDesktop portal 取得鍵盤與指標授權後，逐字送 keysym（ASCII 與 Latin-1 直接用，其餘用 `0x01000000 + 碼位`），每字間隔 3 毫秒；同一份 200 字文字送到 GNOME 文字編輯器（存檔比對）、Firefox 網頁文字框（本機網頁回傳比對）、終端機（`cat > 檔案`）。輸入來源用 `gsettings` 在 xkb 的 us 與 ibus 的 chewing 之間切換。400 次 portal 呼叫的往返時間：中位數 1.08 毫秒、第 95 百分位 2.38 毫秒、最大 5.40 毫秒；全部送完約 1.3 秒。

| 目標 | 輸入來源 | 結果 |
|---|---|---|
| 文字編輯器 | us | 不通過：收到 125 個字元，缺 75 個，沒有多出或替換 |
| 文字編輯器 | chewing | 不通過：同上 |
| Firefox 網頁文字框 | us | 不通過：同上 |
| Firefox 網頁文字框 | chewing | 不通過：同上 |
| 終端機 | us | 不通過：同上 |
| 終端機 | chewing | 不通過：同上 |

六組的缺漏完全相同：所有 ASCII 與 Latin-1 字元（125 個）都正確、順序正確；所有繁體中文、全形標點與表情符號（75 個）都沒有出現，也沒有被換成別的字元（兩個相鄰的空格都還在）。輸入來源切到 ibus 的 chewing 沒有改變結果。原因沒有再查（可能是 Mutter 對沒有鍵盤映射的 Unicode keysym 不產生字元）。

判定：不通過。依設計 §12，要看 S5 通過與否：S5 通過則「非 ASCII 改用貼上」預設打開；S5 也不通過則 Linux 先只支援英文與符號。

### S9：Linux 的指標

做法：portal 的相對移動，在半徑 80 像素的圓上每秒轉一圈（淨位移為零），每個速率 5 秒，Firefox 全螢幕頁面（kiosk）記錄實際收到的事件。

| 項目 | 送出 | 頁面收到 | 判定 |
|---|---|---|---|
| 移動 60 次/秒 | 300 次、0 錯誤、60.2 次/秒 | 308 個事件、59.3 次/秒；淨位移 (-1, 1)；間隔中位數 17 毫秒、最大 184 毫秒 | 通過 |
| 移動 120 次/秒 | 600 次、0 錯誤、120.2 次/秒 | 605 個事件、121.2 次/秒；淨位移 (-1, 1)；間隔中位數 8 毫秒、最大 15 毫秒 | 通過 |
| 移動 240 次/秒 | 1200 次、0 錯誤、240.1 次/秒 | 847 個事件、169.5 次/秒；淨位移 (-1, 1)；間隔最大 191 毫秒 | 路徑正確，但事件被合併；往返時間第 95 百分位 7.2 毫秒、最大 22.4 毫秒 |
| 左鍵 10 次 | 往返中位數 1.52 毫秒 | 按下 10、放開 10；另有 3 個其他按鍵的事件 | 通過；多出的 3 個事件原因未查 |
| 右鍵 10 次 | 往返中位數 1.47 毫秒 | 按下 10、放開 10、其他按鍵 0 | 通過 |
| 離散捲動，垂直 10 次 | 往返中位數 1.37 毫秒 | 12 個滾輪事件，垂直合計 1440；橫向有 192 的殘值 | 方向正確；事件數與殘值疑似來自段落交界，未確認 |
| 離散捲動，水平 10 次 | 往返中位數 1.96 毫秒 | 15 個滾輪事件，水平合計 960；垂直有 200 的殘值 | 同上 |
| 平滑捲動，垂直 | 往返中位數 1.15 毫秒 | 10 個事件，垂直合計 400，橫向 0 | 通過 |
| 平滑捲動，水平 | 往返中位數 1.55 毫秒 | 10 個事件，水平合計 400，垂直 0 | 通過 |

判定：移動、點擊、捲動在 120 次/秒以內都能用，最高可用更新率記為 120 次/秒；240 次/秒送得出去但頁面端會合併到約 170 次/秒。S9 不是不通過，Linux 觸控板可以做。測試時滑鼠位置是使用者原本停的位置（頁面是全螢幕，圓沒有碰到邊界）。

### S5：Linux 的 portal 剪貼簿加 Ctrl+V

做法：先用 `wl-copy` 把 23 位元組的哨兵文字放進剪貼簿（模擬使用者原本複製的內容），接著重複 50 次：向 portal 讀出原內容、以 portal 的剪貼簿服務一段含中文與表情符號的短文字、送 Ctrl+V、再把原內容放回去；每次貼完送 Enter。最後多貼一次，目標裡會看到剪貼簿現在放的是什麼。目標：GNOME 文字編輯器（存檔比對）與 Firefox 網頁文字框（網頁回傳比對）。

| 目標 | 結果 |
|---|---|
| 文字編輯器 | 通過：50 行文字逐字相同，最後一次貼上是原本的哨兵文字（原剪貼簿已還原），共 773 個字元 |
| Firefox 網頁文字框 | 通過：同上，773 個字元 |

兩個目標各 50 次，每次「設定、貼上、還原」的總時間中位數約 0.32 秒（第 95 百分位 0.32 到 0.33 秒，最大 0.34 秒），其中大部分是程式內固定的等待（貼上前 60 毫秒、貼上後 250 毫秒）。讀出原剪貼簿花 2 到 4 毫秒。portal 日誌共記錄 307 次剪貼簿傳輸，全部成功。

判定：通過。與 S4 合併，依設計 §12：「Linux 的非 ASCII 改用貼上」預設打開。ASCII 與 Latin-1 可以繼續用 keysym 逐字送。

### S6：RustDesk 連線中的 portal 注入

持有 portal 工作階段 120 秒，每 10 秒用 keysym 打一行（`S6-tick-NNN`）到文字編輯器，跑兩次。

| 次數 | RustDesk | portal 呼叫成功 | 失敗 | 編輯器裡的行數 |
|---|---|---|---|---|
| 第 1 次 | 連線中 | 12 | 0 | 12 |
| 第 2 次 | 連線中 | 12 | 0 | 12 |

兩次執行的當下，從 Mac（192.168.1.108）到 Linux 的 RustDesk 連線都已經建立（`ss` 顯示該連線處於已建立狀態），所以沒有量到「沒有 RustDesk」的對照，只能說明 RustDesk 連線中 portal 注入沒有被擋。前面的 S4、S9、S5 也很可能是在同一個連線下跑的。

判定：記錄。portal 工作階段在 RustDesk 連線中可以持續注入（24 次呼叫、24 行，無失敗）。RustDesk 自己的輸入是否與 portal 衝突（例如兩邊同時打字）沒有測。

### 未完成

| 項目 | 狀態 | 原因 |
|---|---|---|
| 沒有 RustDesk 的 S6 對照 | 未測 | 測試時 RustDesk 已連線，沒有要求使用者先斷線 |
| Linux 的 S3 在 root 權限下調整連線參數 | 未測 | 需要使用者同意，見下表 |

### 依設計 §12 的判斷與對 WL7–WL10 的影響

| 項目 | 判斷 | 對實作的影響 |
|---|---|---|
| S1（Windows） | 基準版不通過，調參版時間通過但嘗試失敗率 26%。依決策規則：Windows 暫停，回報使用者 | WL7 若繼續，探索前必須請求 `ThroughputOptimized` 連線參數，並要有失敗後自動重試（Unreachable）。需要使用者決定 26% 的首次失敗率是否可接受 |
| S3（Linux） | 不通過（3 秒內 0／19，中位數 6.3 秒）。依決策規則：Linux 暫停，回報使用者 | 不調整 BlueZ 的連線參數（需要 root 或改 `main.conf`）就無法達到 3 秒。是否試、是否放寬標準，需要使用者決定 |
| S2（Windows） | 通過（Edge 與有間隔的記事本）；記事本在 0 毫秒間隔時不通過 | WL8 要有字元間隔設定，預設要 10 毫秒以上，並以記事本為回歸測試目標；表情符號的 ZWJ 序列要保持完整送出 |
| S7（Windows） | 只記錄，不設門檻：呼叫約 1.5 到 2.3 毫秒 | 不是瓶頸 |
| S4（Linux） | 不通過（非 ASCII 全部丟失，ASCII 全對） | S5 通過，所以依決策規則「非 ASCII 改用貼上」預設打開 |
| S9（Linux） | 通過（120 次/秒以內） | Linux 觸控板可以做；更新率上限先訂 120 次/秒，240 次/秒會被頁面合併 |
| S7（Linux） | 只記錄：呼叫約 1.4 到 2.8 毫秒 | 不是瓶頸 |
| S5（Linux） | 通過（50 次、兩個目標、原剪貼簿有還原） | 與 S4 合併：Linux 的「非 ASCII 改用貼上」預設打開；ASCII 與 Latin-1 用 keysym。貼上流程要保存並還原使用者原本的剪貼簿，每次約 0.3 秒 |
| S6（Linux） | 只記錄：RustDesk 連線中 24 次注入全部成功 | 沒有量到對照，也沒測兩邊同時輸入 |

兩項不通過的原因都是 GATT 服務探索慢，不是廣播掃描或訊息本身：S8 量到的掃描延遲（Windows 0.23 秒、Linux 1.24 秒）都在標準內。另一個做法是接收端快取服務探索的結果，但這需要同一個 iPhone 的 GATT 資料庫不變，而鍵盤每次出現都會重新發布 service，沒有驗證過是否可行。

### 尚未驗證

- 正式版 Windows 11 的行為（這台是預覽版 build 26300）。
- 調參版 26% 失敗率與基準版 9% 失敗率的差別是否真實（次數太少）。
- 基準版有 3 次探索只花 0.2 秒以內的原因。
- Linux 在 root 權限下調整連線參數後的探索時間。
- iPhone 以外的手機（Android）。

## WL1 除錯：S1 與 S3 的原因（2026-11-14）

只做調查與量測，沒有改產品程式。探針程式不進 repo，Mac 上的副本在 `~/rk-spike-debug/`（Windows `win/`、Linux `linux/attprobe.py`、執行腳本與 `results/`）。

### 根本原因

| # | 原因 | 狀態 | 證據 |
|---|---|---|---|
| R1 | 每條新連線建立後，iPhone 約 40–46 個連線間隔內沒有任何 ATT 回應，所以耗時與連線間隔成正比 | 已證實 | Linux 自寫 ATT 追蹤：第一個回應在 1,800–2,026 毫秒到（44 次），間隔 45 毫秒。Windows 不調參初始間隔 60 毫秒，連上到第一次參數變更中位數 2,743 毫秒；調參後間隔 15 毫秒，中位數約 600 毫秒 |
| R2 | 連線常在頭幾個間隔內失敗（Windows 的 Unreachable、Linux 的 `le-connection-abort-by-local`） | 現象已證實，原因未查 | Linux 原始 socket 在 372–485 毫秒回 `ENOSYS`；Windows 連上後 77–90 毫秒斷線。Windows 會自動重連，但不重跑進行中的探索呼叫，所以回 Unreachable |
| S1 的 0.2 秒 | 接回還沒斷的舊連線，不是 cache | 已證實 | 這類嘗試沒有新連線事件；Windows 在 `Close()` 後約 3.3 秒才真的斷線 |
| S3 的 5.5 秒 | R1 加上 BlueZ 全量探索（10 個 service、16 個 characteristic、15 個 descriptor，46 次往返） | 已證實 | 自寫 client 重現全量探索 5.40 秒（1 次） |
| 掃描迴圈打斷連線 | 不是原因 | 已否定 | 先停探索、不做 `RemoveDevice`，失敗率與時機相同 |

### 量測（從看到廣播到收到 `helloReply`，毫秒）

| 平台與做法 | 嘗試 | 失敗 | 最小／中位／p95／最大 | 3 秒內 |
|---|---|---|---|---|
| Windows WC：調參、帶位址類型、同一裝置物件重查到 8 秒 | 40 | 0 | 209／520／1,335／2,361 | 40／40 |
| Windows WC2：同上重跑 | 48 | 0 | 201／1,008／3,796／10,342 | 44／48 |
| 其中全新連線 | 33 | 0 | 936／1,231／1,755／2,361 | 33／33 |
| 其中舊連線失效 | 5 | 0 | 1,335／3,796／10,342／10,342 | 1／5 |
| Linux L3：自寫 ATT（L2CAP CID 4）只探索本 service，handle 快取並核對 | 47 | 3 | 2,448／2,624／4,987／7,033 | 35／44 |

Linux 一次連上的 34 次全部在 2,448–2,765 毫秒；需要重試的 9 次是 4,685–7,033 毫秒（重試固定多約 2 秒，原因未查）。

### 對實作的要求

- WL7（Windows）：探索前 `RequestPreferredConnectionParameters(ThroughputOptimized)` 並在連線期間保留回傳物件；`GattSession.MaintainConnection = true`；`GetGattServicesForUuidAsync(service, Uncached)` 在同一裝置物件上每 50 毫秒重查到成功或 8 秒，Unreachable 與 0 個 service 都重試，中途不 Close；位址類型取自廣播。舊連線失效（最多約 10 秒）要靠連線生命週期處理：收到 `bye` 立即釋放、看到新廣播而舊連線查不到 service 時改開新連線。
- WL10（Linux）：不用 BlueZ GATT client，以 L2CAP ATT 固定通道（CID 4，hci1，對方 LE Random）自建最小 client：Exchange MTU 517、Find By Type Value、Read By Type、Find Information、寫 CCCD、Write Request 寫 `hello`；回應 iPhone 送來的 ATT 請求（Error Response）；快取 handle 但每次先核對；連線前 `StopDiscovery`，`ENOSYS` 立即重試最多 3 次。不用 root 的預期是約 2.6 秒。

### 需要 root、都沒執行

| 指令 | 用途 | 影響 |
|---|---|---|
| `sudo btmon -i hci1 -w ~/rk-hci1.btsnoop` | 查 R1、R2 的 HCI 原因 | 只側錄 |
| `echo 6 \| sudo tee /sys/kernel/debug/bluetooth/hci1/conn_min_interval` 與 `echo 12 \| sudo tee …/conn_max_interval` | 縮短 hci1 連線間隔，預估約 1.1 秒（推算，未測） | 只影響 hci1，重開機失效 |

### 其他

- bluetoothd 在 2026-11-13 16:43:07 有一次 segfault（先前 spike 期間），原因未查。
- UI 測試在 Safari 找不到 `rk.status`，主機端的嘗試數不等於鍵盤出現次數。
