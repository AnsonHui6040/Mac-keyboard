# Windows／Linux 接收端與多主機設計（D28）

- 狀態：修訂 4（2026-11-11）。修訂 4 依協定文件 `docs/protocol/v4.md`（WL2）整理出的 16 項待確認定案，使用者於 2026-11-11 批准：名稱規則改以 Unicode 碼位定義、身分雜湊的分隔位元組、握手與配對的邊界情況、驗證失敗與版本不符後的處理（§5.1、§5.2、§5.4、§5.5、§15、§16、§18）。修訂 3 依 S8 量測結果（驗收報告 WL0 各節）改掃描技術、加入握手時的 `notSelected` 後備與 Linux 控制器選擇。修訂 2（2026-11-10）：修訂 2 依使用者要求加入「接收端記多支手機」與 Android 預留（§5.7）。修訂 1：初稿經獨立審查對照程式碼後，改用廣播 UUID 區分主機，並修正狀態格、Mac 掃描時機與版本不符的描述
- 上層規格：`docs/superpowers/specs/2026-10-29-remote-keyboard-design.md`（D1–D24）、`docs/superpowers/specs/2026-11-01-trackpad-design.md`（D25）
- 實作計畫：設計批准後另寫 `docs/superpowers/plans/2026-11-10-windows-linux-receiver-implementation.md`
- 驗收報告：`docs/superpowers/verification/2026-11-10-windows-linux-receiver.md`（開工時建立）

**所有標「Provisional」的項目都未經實測。** §12 的 spike 完成前，不得把它們當作已驗證結果寫入驗收報告、README 或手冊。

## 1. 意圖

目前 iPhone 鍵盤只能把字送到 Mac。使用者另有一台 Windows 11 筆電與一台 Ubuntu 26.04 桌機，希望同一個 iPhone 鍵盤也能對這兩台打字與操作指標，並且在鍵盤上切換要送往哪一台。

## 2. 目標、非目標、反目標

目標：

1. Windows 11 與 Ubuntu 26.04（GNOME Wayland）各有一個常駐接收端，達到可日常使用的 Alpha：配對、系統匣圖示、開機自動啟動、文字輸入（含中文）、觸控板。
2. iPhone 可同時記住多台主機，使用者在鍵盤狀態格點一下輪替目前主機。
3. Mac Receiver 升到同一版協定，功能不退步。
4. 三個平台的接收端附在同一個 GitHub Release。
5. 每個接收端可記住多支手機。
6. 協定不含任何只有 iPhone 才做得到的假設，將來的 Android 鍵盤不需要改接收端與協定就能加入（§5.7）。

非目標：

- Windows 10、其他 Linux 桌面環境（KDE、X11 工作階段）、ARM 版 Windows 與 Linux。能動不代表支援，不測也不寫進手冊。
- Windows／Linux 的焦點安全閘（見 §8）。
- 修飾鍵與快速鍵（隨 D27 延後）。
- 與舊版協定相容。
- Windows 執行檔簽章、Linux 套件庫上架。
- Android 鍵盤 App 本身。這次只做預留，不寫 Android 程式。

反目標：

- 為了支援新平台而改壞 Mac 的延遲或焦點安全行為。
- 同一份協定邏輯在 Swift 與 Rust 之間漂移而沒有測試擋住。
- 文字內容出現在任何平台的 log。

## 3. 前提與限制

| 項目 | 內容 |
|---|---|
| BLE 角色 | 不變。iPhone 鍵盤延伸功能為 GATT peripheral（service `706AA642-68A3-41FA-889D-24E30709B0D0`），主機為 central |
| iPhone 當標準 HID 鍵盤 | 不可行。iOS 不允許 app 廣播 HID service，HID 也送不了中文 |
| Ubuntu 26.04 | GNOME 只有 Wayland 工作階段，不支援 virtual-keyboard 協定 |
| 測試機 | Windows 11 家用版 build 26300（Insider 預覽版，Intel AX201 藍牙）；Ubuntu 26.04.1 x86_64（BlueZ 5.85） |
| 遠端操作 | SSH 用於建置、單元測試、收 log；需要互動桌面的步驟用 RustDesk 或由使用者親手操作。SSH 工作階段無法對互動桌面注入 |
| Windows 網路 | 測試期間只接 Wi-Fi，同時插網線會讓 SSH 回程走錯介面 |
| log | 只記事件種類、長度、時間與結果，不記文字內容、金鑰、nonce、proof |
| 送達保證 | ACK 只代表接收端已處理，不承諾任意 App 的 exactly-once |

## 4. 架構

```
iPhone 鍵盤延伸功能（peripheral）
   │  BLE GATT，協定 v4
   ├── Mac Receiver（Swift，沿用現有程式）
   ├── Windows 接收端（Rust）
   └── Linux 接收端（Rust）
```

