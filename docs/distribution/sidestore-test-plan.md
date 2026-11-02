# SideStore 分發測試計劃

狀態定義：PASS 已實際驗證成功；FAIL 已執行但未通過；BLOCKED 缺少裝置、權限或環境；NOT TESTED 尚未執行。

IPA 結構檢查通過，不代表 SideStore 實機安裝通過。

## 版本

| 欄位 | 內容 |
|---|---|
| 版本 | |
| IPA SHA-256 | |
| iPhone 機型與 iOS | |
| SideStore 版本 | |
| 測試日期 | |

## 測試項目

| 編號 | 項目 | 通過條件 | 狀態 | 證據 |
|---|---|---|---|---|
| T1 | IPA Build 成功 | `scripts/build-sidestore-ipa.sh` exit 0 | NOT TESTED | |
| T2 | IPA 結構驗證成功 | `validation-report.md` 沒有 FAIL | NOT TESTED | |
| T3 | SideStore 能識別 IPA | 匯入時顯示正確名稱與版本，沒有 (1007) | NOT TESTED | |
| T4 | 用自己的免費帳號簽署安裝 | 選保留全部後安裝完成，My Apps 顯示 7 天 | NOT TESTED | |
| T5 | App 實機啟動 | 開啟不閃退，主畫面正常 | NOT TESTED | |
| T6 | 主要功能 | 配對成功；遠端打字到 Mac；手寫模型下載後可辨識 | NOT TESTED | |
| T7 | 不連接開發者電腦 | 拔掉 USB、離開開發者電腦後 T5、T6 仍正常 | NOT TESTED | |
| T8 | 手動 Refresh | 天數更新，App 仍可開啟 | NOT TESTED | |
| T9 | 安裝新版 IPA | 不刪舊版，版本更新且可正常使用 | NOT TESTED | |
| T10 | 更新後資料仍在 | 配對不必重做，鍵盤設定與手寫模型保留 | NOT TESTED | |
| T11 | 權限與 Entitlements | 見下方 | NOT TESTED | |
| T12 | 無原始碼與已知敏感憑證 | `validation-report.md` 第 10 項 PASS | NOT TESTED | |

T1、T2、T12 可自動完成。T3 至 T11 需要實機和 SideStore。

## T11 細項：App Group 與 Keychain

這是本 App 在 SideStore 上最大的風險，要逐項確認：

| 項目 | 通過條件 | 狀態 |
|---|---|---|
| 鍵盤 Extension 保留 | 「新增鍵盤」看得到 Remote Keyboard | NOT TESTED |
| Keychain 共用 | App 配對成功，鍵盤連線時可讀到配對金鑰 | NOT TESTED |
| App Group 設定共用 | App 改按鍵音量，鍵盤重開後跟著改變 | NOT TESTED |
| App Group 檔案共用 | App 下載手寫模型，鍵盤手寫可辨識 | NOT TESTED |
| 藍牙 | App 與鍵盤都能連上 Mac | NOT TESTED |
| Refresh 後仍有效 | T8 之後重做上面四項 | NOT TESTED |

## 7 天有效期

不需要等滿 7 天才算完成本計劃。先驗證手動 Refresh（T8），完整有效期另外記錄：

| 項目 | 狀態 |
|---|---|
| 背景自動續簽 | NOT TESTED |
| 滿 7 天後的實際行為 | NOT TESTED |
