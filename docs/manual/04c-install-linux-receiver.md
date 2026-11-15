# 04c 安裝 Linux 接收端

Linux 接收端是安裝在 Ubuntu 電腦上的接收程式。iPhone 傳來的文字與觸控板動作，由它輸入到電腦目前在最前面的視窗。它沒有主視窗，只在頂端列的右側顯示一個系統匣圖示。

這一章只適用於 Ubuntu 電腦。Mac 請看 [04 安裝 Mac Receiver](04-install-mac-receiver.md)，Windows 請看 [04b 安裝 Windows 接收端](04b-install-windows-receiver.md)。

## 需求

| 項目 | 需求 |
|---|---|
| 作業系統 | Ubuntu 26.04，x86_64，桌面為 GNOME，工作階段為 Wayland |
| 藍牙 | 電腦有藍牙（支援 Bluetooth LE），而且已開啟 |
| 權限 | 安裝時需要 `sudo`，執行接收端不需要 |
| 網路 | 接收端運作時不需要網路，文字只經藍牙傳送 |

安裝套件會一併安裝下列相依套件：`zenity`、`xdg-desktop-portal`、`xdg-desktop-portal-gnome`、`gnome-keyring`、`bluez`。

## 一、下載、驗證並安裝

1. 從 GitHub Release 取得 `remote-keyboard_0.2.0~alpha.1_amd64.deb`，以及同一頁的 `SHA256SUMS.txt`。
2. 打開「終端機」，執行下面的指令，把檔案路徑換成你的 `.deb` 位置。

```bash
sha256sum remote-keyboard_0.2.0~alpha.1_amd64.deb
```

3. 比對輸出的值與 `SHA256SUMS.txt` 裡該檔案的值，兩者必須完全相同。值不同時請重新下載，不要安裝。
4. 在 `.deb` 所在的資料夾執行：

```bash
sudo apt install ./remote-keyboard_0.2.0~alpha.1_amd64.deb
```

安裝後，`/usr/bin/rk-receiver` 是接收端，`/usr/bin/rk-diag` 是診斷工具，應用程式選單多了一個「Remote Keyboard」項目。

## 二、第一次執行

1. 打開應用程式選單，執行「Remote Keyboard」。
2. 第一次執行時，系統跳出視窗，詢問是否允許 Remote Keyboard 使用「遠端桌面」（Remote Desktop）。按「允許」。
3. 頂端列的右側出現 Remote Keyboard 的圖示。

遠端桌面的授權讓接收端可以把按鍵與游標移動送進桌面。沒有授權就不能輸入，系統匣的狀態會顯示「電腦未授權，請選「重新授權」」，這時選系統匣選單的「重新授權」，再按一次「允許」。授權記錄在接收端，之後不會再問。

成功時，系統匣選單的第一行顯示「接收中，等待手機連線」。

## 三、系統匣選單

點頂端列的 Remote Keyboard 圖示，打開選單。選單的文字依系統語言決定，語言是中文時顯示下表的中文，其他語言顯示英文。

| 項目（中文） | 項目（英文） | 說明 |
|---|---|---|
| 第一行（狀態）：接收中，等待手機連線、已連線：手機名稱、配對中，請在手機上開啟配對畫面、已停止接收、電腦未授權，請選「重新授權」 | Receiving, waiting for a phone; Connected: phone name; Pairing: open the pairing screen on the phone; Receiving stopped; Not authorized to type: choose Authorize again | 目前的狀態。這一行不能按 |
| 停止接收、開始接收 | Stop receiving、Start receiving | 「停止接收」會中斷目前連線並停止掃描，直到按「開始接收」或重新啟動接收端才恢復。「已停止」不會存入設定，重新啟動後一律接收中 |
| 電腦名稱　改名… | Computer name　Rename… | 這一行以目前的電腦名稱開頭，預設是「Linux」。按下去會出現輸入框，用來改這台電腦在手機上顯示的名稱，最多 32 個位元組。改名後，已配對的 iPhone 要重新配對才會顯示新名稱 |
| 配對新手機 | Pair a new phone | 開始配對，見 [05 配對](05-pairing.md)。已停止接收時不能按 |
| 已配對的手機 | Paired phones | 列出已配對的手機。選一支手機，再按「刪除」，就解除這支手機的配對。沒有任何手機時顯示「尚未配對任何手機」。最多可以配對 8 支 |
| 允許觸控板控制 | Allow trackpad control | 勾選時，iPhone 可以控制游標，見 [07 觸控板](07-trackpad.md) |
| 非 ASCII 文字改用貼上 | Paste non-ASCII text | 預設勾選。見本章第六節 |
| 開機自動啟動 | Start at sign-in | 勾選時，登入桌面後自動執行接收端 |
| 重新授權 | Authorize again | 重新要求「遠端桌面」的授權 |
| 藍牙控制器 | Bluetooth adapter | 電腦有一張以上的藍牙卡時才會出現。選另一張卡，接收端會重新啟動並改用它 |
| 匯出診斷資料 | Export diagnostics | 產生診斷用的 zip 檔並開啟所在資料夾，內容見 [接收端排錯](../troubleshooting-receiver.md) |
| 結束 | Quit | 結束接收端，iPhone 就無法連到這台電腦 |