Rust 程式放在本 repo 的 `receiver/`，是一個 cargo workspace：

| crate | 內容 | 平台相依 |
|---|---|---|
| `rk-core` | 協定的主機端與手機端：JSON 編解碼、分段與重組、配對、握手、session 加密、計數器通道、去重、指標封包處理。純邏輯，不做 IO，不讀時鐘與亂數來源 | 無 |
| `rk-ble` | 掃描、連線、訂閱 `event`、寫入 `control`、重連。不使用 btleplug（S8 證實它會把同一裝置看過的 service UUID 累加，分不出目前廣播的是哪一個）。Windows 用 `windows` crate 的 WinRT `BluetoothLEAdvertisementWatcher` 與 GATT API；Linux 用 `bluer`（BlueZ D-Bus） | Windows WinRT、Linux BlueZ |
| `rk-inject` | 一個 `Injector` trait（文字、Backspace、Return、指標移動、按鍵、捲動），兩個實作 | Windows `SendInput`；Linux RemoteDesktop portal |
| `rk-receiver` | 執行檔：系統匣、配對對話框、設定、金鑰儲存、自動啟動、log | 兩者 |

`rk-core` 對應 `RemoteKeyboardCore` 中屬於協定的純邏輯，主機端與手機端都移植。要移植的檔案清單由實作計畫逐檔列出；鍵盤版面、中文輸入法、手勢判定這些屬於鍵盤 App 的邏輯不移植。

## 5. 協定 v4

`KeyboardEvent.currentVersion` 由 3 升為 4。三端一起升版，v3 的配對全部作廢。

### 5.1 主機身分

每個接收端第一次啟動時產生 16 bytes 亂數 `hostId`，連同使用者可改的顯示名稱 `hostName`（預設為電腦名稱）一起存在本機。`hostId` 重裝接收端後會重新產生，等同一台新主機。

名稱規則（`hostName` 與 §5.2 的 `phoneName` 相同）：

- 不得為空，UTF-8 長度不得超過 32 bytes。
- 超過時截斷：從頭逐一累加 Unicode 碼位（scalar value），保留累計 UTF-8 長度不超過 32 bytes 的最長開頭。截斷點一定落在碼位的邊界，結果是合法的 UTF-8；由多個碼位組成的字（例如以 U+200D 連接的表情符號）可以被切開。不以字素為單位，因為字素的切分依 Unicode 版本而異，兩種實作可能切出不同結果。
- 截斷由持有該名稱的一端在存入本機時進行；名稱被清空時改用預設名稱。
- 收到空的或超過 32 bytes 的名稱時，收到的一端不自行修正，配對失敗。

### 5.2 配對

沿用 commit-then-reveal 三步驟，改兩處：

1. `pairAccept` 多帶 `hostId` 與 `hostName`。
2. 配對金鑰的 HKDF 改為 salt `rk-pair-v2`，info = `hostPublic ‖ phonePublic ‖ hostId ‖ SHA-256(hostName 的 UTF-8 ‖ 0x00 ‖ platform 的 UTF-8) ‖ phoneId ‖ SHA-256(phoneName 的 UTF-8 ‖ 0x00 ‖ phonePlatform 的 UTF-8)`。主機或手機的身分、名稱被中間人換掉時，兩邊的 6 位數配對碼會不同。

`pairAccept` 另帶 `platform`（`mac`、`windows`、`linux`），同樣納入上述 info 的雜湊輸入（接在 `hostName` 之後，中間隔一個 `0x00` 位元組），iPhone 用它決定提示文字。`hostId`、`hostName`、`platform` 與 `publicKey` 在 `pairAccept` 裡是同一層的欄位，不另包一層物件；`pairReveal` 的 `phoneId`、`phoneName`、`phonePlatform` 也一樣。

iPhone 配對完成並經使用者確認後，存入一筆 `{hostId, hostName, platform, pairKey}`，並把這台設為目前主機。iPhone 最多存 8 台，滿了要先刪一台才能再配對。同一個 `hostId` 再配對一次會覆蓋舊紀錄。

手機身分：每支手機的 App 第一次啟動時產生 16 bytes 亂數 `phoneId`，連同 `phoneName`（預設為裝置名稱，長度規則同 `hostName`）與 `phonePlatform`（`ios`、`android`）放在 `pairReveal` 裡送出。這三項也納入配對金鑰的 HKDF info（接在主機那幾項之後，組成方式與主機相同），被換掉時配對碼會不同。commitment 仍只涵蓋手機的公鑰。

接收端對經配對 UUID（§5.3）找到的連線不寫入 `hello`，只等待 `pairOffer`。

每個接收端最多記 8 支手機，每支一筆 `{phoneId, phoneName, phonePlatform, pairKey}`。同一個 `phoneId` 再配對一次會覆蓋舊紀錄。三個平台的接收端都提供已配對手機清單與個別刪除。

