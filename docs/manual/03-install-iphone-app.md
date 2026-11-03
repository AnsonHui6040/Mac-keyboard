# 03 安裝 iPhone App

本章用 SideStore 把 Remote Keyboard 安裝到 iPhone，加入鍵盤，並開啟需要的權限。

開始前請確認 SideStore 已完成第一次續簽（見 [02 安裝 SideStore](02-install-sidestore.md)），並且 iPhone 連上 Wi-Fi，LocalDevVPN 顯示「已連線」。

## 一、取得並驗證 IPA

1. 在 Mac 下載開發者提供的 `RemoteKeyboard-v版本號-unsigned.ipa`，同時取得對應的 SHA-256 值。
2. 在 Mac 的「終端機」執行下面的指令，把檔案路徑換成你的 IPA 位置。

```bash
shasum -a 256 RemoteKeyboard-v版本號-unsigned.ipa
```

3. 比對輸出的值與開發者提供的 SHA-256，兩者必須完全相同。
4. 用 AirDrop 把同一個 IPA 傳到 iPhone，存到「檔案」App。之後匯入的就是這個已核對過的檔案。

值不同時，請重新下載；重新下載後仍然不同，請回報開發者，不要安裝。

## 二、匯入 IPA

1. 打開 SideStore，進入 **My Apps**。
2. 按左上角的「+」。
3. 在檔案選擇畫面，選擇剛才存好的 IPA。
4. SideStore 詢問如何處理 App Extension 時，選「Keep App Extensions (Register App ID for Each Extension)」。

**不要選 Remove。** 移除 Extension 之後，App 裡就沒有鍵盤了。保留 Extension 會多用 1 個 App ID，所以一次全新安裝共用掉 2 個。

5. 等待安裝完成。

<img src="images/iphone-sidestore-myapps.png" width="320" alt="SideStore 的 My Apps 頁面，Active 清單中有 SideStore 與 Remote Keyboard，兩者都顯示 7 DAYS，下方顯示 5 App IDs Remaining">

成功時，My Apps 的 Active 清單出現 **Remote Keyboard**，到期欄顯示「7 DAYS」。清單下方會顯示剩餘的 App ID 數量。

## 三、加入鍵盤

1. 打開「設定 > 一般 > 鍵盤 > 鍵盤」。
2. 按「新增鍵盤」。
3. 在「第三方鍵盤」區找到 **Remote Keyboard**，按一下。

<img src="images/iphone-ios-add-keyboard.png" width="320" alt="iPhone 的新增鍵盤頁面，上方為建議鍵盤，往下捲是第三方鍵盤區塊">

4. 回到「鍵盤」頁面，確認清單裡有 Remote Keyboard。
5. 按一下 **Remote Keyboard** 這一列。

<img src="images/iphone-ios-keyboards.png" width="320" alt="iPhone 的鍵盤頁面，清單中已有 Remote Keyboard，下方是新增鍵盤">

沒有看到 Remote Keyboard 時，可能是安裝時移除了 Extension。請重新安裝 IPA，並在詢問 Extension 時選「Keep App Extensions (Register App ID for Each Extension)」。

## 四、允許完整取用

遠端打字、手寫，以及自訂的按鍵聲音與震動，都需要「允許完整取用」。

1. 在上一步開啟的 Remote Keyboard 頁面，開啟「允許完整取用」。部分地區的 iOS 顯示為「允許全權取用」，意思相同。
2. 如果出現警告視窗，閱讀後按「允許」。

<img src="images/iphone-ios-keyboard-detail.png" width="320" alt="Remote Keyboard 的鍵盤設定頁面，允許全權取用的開關已開啟">

也可以從「設定」App 的最下方找到 **Remote Keyboard**，進入後再按「鍵盤」，同樣可以開啟。

<img src="images/iphone-ios-app-settings.png" width="320" alt="設定 App 中 Remote Keyboard 的頁面，有藍牙、行動數據與鍵盤三項">

<img src="images/iphone-ios-app-keyboard-fullaccess.png" width="320" alt="設定 App 中 Remote Keyboard 的鍵盤頁面，Remote Keyboard 與允許全權取用兩個開關都已開啟">

成功時，兩個開關都是綠色。

只有在信任這個版本的來源時，才開啟完整取用。隱私說明列出了這項權限的用途，見 [隱私說明](../distribution/privacy-note.md)。

## 五、打開 App 並允許藍牙

1. 在主畫面打開 **Remote Keyboard**。
2. 捲到最下方的「藍牙」區，按「允許藍牙」。
3. iOS 詢問是否允許 Remote Keyboard 使用藍牙時，按「允許」。

<img src="images/iphone-rk-bluetooth.png" width="320" alt="Remote Keyboard 主畫面捲到下方：Mac 配對區顯示尚未配對，藍牙區有允許藍牙按鈕，狀態為已允許">


成功時，「藍牙」區的狀態顯示「已允許」。如果顯示「已拒絕，請到設定開啟」，按「到設定開啟藍牙」，在設定裡開啟藍牙。

主畫面的各區塊如下。

| 區塊 | 內容 |
|---|---|
| 版本 | 這個版本的建置時間 |
| 設定 | 「打開 iPhone 設定」，直接跳到設定 App 的 Remote Keyboard 頁面 |
| 測試輸入 | 一個輸入框，可以在這裡試用鍵盤 |
| 鍵盤 | 「中文輸入設定」，見 [08 App 設定](08-app-settings.md) |
| Mac 配對 | 目前的配對狀態、「配對 Mac」與「解除配對」，見 [05 配對](05-pairing.md) |
| 藍牙 | 「允許藍牙」與目前的藍牙授權狀態 |

下一章：[04 安裝 Mac Receiver](04-install-mac-receiver.md)
