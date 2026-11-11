# Windows／Linux 接收端與多主機（D28）驗收報告

- 設計：`docs/superpowers/specs/2026-11-10-windows-linux-receiver-design.md`
- 計畫：`docs/superpowers/plans/2026-11-10-windows-linux-receiver-implementation.md`

## 總表

| Task | 自動驗證 | 實機驗證 | 結論 |
|---|---|---|---|
| WL0（S8 廣播 UUID 切換） | iOS Debug 與 Release 建置成功；Release 產物不含測試畫面 | 2026-11-11 量測完成 | Mac 通過；Windows 與 Linux 以 btleplug 掃描時不通過，待 S8b |

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
