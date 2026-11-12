# Windows／Linux 接收端與多主機（D28）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把協定升到 v4（多主機、多手機、以廣播 UUID 選主機），並新增 Windows 11 與 Ubuntu 26.04 的 Rust 接收端，達到可日常使用的 Alpha。

**Architecture:** iPhone 鍵盤仍是 GATT peripheral，三種主機都是 central。協定邏輯有兩份實作：Swift 的 `RemoteKeyboardCore`（iPhone、Mac）與 Rust 的 `rk-core`（Windows、Linux，含手機端 reducer），以 `docs/protocol/v4.md` 為依據，用雙向測試向量對拍。Rust 接收端分四個 crate：`rk-core`（純邏輯）、`rk-ble`（Windows 用 WinRT、Linux 用 BlueZ D-Bus，不用 btleplug）、`rk-inject`（Windows `SendInput`、Linux RemoteDesktop portal）、`rk-receiver`（系統匣與外殼）。

**Tech Stack:** Swift 6（CryptoKit、CoreBluetooth、UIKit、SwiftUI、XCTest、XcodeGen、CocoaPods）；Rust stable（`windows` crate、bluer、serde、serde_json、p256、hkdf、hmac、sha2、chacha20poly1305、ashpd、windows crate）；GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-11-10-windows-linux-receiver-design.md`（D28 修訂 4）；上層 `docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`、`docs/superpowers/specs/2026-11-01-trackpad-design.md`。

## Global Constraints

- `KeyboardEvent.currentVersion` = 4；v3 配對全部作廢，不寫相容路徑。
- GATT 資料庫不變：service `706AA642-68A3-41FA-889D-24E30709B0D0`、`event` `C7FC0313-53E7-4DCD-B75F-2AE66FE9C586`、`control` `320468E2-53B6-4B6A-88EC-AE2752415818`。改的只有廣播封包。
- 配對廣播 UUID：`6BA36ECB-1BF9-49C1-B98D-37402247F356`。
- 選定 UUID：`SHA-256("rk-select" ‖ hostId)` 前 16 bytes，byte 6 高四位元設為 `0100`，byte 8 高兩位元設為 `10`。
- `hostId`、`phoneId`：16 bytes 亂數。名稱不得為空，上限 32 個 UTF-8 bytes；超過時以 Unicode 碼位為單位截斷（保留不超過 32 bytes 的最長開頭，結果是合法的 UTF-8，不以字素為單位）；名稱被清空時改用預設名稱。收到空的或超過 32 bytes 的名稱時配對失敗。
- 主機平台字串 `mac`、`windows`、`linux`；手機平台字串 `ios`、`android`。
- iPhone 最多 8 台主機；每個接收端最多 8 支手機。
- 配對時段 120 秒；握手逾時 5 秒，逾時只中斷連線，不寫入 `authFailed`；收到 `notSelected` 或握手逾時後退避 10 秒（Provisional）。
- 驗證失敗（寫入 `authFailed`）後：Mac 到接收工作階段結束為止不再連線該裝置；Windows、Linux 60 秒（Provisional）內不再連線該裝置，系統匣顯示需要重新配對。收到版本不符的訊息：顯示更新提示、中斷連線、60 秒（Provisional）內不再連線該裝置。
- 只有經選定 UUID 找到的連線才寫入 `hello`；經配對 UUID 找到的不寫，只等 `pairOffer`。
- 掃描：Mac 用 CoreBluetooth，以選定 UUID 為過濾條件並允許重複回報（Provisional，S8 量的是不帶過濾條件的情況）；Windows 用 `BluetoothLEAdvertisementWatcher`（主動掃描）；Linux 用 BlueZ 探索，未連線時每 1.5 秒 `StopDiscovery`＋`StartDiscovery` 並對目標裝置 `RemoveDevice`；連線期間不掃描。
- wire 欄位用中性名稱：`hostNonce`、`hostPublic`；proof 標籤 `phone`、`host`。`pairAccept` 的 `hostId`、`hostName`、`platform` 與 `pairReveal` 的 `phoneId`、`phoneName`、`phonePlatform` 都是訊息內同一層的欄位，不另包一層物件。身分雜湊為 `SHA-256(utf8(name) ‖ 0x00 ‖ utf8(platform))`。
- JSON 一律 `.sortedKeys`；`Data` 為 base64；`UUID` 為大寫字串。Rust 輸出必須與 Swift 逐位元組相同。
- log 只記事件種類、長度、時間與結果；不得含文字內容、金鑰、nonce、proof、配對碼、App 名稱、指標位移。
- Windows 與 Linux 不做焦點安全檢查；Mac 的焦點安全、輸入法切換、觸控板行為不得改變。
- 所有標 Provisional 的項目（spec §15）在對應 spike 或實機驗收前不得寫成已驗證。
- 每個 Swift Task 結束必須全綠：`swift test --package-path Packages/RemoteKeyboardCore`、`MacReceiverTests`、iOS 模擬器 build、Mac build。每個 Rust Task 結束必須全綠：`cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`（在 `receiver/`）。
- 建置：改 `project.yml` 後 `xcodegen generate` 再 `LANG=en_US.UTF-8 pod install`；build 用 `-workspace RemoteKeyboard.xcworkspace`；不提交 `*.xcodeproj`、`*.xcworkspace`、`Pods/`、`receiver/target/`。
- 介面文字用台灣繁體中文；Rust 接收端另備英文，依系統語言選擇。
- 實機驗收標 TBD，使用者親手測完才算 PASS。

## 執行規則

- 每個 Task 一個 worktree、一條 branch、一個 PR；Sonnet 子代理寫程式，不得 commit 或 push；主代理重跑全部驗證並經獨立 reviewer 審查後 commit、開 PR、merge。
- 每個 Task 更新驗收報告 `docs/superpowers/verification/2026-11-10-windows-linux-receiver.md`，附實際輸出。
- 遠端機器：`ssh rk-win`（Windows 11，只接 Wi-Fi）、`ssh rk-linux`（Ubuntu 26.04）。需要互動桌面的步驟用 RustDesk 或由使用者親手操作。
- 在兩台測試機安裝任何東西（rustup、MSVC Build Tools、apt 套件）前，先列出項目與大小並取得使用者同意。
- **決策關卡**：WL0 完成後停下，由使用者確認 S8 結果才進 WL2。WL1 的結果決定 WL7–WL10 是否照本計畫進行；任一項依 spec §12 的決策不通過時，停下回報並用 writing-plans 修訂對應 Task。
- WL7 之後的 Task 在 WL1 完成後才細化步驟。現在只定檔案、介面與測試名稱。

## Review Focus

1. **兩台已配對主機同時在旁邊**：只有被選定的那台連線；另一台不連、不顯示錯誤、不干擾連線中的主機。由 WL0 的 S8、WL3 `testSelectUUIDDiffersPerHost`、WL11 實機覆蓋。
2. **接收端掃描看到過期內容而連上不屬於它的鍵盤**：iPhone 回 `notSelected`，已驗證的另一條連線不受影響；接收端退避 10 秒，不列入略過名單。由 WL3 `testHelloForOtherHostRepliesNotSelected`、`testNotSelectedDoesNotDisturbAuthenticatedCentral`、`testNotSelectedBacksOffWithoutSkipping` 覆蓋。
3. **第二支手機配對後，第一支仍能連**：逐把金鑰驗證，順序不影響結果。由 WL3 `testHostFindsKeyAmongSeveralPhones`、`testUnknownPhoneFailsAfterAllKeys` 覆蓋。
4. **名稱含表情符號或超過 32 bytes**：以碼位為單位截斷，表情符號組合可以被切開，結果仍是合法的 UTF-8；兩端算出相同的金鑰與配對碼。收到空的或超過 32 bytes 的名稱時配對失敗。由 WL3 `testNameClampKeepsWholeCharacters`、`testEmptyOrOverlongPeerNameFailsPairing`、測試向量覆蓋。
5. **補充平面字元與組合字元的文字事件**：Windows 送代理對、Linux 送單一 keysym，不拆壞。由 WL8 `utf16_units_for_supplementary_plane`、WL9 `keysym_for_supplementary_plane` 覆蓋。

---

### Task WL0: S8 廣播 UUID 切換 spike（決策關卡）

**Files:**
- Create: `iOS/RemoteKeyboardApp/Debug/AdvertProbeView.swift`（整個檔案包在 `#if DEBUG`）
- Modify: `iOS/RemoteKeyboardApp/HomeView.swift`（`#if DEBUG` 區塊內加一個進入 `AdvertProbeView` 的列）
- Create（不進 repo）：scratchpad 下的 `spike-scan/`（Rust；第一輪用 btleplug，S8b 改用原生介面）與一支 macOS 用的 Swift 指令稿
- Modify: `docs/superpowers/verification/2026-11-10-windows-linux-receiver.md`（新建，寫入 S8 結果）

