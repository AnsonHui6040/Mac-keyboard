# 第三方上架平台評估

調查日期：2026-11-02。前提：沒有付費 Apple Developer 帳號、不公開原始碼、測試者是一般使用者、App 含鍵盤 Extension。

## 推薦

| 平台 | 上架方式 |
|---|---|
| iPhone | **SideStore，並自建 Source**（AltStore Source 格式的 JSON） |
| Mac | **GitHub Releases**（只放成品的公開 repo） |
| 下載位置 | 同一個成品 repo，原始碼 repo 維持私有 |

SideStore 沒有審核，也沒有中央商店：你託管一份 JSON，測試者加入網址，就能在 SideStore 內看到 App 並收到更新。

## iPhone 平台比較

GitHub 數字查於調查當日，只反映熱度，不等於實際使用人數。下載數只計最新版本的附件。

| 平台 | GitHub 星數 | 最新版下載數 | 免費帳號可上架 | 支援鍵盤 Extension | 判斷 |
|---|---|---|---|---|---|
| SideStore | 7,188 | 456,926 | 可以 | 有處理 Extension 的流程，實機待測 | 推薦 |
| AltStore Classic | 14,820 | 8,032（主要不經 GitHub 派發） | 可以 | 同源程式，實機待測 | 備案：續簽要電腦上的 AltServer |
| Feather | 4,976 | 105,489 | 測試者要自備憑證 | 未驗證 | 進階使用者備案 |
| Sideloadly | 非開源 | 無資料 | 可以 | 未驗證 | 備案：續簽要電腦 |
| LiveContainer | 13,673 | 678,326 | 可以 | **不支援** | 不適用：官方寫明不支援 App Extension |
| AltStore PAL | 同 AltStore | 同上 | **不可以** | 不適用 | 不適用：要付費帳號與公證，只限歐盟、日本、巴西 |

`iloader`（4,452 星，最新版下載 148,300）是安裝 SideStore 的電腦工具，不是上架平台。

## 不建議

| 類型 | 原因 |
|---|---|
| 企業憑證簽署服務 | 憑證常被 Apple 撤銷。鍵盤要開完整取用，交給第三方重新簽署，等於要測試者信任多一方 |
| 公開 IPA 下載站 | 來源難以查證，常與破解 App 放在一起，會損害可信度 |
| Homebrew Cask（Mac） | 政策不接受無法通過 Gatekeeper 的 App；已有 cask 因此被標記棄用 |

## 上架限制

- 測試者門檻高：首次要電腦、Wi-Fi、LocalDevVPN，而且每 7 天續簽。
- 新手很可能在 SideStore 安裝階段放棄，不一定是本 App 的問題。
- 免費帳號 App 名額很緊：SideStore 加本 App 已接近上限。
- Source 的 `appPermissions` 要列出 App 與 Extension 的全部 entitlements 和隱私權限，與 IPA 不符時 AltStore 會拒絕安裝。SideStore 是否同樣嚴格，要實測。
- SideStore 官方對 Source 的文件有限，格式相容性以實測為準。

## 資料來源

- [SideStore 官方網站](https://sidestore.io/)、[SideStore FAQ](https://docs.sidestore.io/docs/faq)
- [AltStore：Make a Source](https://faq.altstore.io/developers/make-a-source)
- [AltStore PAL 上架要求](https://faq.altstore.io/developers/distribute-with-altstore-pal)
- [LiveContainer](https://github.com/LiveContainer/LiveContainer)
- [Homebrew 討論：未通過 Gatekeeper 的 cask](https://github.com/orgs/Homebrew/discussions/7050)、[Homebrew issue #20755](https://github.com/Homebrew/brew/issues/20755)
- [側載工具比較（第三方部落格，僅作參考）](https://lemoncert.com/guides/best-ios-sideloading-apps)
