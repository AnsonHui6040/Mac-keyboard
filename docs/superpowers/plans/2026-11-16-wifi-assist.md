# Wi-Fi 輔助（D30）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 觸控板游標封包在同一區域網路時改走 UDP，否則自動退回藍牙；Mac、Windows、Linux 三種接收端都支援。

**Architecture:** 接收端先送加密探測（magic `0x05`）到手機在 `pointerOpen.wifi` 公布的位址；手機收到後把 `0x03` 封包送回探測來源。封包格式、金鑰與計數器不變，接收端把兩條路的封包交給同一個 opener。

**Tech Stack:** Swift（CryptoKit、Network framework）、Rust（chacha20poly1305、tokio `UdpSocket`）。

**Spec:** `docs/superpowers/specs/2026-11-16-wifi-assist-design.md`

## Global Constraints

- 協定版本仍為 4；`wifi` 為選用欄位；舊版兩端必須照舊運作。
- 正規 JSON 依 `docs/protocol/v4.md` §3.1：鍵依位元組排序，沒有值的選用欄位整個鍵不出現。
- log 不記文字、按鍵、金鑰、nonce、封包內容；位址只記個數。
- Provisional 值：探測間隔 250 ms、路徑存活 1000 ms、`addrs` 上限 4。
- 子代理不得 commit 或 push；只改 brief 列出的檔案。
- Xcode project 由 XcodeGen 產生：改 `project.yml`，`xcodegen generate`，`LANG=en_US.UTF-8 pod install`，build 用 `-workspace RemoteKeyboard.xcworkspace`。
- 測試：`swift test --package-path Packages/RemoteKeyboardCore`；`cd receiver && cargo test --workspace`；Mac 測試用 `xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -destination 'platform=macOS'`。

## Review Focus

1. 區域網路上的第三者送垃圾 UDP 到接收端的 socket：不得觸發「連續 8 個失敗換新 `pointerGrant`」（W10）。測試放 WF2、WF4。
2. 手機在 UDP 路徑可用時，藍牙 `radioBlocked` 不得卡住游標封包；路徑失效後下一個封包必須改走藍牙且計數器不重用。測試放 WF3（`PointerPathMonitor` 與送出選擇的純邏輯）。
3. `pointerOpen` 帶不合規則的 `wifi`（0 個或 5 個位址、迴路位址、port 0）：接收端照常開啟通道但不探測。測試放 WF1（解碼）與 WF2（行為）。
4. 通道關閉、連線中斷、開關關閉、`pointerGrant` 換新後不得再送任何探測。測試放 WF2、WF4。
5. 探測被重播（同一個資料報收兩次）：手機不得延長路徑存活。測試放 WF1（opener）與 WF3。

---

### Task WF1：共用協定（Swift Core＋Rust rk-core＋協定文件）