### 5.3 用廣播 UUID 區分主機

現況是鍵盤與主 App 的配對畫面都廣播同一個 service UUID，任何接收端看到就連。多台主機同時在旁邊時會互相搶連線，而鍵盤一次只服務一個 central（`CentralBinding`），所以改成由廣播內容決定誰該連：

| 廣播者 | 廣播的 service UUID | 誰會掃描它 |
|---|---|---|
| 鍵盤（已選定主機） | 選定 UUID：`SHA-256("rk-select" ‖ hostId)` 的前 16 bytes，套上 UUID v4 的版本與變體位元 | 只有該主機 |
| 主 App 配對畫面 | 固定的配對 UUID（新增一個常數，寫入 `GATTServiceSpec`） | 只有配對時段開著的接收端 |

GATT 資料庫裡的 service 與 characteristic UUID 不變，改的只有廣播封包。未被選定的主機看不到自己的選定 UUID，正常情況下不會連線。這是第一層過濾；掃描層偶爾看到過期內容時由 §5.4 的 `notSelected` 接手。

S8 實測（2026-11-11，每個平台 21 次切換）：

| 平台 | 掃描方式 | 看到新 UUID 的延遲（中位數／最大） |
|---|---|---|
| Mac | CoreBluetooth，允許重複回報 | 0.05／0.24 秒 |
| Windows | WinRT 廣播監看，主動掃描 | 0.23／1.0 秒 |
| Linux | BlueZ 探索，每 1.5 秒 `StopDiscovery`＋`StartDiscovery` 並對該裝置 `RemoveDevice` | 1.24／1.56 秒 |

Linux 必須這樣做的原因：核心的掃描帶重複過濾，晶片對同一裝置只回報一次，要到核心每 10.8 秒重啟掃描才再回報；BlueZ 的裝置物件又會累加 UUID。Linux 在切換後約 1.5 秒內可能同時看到新舊兩個 UUID。

各平台的掃描時機：

| 平台 | 掃描選定 UUID 的時機 |
|---|---|
| Mac | 不變：接收工作階段被啟動（點到可編輯欄位或手動開始）後才掃描，沿用現有的閒置逾時 |
| Windows、Linux | 接收端執行期間持續掃描，因為這兩個平台沒有焦點判斷 |

### 5.4 握手

`hello` 多帶 `hostId`：

```
主機   → hello(hostId, hostNonce)
iPhone → helloReply(phoneNonce, phoneProof)
主機   → auth(hostProof)
```

- 只有經選定 UUID 找到的連線才寫入 `hello`。
- iPhone 只用目前主機的金鑰。`hello` 的 `hostId` 不是目前主機時（包括 iPhone 沒有目前主機的情況），iPhone 只對送出這則 `hello` 的 central 回一則明文 `notSelected`（新的 `PeripheralMessage`，不帶任何內容）。不論該 `hostId` 有沒有配對過都回同一則，不洩漏配對清單。
- `hello` 的 `hostId` 長度不是 16 bytes 屬於格式錯誤，和 `hostNonce` 長度不對同樣處理：握手失敗，不回 `notSelected`。
- 這則回覆不保存任何狀態，也不影響目前已驗證的連線：鍵盤仍只和一個 central 做握手與收發事件，對其他 central 唯一會做的事就是回 `notSelected`。若送錯 `hostId` 的正是目前綁定的 central，回覆後解除綁定。
- 非綁定的 central 送來 `hostId` 相符的 `hello` 時：目前綁定的連線已驗證則忽略；尚未驗證則改由這個 central 接手，重新開始握手（沿用現有「已驗證的連線不可被取代」的規則）。
- 接收端收到 `notSelected` 後中斷連線，10 秒（Provisional）內不再連這個裝置，之後要重新在廣播中看到自己的選定 UUID 才連。不顯示錯誤，不列入略過名單。握手逾時維持 5 秒（Mac 現值）；逾時只中斷連線並走同一段退避，不寫入 `authFailed`。這段退避是新邏輯，Mac 現有的 link 狀態機沒有，要新增。
- 驗證失敗（寫入 `authFailed`）之後：Mac 維持現況，到接收工作階段結束為止不再連線該裝置；Windows 與 Linux 沒有接收工作階段，60 秒（Provisional）內不再連線該裝置，系統匣顯示需要重新配對。
- 接收端在連線期間停止掃描（Linux 停止定時重啟探索），斷線後才恢復。
- proof 的 HMAC、session 金鑰與計數器通道的推導不變（金鑰本身已綁定 `hostId`）。
- 接收端不知道連上來的是哪支手機，`helloReply` 也不帶 `phoneId`（避免在明文中出現可追蹤的固定識別碼）。接收端拿每一把已存的金鑰依序驗證 `phoneProof`，驗過的那把就是這支手機；最多 8 次 HMAC。全部不符才算驗證失敗。
- 同一台主機同一時間只服務一支手機。兩支手機都選了同一台主機時，先連上的佔用，另一支顯示未連接，等前一支斷線後才連得上。
- wire 上原本以 Mac 命名的欄位與標籤改為中性名稱：`macNonce` 改 `hostNonce`、`auth` 的 proof 標籤 `mac` 改 `host`、配對的 `macPublic` 改 `hostPublic`。既然 v4 本來就不相容，一次改完。