接收端有訊息要你處理時，會用下列其中一種方式顯示。「提示文字」是游標停在系統匣圖示上時出現的文字；「視窗」是跳出的對話框，按「確定」關閉。

| 訊息 | 顯示方式 | 處理 |
|---|---|---|
| 這支手機需要重新配對 | 提示文字 | 在手機與電腦兩邊重新配對 |
| 請更新 iPhone App | 提示文字 | 把 iPhone App 更新到同一版 |
| 配對失敗，請再試一次 | 視窗 | 重新按「配對新手機」 |
| 已配對 8 支手機，請先刪除一支 | 視窗 | 到「已配對的手機」刪除不用的手機 |
| 無法儲存配對資料 | 視窗 | 重新配對；仍失敗就匯出診斷資料 |
| 藍牙未開啟，無法掃描 | 提示文字 | 開啟電腦的藍牙 |
| 讀不到已配對手機的金鑰，鑰匙圈可能還沒解鎖 | 提示文字 | 解鎖 GNOME 鑰匙圈，接收端稍後會再讀一次 |
| 設定檔無法讀取，也無法備份；這次的設定不會儲存，原檔保持不動 | 視窗 | 匯出診斷資料，見 [接收端排錯](../troubleshooting-receiver.md) |

## 四、開機自動啟動與從舊的手動安裝升級

在系統匣選單勾選「開機自動啟動」，接收端會在 `~/.config/autostart/remote-keyboard.desktop` 寫入自動啟動項目，指向 `/usr/bin/rk-receiver`。

以前把接收端手動複製到 `~/.local/bin` 的人，升級時：

1. 結束執行中的接收端。
2. 刪除 `~/.local/bin/rk-receiver` 與 `~/.local/bin/rk-diag`，避免終端機執行到舊的那一份。
3. 安裝 `.deb`，從應用程式選單啟動「Remote Keyboard」。

接收端啟動時，如果自動啟動已經開啟，而項目指向的不是自己，會把項目改寫成 `/usr/bin/rk-receiver`，所以不必重新勾選。

## 五、升級與解除安裝

| 情況 | 做法 |
|---|---|
| 升級 | 對新的 `.deb` 再執行一次 `sudo apt install ./檔名.deb`。設定與配對都保留 |
| 從 v0.1 升級 | 這個版本的通訊協定是 v4，與 v0.1 不相容。iPhone App 與 Mac Receiver 都要更新，所有電腦都要重新配對 |
| 解除安裝 | `sudo apt remove remote-keyboard` |

設定檔在 `~/.config/remote-keyboard/config.json`，log 在 `~/.local/state/remote-keyboard/logs/`。解除安裝不會刪除這兩個位置。要完全清除，自行刪除。

## 六、使用時要知道的事

| 項目 | 說明 |
|---|---|
| 沒有焦點安全閘 | Linux 接收端不判斷目前的欄位是什麼。文字會送到目前最前面的視窗，包括密碼欄。要打字前，先確認游標在你要輸入的欄位，不要用這個鍵盤輸入密碼 |
| 非 ASCII 文字用貼上 | 中文、表情符號等非 ASCII 文字，預設經剪貼簿貼上，所以每次輸入都會覆蓋電腦剪貼簿裡原本的內容。取消勾選「非 ASCII 文字改用貼上」就不會動剪貼簿，但接收端只能直接打出 Latin-1 範圍內的字元 |
| 藍牙卡 | 電腦有多張藍牙卡時，在「藍牙控制器」選擇要用哪一張 |
| 連不上時 | iPhone 的 Remote Keyboard 鍵盤要在畫面上，接收端才會連線。先看系統匣的第一行狀態是不是「已停止接收」或「電腦未授權」 |

成功時，iPhone 鍵盤的狀態格顯示這台電腦的名稱與「已連接」。

## 七、選用：縮短連線間隔，讓觸控板更順

Linux 的預設藍牙連線間隔較長，觸控板可能有延遲感。下面兩個指令把指定藍牙卡的連線間隔縮到 7.5 至 15 毫秒。這是選用的，需要 root 權限，接收端不會替你執行，由你自己決定要不要做。

先找出接收端使用的藍牙卡名稱，例如 `hci0`、`hci1`（執行 `ls /sys/class/bluetooth` 可以列出），把下面的 `hciN` 換成它：

```bash
echo 6 | sudo tee /sys/kernel/debug/bluetooth/hciN/conn_min_interval
echo 12 | sudo tee /sys/kernel/debug/bluetooth/hciN/conn_max_interval
```

| 項目 | 說明 |
|---|---|
| 影響範圍 | 只影響指定的那張藍牙卡，不改 `/etc/bluetooth/main.conf`，也不需要重啟 `bluetoothd` |
| 重新開機 | 重新開機後會還原，要再做一次 |
| 數值 | 以 1.25 毫秒為單位，6 與 12 就是 7.5 與 15 毫秒 |

完成之後，接收端已經可以和 iPhone 配對。

下一章：[05 配對](05-pairing.md)
