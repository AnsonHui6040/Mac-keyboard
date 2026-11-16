# Wi-Fi 輔助：觸控板游標封包改走區域網路（D30）

**日期**：2026-11-16｜**狀態**：APPROVED（使用者 2026-11-16 指示「開始處理 Wi-Fi 輔助實作，全程不需要問我」，設計決定由主代理作出）｜**前身**：`docs/superpowers/research/2026-11-01-trackpad-wifi-fallback.md`

## 1. 目的

觸控板游標在藍牙上會「停一下再追」。2026-11-01 的分析指出瓶頸是 BLE 連線事件的時間表：iPhone 是 Peripheral，無法決定連線間隔，一次錯過就延後 15–30 ms。頻寬不是問題。

本設計讓 `0x03` 游標封包在手機與電腦位於同一個區域網路時改走 UDP。其餘全部（配對、握手、金鑰、文字、`pointerOpen`／`pointerClose`、心跳、看門狗）不變，仍走藍牙。Wi-Fi 不通時自動退回藍牙，使用者不需要任何操作。

## 2. 目標、非目標

| 類別 | 內容 |
|---|---|
| 目標 | 三種接收端（Mac、Windows、Linux）都支援；同一區域網路時游標封包走 UDP；Wi-Fi 不通、被拒權限、路由器隔離用戶端時自動用藍牙；新舊版本可以混用 |
| 非目標 | 文字與其他事件走 Wi-Fi；AWDL／點對點 Wi-Fi；Bonjour 探索；跨網段或經網際網路；IPv6 |
| 反目標 | 不新增配對步驟；不在 Wi-Fi 上傳送任何未加密的內容；不讓區域網路上的第三者能令觸控板失效 |

## 3. 前提（查證結果）

來源：Apple TN3179「Understanding local network privacy」（2026-10-06 版）。

| # | 事實 | 對設計的影響 |
|---|---|---|
| F1 | 送出 UDP 單播到區域網路位址需要「區域網路」權限；接收 UDP 單播不需要 | iPhone 送游標封包要權限；Mac 送探測封包要權限 |
| F2 | App 擴充功能沿用主 App 的權限狀態；說明文字放在主 App 的 `Info.plist` | 由主 App 觸發提示；鍵盤擴充功能不放 `NSLocalNetworkUsageDescription` |
| F3 | 權限未決定時，被視為在背景的程式會被直接拒絕，不顯示提示 | 主 App 在前景時先觸發提示，見 §6.4 |
| F4 | 沒有 API 可直接問有沒有權限；被拒時 `NWConnection` 進入 `waiting` 且 `unsatisfiedReason == .localNetworkDenied` | 以「有沒有收到探測、送不送得出」判斷路徑，不判斷權限本身 |
| F5 | macOS 15 起也有區域網路權限；由 launchd 啟動的 daemon、root、Terminal 執行的工具不受限 | Mac Receiver 第一次送探測時會跳提示，使用者允許一次 |
| F6 | 一般使用者安裝的 Windows 接收端（per-user Inno）無法新增防火牆規則；Windows 防火牆是有狀態的，主機先送出的 UDP，對方從同一位址與連接埠的回覆可以進來 | 由接收端先送探測（§5.2），不需要防火牆規則 |

## 4. 決定

