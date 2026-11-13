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
| WL6（`rk-core` 與 CI） | Mac 上 `cargo test --workspace` 246 個測試 0 失敗、`cargo clippy -D warnings` 無警告；`swift test` 1117 個測試 0 失敗；PR 上 Windows 與 Ubuntu 的 CI：見下節 | 不適用（純邏輯） | 完成；`rk-win`、`rk-linux` 上的 `cargo test` 待測試機連線 |

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
