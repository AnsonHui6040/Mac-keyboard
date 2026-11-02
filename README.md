# Remote Keyboard

Remote Keyboard 讓 iPhone 變成 Mac 的藍牙鍵盤。在 iPhone 上切換到 Remote Keyboard 鍵盤，打的字會經藍牙加密傳到 Mac，直接輸入到 Mac 目前游標所在的文字欄位。鍵盤另有觸控板模式，可以用 iPhone 移動 Mac 的游標、點按與捲動。

目前是 v0.1.0 測試版，透過 SideStore 安裝，不是 App Store 的正式版。

## 功能

- 遠端模式：在 iPhone 打字，文字出現在 Mac 目前的輸入欄位。
- 本機模式：同一個鍵盤也可以直接打字到 iPhone 的 App。
- 即時與草稿：即時模式每按一個鍵就送出；草稿模式先在鍵盤上編輯，按「傳送」才一次送出。
- 輸入方式：英文、符號、中文手寫、速成。
- 觸控板：移動、點按、雙擊、右鍵、拖曳、捲動。
- 密碼保護：Mac 的密碼欄、安全輸入與鎖定畫面不會收到文字。

## 需求

| 項目 | 需求 |
|---|---|
| iPhone | iOS 18 以上 |
| Mac | macOS 15 以上，Apple 晶片 |
| 連線 | 藍牙；安裝與續簽 iPhone App 時需要 Wi-Fi |
| Apple 帳號 | 你自己的免費 Apple 帳號，不需要付費的開發者計畫 |
| 安裝時 | 一條 USB 線，連接 iPhone 與 Mac |

## 如何取得

| 項目 | 說明 |
|---|---|
| iPhone App | 用 SideStore 安裝開發者提供的 IPA，以你自己的免費 Apple 帳號簽署 |
| Mac Receiver | 開發者提供的 zip 檔，解壓縮後放進「應用程式」 |
| 公證 | Mac Receiver 沒有經過 Apple 公證，第一次打開要到系統設定手動允許 |
| 有效期 | 免費帳號簽署的 App 只有 7 天有效，要在到期前續簽 |
| 名額 | 免費帳號同時最多 3 個側載 App，SideStore 自己佔 1 個 |

## 使用手冊

第一次安裝請依章節順序閱讀。

| 章節 | 內容 |
|---|---|
| [手冊首頁](docs/manual/README.md) | 章節總表與建議閱讀順序 |
| [01 開始之前](docs/manual/01-before-you-start.md) | 需要準備的東西、免費帳號的限制、安全原則、整體流程 |
| [02 安裝 SideStore](docs/manual/02-install-sidestore.md) | LocalDevVPN、iloader、信任開發者、開發者模式、登入與第一次續簽 |
| [03 安裝 iPhone App](docs/manual/03-install-iphone-app.md) | 驗證並匯入 IPA、加入鍵盤、允許完整取用與藍牙 |
| [04 安裝 Mac Receiver](docs/manual/04-install-mac-receiver.md) | 下載、解壓縮、第一次打開、藍牙與輔助使用權限、選單列面板 |
| [05 配對](docs/manual/05-pairing.md) | 用六位數配對碼把 iPhone 與 Mac 配成一組 |
| [06 使用鍵盤](docs/manual/06-using-the-keyboard.md) | 本機與遠端、即時與草稿、手寫、速成、狀態列提示、密碼的處理 |
| [07 觸控板](docs/manual/07-trackpad.md) | 觸控板手勢與設定 |
| [08 App 設定](docs/manual/08-app-settings.md) | 聽寫、按鍵回饋、觸控板靈敏度、手寫模型 |
| [09 續簽與更新](docs/manual/09-refresh-and-update.md) | 7 天續簽、更新 IPA 與 Mac Receiver、什麼情況會遺失資料 |
| [10 疑難排解](docs/manual/10-troubleshooting.md) | 安裝、配對與打字的常見問題 |

## 隱私與安全

- 文字只經藍牙加密傳到你配對的 Mac，不會傳到開發者或任何伺服器。App 的紀錄只有事件種類、長度、時間與結果，不含文字內容。
- 鍵盤需要「允許完整取用」，Mac Receiver 需要「藍牙」與「輔助使用」權限，用途都寫在隱私說明裡。
- 手寫辨識使用 Google ML Kit，使用手寫時 ML Kit 會連到 Google 下載模型並傳送使用與效能資料。
- 請不要用這個鍵盤輸入密碼。部分終端機的密碼提示、遠端桌面內的欄位等偵測不到，文字仍會送出。
- 請不要把 Apple 帳號密碼或雙重驗證碼交給任何人，包括開發者。

詳細內容請見 [隱私說明](docs/distribution/privacy-note.md) 與 [風險說明](docs/distribution/risk-note.md)。

## 開發者

建置方式、專案狀態與發佈腳本請見 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