| # | 項目 | 決定 | 理由 |
|---|---|---|---|
| W1 | 誰先送 | 接收端先送探測到手機；手機收到合法探測後，把游標封包送回探測的來源位址 | F6：Windows 不需防火牆規則；F1：手機收探測不需權限 |
| W2 | 位址交換 | `pointerOpen` 加選用欄位 `wifi`，內含手機的 IPv4 位址（最多 4 個）與 UDP 連接埠；經已加密的藍牙傳送 | 不用 Bonjour，不需 `NSBonjourServices`；舊接收端依 §3.1「不認識的鍵一律忽略」，自動不用 Wi-Fi |
| W3 | 能力協商 | 不協商。手機收不到探測就一直用藍牙 | 新手機配舊接收端、舊手機配新接收端都照舊運作 |
| W4 | 游標封包格式 | 不變：同一個 `0x03` 信封、同一把 `K_ptr`、同一個計數器 | 接收端把兩條路的封包交給同一個 opener，防重播自然跨傳輸一致 |
| W5 | 每個封包走哪一條 | 路徑可用時只走 UDP，否則只走藍牙；不同時送兩條 | 避免重複；計數器共用，接收端分不出也不需分 |
| W6 | 探測封包 | 新的計數器通道：magic `0x05`，主機到手機，16 bytes 明文全為 0；金鑰從同一個 `pairKey` 與兩個握手 nonce 推導，標籤 `rk-wfprobe-h2p` | 沿用既有信封與防重播，手機不接受偽造的探測，區域網路上的人無法把游標資料引到別處 |
| W7 | 探測頻率與路徑存活 | 接收端每 250 ms 對每個位址送一個探測（Provisional）。手機在最後一個合法探測後 1000 ms 內（Provisional）認定路徑可用 | 1 秒內退回藍牙；探測同時保持 Windows 防火牆與 NAT 的狀態 |
| W8 | 何時探測 | 接收端只在指標通道開啟、`pointerOpen` 帶 `wifi` 時探測；通道關閉、連線中斷、開關關閉、`pointerGrant` 換新時停止 | 只有觸控板頁開著才用 Wi-Fi，省電 |
| W9 | 接收端只收哪些 UDP | 只收來源等於某個已探測目標（位址＋連接埠）的資料報；長度 41、首位元組 `0x03` | 擋掉無關流量 |
| W10 | UDP 上的失敗不計數 | UDP 收到但未通過 §8.2 檢查的封包只丟棄，不計入「連續 8 個未通過即換新 `pointerGrant`」 | 反目標：區域網路上的人送垃圾封包不能令觸控板一直被關 |
| W11 | 手機端開關 | 主 App「設定 › 觸控板」新增「經 Wi-Fi 傳送游標」，預設開。關閉時 `pointerOpen` 不帶 `wifi` | 使用者可以比較兩條路，也可以完全不用區域網路 |
| W12 | 權限提示 | 主 App 進入「設定 › 觸控板」頁、或把開關打開時，用 TN3179 的方法觸發一次區域網路提示 | F3：鍵盤擴充功能自己觸發可能被直接拒絕 |
| W13 | 顯示 | 觸控板頁頂部、傳輸次數旁顯示目前路徑「Wi-Fi」或「藍牙」 | 使用者與實機測試都能直接看到 |
| W14 | 接收端開關 | 不新增 | YAGNI；手機端開關已足夠 |
| W15 | 手機的監聽 | 鍵盤擴充功能用 `NWListener`（UDP，連接埠由系統配給），只在指標通道開啟期間存在 | 收探測不需權限（F1） |
| W16 | log | 只記事件種類、次數、時間與結果：`wifi_probe_start targets=`、`wifi_path_up`、`wifi_path_down`、各傳輸的游標封包數；不記任何封包內容，位址只記個數 | 專案規則：log 不記內容 |

## 5. 協定變更（寫入 `docs/protocol/v4.md`，協定版本仍為 4）

### 5.1 `pointerOpen` 的選用欄位 `wifi`

```json
{"pointerOpen":{"grant":305419896,"wifi":{"addrs":["192.168.1.23"],"port":50123}}}
```

| 欄位 | 型別 | 規則 |
|---|---|---|
| `addrs` | 字串陣列 | 1 到 4 個點分十進位 IPv4 位址；不得是 0.0.0.0、迴路位址、廣播位址或多播位址 |
| `port` | 整數 | 1 到 65 535 |

接收端遇到不合規則的 `wifi`：當作沒有帶 `wifi` 處理（仍照常開啟通道），不視為格式錯誤。不帶 `wifi` 與 v4 原本相同。

### 5.2 探測封包（§8.6，新增）

| 項目 | 值 |
|---|---|
| magic | `0x05` |
| 方向 | 主機到手機，UDP，目的地為 `wifi.addrs[i]:wifi.port` |
| 金鑰 | `HKDF-SHA256(ikm = pairKey, salt = 空, info = "rk-wfprobe-h2p"(14) ‖ hostNonce(16) ‖ phoneNonce(16), 32)` |
| nonce | `"WFP3"(4) ‖ counter(8, BE)` |
| 明文 | 16 bytes，傳送端一律為 0；接收端不檢查內容 |
| 封包長度 | 41 |
| 計數器與防重播 | 與 §8.2 相同；每條已驗證的連線一組，從 1 起，用到連線結束 |

範例向量（`pairKey` 取自 §5.5、nonce 取自「記號」、計數器 1）由 WF1 以 Swift 產生、Rust 驗證，寫入 §8.6。

### 5.3 游標封包在 UDP 上

