# 安裝教學影片 YouTube 上傳資料（v0.2.0 Alpha 1）

影片檔：`video/out/renders/Main.mp4`（346 秒，1920×1080，30 fps，有音樂與音效，沒有旁白）。
下方「標題」與「說明」兩段直接貼到 YouTube。說明全長約 1,700 字元，低於 YouTube 的 5,000 字元上限。

## 標題

Remote Keyboard 安裝教學：把 iPhone 變成 Mac 的藍牙鍵盤和觸控板（v0.2.0 Alpha 1）

## 說明

這支影片從零開始，示範在 iPhone 與 Mac 上安裝 Remote Keyboard，配對後在 Mac 打出第一個字。影片沒有旁白，每一步都有字幕。

Remote Keyboard 把 iPhone 變成電腦的藍牙鍵盤和觸控板，支援 Mac、Windows 11 與 Ubuntu 26.04。影片只示範 Mac；Windows 與 Linux 的接收端請看使用手冊第 04b、04c 章。

影片對應 v0.2.0 Alpha 1（iPhone App build 5）。內容與手冊有出入時，以手冊為準。

章節
0:00 Remote Keyboard 是什麼
0:12 需要準備的東西
0:25 安全提醒
0:38 安裝 LocalDevVPN
0:51 用 iloader 安裝 SideStore
1:15 信任開發者與開發者模式
1:39 登入 SideStore
1:50 第一次續簽
2:04 錯誤 -80045
2:13 下載 IPA 並核對 SHA-256
2:33 用 SideStore 安裝 Remote Keyboard
2:58 加入鍵盤
3:12 允許完整取用
3:23 打開 App 並允許藍牙
3:37 下載 Mac Receiver 並核對 SHA-256
3:57 第一次打開 Mac Receiver
4:23 允許藍牙與輔助使用
4:39 配對
5:00 完成配對
5:08 在 Mac 打出第一個字
5:25 區域網路權限、續簽與使用手冊

下載
Release 頁面：https://github.com/AnsonHui6040/Mac-keyboard/releases/tag/v0.2.0-alpha.1
使用手冊：https://github.com/AnsonHui6040/Mac-keyboard/blob/main/docs/manual/README.md

SHA-256（安裝前請核對，與 Release 頁面的 SHA256SUMS.txt 相同）
RemoteKeyboard-v0.2.0-unsigned.ipa
c659466046402f8beb1a0e5205cc1480226800a81cd830176a4695ea1501a02a
RemoteKeyboardReceiver-v0.2.0-macOS.zip
b630e808908459d8bbf318d4a1ba42d9088f2904878fc1f7dcdc90ad35eabd31

需求
iPhone：iOS 18 以上，已設定螢幕鎖定密碼
Mac：macOS 15 以上，Apple 晶片
一條 USB 線、Wi-Fi，以及你自己的免費 Apple 帳號

安全提醒
請不要把 Apple 帳號密碼或雙重驗證碼交給任何人，包括開發者。
請不要用這個鍵盤輸入密碼。
免費帳號簽署的 App 只有 7 天有效，要在到期前到 SideStore 續簽。
Mac Receiver 沒有經過 Apple 公證，第一次打開會被擋下，處理方式見影片 3:57。

從 v0.1 升級
v0.2 的通訊協定與 v0.1 不相容，iPhone App 與 Mac Receiver 都要更新，每台電腦都要重新配對。
iPhone：用 SideStore 匯入新的 IPA，不要先刪除舊版。
Mac：用新的 zip 取代舊的 App，重新允許輔助使用與藍牙。
詳細步驟見 Release 頁面的發佈說明。

v0.2 新功能
iPhone 最多記住 8 台電腦，在鍵盤的狀態格點一下切換。
Windows 11 與 Ubuntu 26.04 接收端。
iPhone 與電腦在同一個 Wi-Fi 時，觸控板游標改走 Wi-Fi，移動比較順；第一次使用時 Mac 會詢問區域網路，按「允許」。

這是 Alpha 測試版，功能還會調整，也可能有問題，請不要用在重要工作上。本軟體依現狀提供，不提供任何保證。
