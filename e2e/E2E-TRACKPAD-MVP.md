# 觸控板 MVP 試用（使用者親手）

結果欄在使用者試用前一律 TBD。

## 安裝

### Mac

1. 在 repo 根目錄（branch `trackpad-mvp`）執行 `scripts/install-mac-receiver.sh`。它會建置並安裝到 `/Applications/Remote Keyboard Receiver.app`，然後自動開啟。
2. 第一次從這個版本開啟時：
   - 到 系統設定 › 隱私權與安全性 › 輔助使用，重新允許「Remote Keyboard Receiver」，舊的項目可以移除。
   - 到 系統設定 › 隱私權與安全性 › 藍牙，重新允許「Remote Keyboard Receiver」。
   - 面板的「系統設定」區有直接打開這兩頁的按鈕。
3. 確認面板的「允許觸控板控制」已開啟（預設開）。

### iPhone

使用 Personal Team 簽名，build 7 天到期。二選一：

- Xcode 開 `RemoteKeyboard.xcworkspace`，scheme 選 `RemoteKeyboardApp`，裝置選自己的 iPhone，按 Run。
- 或用指令：
  ```bash
  xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -destination 'id=<iPhone UDID>' -derivedDataPath ~/Library/Caches/RemoteKeyboard/ios-dd -allowProvisioningUpdates
  ```
  建置後再執行：
  ```bash
  xcrun devicectl device install app --device <UDID> ~/Library/Caches/RemoteKeyboard/ios-dd/Build/Products/Debug-iphoneos/RemoteKeyboardApp.app
  ```

## 啟動

1. Mac 點一下任何可輸入文字的地方（例如 TextEdit），讓 Receiver 開始接收。或在面板手動開始。
2. iPhone 任一 App 叫出 Remote Keyboard，切到「遠端」。等狀態列顯示已連上 Mac。
3. 按狀態列的「觸控板」。鍵區變成灰色觸控板。按「鍵盤」返回。

## 操作

| 操作 | 手勢 |
|---|---|
| 移動游標 | 單指滑動（越快移得越遠） |
| 左鍵點擊 | 單指輕點 |
| 拖曳 | 單指按住約 0.4 秒不動，然後移動；手指離開即放開 |
| 捲動 | 雙指滑動 |

## 試用清單

| # | 項目 | 結果 |
|---|---|---|
| 1 | iPhone 連上 Mac，觸控板頁顯示可用 | TBD |
| 2 | 移動游標：流暢度、延遲、跳動 | TBD |
| 3 | 點擊桌面圖示 | TBD |
| 4 | 開啟並操作一般視窗 | TBD |
| 5 | 拖曳視窗（按住標題列） | TBD |
| 6 | Safari 或其他 App 捲動頁面（方向是否符合預期） | TBD |
| 7 | 斷線後重連：收起鍵盤再叫出，或關開 iPhone 藍牙 | TBD |
| 8 | 拖曳中收起鍵盤：Mac 左鍵應自動放開 | TBD |
