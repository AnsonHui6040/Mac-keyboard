# Remote Keyboard 測試版安裝指南

這份指南給沒有程式開發經驗的測試者。整個流程用你自己的免費 Apple 帳號，不需要付費。

**請勿把 Apple 帳號密碼或雙重驗證碼交給任何人，包括開發者。** 如需回報問題，也不要傳送配對檔（Pairing File）或憑證檔。

## 開始前先了解

| 項目 | 說明 |
|---|---|
| App 有效期 | 免費帳號簽署的 App 只有 7 天有效，要定期續簽 |
| App 數量 | 免費帳號同時最多 3 個側載 App，SideStore 自己佔 1 個 |
| 本 App 佔用 | 主 App 和鍵盤各佔 1 個 App ID，所以每次全新安裝用掉 2 個 |
| App ID 上限 | 每 7 天最多註冊 10 個，無法手動刪除 |
| 網路 | 安裝和續簽都要 Wi-Fi 加 LocalDevVPN，行動網路不行 |
| Mac | 要搭配 Mac 上的 Remote Keyboard Receiver，由開發者另外提供 |

SideStore 是第三方工具，不是 Apple 的服務。首次安裝可能要花時間排解問題，安裝前請先備份 iPhone。

## A. 首次準備

### 你需要
- iPhone，已設定密碼
- Wi-Fi
- 自己的 Apple 帳號，也可以另外申請一個專門用來側載的帳號
- 電腦和 USB 線（只有首次安裝需要）