### 5.5 切換主機與版本不符

使用者在鍵盤輪替主機時，iPhone 更新目前主機、改廣播新的選定 UUID，然後做一次完整的 link reset（沿用現有 `resetLink`）。原主機被斷線後看不到自己的 UUID，不會重連；新主機看到後連線並握手。目標是點下去後 5 秒內（Provisional）新主機可以打字；選到 Mac 而 Mac 的接收工作階段沒有啟動時，狀態格顯示未連接，和現在相同。

版本不符：

| 情況 | 行為 |
|---|---|
| v4 iPhone 遇到 v3 接收端 | 不會發生連線：v3 接收端掃描的是舊 UUID，v4 鍵盤不再廣播它。主 App 首頁與手冊提示要更新電腦上的接收端 |
| v3 iPhone 遇到 v4 接收端 | 同上，v4 接收端不掃描舊 UUID。接收端的未配對畫面提示要更新 iPhone App |
| 版本欄位不符的訊息（防禦用） | `PeripheralCodec.decode` 會立即拒絕。接收端要新增一個分支：顯示「請更新 iPhone App」而不是靜默略過，中斷連線，60 秒（Provisional）內不再連線該裝置 |

### 5.6 `ReceiverStatus` 在 Windows／Linux 的值

| 欄位 | 值 |
|---|---|
| `ready` | 驗證完成且注入後端可用時為 `true` |
| `appName` | 不送 |
| `focusEpoch` | 固定為 1 |
| `trusted` | Linux 尚未取得 portal 授權時為 `false`，其餘為 `true` |
| `measure` | 不送 |
| `inputBlocked` | 不送 |
| `pointerGrant` | 與 Mac 相同：接收端的觸控板開關打開時才送 |

### 5.7 Android 預留

這次不做 Android，但下列幾點現在就定下來，讓將來的 Android 鍵盤只需要寫 App，不必動接收端與協定：

| 項目 | 做法 |
|---|---|
| 協定文件 | 新增 `docs/protocol/v4.md`，用不依賴任何程式語言的方式寫明 GATT 結構、廣播、每種訊息的 JSON 形狀、分段格式、配對與握手步驟、金鑰推導的每個輸入、計數器通道封包。它是協定的依據，Swift 與 Rust 兩份實作都以它為準 |
| 測試向量 | §11 的向量檔是純 JSON，第三種實作可以直接拿來驗證 |
| 手機端協定邏輯 | `rk-core` 同時包含手機端的 reducer（配對、握手、事件封裝、分段、計數器通道）。現在的用途是讓 Rust 測試能在同一個程序內跑完整的「手機對主機」流程；將來 Android App 可以經 JNI 直接使用，不必用 Kotlin 再寫一份。JNI 綁定這次不做 |
| 廣播大小 | 廣播封包只放一個 128-bit service UUID，不放裝置名稱或其他資料，Android 的 31 bytes 傳統廣播放得下 |
| 手機身分 | `phonePlatform` 欄位已含 `android`，接收端清單可以區分 |
| 平台特例 | 協定不依賴 iOS 的鍵盤延伸功能生命週期或 iCloud 配對連線。Mac Receiver 為了同一個 iCloud 帳號的系統連線所做的處理（sealed `bye`、appearance probe）留在 Mac 的轉接層，不進協定 |

沒有驗證過的部分：Android 的輸入法服務在背景維持 BLE peripheral 的行為、各廠牌的廣播限制。這些要等真的做 Android 時才測，這次不列入 spike。

## 6. iPhone 端變更