**Interfaces:**
- Produces: S8 的結論（每個平台看到新 UUID 的延遲、舊 UUID 是否殘留），決定 WL2 是否照 spec §5.3 進行。

- [ ] **Step 1：取得同意後安裝工具鏈。** Linux：`rustup`（stable）與 `libdbus-1-dev`。Windows：`rustup` 與 MSVC Build Tools（C++ 工作負載）。安裝前把項目與下載大小列給使用者。
- [ ] **Step 2：寫 `AdvertProbeView`。** 一個按鈕在兩個固定 UUID 之間切換廣播：`11111111-2222-4333-8444-555555555555` 與 `AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE`；每次切換先 `stopAdvertising` 再 `startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])`，畫面顯示目前 UUID 與切換時刻（毫秒）。
- [ ] **Step 3：寫 `spike-scan`。** 命令列程式持續掃描（不帶 service 過濾），每收到一筆廣播印一行：單調時鐘毫秒、裝置識別碼、該筆廣播的 service UUID 清單。Windows 與 Linux 用同一份原始碼。macOS 用 `CBCentralManager` 寫等效的指令稿，掃描選項帶 `CBCentralManagerScanOptionAllowDuplicatesKey: true`。
- [ ] **Step 4：實機量測。** 三個平台各切換 20 次，記錄每次從切換到第一次看到新 UUID 的時間，以及之後 10 秒內是否還收到含舊 UUID 的廣播。iPhone 的操作由使用者執行。
- [ ] **Step 5：寫入驗收報告。** 每個平台的中位數、最大值、舊 UUID 殘留次數。通過條件（Provisional）：新 UUID 在 3 秒內出現。
- [ ] **Step 6：驗證並 commit。** iOS 模擬器 build 與 Release build 皆成功，Release 產物不含 `AdvertProbeView`（`nm` 找不到符號）。

```bash
git add iOS/RemoteKeyboardApp/Debug/AdvertProbeView.swift iOS/RemoteKeyboardApp/HomeView.swift docs/superpowers/verification/2026-11-10-windows-linux-receiver.md
git commit -m "test: debug screen that alternates the advertised service UUID (S8)"
```

- [ ] **Step 7：停下回報。** 任一平台不通過時依 spec §12 處理，不進 WL2。

---

### Task WL1: S1–S7、S9 連線與注入 spike

**Files:**
- Create（不進 repo）：scratchpad 下的 `spike-link/`（Windows 用 WinRT、Linux 用 bluer）、`spike-win-input/`（`SendInput`）、`spike-portal/`（ashpd）
- Modify: `docs/superpowers/verification/2026-11-10-windows-linux-receiver.md`

**Interfaces:**
- Consumes: 現行 v3 的 iPhone App 與既有配對（不重新配對）；WL0 安裝的工具鏈。
- Produces: S1–S7、S9 的結論；Linux「非 ASCII 改用貼上」的預設值；WL7–WL10 是否需要修訂。

