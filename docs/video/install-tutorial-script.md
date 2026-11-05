# 安裝教學動畫：步驟與字幕

## 製作須知

| 項目 | 內容 |
|---|---|
| 目的 | 帶沒有程式背景的測試者，由零開始裝好 Remote Keyboard 並打出第一個字 |
| 版本 | v0.1.0 build 2，下載頁：https://github.com/AnsonHui6040/Mac-keyboard/releases/tag/v0.1.0-b2 |
| 長度 | 約 5 分 35 秒，分 21 個場景 |
| 語言 | 字幕用台灣繁體中文 |
| 內容依據 | `docs/manual/01` 至 `05` 章；內容有出入時，以手冊為準 |
| 畫面 | 全部重繪成向量介面。`docs/manual/images/` 的截圖只作參考，不直接放入影片 |
| 風格 | 深色舞台，第 16 場樣板為準 |
| 聲音 | 沒有旁白，由字幕和指向帶路。另有原創合成的背景音樂與介面音效（使用者 2026-11-05 決定）：音樂是柔和的 pad，不搶閱讀；按下、打字、「按這個」「不要按」標示出現、連線成功各有一個很輕的音效；第 11、16 場標示出現期間音樂自動降低約 4 dB |

### 內容規則

1. 按鈕與畫面文字要和台灣繁體中文系統的實際畫面一字不差，下表用「」標示。不需要操作的說明文字用灰色線條代替。
2. 不可出現任何真實的 Apple 帳號、密碼、驗證碼、裝置名稱或 UDID。帳號欄用遮罩或虛構內容。
3. 第 11 場的「Keep App Extensions (Register App ID for Each Extension)」、第 16 場的藍色「丟到垃圾桶」是兩個最容易做錯的地方，畫面要明顯標示，停留時間不可縮短。
4. 不用霓虹、紫藍漸變、大量粒子或三欄功能卡片。

### 沒有截圖可以參考的畫面

截圖都來自系統語言為香港繁體中文的裝置，文字以台灣繁體中文系統字串為準，不可照抄截圖。

| 場景 | 畫面 | 處理方式 |
|---|---|---|
| 5 | sidestore.io 下載頁、iPhone 的「信任這部電腦？」、iloader 驗證碼面板 | 依系統慣例繪製，標明未對過實機；驗證碼的六位數字是虛構的 |
| 6 | 開發者模式開關與重新啟動確認 | 同上 |
| 7 | SideStore 登入 | 同上 |
| 10 | Finder 下載、終端機核對 SHA-256 | 繪製，路徑與使用者名稱用虛構內容；檔名與 SHA-256 是 v0.1.0-b2 Release 頁面上的真實公開值 |
| 11 | 檔案選擇畫面 | 依系統慣例繪製 |
| 15 | zip 解壓縮、拖進「應用程式」、從「應用程式」打開 | 繪製 |

第 11 場的 Extension 視窗標題為「App Contains Extensions」，由上到下有五個按鈕：Keep App Extensions (Use Main Profile)、Keep App Extensions (Register App ID for Each Extension)、Remove App Extensions、Choose App Extensions、Cancel。

## 場景