| 位置 | 變更 |
|---|---|
| `iOS/Shared/PairingStore.swift` | 改為多筆紀錄。每台主機一個 Keychain 項目（account 為 `pairKey.<hostId 十六進位>`）；主機清單（`hostId`、名稱、順序）與目前主機存在 App Group。首次啟動時刪除舊的 `pairKey` 項目 |
| `PhoneHandshake`、`PhonePairing` | 依 §5.2、§5.4 修改，維持純 reducer，金鑰查找由呼叫端注入 |
| 手機身分 | 產生並儲存 `phoneId`（App Group）；`phoneName` 取裝置名稱 |
| 鍵盤廣播（`KeyboardBLEPeripheral`） | 改廣播目前主機的選定 UUID；沒有配對時不廣播 |
| 主 App 配對（`PairingPeripheral`） | 改廣播配對 UUID |
| 鍵盤狀態格（`TopAreaView`、`StatusLine`） | 現況只顯示短狀態（已連接、未連接、尚未配對），格寬約 68–71 pt，約六個中文字。已配對兩台以上時改為兩行：第一行主機名稱（放不下時尾端省略），第二行現有的短狀態；只配對一台時維持現在的單行。已配對兩台以上時點一下輪替到清單中的下一台，立即顯示新主機名稱與未連接狀態；只有一台時點擊沒有作用。完成後要在 402 pt 與 375 pt 兩種寬度截圖給使用者確認 |
| 提示文字（`StatusLine`） | 現有文字寫死「Mac」（例如「Mac 未授權輔助使用」「Mac 沒有輸入欄位」）。改為依目前主機的 `platform` 取字：Mac 維持原文；Windows 與 Linux 不會出現焦點與密碼欄相關提示；Linux 的 `trusted = false` 顯示「電腦未授權」 |
| 主 App 首頁 | 「已配對」區塊改為主機清單：每台可刪除，另有「新增電腦」進入現有配對流程。目前主機有標示，點一台可設為目前主機 |
| 主 App 設定教學 | 文字由「Mac」改為涵蓋三種電腦，內容由實作時依現有教學頁改寫 |

鍵盤在沒有 Full Access 時讀不到 Keychain 與 App Group，行為和現在相同（顯示尚未配對）。

## 7. Mac Receiver 變更

- 產生並儲存 `hostId`、`hostName`，`MacHandshake`、`MacPairing` 依 §5 修改。
- 配對紀錄改為多筆（最多 8 支手機），握手時逐把金鑰驗證；面板的配對區塊改為手機清單，每支可個別刪除。
- 掃描對象改為自己的選定 UUID；配對時段開著時另外掃描配對 UUID。掃描時機不變（接收工作階段啟動後）。
- 新增握手逾時後的 10 秒退避（§5.4）。
- `hostId`、`hostName` 與配對金鑰放在一起：Mac 現況刻意把金鑰存成權限 0600 的檔案而不是 Keychain（`MacPairingStore`），維持這個做法。
- 舊配對金鑰在升級後第一次啟動時刪除，面板回到未配對狀態。
- 焦點安全、輸入法切換、觸控板行為不變。

## 8. 注入

Windows 與 Linux 都不做焦點安全檢查：不判斷焦點是否可編輯、不判斷密碼欄、不比對 focus epoch。行為等同一把實體藍牙鍵盤，字會送到當下有鍵盤焦點的地方。手冊要寫明這一點與 Mac 的差異。

### 8.1 Windows

| 動作 | 做法 |
|---|---|
| 文字 | `SendInput` 搭配 `KEYEVENTF_UNICODE`，逐個 UTF-16 code unit 送出按下與放開；補充平面字元送代理對 |
| Backspace、Return | 虛擬鍵 `VK_BACK`、`VK_RETURN` |
| 指標移動 | `MOUSEEVENTF_MOVE` 相對位移 |
| 按鍵 | 左右鍵按下與放開 |
| 捲動 | `MOUSEEVENTF_WHEEL`、`MOUSEEVENTF_HWHEEL`，位移到滾輪單位的換算係數 Provisional |

已知限制，寫入手冊：

- 以系統管理員身分執行的視窗、UAC 提示與鎖定畫面收不到（Windows 的完整性層級隔離）。接收端不以系統管理員身分執行。
- 執行檔未簽章，第一次執行會出現 SmartScreen 警告。

主機輸入法：`KEYEVENTF_UNICODE` 預期不經過輸入法，注音輸入法開著時是否仍正確，Provisional，由 spike 驗證。

### 8.2 Linux

走 `org.freedesktop.portal.RemoteDesktop`（Rust 用 `ashpd`）：

| 動作 | 做法 |
|---|---|
| 工作階段 | 申請 keyboard 與 pointer 兩種裝置，`persist_mode` 設為持續，restore token 存在本機，之後啟動不再跳授權視窗 |
| 文字 | `NotifyKeyboardKeysym`，ASCII 用對應 keysym，其餘用 Unicode keysym（`0x01000000 + code point`） |
| Backspace、Return | 對應 keysym |
| 指標移動、按鍵、捲動 | `NotifyPointerMotion`、`NotifyPointerButton`、`NotifyPointerAxis` |

中文後備：設定中有「非 ASCII 文字改用貼上」開關。打開時，含非 ASCII 字元的文字事件改走 portal 的 Clipboard 介面寫入剪貼簿，再送 Ctrl+V，完成後把剪貼簿還原成原本的內容。預設值由 spike 結果決定：keysym 路徑通過 §12 的 S4 就預設關閉，否則預設打開。已知代價寫入手冊：終端機要用 Ctrl+Shift+V 所以貼不進去、剪貼簿會短暫被覆蓋、剪貼簿管理工具會留下紀錄。

