# 10 疑難排解

先找到你遇到的情況，再照處理欄操作。分成三類：安裝與續簽、Mac Receiver、鍵盤與配對。

回報問題時，請提供完整的錯誤碼與 iOS 版本。請不要傳送密碼、Apple 帳號資料、雙重驗證碼、配對檔或憑證。

## 安裝與續簽

| 問題 | 如何確認 | 如何處理 |
|---|---|---|
| 無法登入 Apple 帳號，或畫面卡住 | SideStore 登入時凍結或出現錯誤碼 | 確認帳號大小寫；出現 -80045 時，照 [02 安裝 SideStore](02-install-sidestore.md) 的 Anisette 設定處理；在 SideStore 設定改用另一個 Anisette 伺服器；仍不行就換專用帳號 |
| 收不到雙重驗證碼 | SideStore 要求輸入驗證碼但沒有收到 | iOS 18.1 以上：先關閉 Wi-Fi 與行動數據，到「設定 > 你的名字 > 登入與安全性 > 取得驗證碼」，再把驗證碼輸入到 SideStore |
| 連不上 LocalDevVPN，或出現 (1414)、(27) | 檢查 Wi-Fi 與 LocalDevVPN 是否都顯示已連線 | 關閉 DNS 阻擋工具與其他 VPN；重新開啟 SideStore 與 LocalDevVPN；再不行就更換配對檔 |
| 配對檔失效，出現 (1006)、(1414) | 兩項連線都正常但仍然失敗 | 在 Mac 用 iloader：選 Delete Stored Pairing，選裝置後在 iPhone 按「信任」，再到 Manage Pairing File，在 SideStore 旁按 Place，看到成功訊息才算完成 |
| IPA 格式錯誤，出現 (1007) | 用 `shasum -a 256` 比對 SHA-256 | 重新下載 IPA；值仍不同，就回報開發者 |
| 簽署失敗，出現 ldid、(3007)、(3008)、(3017) | 記下完整錯誤碼 | 在 SideStore 重新 Refresh 再試；仍失敗，把錯誤碼回報開發者，不要傳憑證 |
| 安裝後無法開啟 | App 圖示一點就退出 | 先確認已信任開發者並開啟開發者模式（見 [02 安裝 SideStore](02-install-sidestore.md)）；再確認未過期；然後 Refresh。把 iOS 版本回報開發者 |
| 超過 App ID 上限，出現 (1009)、(3013) | 查看 My Apps 的剩餘 App ID | App ID 無法手動刪除，只能等最舊的滿 7 天；不要反覆刪除重裝 |
| 超過 3 個 App | 安裝時提示數量已滿，或出現「無法驗證其完整性」 | 免費帳號同時最多 3 個側載 App，SideStore 佔 1 個。停用或移除其他用同一個 Apple 帳號簽署的 App，包括自己用 Xcode 裝的 App |
| App 已到期 | 圖示點了打不開 | 連上 Wi-Fi 與 LocalDevVPN 後 Refresh；不要刪除 App |
| 更新後資料不見 | 配對或設定消失 | 確認有沒有換帳號或刪除舊版；重新配對，並回報發生經過 |
| iOS 26.4 以上，Refresh 出現 (27) | Stable 版無法 Refresh | 回報開發者你的 iOS 版本；SideStore 官方文件提到可能需要改用 nightly 版 |