**Files:**
- Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Channel/CounterChannel.swift`（`Kind.wifiProbe`：magic `0x05`、info `rk-wfprobe-h2p`、nonce 前綴 `WFP3`、明文 16）
- Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/KeyboardEvent.swift`（`pointerOpen(grant: UInt32, wifi: WifiOffer?)`）
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/WifiOffer.swift`
- Modify: 所有 `.pointerOpen(grant:)` 的呼叫處（iOS、macOS、Core）改為帶 `wifi: nil`，行為不變
- Modify: `receiver/rk-core/src/channel.rs`（`derive_probe_key`、`ProbeSealer`／`ProbeOpener` 或以參數化的既有型別實作）、`receiver/rk-core/src/message.rs`（`EventKind::PointerOpen { grant, wifi: Option<WifiOffer> }`）
- Modify: `receiver/rk-core/src/rust_vectors.rs`、`receiver/testdata/*.json`、Swift 的對應向量測試
- Modify: `docs/protocol/v4.md`（§3.4 表格與範例、新增 §8.6，含範例向量）

**Interfaces:**
- Produces（Swift）：`public struct WifiOffer: Equatable, Sendable { public let addrs: [String]; public let port: UInt16; public init?(addrs:port:) }`，`init?` 依 spec §5.1 驗證；`CounterChannel.Kind.wifiProbe`；`ChannelSet.sealer(.wifiProbe)`／`opener(.wifiProbe)`。
- Produces（Rust）：`pub struct WifiOffer { pub addrs: Vec<Ipv4Addr>, pub port: u16 }`，`WifiOffer::new(addrs, port) -> Option<Self>`；`rk_core::channel::{PROBE_MAGIC (0x05), seal_probe / ProbeSealer::seal(&mut self) -> Result<[u8; 41], ChannelError>}`；`EventKind::PointerOpen { grant: u32, wifi: Option<WifiOffer> }`。解碼時不合規則的 `wifi` 變成 `None`，不是錯誤。

- [ ] 測試先行：Swift `wifiProbe` 封包可用同金鑰打開、重播被拒；`pointerOpen` 帶／不帶 `wifi` 的正規 JSON 與 spec §5.1 範例逐位元組相同；不合規則的 `wifi` 解碼為 `nil`（0 個、5 個位址、`127.0.0.1`、`224.0.0.1`、`255.255.255.255`、`0.0.0.0`、port 0）
- [ ] Rust 同樣的測試；`rust_vectors` 與 Swift 向量互相驗證（探測計數器 1 的封包、帶 `wifi` 的 `pointerOpen` 密封事件）
- [ ] 實作至全綠：`swift test --package-path Packages/RemoteKeyboardCore`、`cd receiver && cargo test --workspace`
- [ ] iOS 與 Mac 編譯通過（只改呼叫處簽名）
- [ ] 協定文件更新

### Task WF2：Windows／Linux 接收端

**Files:**
- Create: `receiver/rk-receiver/src/wifi.rs`（純邏輯：目標、排程、來源過濾）
- Modify: `receiver/rk-receiver/src/app.rs`（`Effect::Wifi(WifiCommand)`、`on_wifi_datagram`、計時）、`receiver/rk-receiver/src/runner.rs`（UDP socket）、`receiver/rk-core/src/pointer.rs`（UDP 來源的失敗不計數）、`receiver/rk-receiver/src/diag_stats.rs`（若需統計）

**Interfaces:**
- Consumes：WF1 的 `WifiOffer`、探測 sealer。
- Produces：`pub enum WifiCommand { Send { to: Vec<SocketAddrV4>, bytes: Vec<u8> } }`；`App::on_wifi_datagram(&mut self, from: SocketAddr, bytes: &[u8]) -> Vec<Effect>`；`PointerReceiver::handle_packet_from(&mut self, packet, now, transport: Transport)`（`Transport::{Ble, Udp}`；`Udp` 的失敗不計入 8 次）。

- [ ] 測試：開啟通道且帶 `wifi` → 下一次計時產生對每個位址的 `Send`，探測可用該連線的探測金鑰打開；250 ms 節奏
- [ ] 測試：不帶 `wifi`、`wifi` 不合規則、通道被拒 → 不產生 `Send`
- [ ] 測試：`pointerClose`、斷線、開關關閉、`pointerGrant` 換新後不再產生 `Send`
- [ ] 測試：來源不在目標內的資料報被忽略；來自目標的合法 `0x03` 會移動游標（與藍牙相同效果）
- [ ] 測試：UDP 上連續 20 個壞封包不換新 `pointerGrant`；藍牙上 8 個仍會
- [ ] runner：綁定 `0.0.0.0:0`、送出、接收；socket 錯誤只記 log 不中止程式
- [ ] log：`wifi_probe_start targets=`、`wifi_probe_stop`、`pointer_in transport=udp` 的計數（併入既有 pointer timing 統計即可）
- [ ] `cargo test --workspace`、`cargo clippy --workspace -- -D warnings` 全綠；Windows target 交叉檢查依既有做法（`cargo check --target x86_64-pc-windows-gnu` 或 CI）

### Task WF3：iPhone（主 App＋鍵盤擴充功能）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/PointerPathMonitor.swift`
- Create: `iOS/RemoteKeyboardExtension/Trackpad/WifiPointerLink.swift`（`NWListener`、位址列舉、UDP 送出）
- Create: `iOS/RemoteKeyboardApp/...`（區域網路提示觸發，位置依既有設定頁）
- Modify: `KeyboardBLEPeripheral.swift`（`openPointer` 帶 `wifi`、`drainWithPointer` 依路徑選擇）、`TrackpadPageView.swift`（W13 顯示）、主 App 設定頁（W11）、`project.yml`（主 App `Info.plist` 加 `NSLocalNetworkUsageDescription`）、共用設定（App Group 鍵）

**Interfaces:**
- Consumes：WF1。
- Produces：`public struct PointerPathMonitor { public init(liveWindowMicros: UInt64 = 1_000_000); public mutating func probeAccepted(atMicros: UInt64); public func path(atMicros: UInt64) -> PointerPath; public mutating func reset() }`，`public enum PointerPath { case bluetooth, wifi }`。

- [ ] 測試（Core）：沒有探測為 `.bluetooth`；探測後 1000 ms 內 `.wifi`、之後 `.bluetooth`；`reset` 回 `.bluetooth`
- [ ] 擴充功能：通道開啟時起 listener，取得 port 與位址後才送 `pointerOpen`（listener 500 ms 內沒有 ready 就不帶 `wifi`）；收到資料報先用 `opener(.wifiProbe)` 驗證，成功才 `probeAccepted` 並記下來源
- [ ] `drainWithPointer`：`.wifi` 時封包以 UDP 送出、不受 `radioBlocked` 影響；送出錯誤時 `reset` 並把該封包改由藍牙處理（新計數器重新密封）
- [ ] 通道關閉或連線結束時關閉 listener 與連線、`reset`
- [ ] 主 App 開關（預設開）與 W12 提示觸發；關閉時不帶 `wifi`
- [ ] 觸控板頁顯示「Wi-Fi」／「藍牙」
- [ ] 鍵盤 lifecycle log：`wifi path up`、`wifi path down reason=`，不記位址
- [ ] `swift test`、iOS build（Debug＋Release）通過
- [ ] 實機（主代理）：與 WF2 的 Linux 接收端驗證路徑與游標；最後重裝 Release

### Task WF4：Mac Receiver

**Files:**
- Create: `macOS/MacReceiver/Bluetooth/WifiProbeLink.swift`
- Modify: `ReceiverBLECentral.swift`（`pointerOpen` 的 `wifi`、探測計時、UDP 收到的 `0x03` 交給既有處理且不計失敗）、`macOS/MacReceiver/Info.plist`（`NSLocalNetworkUsageDescription`）、`PointerReceiver.swift`（若失敗計數在此）
- Test: `macOS/MacReceiverTests/WifiProbeLinkTests.swift`

- [ ] 測試：與 WF2 相同的五類行為（以注入的時間與假的 UDP 送出）
- [ ] 實作與 `xcodebuild test` 全綠
- [ ] 實機 TBD（使用者重裝 Mac Receiver 並允許區域網路提示）

### Task WF5：實機驗證與文件

**Files:**
- Modify: `docs/superpowers/verification/2026-10-29-remote-keyboard-acceptance-report.md`（新增「Wi-Fi 輔助（D30）」一節）
- Modify: `docs/manual/`（觸控板章節與疑難排解，中英文）
- Create: `e2e/E2E-WIFI-ASSIST.md`（使用者手感清單，實機項目 TBD）

- [ ] Linux、Windows：觸控板頁顯示 Wi-Fi、游標移動、接收端 log 有 UDP 封包數；擋住 UDP 後 1 秒內顯示藍牙
- [ ] 報告附實際輸出；自動與實機分開列
- [ ] iPhone 重裝 Release