- [ ] **Step 1：`spike-link`。** Windows 用 WinRT、Linux 用 bluer（不用 btleplug），Linux 指定 hci1。掃描 service `706AA642-…`，連線，訂閱 `event`，寫入 `{"hello":{"macNonce":"<16 bytes base64>"}}` 到 `control`，等待一則經 `FrameCodec` 分段、`type` 為 `helloReply` 的訊息；印出協商後的 MTU 與每一步的耗時。測試前先結束 Mac Receiver。
- [ ] **Step 2：S1（Windows）與 S3（Linux）。** 各做 20 次「鍵盤收起再叫出」，記錄每次從看到廣播到收到 `helloReply` 的時間。通過條件：20 次都在 3 秒內。
- [ ] **Step 3：`spike-win-input` 與 S2。** 讀一個 UTF-8 檔案，啟動後倒數 5 秒，用 `SendInput` + `KEYEVENTF_UNICODE` 逐個 UTF-16 code unit 送出。測試文字 200 字，含英文、繁體中文、表情符號（補充平面）。目標：記事本、瀏覽器網址列、WordPad 或同類編輯器；注音輸入法開與關各一次。以目標內容與原文逐字比對。
- [ ] **Step 4：`spike-portal` 與 S4。** 建立 RemoteDesktop 工作階段（keyboard + pointer，`persist_mode` 持續），同樣的 200 字用 `NotifyKeyboardKeysym` 送出。目標：文字編輯器、Firefox、終端機；IBus 中文輸入法開與關各一次。
- [ ] **Step 5：S5。** 同一個程式加上 Clipboard 介面：寫入、送 Ctrl+V、還原。文字編輯器與 Firefox 各 50 次。
- [ ] **Step 6：S9。** 同一個程式送指標：每秒 60、120、240 次的相對移動各 5 秒，左右鍵各 10 次，垂直與水平捲動各 10 次；記錄 portal 呼叫的往返時間。
- [ ] **Step 7：S6。** RustDesk 連線中重跑 Step 4 的文字編輯器一項。
- [ ] **Step 8：S7。** 在 `spike-link` 收到 notify 時立刻呼叫注入，記錄中位數與 p95。
- [ ] **Step 9：寫入驗收報告並停下回報。** 每項附原始數字與通過與否；依 spec §12 的決策列出對 WL7–WL10 的影響。spike 程式不 commit。

---

### Task WL2: 協定文件 v4

**Files:**
- Create: `docs/protocol/v4.md`

**Interfaces:**
- Produces: WL3（Swift）與 WL6（Rust）共同依據的規格。

- [ ] **Step 1：寫文件。** 章節固定為：GATT 結構與廣播（含選定 UUID 的計算與配對 UUID）；分段格式；每種 `ControlMessage` 與 `PeripheralMessage` 的 JSON 範例（鍵已排序）；身分欄位與名稱截斷規則；配對三步驟與金鑰推導；握手與逐把金鑰驗證；session 加密；計數器通道封包；`ReceiverStatus` 各平台的值；版本不符的處理。現有行為以 `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/` 與 `Channel/` 的程式為準，v4 的差異以 spec §5 為準。
- [ ] **Step 2：金鑰推導寫成逐位元組的定義。**

```
info = hostPublic(65) ‖ phonePublic(65)
     ‖ hostId(16)  ‖ SHA-256(utf8(hostName)  ‖ 0x00 ‖ utf8(hostPlatform))
     ‖ phoneId(16) ‖ SHA-256(utf8(phoneName) ‖ 0x00 ‖ utf8(phonePlatform))
pairKey    = HKDF-SHA256(ikm = ECDH(P-256), salt = "rk-pair-v2", info, 32 bytes)
phoneProof = HMAC-SHA256(pairKey, "phone" ‖ hostNonce ‖ phoneNonce)
hostProof  = HMAC-SHA256(pairKey, "host"  ‖ hostNonce ‖ phoneNonce)
```

- [ ] **Step 3：檢查。** `grep -n "macNonce\|macPublic\|macProof" docs/protocol/v4.md` 結果為 0；文件中每個 JSON 範例都能用 `python3 -m json.tool` 解析。
- [ ] **Step 4：Commit。** `git commit -m "docs: language-neutral protocol specification v4"`

---

### Task WL3: Core 協定 v4（Swift 純邏輯）

**Files:**
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/Identity.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/SelectUUID.swift`
- Create: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Shared/PairedList.swift`
- Modify: `Shared/GATTServiceSpec.swift`、`Shared/Pairing.swift`、`Shared/PairingFlow.swift`、`Shared/AuthHandshake.swift`、`Shared/ControlMessage.swift`、`Shared/KeyboardEvent.swift`（同目錄）
- Modify: `Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Receiver/ReceiverLinkStateMachine.swift`
- Create: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/IdentityTests.swift`、`SelectUUIDTests.swift`、`PairedListTests.swift`、`ProtocolVectorTests.swift`
- Modify: 既有的 `PairingTests.swift`、`PairingFlowTests.swift`、`AuthHandshakeTests.swift`、`ControlMessageTests.swift`、`EventCodecTests.swift`
- Create: `receiver/testdata/swift-vectors-v4.json`

**Interfaces:**
- Consumes: `docs/protocol/v4.md`（WL2）。
- Produces:

```swift
public enum HostPlatform: String, Codable, Sendable { case mac, windows, linux }
public enum PhonePlatform: String, Codable, Sendable { case ios, android }
public struct HostIdentity: Codable, Equatable, Sendable { public let id: Data; public let name: String; public let platform: HostPlatform }    // Codable 只用於本機儲存，不是 wire 形狀
public struct PhoneIdentity: Codable, Equatable, Sendable { public let id: Data; public let name: String; public let platform: PhonePlatform }
public enum IdentityName { public static let maxBytes = 32
    public static func clamp(_ name: String) -> String      // 以 Unicode 碼位為單位，保留不超過 32 bytes 的最長開頭
    public static func isValid(_ name: String) -> Bool }    // 非空且不超過 32 bytes；收到的名稱不合格時配對失敗