| # | 秒數 | 畫面 | 操作重點（不上畫面，用來核對指向目標） | 字幕 |
|---|---|---|---|---|
| 1 | 10 | iPhone 打字，文字同步出現在 Mac | 把 iPhone 變成 Mac 的藍牙鍵盤 | Remote Keyboard 把 iPhone 變成 Mac 的藍牙鍵盤和觸控板。接下來一步一步帶你裝好。 |
| 2 | 13 | 準備清單逐項出現 | iOS 18 以上且已設定螢幕鎖定密碼、macOS 15 以上（Apple 晶片）、USB 線、Wi-Fi、免費 Apple 帳號 | 先準備這些：iOS 18 以上的 iPhone、Apple 晶片的 Mac、一條 USB 線、Wi-Fi，還有你自己的免費 Apple 帳號。 |
| 3 | 13 | 鎖頭圖示與提醒 | 帳號密碼與驗證碼不要交給任何人；不要用這個鍵盤輸入密碼 | 請記得，Apple 帳號密碼和驗證碼不要交給任何人，包括開發者。也不要用這個鍵盤輸入密碼。 |
| 4 | 13 | App Store、`iphone-localdevvpn.png` | 安裝 LocalDevVPN，按連線，按「允許」 | 第一步，在 iPhone 的 App Store 安裝 LocalDevVPN。打開後按連線，再按「允許」，看到「已連線」就可以了。 |
| 5 | 24 | USB 連線、`mac-iloader.png` | 下載 iloader，Add Account，輸入驗證碼，選 Stable SideStore | 接著到 sidestore.io 下載 iloader 並打開，用 USB 線接上 iPhone，在 iPhone 按「信任」。在 iloader 登入你的 Apple 帳號，如果要驗證碼，輸入 Apple 裝置收到的號碼。確認有列出 iPhone，再安裝 Stable SideStore。 |
| 6 | 24 | `iphone-ios-vpn-device-management.png`，開發者模式 | 設定 > 一般 > VPN 與裝置管理；信任，選「允許並重新啟動」；設定 > 隱私權與安全性 > 開發者模式 | 到「設定」、「一般」、「VPN 與裝置管理」，信任你的 Apple 帳號，選「允許並重新啟動」，再輸入密碼。如果 iOS 要求開發者模式，就到「隱私權與安全性」最下方開啟。手機重新啟動後，在確認視窗選擇開啟，並輸入密碼。 |
| 7 | 11 | LocalDevVPN 已連線，SideStore 登入 | 用同一個 Apple 帳號登入 | 確認 LocalDevVPN 顯示「已連線」，打開 SideStore，用剛才同一個 Apple 帳號登入。 |
| 8 | 14 | SideStore 的 My Apps，按「7 DAYS」 | 先完成第一次續簽；出現詢問時按 Yes 或 Refresh Now | 登入後到 My Apps，按 SideStore 旁邊的「7 DAYS」完成第一次續簽。如果跳出詢問，按 Yes 或 Refresh Now。做完才能安裝其他 App。 |
| 9 | 9 | 錯誤碼 -80045，手冊第 02 章畫面 | 看到 -80045，照手冊第 02 章處理 | 如果登入時看到錯誤 -80045，不是密碼錯，請照手冊第二章處理。 |
| 10 | 20 | Release 頁面、終端機、AirDrop | 下載 IPA，核對 SHA-256，AirDrop 到 iPhone，存到「檔案」 | 現在到 GitHub 的 Release 頁面下載 IPA，打開「終端機」輸入指令，核對 SHA-256 完全相同，再用 AirDrop 傳到 iPhone，存到「檔案」。 |
| 11 | 25 | `iphone-sidestore-myapps.png`，Extension 選單，標示第二個選項 | 按「+」；選 Keep App Extensions (Register App ID for Each Extension)；不要選 Remove；安裝完成後 My Apps 的 Active 清單出現 Remote Keyboard，7 DAYS | 開著 LocalDevVPN，在 My Apps 按左上角的加號，選這個 IPA。詢問 Extension 時，選第二個，Register App ID for Each Extension。千萬不要選 Remove，否則就沒有鍵盤了。等安裝完成，My Apps 會出現 Remote Keyboard。 |
| 12 | 14 | `iphone-ios-add-keyboard.png`、`iphone-ios-keyboards.png` | 設定 > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤 | 到「設定」、「一般」、「鍵盤」、「鍵盤」，按「新增鍵盤」，在第三方鍵盤選 Remote Keyboard。回到鍵盤清單，再按一下這一列。 |
| 13 | 11 | `iphone-ios-keyboard-detail.png` | 開啟「允許完整取用」 | 開啟「允許完整取用」，出現警告時按「允許」。遠端打字和手寫都需要這項權限。 |
| 14 | 14 | App 首次引導、`iphone-rk-setup.png` | 看完引導，設定進度 > 藍牙 > 允許藍牙 | 打開 Remote Keyboard，看完引導後，在「設定進度」按「藍牙」，再按「允許藍牙」和「允許」。iPhone 這邊就好了。 |
| 15 | 20 | Release 頁面，終端機，解壓縮，拖進「應用程式」，再從「應用程式」打開 | 下載 zip，核對 SHA-256，拖進「應用程式」，連按兩下 Remote Keyboard Receiver | 換到 Mac。下載 zip，同樣在「終端機」核對 SHA-256，連按兩下解壓縮，把 Receiver 拖到「應用程式」，再從「應用程式」打開它。 |
| 16 | 26 | `mac-gatekeeper-dialog.png`、`mac-settings-security.png`、`mac-gatekeeper-open-anyway.png`、`mac-gatekeeper-auth.png`，標示每個正確按鈕 | 按「完成」；隱私權與安全性 > 強制打開；再按中間的「強制打開」；藍色是「丟到垃圾桶」，不要按 | 這個版本沒有經過 Apple 公證，第一次打開會被擋下，這是正常的。先按「完成」，到系統設定的「隱私權與安全性」，捲到最下方按「強制打開」。系統再問一次時，要按中間的「強制打開」。藍色那顆是丟到垃圾桶，不要按。最後用 Touch ID 或密碼確認。 |
| 17 | 16 | `mac-settings-bluetooth.png`、`mac-settings-accessibility.png` | 允許藍牙；輔助使用開啟 Remote Keyboard Receiver | 系統詢問藍牙時按「允許」。再點選單列的鍵盤圖示，按「打開輔助使用設定」，在清單裡開啟 Remote Keyboard Receiver。 |
| 18 | 21 | `mac-receiver-pairing-wait.png`、`iphone-rk-pairing-code.png`、`mac-receiver-pairing-code.png` 並排 | 配對新 iPhone；配對 Mac；核對六位數字 | 最後是配對。在 Mac 面板按「配對新 iPhone」。在 iPhone 的 App 按「已配對 Mac」，再按「配對 Mac」。兩邊會顯示同一組六位數字，核對完全相同後，先在 Mac、再在 iPhone 按「確認」。 |
| 19 | 8 | `mac-receiver-pairing-saved.png`、`iphone-rk-after-pair.png` | 兩邊按「完成」 | 兩邊都確認之後，再各按一次「完成」，配對就好了。 |
| 20 | 17 | `kb-connected.png`，文字出現在 Mac 的「文字編輯」 | 先在 Mac 的「文字編輯」點一下；按地球鍵選 Remote Keyboard，選「遠端」 | 先在 Mac 打開「文字編輯」，在文件裡點一下。接著在 iPhone 的任何輸入框叫出鍵盤，按住地球鍵選 Remote Keyboard，再選「遠端」。看到綠色的「已連接」，打字就會出現在 Mac 上。 |
| 21 | 12 | 日曆標示 7 天，手冊連結 | 7 天內要續簽；完整手冊在 GitHub | 免費帳號簽署的 App 只有 7 天有效，記得在到期前到 SideStore 續簽。遇到問題，請看 GitHub 上的使用手冊。 |