- 手機收到合法探測後，把之後的 `0x03` 封包以 UDP 送到該探測的來源位址與連接埠，每個資料報一個封包。
- 接收端把 UDP 收到的封包與藍牙收到的交給同一個處理流程（§8.2 的檢查、§8.4 的按鍵狀態與看門狗），只有 W10 不同。

## 6. 各端變更

### 6.1 共用邏輯（Swift `RemoteKeyboardCore`、Rust `rk-core`）

- 計數器通道新增 `wifiProbe` 種類（Swift `CounterChannel.Kind.wifiProbe`；Rust `rk-core` 新增探測的 sealer）。
- `KeyboardEvent.pointerOpen` 帶選用的 `WifiOffer { addrs, port }`；兩種語言對同一事件輸出逐位元組相同的 JSON，並有跨語言向量。
- Swift 新增純邏輯 `PointerPathMonitor`：記錄最後一個合法探測的時間與來源，回答「現在走 UDP 還是藍牙」，可用注入的時間測試。

### 6.2 Windows／Linux 接收端（`rk-receiver`）

- `App` 收到帶 `wifi` 的 `pointerOpen` 並開啟通道後，記錄目標，並經既有計時機制每 250 ms 產生 `Effect::Wifi(WifiCommand::Send { to, bytes })`。
- `runner` 持有一個綁在 `0.0.0.0:0` 的 UDP socket（tokio），執行送出，並把收到的資料報交給 `App::on_wifi_datagram(from, bytes)`。
- 通道關閉等 W8 的情況清除目標並停止探測。

### 6.3 Mac Receiver

- 與 6.2 相同的行為，以 Network framework 實作，放在 `ReceiverBLECentral` 所在的序列佇列。
- `Info.plist` 加 `NSLocalNetworkUsageDescription`。

### 6.4 iPhone

- 主 App：`Info.plist` 加 `NSLocalNetworkUsageDescription`；設定頁開關與提示觸發（W11、W12）；開關值經 App Group 給鍵盤。
- 鍵盤擴充功能：指標通道開啟時起 `NWListener`，取得連接埠與本機 IPv4 位址（`getifaddrs`，篩選有 `IFF_BROADCAST`、非迴路的介面，不寫死 `en0`），放進 `pointerOpen`；收到探測交給 `PointerPathMonitor`；`drainWithPointer` 在路徑可用時改用 UDP 送，藍牙忙碌（`radioBlocked`）不影響 UDP。
- 觸控板頁顯示路徑（W13）。

## 7. 驗證

| 類別 | 項目 | 方法 |
|---|---|---|
| 自動 | 探測與 `wifi` 欄位的跨語言向量 | `swift test`、`cargo test` |
| 自動 | 接收端：探測排程、來源過濾、W10、W8 各種停止情況 | `rk-receiver` 單元測試、Mac `MacReceiverTests` |
| 自動 | 手機：`PointerPathMonitor` 的存活判斷與退回藍牙 | `swift test` |
| 實機（主代理可跑） | Linux、Windows：觸控板頁顯示「Wi-Fi」，游標可動；接收端 log 有 `wifi_path_up` 與 UDP 封包數 | iPhone UI 測試＋SSH 讀 log |
| 實機（主代理可跑） | 退回：接收端阻擋 UDP（Linux 用 `/tmp/rk-*` 內的測試設定）時 1 秒內回到藍牙 | 同上 |
| 實機 TBD（使用者） | 手感：與藍牙比較是否更順 | 使用者親手 |
| 實機 TBD（使用者） | Mac：允許區域網路提示後可用 | 使用者重新安裝 Mac Receiver 後親手 |

## 8. Provisional 總表

| 值 | 用途 | 依據 |
|---|---|---|
| 250 ms | 探測間隔 | 無量測；兼顧退回速度與流量（每個位址每秒 4 個 41 bytes） |
| 1000 ms | 路徑存活時限 | 容許連續丟失 3 個探測 |
| 4 | `addrs` 上限 | 一般手機只有一個 Wi-Fi IPv4 位址 |

## 9. 風險

| 風險 | 處理 |
|---|---|
| 鍵盤擴充功能實際上拿不到主 App 的區域網路權限（F2 有開發者回報例外） | WF3 第一個實機步驟就驗證；不行時路徑一直不可用，行為等同現在，記錄後停下回報 |
| 路由器隔離無線用戶端、訪客網路 | 收不到探測，維持藍牙 |
| 手機換了 Wi-Fi 或位址 | 探測停止到達，1 秒內退回藍牙；下次 `pointerOpen` 帶新位址 |