官方資料：[安裝需求](https://docs.sidestore.io/docs/installation/prerequisites)、[安裝步驟](https://docs.sidestore.io/docs/installation/install)、[FAQ](https://docs.sidestore.io/docs/faq)、[疑難排解](https://docs.sidestore.io/docs/troubleshooting)。

## 鍵盤與 App 安裝

| 問題 | 如何確認 | 如何處理 |
|---|---|---|
| 鍵盤清單沒有 Remote Keyboard | 到「設定 > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤」查看 | 可能安裝時移除了 Extension。重新安裝 IPA，Extension 選「Keep App Extensions (Register App ID for Each Extension)」 |
| 無法配對，或設定不共用 | App 顯示未配對，或鍵盤讀不到設定 | 確認已開啟「允許完整取用」；回報開發者，這是測試重點之一 |
| 手寫頁不能辨識 | 手寫頁沒有候選字，或中文頁變成速成 | 到 App 的「中文輸入與手寫」確認手寫模型狀態是「已下載」，並確認已開啟「允許完整取用」 |

## Mac Receiver

| 問題 | 如何確認 | 如何處理 |
|---|---|---|
| 打開時被阻擋 | 出現 Apple 無法驗證的提示 | 按「完成」，到「系統設定 > 隱私權與安全性」，在安全性區段按「強制開啟」（較舊的 macOS 為「仍要打開」）。做法見 [04 安裝 Mac Receiver](04-install-mac-receiver.md) |
| 面板顯示「尚未授權輔助使用，無法輸入文字」 | 面板最上方的紅字 | 到「系統設定 > 隱私權與安全性 > 輔助使用」開啟 Remote Keyboard Receiver；清單沒有就按「＋」加入；開關已開啟仍顯示，就先移除再重新加入 |
| 面板顯示藍牙的紅字說明 | 面板最上方出現藍牙相關的紅字 | 開啟 Mac 的藍牙；或按「打開藍牙設定」，開啟 Remote Keyboard Receiver 的開關 |
| 更新後輔助使用又被要求授權 | 面板顯示「尚未授權輔助使用，無法輸入文字」 | 這是正常的，更新後要重新允許一次；配對仍保留 |

## 鍵盤連線與打字

| 問題 | 如何確認 | 如何處理 |
|---|---|---|
| 鍵盤停在「未連接」 | 狀態列為紅色的未連接，觸控板按鍵是灰色 | 先按 Mac 面板的「開始接收」，或在 Mac 點一下文字欄位；Receiver 閒置 30 分鐘會停止接收。仍不行，關閉停在密碼欄的瀏覽器分頁或其他 App，它們可能開著安全輸入。再不行，收起鍵盤重新叫出，或結束 Receiver 後重開 |
| 鍵盤顯示「手寫模型匯入失敗」 | App 的「中文輸入與手寫」 | 在「中文輸入與手寫」的「手寫模型」按「刪除手寫模型」，再按「下載手寫模型」重新下載，再回到鍵盤 |
| App 首頁顯示「連線有問題」 | 首頁「設定進度」展開後的第一行 | 按那一行，依畫面處理。鍵盤下次連上後會自動消失 |
| 鍵盤顯示「配對驗證失敗」 | Mac 的 Receiver 面板配對狀態 | 兩邊重新配對：Mac 按「配對新 iPhone」，iPhone 按「配對 Mac」，核對配對碼後兩邊都按「確認」，最後按「完成」。見 [05 配對](05-pairing.md) |
| 鍵盤顯示「尚未配對」 | 狀態列為紅色的尚未配對 | 依 [05 配對](05-pairing.md) 配對 |
| 在一般欄位也顯示「密碼不能輸入」 | Mac 的游標明明在一般文字欄位 | 有其他 App 開著安全輸入。關閉終端機的「安全鍵盤輸入」，並關閉停在密碼欄的瀏覽器分頁或其他 App，然後在 Mac 點一下文字欄位 |
| 顯示「Mac 沒有輸入欄位，未輸入」 | 打字後出現紅字提示 | 在 Mac 點一下要輸入的文字欄位，再打字 |
| 顯示「Mac 未授權輔助使用」 | 狀態列為紅色 | 在 Mac 允許輔助使用，見 [04 安裝 Mac Receiver](04-install-mac-receiver.md) |
| 顯示「N 個按鍵未確認是否送達」 | 連線中斷後出現 | 到 Mac 檢查文字，補上缺少的部分或刪掉重複的部分 |
| 觸控板顯示「Mac 未允許觸控板控制」 | 觸控板頁中央的灰色文字 | 在 Mac 面板勾選「允許觸控板控制」 |
| 觸控板按鍵是灰色 | 頂部的「觸控板」不能按 | 鍵盤尚未連上 Mac 或尚未配對，先處理狀態列的問題 |

回到章節：[手冊首頁](README.md)