public enum SelectUUID { public static func make(hostId: Data) -> UUID }
// GATTServiceSpec.Link.pairingAdvertUUID = "6BA36ECB-1BF9-49C1-B98D-37402247F356"

// ControlMessage：改為手寫 Codable（不用自動合成），其餘訊息的位元組不變
case pairAccept(publicKey: Data, host: HostIdentity)     // wire 扁平：{"pairAccept":{"hostId":"…","hostName":"…","platform":"mac","publicKey":"…"}}
case hello(hostId: Data, hostNonce: Data)
// PeripheralMessage
case pairReveal(publicKey: Data, phone: PhoneIdentity)   // wire 扁平：{"phoneId":"…","phoneName":"…","phonePlatform":"ios","protocolVersion":4,"publicKey":"…","type":"pairReveal"}
case notSelected                                          // wire: {"protocolVersion":4,"type":"notSelected"}
// CentralBinding 新增：func helloDisposition(from: UUID, hostIdMatches: Bool, locked: Bool) -> .handshake | .replyNotSelected | .ignore
//   不相符 → .replyNotSelected（來自綁定的 central 時回覆後解除綁定）；相符且來自綁定的 central → .handshake；
//   相符、來自其他 central：locked（綁定的連線已驗證）→ .ignore，否則改綁定到它 → .handshake
//   hostId 或 hostNonce 不是 16 bytes 屬於格式錯誤：綁定的 central 送來時握手失敗，其他 central 送來時忽略，不回 notSelected
// MacHandshakeOutput 新增 .notSelected；ReceiverLinkStateMachine 新增事件 .notSelected(UUID)

Pairing.sharedKey(myPrivate:peerPublic:hostPublic:phonePublic:host:phone:) throws -> SymmetricKey
Pairing.phoneProof(key:hostNonce:phoneNonce:) / hostProof(key:hostNonce:phoneNonce:) 與對應的 verify

PhonePairing.init(privateKey:phone: PhoneIdentity)      // 完成後多一個 public private(set) var host: HostIdentity?
MacPairing.init(privateKey:host: HostIdentity)          // 完成後多一個 public private(set) var phone: PhoneIdentity?

public struct PairedHost: Codable, Equatable, Sendable { public let identity: HostIdentity }
public struct PairedPhone: Equatable, Sendable { public let identity: PhoneIdentity; public let pairKey: SymmetricKey }
public struct PairedList<Entry> { public static var capacity: Int { 8 } ... }   // add（同 id 覆蓋，滿了回傳 .full）、remove(id:)、entries
public struct HostSelection { public private(set) var hosts: [HostIdentity]; public private(set) var selectedId: Data?
    public mutating func add(_:) -> AddResult; public mutating func remove(id:); public mutating func select(id:) -> Bool; public mutating func cycle() -> HostIdentity? }

PhoneHandshake.init(selected: (hostId: Data, pairKey: SymmetricKey)?, phoneNonce: Data)
MacHandshake.init(hostId: Data, phones: [PairedPhone], hostNonce: Data)
// MacHandshakeOutput.authenticated(reply: ControlMessage, phoneId: Data)

ReceiverLinkStateMachine.handshakeBackoffSeconds = 10.0     // 新事件 .handshakeTimeout(UUID)、.notSelected(UUID) → [.cancel(id)]，並把該裝置放進暫擋名單 10 秒；掃描照常，其他裝置不受影響（與 .unsupportedVersion 共用同一份暫擋名單）
ReceiverLinkStateMachine.unsupportedVersionHoldSeconds = 60.0   // 新事件 .unsupportedVersion(UUID)：中斷該連線，60 秒內再發現同一個裝置時不連線，其他裝置不受影響
```

- [ ] **Step 1：寫失敗的測試。** 名稱與斷言如下，全部先確認 RED。

```swift
// IdentityTests
func testNameClampKeepsWholeCharacters()      // 11 個「測」（33 bytes）→ 10 個（30 bytes）；"a" + 8 個 👨‍👩‍👧（145 bytes）→ 30 bytes，結尾為 U+1F468、U+200D、U+1F469：
                                              // 表情符號組合可以被切開，但截斷點在碼位邊界，Data(result.utf8) 能解回同一個字串