授權被拒或 token 失效時，接收端回報 `trusted = false`，鍵盤沿用現有的未授權提示，系統匣選單提供「重新授權」。

主機輸入法：IBus 中文輸入法開著時 keysym 是否被攔成組字，Provisional，由 spike 驗證。若會被攔，處理方式在 spike 後補進本設計，不在此預設。

## 9. 觸控板

沿用 D25 的封包、計數器通道、`pointerGrant` 與可靠事件 ACK，iPhone 端不改。接收端有「允許觸控板控制」開關，預設值與 Mac 相同。

Mac 端的指標播放邏輯（補間、加速度曲線）在 `rk-core` 重寫，以同一組輸入輸出測試向量對拍。捲動的階段（began、ended、cancelled）在 Windows／Linux 沒有對應概念，只取位移。捲動與移動的換算係數、Windows 高解析度滾輪的使用方式都是 Provisional。

## 10. 接收端外殼

| 項目 | Windows | Linux |
|---|---|---|
| 系統匣 | 通知區域圖示 | StatusNotifierItem（Ubuntu 預設已啟用 AppIndicator 擴充套件） |
| 選單 | 連線狀態（含目前連線的手機名稱）、主機名稱、配對新手機、已配對手機清單（每支可刪除）、允許觸控板控制、開機自動啟動、（Linux）非 ASCII 改用貼上、（Linux）重新授權、結束 | 同左 |
| 配對 | 選「配對新手機」後開啟 120 秒配對時段；收到配對請求時跳出原生對話框顯示手機名稱、6 位數配對碼與「相符」「不相符」兩個按鈕 | 同左 |
| 金鑰儲存 | Windows 認證管理員 | Secret Service（GNOME Keyring） |
| 設定與 `hostId` | `%APPDATA%\RemoteKeyboard\config.json` | `~/.config/remote-keyboard/config.json` |
| 自動啟動 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | `~/.config/autostart/remote-keyboard.desktop` |
| log | `%LOCALAPPDATA%\RemoteKeyboard\logs\` | `~/.local/state/remote-keyboard/` |
| 單一執行個體 | 具名 mutex | 檔案鎖 |

介面語言為繁體中文與英文，依系統語言選擇。不做獨立的設定視窗，所有操作都在系統匣選單與原生對話框完成。

連線行為：未連線時持續掃描自己的選定 UUID，看到廣播就連線；配對時段開著時另外掃描配對 UUID。連線期間不掃描。斷線後立即重新掃描；收到 `notSelected` 或握手逾時則依 §5.4 退避。

Linux 接收端的系統匣選單可選擇藍牙控制器（機器上有多個時才顯示），選擇存入設定檔；預設用 BlueZ 的預設控制器。

## 11. 跨語言一致性

1. `rk-core` 的 JSON 輸出必須與 Swift 的 `JSONEncoder`（`.sortedKeys`）逐位元組相同：鍵的順序、`Data` 用 base64、`UUID` 用大寫字串、enum 帶關聯值的巢狀形狀。
2. `docs/protocol/v4.md` 是協定的依據（§5.7）。兩份實作不一致時，以文件為準修正程式；文件有錯則先改文件。
3. Swift 測試以固定的金鑰與 nonce 產生測試向量檔 `receiver/testdata/swift-vectors-v4.json`，內容涵蓋：每種訊息的編碼、配對金鑰與配對碼、兩個方向的 proof、session 金鑰密文、計數器通道封包、分段。檔案提交進 repo，另有一個 Swift 測試檢查提交的檔案與重新產生的結果相同。
4. Rust 測試讀這個檔案，逐項比對編碼並解開密文。
5. `rk-core` 內部另有不經 BLE 的端到端測試：Rust 的手機端 reducer 對 Rust 的主機端 reducer 跑完配對、握手、送事件、觸控板封包。
6. 反方向：Rust 測試產生 `receiver/testdata/rust-vectors-v4.json`（Rust 封裝的密文與封包），Swift 測試負責解開。
7. GitHub Actions 新增 workflow，在 `windows-latest` 與 `ubuntu-latest` 跑 `cargo build`、`cargo test`、`cargo clippy`，並在發佈時產生兩個平台的執行檔。

## 12. Spike（與設計並行，程式用完即丟）

spike 用現行 v3 協定與現有 iPhone App，不需要重新配對：只驗證到「主機寫入 `hello`、iPhone 回 `helloReply`」為止，proof 不驗證。S8 例外，需要一個只在 Debug 建置出現的 iOS 測試畫面。測試時 Mac Receiver 要先結束，避免搶連線。spike 程式放在 scratchpad，不進 repo；結果寫入驗收報告。

| 編號 | 平台 | 驗證內容 | 通過條件（Provisional） |
|---|---|---|---|
| S1 | Windows | 以原生介面（WinRT；Linux 的 S3 用 bluer）掃描到鍵盤、連線、訂閱 `event`、寫入 `control`、收到 `helloReply`；記錄協商後的 MTU | 連續 20 次「鍵盤收起再叫出」都能在 3 秒內重連 |
| S2 | Windows | `SendInput` 送英文、中文、表情符號到記事本、瀏覽器網址列、Word 或同類編輯器；注音輸入法開與關各測一次 | 每個目標 200 字無漏字、無亂序 |
| S3 | Linux | 同 S1，後端為 BlueZ | 同 S1 |
| S4 | Linux | portal keysym 送英文、中文、表情符號到文字編輯器、Firefox、終端機；IBus 中文輸入法開與關各測一次 | 每個目標 200 字無漏字、無亂序 |
| S5 | Linux | portal Clipboard 寫入、送 Ctrl+V、還原 | 文字編輯器與 Firefox 各 50 次無錯字，原剪貼簿內容還原 |
| S6 | Linux | RustDesk 連線中時，接收端的 portal 工作階段是否仍可注入 | 記錄結果；不通過時 Linux 的打字驗證改由使用者在本機確認 |
| S7 | 兩者 | 主機收到 notify 到注入呼叫返回的時間 | 記錄中位數與 p95，不設門檻 |
| S8（已完成，三平台通過，見驗收報告） | Windows、Linux、Mac | 用一個小型 iOS 測試畫面輪流廣播兩個不同的 service UUID，觀察各平台的掃描何時看到新 UUID、是否還把舊 UUID 算在同一個裝置上（掃描快取） | 換 UUID 後 3 秒內看到新的；舊 UUID 殘留的情況有紀錄 |
| S9 | Linux | portal 的指標移動（每秒 60 次以上）、左右鍵、捲動 | 游標移動連續、點擊與捲動正確；記錄可用的最高更新率 |

決策：

- S1 或 S3 不通過：該平台暫停，先查原因並回報使用者，不進入該平台的實作。
- S8 不通過（某平台看不到 UUID 變化）：回報使用者，改回「所有主機都連、由 iPhone 在握手時拒絕」的做法前要重新設計，因為那需要鍵盤同時處理多個 central。
- S9 不通過：Linux 的觸控板不做，文字輸入照常。
- S4 不通過、S5 通過：Linux 的「非 ASCII 改用貼上」預設打開。
- S4、S5 都不通過：Linux 先只支援英文與符號，並回報使用者決定是否改做 IBus 引擎。

## 13. 實作順序

1. 協定文件 `docs/protocol/v4.md`，接著協定 v4、多主機與多手機：iPhone 與 Mac（Swift），含測試向量產生。完成後 Mac 單機可用。
2. `rk-core`，以測試向量對拍。
3. Windows 接收端：`rk-ble`、Windows 注入、外殼、觸控板。
4. Linux 接收端：Linux 注入、外殼、觸控板。
5. 發佈：CI 產生執行檔、手冊與 README 更新、重新配對提示。

spike S8 要在第 1 步開始前完成，因為它決定協定的形狀。S1、S2 在第 1 步期間進行，S3 到 S6 與 S9 最晚在第 3 步開始前完成，讓 Linux 的風險在投入 Linux 實作前已有數據。每一步拆成的 Task 由實作計畫定義，一個 Task 一個 worktree、一條 branch、一個 PR。

## 14. 驗證

| 類別 | 項目 |
|---|---|
| 自動 | `swift test --package-path Packages/RemoteKeyboardCore`；Mac 與 iOS 的 Xcode 測試；`cargo test`、`cargo clippy`（本機與 CI）；雙向測試向量 |
| 實機（使用者親手，標 TBD 至測完） | 同一台主機配對兩支手機並分別打字、刪除其中一支後另一支不受影響（需要第二支 iPhone 或 iPad；沒有的話這項維持 TBD）；三台主機各自配對、打字（英文、中文、語音聽寫、手寫）、觸控板；鍵盤上輪替三台主機；刪除一台主機後其餘不受影響；開機自動啟動；Linux 重新授權；Windows 管理員視窗收不到的限制如手冊所述 |

BLE、注入與系統匣在 CI 上無法測，只能在實機驗收。

## 15. Provisional 總表

| 項目 | 起始值或假設 |
|---|---|
| 握手逾時後的退避 | 10 秒 |
| `notSelected` 後的退避 | 10 秒 |
| Windows、Linux 驗證失敗後不再連線該裝置的時間 | 60 秒，沒有量測依據 |
| 收到版本不符的訊息後不再連線該裝置的時間 | 60 秒，沒有量測依據 |
| Mac 以選定 UUID 為過濾條件並允許重複回報的掃描 | 假設仍逐筆反映目前的 UUID；S8 量的是不帶過濾條件的情況 |
| Linux 重啟探索的間隔 | 1.5 秒（S8 只驗證過這個值，且只跑一輪） |
| Linux 定時重啟探索對其他藍牙程式與耗電的影響 | 未量測 |
| portal 指標移動的更新率足夠 | 未知，S9 |
| 切換主機到可打字 | 5 秒內 |
| Windows／BlueZ 連 iPhone 鍵盤延伸功能的穩定度 | 假設可行，S1、S3 |
| Windows `KEYEVENTF_UNICODE` 不受輸入法影響 | 假設成立，S2 |
| portal Unicode keysym 可靠送出中文 | 假設成立，S4 |
| portal keysym 不被 IBus 攔截 | 未知，S4 |
| portal Clipboard 可寫入並還原 | 假設成立，S5 |
| RustDesk 與接收端的 portal 工作階段並存 | 未知，S6 |
| restore token 可跨重開機持續 | 假設成立，Linux 實機驗收 |
| 捲動與移動換算係數 | 實作時以 Mac 手感為準調整 |
| 重連退避參數 | 照 Mac 現值 |
| Windows build 26300 為預覽版 | 結果可能與正式版不同，驗收報告需註明 |

## 16. 我的決定（請審閱）

以下不是使用者說的，是我為了讓設計完整而定的：

1. 主機身分用隨機 `hostId` 加可改名稱，並綁進配對金鑰推導。
2. 用廣播的 service UUID 區分主機與配對，未被選定的主機不連線；鍵盤維持一次只和一個 central 握手。握手時的 `notSelected` 後備是使用者在 2026-11-11 決定加入的。
3. iPhone 最多 8 台主機；每個接收端最多 8 支手機。
4. wire 上以 Mac 命名的欄位與標籤改為中性的 `host…`。
5. 接收端不做設定視窗，只有系統匣選單與原生對話框。
6. Windows 與 Linux 的金鑰放系統的憑證儲存（Windows 認證管理員、GNOME Keyring）；Mac 維持現有的 0600 檔案。
7. Windows 接收端不以系統管理員身分執行。
8. Linux 中文後備做成開關，預設值由 spike 決定。
9. spike 只做到 `helloReply`，沿用 v3，不動現有配對。
10. 實作順序把協定 v4 與多主機（Swift 端）排在最前面，Windows 其次，Linux 最後；Linux 的 spike 提前到 Windows 實作開始前。
11. 支援範圍只寫 Windows 11 與 Ubuntu 26.04 GNOME。
12. Rust 分成四個 crate；BLE 不用 btleplug，Windows 用 `windows` crate、Linux 用 `bluer`。
13. 在兩台測試機上用 rustup 安裝 Rust 工具鏈直接建置；Windows 另需安裝 MSVC Build Tools，安裝前會先徵得使用者同意。
14. Windows 與 Linux 接收端執行期間持續掃描；Mac 維持「啟動接收工作階段後才掃描」。
15. 狀態格在多主機時改為兩行（主機名稱加短狀態）。
16. 配對時多帶 `platform`，iPhone 的提示文字依平台取字。
17. 接收端用逐把金鑰驗證來認手機，握手明文不帶 `phoneId`。
18. 同一台主機同一時間只服務一支手機，先連先用。
19. Linux 可選擇藍牙控制器，連線期間停止掃描。
20. Android 預留的範圍如 §5.7：協定文件、手機端邏輯進 `rk-core`、廣播只放一個 UUID；不做 JNI 綁定與任何 Android 程式。
21. 名稱截斷以 Unicode 碼位為單位，不以字素為單位（§5.1）。使用者於 2026-11-11 批准。
22. Windows 與 Linux 驗證失敗後 60 秒內不再連線該裝置，系統匣顯示需要重新配對（§5.4）。使用者於 2026-11-11 批准。
23. 收到版本不符的訊息時顯示更新提示、中斷連線，60 秒內不再連線該裝置（§5.5）。使用者於 2026-11-11 批准。

## 17. 留給實作者

- `rk-core` 逐檔移植清單與每個 Task 的切分。
- Rust 的系統匣、對話框、金鑰儲存、單一執行個體各用哪個 crate。
- 系統匣圖示與各狀態的外觀。
- 測試向量檔的確切 JSON 結構。
- Linux 執行檔的包裝格式（單一執行檔或 `.deb`）。

## 18. 尚未決定（不在本設計）

- repo 名稱與產品文案是否不再只提 Mac。
- 教學影片與產品影片是否重拍。
- 修飾鍵與快速鍵（D27）。
- Android 鍵盤 App（版面、輸入法、觸控板手勢、配對畫面都要另寫）。
- 兩支手機同時操作同一台主機。
- 觸控板設計文件（`2026-11-01-trackpad-design.md` §5、§6）與已出貨行為不一致，待更新。協定文件 `docs/protocol/v4.md` 以已出貨的程式為準。