### 步驟
1. 在 iPhone 的 App Store 安裝 **LocalDevVPN**。打開後按 Connect，系統詢問 VPN 設定時按「允許」。
2. 到 [SideStore 官方網站](https://sidestore.io/)，依照官方連結在電腦安裝 **iloader**。Windows 另外需要安裝 iTunes，官方建議用 Apple 網站的版本。
3. 用 USB 連接 iPhone。如果出現提示，在 iPhone 按「信任」並輸入密碼。
4. 打開 iloader，登入 Apple 帳號。帳號有分大小寫。
5. 選擇你的裝置，再選 **Stable SideStore** 安裝。
6. 在 iPhone 打開「設定 > 一般 > VPN 與裝置管理」，在「開發者 App」下選你的帳號，然後按信任。iOS 18 以上要選「允許並重新啟動」，再輸入密碼。
7. 如果系統要求開發者模式：到「設定 > 隱私權與安全性」，捲到最下面開啟「開發者模式」，iPhone 會重新啟動。
8. 連上 Wi-Fi，打開 LocalDevVPN 並按 Connect。
9. 打開 SideStore，用剛才在 iloader 用的同一個 Apple 帳號登入。如果出現「This action cannot be completed at this time. (-80045)」，先照下面的方法處理，再登入。
10. 到 My Apps，按 SideStore 旁邊的「7 DAYS」進行 Refresh。如果詢問是否撤銷或建立新憑證，按 Yes 或 Refresh Now。

成功時 iPhone 會回到主畫面並顯示通知，幾秒後 SideStore 就可以再次使用。**請先完成這次 Refresh，再安裝其他 App。**

### 登入出現 (-80045)
這是 SideStore 目前已知的問題，和密碼無關。在 SideStore 的 Settings 依序做：

1. User Customizations：關閉 **On-Device Anisette**，詢問是否重新啟動時選是。
2. Anisette Servers：選 **SideStore (New)**，再捲到最下面關閉 **Enable Auto Rotation**。
3. User Customizations > Anisette Client Configuration > Remote Server Sync：按 **Fetch**，再按 **Save as Overrides**。
4. 回到 User Customizations，按 **Reset adi.pb**。
5. 完全關閉 SideStore 再打開，重新登入，可能要等一下。

如果仍然失敗，第 2 步改選 **Jkcoxson**，再做一次第 3 至 5 步。不要連續嘗試太多次，Apple 可能暫時限制登入。登入後帳號的裝置清單可能多出一部 Mac，那是 Anisette 伺服器產生的虛擬裝置。

> iOS 26.4 以上：SideStore 官方的錯誤碼文件提到，遇到錯誤 (27) 時要改用 nightly 版。如果 Stable 版無法 Refresh，請先告訴開發者你的 iOS 版本。

## B. 安裝測試 App

1. 下載開發者提供的 `RemoteKeyboard-v版本號-unsigned.ipa`，存到 iPhone 的「檔案」。
2. 核對 SHA-256（開發者會一併提供）。在 Mac 可用這個指令，結果要和提供的值完全相同：

```bash
shasum -a 256 RemoteKeyboard-v版本號-unsigned.ipa
```

3. 確認 Wi-Fi 和 LocalDevVPN 都已連線。
4. 打開 SideStore 的 My Apps，按左上角的「+」，選擇這個 IPA。
5. **詢問 App Extension 時，選「Keep App Extensions (Register App ID for Each Extension)」。不要選 Remove，移除後就沒有鍵盤了。** 這會多用 1 個 App ID。
6. 等待安裝完成。

### 開啟鍵盤
1. 打開 Remote Keyboard，依畫面配對 Mac（App 內的「配對 Mac」）。
2. 到「設定 > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤」，加入 Remote Keyboard。
3. 點一下剛加入的鍵盤，開啟「允許完整取用」。遠端打字和手寫都需要它。
4. 手寫需要在 App 的「中文輸入設定」下載手寫模型（約 30 MB）。
5. 在備忘錄打開鍵盤試打，確認文字出現在 Mac。

## Mac 端安裝

1. 下載 `RemoteKeyboardReceiver-v版本號-macOS.zip` 並核對 SHA-256，然後解壓縮，把 App 拖到「應用程式」資料夾。
2. 打開 App。這個版本沒有經過 Apple 公證，系統會阻擋。先關閉提示，到「系統設定 > 隱私權與安全性」，捲到「安全性」，按「仍要打開」，再輸入密碼確認。
3. 依提示允許**藍牙**。
4. 到「系統設定 > 隱私權與安全性 > 輔助使用」，開啟 Remote Keyboard Receiver。清單沒有它時，按左下角「＋」，在「應用程式」選它加入。App 需要這個權限才能把文字輸入到其他 App。
5. 從選單列打開 Receiver，依畫面和 iPhone 配對。

更新 Mac 版之後要重新開啟輔助使用權限，配對會保留，不用重新配對。如果開關已開啟，面板仍顯示「輔助使用未授權」，請把它從清單移除，再按「＋」重新加入。

為了安全，Mac 鎖定畫面、游標在密碼欄，或其他 App 開啟安全輸入（例如終端機的「安全鍵盤輸入」）時，文字不會送出，也不會留在草稿，鍵盤會顯示「密碼不能輸入」。其他 App 忘了關閉安全輸入時，一般欄位也會顯示這句，關閉該 App 的安全輸入即可恢復。Mac 沒有輸入欄位時，即時模式打的字同樣不會保留，鍵盤會提示「Mac 沒有輸入欄位，未輸入」。**請不要用這個鍵盤輸入密碼。**

## C. 7 天續簽

1. 在 SideStore 的 My Apps 看到期日。
2. 到期前連上 Wi-Fi 和 LocalDevVPN。
3. 按 App 旁的天數進行 Refresh。
4. 確認天數已更新。
5. 打開 Remote Keyboard，確認可以正常使用。

SideStore 會嘗試在背景自動續簽，但這取決於系統的背景執行條件，**不保證每次成功**。建議每 3 至 5 天手動確認一次。

## D. 更新 App

1. 取得新版 IPA 並核對 SHA-256。
2. 確認仍使用**同一個 Apple 帳號**。
3. **不要先刪除舊版。**
4. 連上 Wi-Fi 和 LocalDevVPN，在 SideStore 用同樣方式選擇新版 IPA。
5. 詢問 App Extension 時，選「Keep App Extensions (Register App ID for Each Extension)」。
6. 打開 App，確認配對和設定還在。

### 可能遺失資料的情況
| 情況 | 結果 |
|---|---|
| 先刪除舊版再安裝 | 配對和設定會遺失 |
| 換另一個 Apple 帳號簽署 | 視為不同 App，配對和設定會遺失，要重新配對 |
| 讓 App 過期後被移除 | 可能遺失，請在到期前續簽 |

## E. 常見問題

| 問題 | 如何確認 | 如何處理 |
|---|---|---|
| 無法登入 Apple 帳號，或畫面卡住 | SideStore 登入時凍結或出現錯誤碼 | 確認帳號大小寫；在 SideStore 設定改用另一個 Anisette 伺服器；仍不行就換專用帳號 |
| 收不到雙重驗證碼 | SideStore 要求輸入驗證碼但沒有收到 | iOS 18.1 以上：先關閉 Wi-Fi 和行動數據，到「設定 > 你的名字 > 登入與安全性 > 取得驗證碼」，再輸入到 SideStore |
| 連不上 LocalDevVPN，或出現 (1414)、(27) | 檢查 Wi-Fi 和 LocalDevVPN 是否都顯示已連線 | 關閉 DNS 阻擋工具和其他 VPN；重開 SideStore 和 LocalDevVPN；再不行就更換配對檔 |
| 配對檔失效，出現 (1006)、(1414) | 兩項連線都正常但仍然失敗 | 用 iloader：Delete Stored Pairing，選裝置後在 iPhone 按信任，再到 Manage Pairing File 的 SideStore 旁按 Place，看到成功訊息才算完成 |
| IPA 格式錯誤，出現 (1007) | 比對 SHA-256 | 重新下載 IPA；值仍不同就回報開發者 |
| 簽署失敗，出現 ldid、(3007)、(3008)、(3017) | 記下完整錯誤碼 | 重新 Refresh SideStore 再試；仍失敗請把錯誤碼回報開發者，不要傳憑證 |
| 安裝後無法開啟 | App 圖示一點就退出 | 先確認已信任開發者並開啟開發者模式；再確認未過期；然後 Refresh。把 iOS 版本回報開發者 |
| 鍵盤清單沒有 Remote Keyboard | 到「新增鍵盤」查看 | 可能安裝時移除了 Extension。重新安裝 IPA，Extension 選「Keep App Extensions (Register App ID for Each Extension)」 |
| 無法配對或設定不共用 | App 顯示未配對，或鍵盤讀不到設定 | 確認已開啟完整取用；回報開發者，這正是測試重點之一 |
| 鍵盤顯示「配對驗證失敗」 | Mac 的 Receiver 面板配對狀態 | 兩邊重新配對：Mac 按「配對新 iPhone」，iPhone App 按「配對 Mac」，核對配對碼後兩邊都按確認，最後按完成 |
| 超過 App ID 上限，出現 (1009)、(3013) | 查看 My Apps 的到期日 | App ID 無法手動刪除，只能等最舊的滿 7 天；不要反覆刪除重裝 |
| 鍵盤連不上 Mac | Mac 的 Receiver 面板顯示沒有在接收 | Receiver 閒置 30 分鐘會停止接收。在 Mac 點一下文字欄位，或從選單列打開 Receiver 按「開始接收」。如果仍然不行，關閉停在密碼欄的瀏覽器分頁或其他 App，它們可能開著安全輸入 |
| 超過 3 個 App | 安裝時提示數量已滿，或出現「無法驗證其完整性」 | 免費帳號同時最多 3 個側載 App，SideStore 佔 1 個。停用或移除其他用同一個 Apple 帳號簽署的 App，包括自己用 Xcode 裝的 App |
| App 已到期 | 圖示點了打不開 | 連上 Wi-Fi 和 LocalDevVPN 後 Refresh；不要刪除 App |
| 更新後資料不見 | 配對或設定消失 | 確認有沒有換帳號或刪除舊版；重新配對，並回報發生經過 |

官方資料：[安裝需求](https://docs.sidestore.io/docs/installation/prerequisites)、[安裝步驟](https://docs.sidestore.io/docs/installation/install)、[FAQ](https://docs.sidestore.io/docs/faq)、[疑難排解](https://docs.sidestore.io/docs/troubleshooting)。