func testNameClampLeavesShortNamesAlone()
func testNameValidityRejectsEmptyAndOverlong()   // "" 與 33 bytes → false；32 bytes → true
// SelectUUIDTests
func testSelectUUIDIsDeterministicAndVersion4()   // 同 hostId 兩次相同；uuid.uuid.6 >> 4 == 4；uuid.uuid.8 >> 6 == 2
func testSelectUUIDDiffersPerHost()
func testSelectUUIDNeverEqualsLinkOrPairingUUID()
// PairingTests
func testSharedKeyChangesWhenHostNameChanges()
func testSharedKeyChangesWhenHostPlatformChanges()
func testSharedKeyChangesWhenPhoneIdentityChanges()
func testProofLabelsAreDistinct()                 // phoneProof != hostProof（相同輸入）
// PairingFlowTests
func testPairingCarriesBothIdentities()           // 兩端完成後 host、phone 互相看到對方的身分，pairKey 與 sas 相同
func testTamperedHostNameGivesDifferentSAS()
func testEmptyOrOverlongPeerNameFailsPairing()    // pairAccept 的 hostName、pairReveal 的 phoneName 為空或 33 bytes → .failed，不自行截斷
func testWrongIdLengthFailsPairing()              // hostId 或 phoneId 不是 16 bytes → .failed
// AuthHandshakeTests
func testHelloForOtherHostRepliesNotSelected()    // PhoneHandshake.receive(.hello(其他 hostId)) == .send(.notSelected)，沒配對過的 hostId 也一樣；selected 為 nil 時也回 .notSelected
func testHelloWithBadHostIdLengthFails()          // hostId 15 bytes → .failed，不是 .notSelected；與 hostNonce 15 bytes 相同
func testMatchingHelloFromOtherCentralIsIgnoredWhenLocked()      // CentralBinding：綁定的連線已驗證 → .ignore，綁定不變
func testMatchingHelloFromOtherCentralTakesOverWhenNotLocked()   // 綁定的連線未驗證 → 改綁定並 .handshake
func testNotSelectedDoesNotDisturbAuthenticatedCentral()   // CentralBinding：已驗證時，另一個 central 的 hello 得到 .replyNotSelected，綁定不變
func testHelloFromBoundCentralWithWrongHostReleasesBinding()
func testHostTreatsNotSelectedAsBackoff()         // MacHandshake.receive(.notSelected) == .notSelected，不是 .authFailed
func testHelloForSelectedHostReplies()
func testHostFindsKeyAmongSeveralPhones()         // 8 支手機，目標在第 1、第 8 位都回 .authenticated 且 phoneId 正確
func testUnknownPhoneFailsAfterAllKeys()          // 回 .authFailed
func testNoPhonesFails()
// PairedListTests
func testAddOverwritesSameId(); func testAddBeyondEightIsRefused(); func testRemoveSelectedPicksNextOrNone()
func testCycleWrapsAround(); func testCycleWithOneHostReturnsNil()
// ControlMessageTests / EventCodecTests
func testHelloWireShape()                         // {"hello":{"hostId":"…","hostNonce":"…"}}
func testPairAcceptWireShape()                    // 身分欄位與 publicKey 同一層，鍵依序為 hostId、hostName、platform、publicKey
func testPairRevealWireShape()                    // 扁平：phoneId、phoneName、phonePlatform、protocolVersion、publicKey、type
func testUnchangedControlMessagesKeepTheirBytes() // 手寫 Codable 後 ack、status、auth、authFailed、bye、sealed 的輸出與 docs/protocol/v4.md 的範例逐位元組相同
func testVersion3MessageIsUnsupportedVersion()
// ReceiverLinkStateMachine（既有測試檔）
func testHandshakeTimeoutBacksOffWithoutSkipping()   // .handshakeTimeout(id) 於 .ready(id) → [.cancel(id)]；10 秒內再發現 id 不連線，再發現其他裝置照常連線；不產生 .startScanAfter
func testNotSelectedBacksOffWithoutSkipping()        // .notSelected(id) 同上
func testUnsupportedVersionHoldsOnlyThatDeviceFor60Seconds()   // 60 秒內同一個裝置再被發現時不連線，另一個裝置照常連線；60 秒後恢復
```

- [ ] **Step 2：實作到全綠。** `IdentityName.clamp` 以 Unicode 碼位為單位累加 UTF-8 長度。`ControlMessage` 改為手寫 Codable，讓 `pairAccept` 的身分欄位扁平；`PhonePairing`、`MacPairing` 收到不合格的名稱或長度不對的識別碼時回 `.failed`。`MacHandshake` 依清單順序驗證 proof，每把都用常數時間比較。把所有 `mac…` 參數與欄位名稱改為 `host…`，`macLabel` 改為 `"host"`，`pairSalt` 改為 `"rk-pair-v2"`。
- [ ] **Step 3：測試向量。** `ProtocolVectorTests.testVectorsFileIsCurrent()` 以固定輸入（私鑰、nonce、身分寫死在測試內）產生一份 JSON，與 `receiver/testdata/swift-vectors-v4.json` 比對；環境變數 `RK_WRITE_VECTORS=1` 時改為寫檔。內容：每種訊息的編碼位元組、`selectUUID`、名稱截斷前後、`pairKey`、`sas`、兩個 proof、兩個方向各一則 session 密文與其明文、指標通道一個封包與其明文、一則 600 bytes 訊息以 185 bytes 分段的結果。
- [ ] **Step 4：驗證。** `swift test --package-path Packages/RemoteKeyboardCore` 全過。此時 iOS 與 Mac 的 adapter 會編譯失敗，屬預期，WL4、WL5 修復；本 Task 的 PR 與 WL4、WL5 一起合併前不單獨 merge 進 main。
- [ ] **Step 5：Commit。** `git commit -m "feat(core): protocol v4 with host and phone identities"`

WL3、WL4、WL5 共用一條 branch `protocol-v4` 與一個 PR，三者都完成、全部 build 通過後才 merge（main 不能停在編譯不過的狀態）。

---

### Task WL4: iPhone 多主機

**Files:**
- Modify: `iOS/Shared/PairingStore.swift`
- Create: `iOS/Shared/PhoneIdentityStore.swift`
- Modify: `iOS/RemoteKeyboardExtension/Bluetooth/KeyboardBLEPeripheral.swift`、`iOS/RemoteKeyboardApp/PairingPeripheral.swift`、`iOS/RemoteKeyboardApp/PairingView.swift`、`iOS/RemoteKeyboardApp/HomeView.swift`
- Modify: `iOS/RemoteKeyboardExtension/UI/TopAreaView.swift`、`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Keyboard/StatusLine.swift`、`Keyboard/KeyAction.swift`（同套件）
- Modify: `iOS/RemoteKeyboardApp/KeyboardPreviewView.swift`
- Test: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/StatusLineTests.swift`（既有或新建）

**Interfaces:**
- Consumes: WL3 的 `HostSelection`、`SelectUUID`、`PhoneHandshake.init(selected:phoneNonce:)`、`PhonePairing.init(privateKey:phone:)`。
- Produces:

```swift
enum PairingStore {
    static func loadHosts() -> HostSelection                 // App Group UserDefaults，鍵 "rk.hosts.v4"
    static func saveHosts(_ selection: HostSelection)
    static func savePairKey(_ key: SymmetricKey, hostId: Data) -> OSStatus   // Keychain account "pairKey." + hostId 十六進位小寫
    static func loadPairKey(hostId: Data) -> SymmetricKey?
    static func deleteHost(id: Data)                          // 同時刪 Keychain 項目與清單紀錄
    static func removeLegacyKey()                             // 刪 account "pairKey"；App 與 Extension 啟動時各呼叫一次
}
enum PhoneIdentityStore { static func load() -> PhoneIdentity }   // 第一次呼叫時產生 phoneId，存 App Group；name = UIDevice.current.name
// StatusLine.Display 多一個 title: String?（主機名稱；只配對一台時為 nil）
// StatusLine.display(mode:link:receiver:paired:note:host: HostIdentity?, hostCount: Int)
// KeyAction 新增 .cycleHost
```

- [ ] **Step 1：StatusLine 測試（RED）。**

```swift
func testSingleHostHasNoTitle()                  // hostCount 1 → title == nil，text 與現況相同
func testTwoHostsShowHostNameAsTitle()           // title == host.name
func testLinuxUntrustedSaysComputerNotAuthorized()   // platform .linux、trusted false → text == "電腦未授權"
func testMacUntrustedKeepsExistingText()
func testWindowsNeverShowsInputBlocked()
```

- [ ] **Step 2：實作 `StatusLine` 與 `PairingStore`、`PhoneIdentityStore`。**
- [ ] **Step 3：`KeyboardBLEPeripheral`。** 廣播 `SelectUUID.make(hostId:)`；沒有選定主機時不廣播。`.cycleHost`：`HostSelection.cycle()` → `saveHosts` → 以新 UUID 重新廣播 → `resetLink`。握手改用 `PhoneHandshake(selected:phoneNonce:)`。
- [ ] **Step 4：`PairingPeripheral`、`PairingView`。** 廣播 `pairingAdvertUUID`；確認畫面顯示主機名稱與配對碼；確認後 `HostSelection.add` 並設為目前主機；清單已滿時在開始配對前就擋下並顯示「已達 8 台上限，請先刪除一台」。
- [ ] **Step 5：`TopAreaView`。** `title` 不為 nil 時狀態格改兩行（第一行主機名稱、單行、尾端省略；第二行短狀態），整格可點，點擊送 `.cycleHost`；`title` 為 nil 時維持現況且不可點。
- [ ] **Step 6：`HomeView`。** 「已配對」區塊改為主機清單：每列顯示名稱與平台、目前主機有勾選記號、點一列設為目前主機、左滑刪除；清單下方「新增電腦」。
- [ ] **Step 7：預覽狀態。** `KeyboardPreviewView` 新增 `twoHosts`、`twoHostsLongName`（名稱 32 bytes）兩個 `-rkPreview` 狀態。
- [ ] **Step 8：驗證。** `swift test` 全過；iOS 模擬器 build 成功；在 iPhone 18 Pro（402 pt）與 iPhone SE 3（375 pt）模擬器對 `twoHosts`、`twoHostsLongName` 截圖存入 `docs/superpowers/verification/evidence/`，交使用者確認。
- [ ] **Step 9：Commit。** `git commit -m "feat(ios): several paired hosts, tap the status cell to switch"`

---

### Task WL5: Mac Receiver v4 與多手機

**Files:**
- Modify: `macOS/MacReceiver/Pairing/MacPairingStore.swift`、`Pairing/ReceiverSecurity.swift`、`Pairing/PairingSheet.swift`、`Bluetooth/ReceiverBLECentral.swift`、`ReceiverPanel.swift`（皆在 `macOS/MacReceiver/`）
- Modify: `macOS/MacReceiverTests/MacPairingStoreTests.swift`、`ReceiverSecurityTests.swift`、`ReceiverBLECentralTests.swift`、`TestPhone.swift`

**Interfaces:**
- Consumes: WL3 的 `MacHandshake.init(hostId:phones:hostNonce:)`、`MacPairing.init(privateKey:host:)`、`PairedPhone`、`SelectUUID`、`.handshakeTimeout`。
- Produces:

```swift
protocol PairingStoring: AnyObject {            // 取代 PairKeyStoring
    func loadHost() -> HostIdentity             // 沒有就產生並存檔；name 預設 Host.current().localizedName
    func loadPhones() -> [PairedPhone]
    func save(_ phone: PairedPhone) throws      // 同 phoneId 覆蓋；已 8 支且為新 id 時 throw .full
    func delete(phoneId: Data)
    func removeLegacyKey()                      // 刪舊的 pair-key 檔
}
// 檔案：<Application Support>/RemoteKeyboardReceiver/host.json（0600）、phones/<phoneId 十六進位>.key（0600，32 bytes）、phones/<phoneId 十六進位>.json（名稱與平台）
```

- [ ] **Step 1：測試（RED）。**

```swift
// MacPairingStoreTests
func testHostIdentityIsStableAcrossLoads(); func testSecondPhoneDoesNotReplaceFirst()
func testSamePhoneIdOverwrites(); func testNinthPhoneIsRefused(); func testFilesAre0600()
func testLegacyKeyFileIsRemoved()
// ReceiverSecurityTests
func testSecondPairedPhoneAuthenticates()
func testHandshakeTimeoutDoesNotSkipPeripheral()        // 逾時後同一個 peripheral 再次被發現時仍會連線
func testHandshakeTimeoutWritesNoAuthFailed()           // 逾時只中斷連線，control 上沒有寫入 authFailed
func testUnsupportedVersionShowsUpdatePhoneNote()       // 收到 protocolVersion 3 → 面板狀態為「請更新 iPhone App」
func testUnsupportedVersionDisconnectsAndHoldsFor60Seconds()   // 中斷連線；60 秒內同一個 peripheral 再被發現時不連線
func testPairingAdvertConnectionSendsNoHello()          // 經配對 UUID 找到的連線即使已有配對金鑰也不寫入 hello，只等 pairOffer
// ReceiverBLECentralTests
func testScansSelectUUIDOnly(); func testScansPairingUUIDOnlyWhileWindowOpen()
func testScanAllowsDuplicates()                         // 掃描選項帶 CBCentralManagerScanOptionAllowDuplicatesKey: true
```

