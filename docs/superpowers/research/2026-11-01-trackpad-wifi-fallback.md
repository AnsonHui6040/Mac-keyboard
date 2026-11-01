# 備用方案：觸控板游標資料改走 Wi-Fi（暫不進行）

狀態：備用，2026-11-01 使用者決定暫不進行。啟動前須另寫設計文件並經批准。

## 起因

自動模式實機可用，但游標移動時有輕微抖動。

| 取樣（每個 120 Hz 刷新讀游標位置） | 內建觸控板 | iPhone 自動（第 1 次） | iPhone 自動（第 2 次） |
|---|---|---|---|
| 移動中靜止幀 | 2.5% | 18.1% | 36.9% |
| 步距不均 P50／P90 | 0.20／0.82 | 0.48／1.21 | 0.89／3.00 |
| 突跳 | 14 | 68 | 192 |

同一份程式兩次結果相差一倍，較符合無線環境變動，而不是參數未調好。

## 判斷：瓶頸在 BLE 的時間表，不在頻寬

| 項目 | 實際情況 |
|---|---|
| 連線間隔 | 由 Central（Mac）決定；Apple 指引最低 15 ms。iPhone 作為 Peripheral 只能用 `setDesiredConnectionLatency` 給 low／medium／high，且不保證生效 |
| 頻寬 | 游標資料不到 4 KB/s，遠低於上限 |
| 干擾或重傳 | 該次連線事件錯過，封包延到下一個（15–30 ms 後），形成「停一下再追」 |
| 已量到 | 下一個可送時槽 P95 21–25 ms；Mac 到達間隔標準差 14.5 ms |

## 其他裝置的做法

| 裝置 | 傳輸 | 穩定的原因 |
|---|---|---|
| 藍牙滑鼠（BLE HID） | BLE | 硬體自行協商短間隔，每個連線事件送一份報告；iPhone App 做不到 |
| Logitech 接收器 | 專屬 2.4 GHz | 獨立無線電，每秒輪詢 125–1000 次 |
| Universal Control／Sidecar | Wi-Fi 點對點 | 不走 BLE |
| iPhone 遙控滑鼠 App | 區域網路 Wi-Fi | 不走 BLE |

## 方案內容

- BLE 保留：配對、金鑰、鍵盤文字、心跳、看門狗不變。
- 只有 `0x03` 游標封包改走 Network framework（同一 Wi-Fi 的區域網路，或 AWDL 點對點），沿用現有 AEAD 與封包格式。
- Wi-Fi 不可用時退回 BLE。

## 啟動前要先查證

| # | 待查 | 說明 |
|---|---|---|
| 1 | 鍵盤擴充功能能否取得「區域網路」權限 | Remote Mode 已要求完全取用（`RequestsOpenAccess`），但擴充功能是否會跳出區域網路權限提示未驗證 |
| 2 | 同一 Wi-Fi 與點對點的延遲及穩定度 | 需實機比較 |
| 3 | 探索與配對 | 用 Bonjour 找 Mac，或由 BLE 交換位址 |
| 4 | 金鑰與防重放 | 沿用 BLE 配對產生的金鑰，計數器跨傳輸一致 |
| 5 | 省電與背景 | 擴充功能在前景時才連線 |

## 環境排查（不改程式）

- Mac Wi-Fi 已確認為 5 GHz 頻道 48，訊號 −45 dBm；iPhone 藍牙 RSSI −42。
- 未查：iPhone 的 Wi-Fi 頻段、附近其他藍牙裝置。

## 參考

- Silicon Labs – Selecting Suitable Connection Parameters for Apple Devices：https://docs.silabs.com/bluetooth/latest/mobile-apps-suitable-connection-parameters
- Apple – setDesiredConnectionLatency(_:for:)：https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/setdesiredconnectionlatency(_:for:)
- Apple Community – Bluetooth 滑鼠游標停頓與 Wi-Fi 干擾：https://discussions.apple.com/thread/254883600
