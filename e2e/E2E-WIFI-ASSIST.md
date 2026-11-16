# E2E：觸控板 Wi-Fi 輔助（D30）

規格：`docs/superpowers/specs/2026-11-16-wifi-assist-design.md`。自動量測工具：`e2e/scripts/measure-trackpad.sh`（`RK_WIFI_POINTER=on|off`）。

前提：iPhone 與電腦在同一個 Wi-Fi 網路；App 設定「經 Wi-Fi 傳送游標」開啟，並已允許「區域網路」權限。

## 自動實機量測（主代理執行）

| # | 項目 | 方法 | 通過條件 | 結果 |
|---|---|---|---|---|
| A1 | Windows：Wi-Fi 開時游標走 UDP | `RK_HOST_NAME=Windows RK_WIFI_POINTER=on measure-trackpad.sh win 20` | `path_start=wifi`、`path_end=wifi`；`udp=` 等於 `packets=`、`ble=0` | PASS（2026-11-17）：20/20 筆，`udp=844 packets=844 ble=0`，路徑始終為 wifi |
| A2 | Windows：Wi-Fi 關時游標走藍牙 | 同上，`RK_WIFI_POINTER=off` | `path_*=bluetooth`；`udp=0` | PASS（2026-11-17）：20/20 筆，`ble=845 udp=0` |
| A3 | Windows：Wi-Fi 時輸出節奏不比藍牙差 | 比較 A1、A2 的 `pointer_timing_out` | Wi-Fi 的 p90 不高於藍牙 + 5 ms | PASS（PR #130 後）：每筆 p90 中位數 Wi-Fi 20.5 ms、藍牙 21 ms。修正前 FAIL：Wi-Fi 46 ms、藍牙 29.5 ms |
| A3b | Windows：急轉向筆跡 | `RK_STROKE_PATTERN=turns`（每筆連續 2 秒，每 0.1 秒隨機轉向上下左右，每段 40 pt，seed 1，Wi-Fi 開／關路線相同） | 同 A3 | PASS（2026-11-17）：兩邊各 2,785 個封包；輸出間隔每筆 p90 中位數 Wi-Fi 18 ms、藍牙 21.5 ms，p99 中位數 32.5 ms、35 ms；播放延遲上限 24.5 ms、35 ms |
| A4 | Linux：同 A1–A3 | `measure-trackpad.sh linux 20` | 同上 | TBD（需安裝新版 .deb） |
| A5 | Mac：同 A1–A3 | `measure-trackpad.sh mac 20` | 同上 | TBD（需重裝 Mac Receiver 並允許區域網路） |

## 使用者手感（實機，TBD）

| # | 項目 | 步驟 | 通過條件 | 結果 |
|---|---|---|---|---|
| B1 | 首次允許 | 新裝 App，開啟「經 Wi-Fi 傳送游標」 | 出現「區域網路」權限提示；按允許後觸控板頁顯示「Wi-Fi」 | TBD |
| B2 | 拒絕權限 | 在提示按「不允許」 | 觸控板頁顯示「藍牙」，游標照常移動 | TBD |
| B3 | 關閉開關 | App 設定關閉「經 Wi-Fi 傳送游標」 | 觸控板頁顯示「藍牙」 | TBD |
| B4 | 離開 Wi-Fi | 觸控板使用中關掉 iPhone Wi-Fi | 約 1 秒內顯示「藍牙」，游標不停 | TBD |
| B5 | 回到 Wi-Fi | 再開 iPhone Wi-Fi，重新叫出觸控板 | 顯示「Wi-Fi」 | TBD |
| B6 | 手感 | 在 Windows、Linux、Mac 各畫圈 30 秒 | 不比藍牙卡；點擊、拖曳、捲動正常 | TBD |
| B7 | 打字不受影響 | Wi-Fi 開啟時打 50 字 | 0 遺漏、0 重複 | TBD |
| B8 | Mac 區域網路權限 | 重裝 Mac Receiver 後第一次使用觸控板 | 出現 Mac「區域網路」提示；允許後顯示「Wi-Fi」 | TBD |