- [ ] **Step 2：實作。** 掃描改為 `[SelectUUID.make(hostId:)]` 並允許重複回報，配對時段開著時加上 `pairingAdvertUUID`，時段關閉時立刻重設掃描條件。每次發現時依該筆廣播的 service UUID 記下是經選定 UUID 還是配對 UUID 找到的，經配對 UUID 的連線不寫入 `hello`。`TestPhone` 改為 v4。
- [ ] **Step 3：面板。** 配對區塊改為手機清單（名稱、平台、刪除），上方顯示目前連線的手機名稱；配對確認框顯示手機名稱。
- [ ] **Step 4：驗證。** `swift test`、`MacReceiverTests`、Mac build、iOS 模擬器 build、真機 build-for-testing 全過。安裝後執行 `scripts/install-mac-receiver.sh` 並用 `lsregister -u` 清掉 build 產物。
- [ ] **Step 5：實機項目（TBD）。** iPhone 與 Mac 重新配對、打字、觸控板；Mac 的延遲與焦點行為與升級前相同；帶選定 UUID 過濾條件的掃描在 iPhone 切換主機後 3 秒內跟上，且不會連上已改選其他主機的 iPhone（Provisional，S8 沒有量過帶過濾條件的情況）。
- [ ] **Step 6：Commit、開 PR（含 WL3、WL4）。** `git commit -m "feat(mac): protocol v4, several paired phones"`

---

### Task WL6: `rk-core`（Rust 協定核心）與 CI

**Files:**
- Create: `receiver/Cargo.toml`（workspace）、`receiver/rk-core/Cargo.toml`、`receiver/rk-core/src/{lib,json,frame,identity,pairing,handshake,session,channel,dedup,pointer,select_uuid}.rs`
- Create: `receiver/rk-core/tests/{swift_vectors,loopback}.rs`、`receiver/testdata/rust-vectors-v4.json`
- Create: `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/RustVectorTests.swift`
- Create: `.github/workflows/receiver.yml`
- Modify: `.gitignore`（加 `receiver/target/`）

**Interfaces:**
- Consumes: `docs/protocol/v4.md`、`receiver/testdata/swift-vectors-v4.json`。
- Produces（`rk_core`）：

```rust
pub struct HostIdentity { pub id: [u8; 16], pub name: String, pub platform: HostPlatform }
pub struct PhoneIdentity { pub id: [u8; 16], pub name: String, pub platform: PhonePlatform }
pub struct PairedPhone { pub identity: PhoneIdentity, pub pair_key: [u8; 32] }
pub fn select_uuid(host_id: &[u8; 16]) -> uuid::Uuid;
pub fn clamp_name(name: &str) -> String;
pub enum ControlMessage { Ack(Ack), Status(ReceiverStatus), PairAccept{..}, Hello{..}, Auth{..}, AuthFailed, Bye, Sealed(Vec<u8>) }
pub enum PeripheralMessage { Event(KeyboardEvent), PairOffer{..}, PairReveal{..}, HelloReply{..}, NotSelected, Sealed(Vec<u8>) }
pub fn encode_control(&ControlMessage) -> Vec<u8>;  pub fn decode_peripheral(&[u8]) -> Result<PeripheralMessage, CodecError>;
pub struct FrameReassembler;  pub fn split_frames(payload: &[u8], message_id: u16, max_frame: usize) -> Result<Vec<Vec<u8>>, FrameError>;
pub struct HostPairing;  pub struct PhonePairing;       // 亂數與金鑰由呼叫端注入
pub struct HostHandshake; pub struct PhoneHandshake;    // HostHandshake::new(host_id, phones, host_nonce)
pub enum HostOutput { None, Send(ControlMessage), Authenticated { reply: ControlMessage, phone_id: [u8; 16] }, PairOffer(..), PairReveal(..), Event(KeyboardEvent), MalformedPayload, AuthFailed, NotSelected, UnsupportedVersion(i64) }
pub struct ChannelSet;  pub struct EventDeduplicator;  pub struct PointerPlayout;
```

- [ ] **Step 1：`swift_vectors.rs`（RED）。** 逐項讀向量檔：`encodes_every_message_byte_for_byte`、`derives_pair_key_and_sas`、`verifies_both_proofs`、`opens_swift_session_ciphertext_both_directions`、`opens_swift_pointer_packet`、`splits_and_reassembles_frames`、`select_uuid_matches`、`clamp_name_matches`。
- [ ] **Step 2：`loopback.rs`（RED）。** `pair_then_handshake_then_event`、`eight_phones_last_one_authenticates`、`unknown_phone_fails`、`hello_for_other_host_replies_not_selected`、`version_3_message_is_unsupported_version`、`tampered_frame_fails_auth`、`replayed_pointer_packet_is_dropped`。
- [ ] **Step 3：實作到全綠。** JSON 用手寫的 `Serialize`／`Deserialize`，輸出鍵依字典序、base64 用標準字母表含填充、UUID 大寫。不讀時鐘與亂數。
- [ ] **Step 4：反向向量。** `cargo test -p rk-core write_rust_vectors -- --ignored` 產生 `rust-vectors-v4.json`（Rust 封裝的 session 密文、指標封包、分段）；`RustVectorTests.testSwiftOpensRustVectors()` 解開並比對明文。
- [ ] **Step 5：CI。** `receiver.yml` 在 `pull_request` 且路徑含 `receiver/**` 時於 `windows-latest`、`ubuntu-latest` 跑 `cargo build --workspace`、`cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`；Ubuntu 先 `apt-get install -y libdbus-1-dev pkg-config`。
- [ ] **Step 6：驗證。** 本機（Mac）、`rk-win`、`rk-linux` 三處 `cargo test -p rk-core` 全過；`swift test` 全過；PR 上的 CI 兩個平台皆綠。
- [ ] **Step 7：Commit。** `git commit -m "feat(receiver): rk-core protocol crate checked against Swift vectors"`

---

### Task WL7: `rk-ble` 與 Windows 接收端外殼

WL1 完成後細化。先定下：

**Files:** `receiver/rk-ble/src/{lib,link,scan}.rs`、`receiver/rk-receiver/src/{main,app,config,store,tray,pairing_dialog,autostart,log,i18n}.rs`、`receiver/rk-receiver/src/platform/windows.rs`

**Interfaces:**
- Consumes: `rk_core` 全部；WL0 的 S8 結論（掃描方式）；WL1 的 S1 數據（重連行為、MTU）。`rk-ble` 分 `windows.rs`（WinRT）與 `linux.rs`（bluer，含 `--adapter` 選擇）兩個後端，對上層是同一組 `LinkEvent`／`LinkCommand`。
- Produces:

```rust
// rk-ble
pub enum LinkEvent { Discovered, Connected { mtu: usize }, Notification(Vec<u8>), Disconnected }
pub struct Link;  impl Link { pub async fn run(select: Uuid, pairing: Option<Uuid>, tx: Sender<LinkEvent>, rx: Receiver<LinkCommand>) }
pub enum LinkCommand { Write(Vec<u8>), Disconnect, SetPairingScan(bool), BackoffRescan(Duration) }
// rk-receiver
pub trait PhoneStore { fn host(&self) -> HostIdentity; fn phones(&self) -> Vec<PairedPhone>; fn save(&self, p: PairedPhone) -> Result<(), StoreError>; fn delete(&self, id: &[u8; 16]); }
pub trait Injector { fn text(&mut self, s: &str) -> Result<(), InjectError>; fn backspace(&mut self) -> ..; fn enter(&mut self) -> ..; fn pointer_move(&mut self, dx: f64, dy: f64) -> ..; fn button(&mut self, b: Button, down: bool) -> ..; fn scroll(&mut self, dx: f64, dy: f64) -> ..; fn ready(&self) -> bool; }
```

**Tests:** `app` 以假的 `Link`、`Injector`、`PhoneStore` 測：`pairing_window_closes_after_120_s`、`confirmed_pairing_saves_phone`、`rejected_pairing_saves_nothing`、`handshake_timeout_backs_off_10_s_without_auth_failed`、`not_selected_backs_off_10_s_without_error`、`auth_failed_holds_device_60_s_and_shows_repair_note`、`pairing_advert_connection_sends_no_hello`、`scanning_stops_while_connected`、`status_is_ready_only_when_injector_ready`、`unsupported_version_shows_update_phone_note`、`unsupported_version_disconnects_and_holds_device_60_s`、`paired_phone_list_delete_removes_key`、`log_lines_never_contain_text`（送「機密」後掃描所有 log 輸出）、`second_instance_exits`。

**實機（TBD）：** Windows 上配對、開機自動啟動、系統匣選單各項。

---

### Task WL8: Windows 注入與觸控板

WL1 完成後細化。

**Files:** `receiver/rk-inject/src/{lib,windows}.rs`

**Tests:** 純函式 `utf16_inputs(&str) -> Vec<KeyInput>`：`utf16_units_for_supplementary_plane`（「😀」→ 兩個 code unit，各有按下與放開）、`combining_sequence_keeps_order`、`empty_text_sends_nothing`；`wheel_units` 的換算與餘數累加：`small_scroll_deltas_accumulate`。

**實機（TBD）：** 記事本、瀏覽器、Office 類編輯器的英文、中文、語音聽寫、手寫；觸控板移動、點擊、拖曳、捲動；管理員視窗收不到的限制如手冊所述。

---

### Task WL9: Linux 注入（portal）

WL1 完成後細化；S4、S5、S9 的結果決定預設值與是否包含觸控板。

**Files:** `receiver/rk-inject/src/linux.rs`、`receiver/rk-receiver/src/platform/linux.rs`

**Tests:** `keysym_for_ascii`、`keysym_for_supplementary_plane`（U+1F600 → `0x0101F600`）、`non_ascii_uses_paste_when_enabled`、`clipboard_is_restored_after_paste`（假的 portal）、`denied_session_reports_untrusted`、`restore_token_is_reused`。

**實機（TBD）：** 文字編輯器、Firefox、終端機的英文與中文；重新授權；重開機後不再跳授權視窗；觸控板。

---

### Task WL10: Linux 接收端外殼

**Files:** `receiver/rk-receiver/src/platform/linux.rs`（系統匣、Secret Service、autostart、檔案鎖）

**Tests:** `autostart_desktop_file_contents`、`config_paths_follow_xdg`。

**實機（TBD）：** 配對、開機自動啟動、系統匣選單各項。

---

### Task WL11: 三主機整合驗收

**Files:** `e2e/E2E-WL-MULTI-HOST.md`（實機檢查表）、驗收報告。

檢查表涵蓋 spec §14 的實機項目：三台主機各自配對與打字、鍵盤輪替三台並量測切換時間（20 次）、刪除一台後其餘不受影響、兩支手機配對同一台主機、兩台主機同時在旁邊時互不干擾（Review Focus 1）。

---

### Task WL12: 發佈

**Files:** `.github/workflows/receiver.yml`（加 release job，產生 Windows `.exe` 與 Linux 執行檔）、`README.md`、`README.en.md`、手冊（中英）、`release-notes/`、主 App 教學頁文字。

內容：三平台安裝步驟、重新配對提示、SmartScreen 警告、Windows 與 Linux 沒有焦點安全閘的說明、Linux 貼上模式的代價、支援範圍。發佈本身等使用者說「發佈」才做。
