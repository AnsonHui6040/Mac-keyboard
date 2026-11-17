# 觸控板手感定案參數表（2026-11-17）

本表把目前這一版觸控板的手感參數定為固定值，基準為 main `fa53762`（D30 Wi-Fi 輔助與三平台實機量測完成後）。

- 表內數值取代 `2026-11-01-trackpad-design.md` §14 的 Provisional 起始值；兩者不同時以本表為準。
- 每個數值都由測試鎖住（見「鎖定測試」）。要改任何一個數值，必須同時改本表、改測試，並附新的實機量測證據。
- 使用者可調的設定（靈敏度、傳輸次數、Wi-Fi 輔助）鎖住的是預設值與範圍，不是使用者自己選的值。
- 實機依據：`e2e/E2E-WIFI-ASSIST.md` A1–A5、`docs/superpowers/verification/evidence/D30-*.txt`。使用者手感 B1–B8 仍為 TBD。

## 1. iPhone 手勢判定

來源：`Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Pointer/TrackpadGesture.swift`

| 參數 | 定案值 | 作用 |
|---|---|---|
| `tapMaxMicros` | 200 ms | 單指在此時間內抬起才算輕點 |
| `travelThreshold` | 8 pt | 超過此距離才開始移動游標或捲動；之前的位移一次補上 |
| `longPressMicros` | 400 ms | 單指不動按住此時間開始拖曳 |
| `doubleTapMaxMicros` | 500 ms | 第二下輕點與第一下抬起的最長間隔 |
| `doubleTapMaxDistance` | 12 pt | 第二下輕點與第一下抬起位置的最大距離 |
| `twoFingerTapMaxMicros` | 300 ms | 雙指輕點（右鍵）從第一指按下到最後一指抬起的上限 |
| `twoFingerTapMaxTravel` | 12 pt | 雙指輕點時每指可移動的上限 |

## 2. iPhone 移動與送出

| 參數 | 定案值 | 範圍 | 來源 |
|---|---|---|---|
| 靈敏度預設 | 1.0 | 0.2–3.0，每格 0.1 | `TrackpadSensitivity.swift` |
| 傳輸次數預設 | 自動（存 0） | 20–120 次／秒，每格 10，最後一格為自動 | `TrackpadSendRate.swift` |
| 固定速率時的 MOVE 間隔 | 16.667 ms（60 次／秒） | — | `PointerSender.moveIntervalMicros` |
| 心跳間隔（按住時） | 100 ms | — | `PointerSender.heartbeatIntervalMicros` |
| 單段位移最多拆成 | 8 個封包 | 超出部分捨棄並標記截斷 | `PointerSender.maxSplit` |
| Wi-Fi 輔助預設 | 開 | 開／關 | `WifiPointerSetting.swift` |
| Wi-Fi 路徑就緒等待 | 0.5 s | — | `iOS/RemoteKeyboardExtension/Trackpad/WifiPointerLink.swift` |

## 3. 加速曲線（接收端，三平台相同）

`g(v) = g0 + (gmax − g0) · v² / (v² + v0²)`，`v = hypot(dx, dy) / dt`（pt/s）。

| 參數 | 定案值 | Swift（Mac） | Rust（Windows、Linux） |
|---|---|---|---|
| g0 | 1.25 | `PointerAcceleration.baseGain` | `BASE_GAIN` |
| gmax | 3.5 | `maxGain` | `MAX_GAIN` |
| v0 | 550 pt/s | `kneeSpeed` | `KNEE_SPEED` |
| dt 下限 | 5 ms | `minDtSeconds` | `MIN_DT_SECONDS` |
| dt 上限 | 150 ms | `maxDtSeconds` | `MAX_DT_SECONDS` |

## 4. 接收端播放緩衝（Playout）

Swift：`PointerPlayout.swift`；Rust：`receiver/rk-core/src/pointer.rs` 的 `PointerPlayout`。

| 參數 | 定案值 | 作用 | 平台 |
|---|---|---|---|
| 最大延遲下限 | 20 ms | 游標落後封包的基本上限 | 三平台 |
| 片段時長下限／上限 | 4／50 ms | 每個 MOVE 攤開播放的時間範圍 | 三平台 |
| 預設片段時長 | 8 ms | 封包沒帶時長時使用 | 三平台 |
| 延遲餘量 | 5 ms | 加在片段時長或到達週期之上 | 三平台 |
| 自適應延遲上限 | 60 ms | 依到達週期放寬延遲的上限 | 三平台 |
| 新一批封包間隔 | 4 ms | 晚於此間隔即視為新一批 | 三平台 |
| 週期計算的最大間隔 | 100 ms | 更長視為停頓，不計入 | 三平台 |
| 忘記歷史的間隔 | 300 ms | 更長時清除週期歷史 | 三平台 |
| 週期歷史筆數 | 8 | 取中位數 | 三平台 |
| 抖動緩衝上限 | 80 ms | 開頭延遲最多加到此值 | 只有 Mac |
| 抖動緩衝半衰期 | 5 s | 連線乾淨時緩衝減半的時間 | 只有 Mac |
| 抖動緩衝下限 | 5 ms | 低於此值歸零 | 只有 Mac |
| 補充放慢倍率 | 1.25 | 緩衝不足時片段放慢以補回 | 只有 Mac |
| 停頓判定 | 比平常週期長 20 ms 且超過兩倍 | 判定為無線電停頓 | 只有 Mac |
| 重新學習前的停頓次數 | 3 | 連續 3 次即視為新的到達週期 | 只有 Mac |
| 同一筆劃間隔 | 100 ms | 間隔內的封包屬同一筆劃 | 只有 Mac |

## 5. 接收端計時與看門狗

| 參數 | 定案值 | 來源 |
|---|---|---|
| 按鍵看門狗 | 350 ms 沒收到封包即放開 | `PointerEngine.buttonWatchdogMicros`、`BUTTON_WATCHDOG_MICROS` |
| 捲動看門狗 | 150 ms 沒收到封包即結束捲動 | `PointerEngine.scrollWatchdogMicros`、`SCROLL_WATCHDOG_MICROS` |
| Windows／Linux 畫面節拍 | 每 8 ms 一格，以絕對時鐘排程（PR #130） | `receiver/rk-receiver/src/app.rs` `FRAME_TICK_MS` |
| Windows／Linux 看門狗節拍 | 25 ms | `app.rs` `WATCHDOG_TICK_MS` |
| Mac 畫面節拍 | 跟螢幕更新（CADisplayLink） | `macOS/MacReceiver/Input/PointerFrameSource.swift` |
| Mac 看門狗節拍 | 50 ms | `PointerReceiver.watchdogInterval` |
| Mac 畫面來源停止後重啟 | 200 ms | `PointerReceiver.frameStallMicros` |
| Wi-Fi 探測間隔 | 每個位址 250 ms | `receiver/rk-receiver/src/wifi.rs` `PROBE_INTERVAL_MS`、Mac `WifiProbeLink.probeInterval` |

## 6. 捲動

| 平台 | 定案值 | 來源 |
|---|---|---|
| Mac | 1 iPhone pt = 1 像素連續捲動，內容跟手指走 | `PointerInjector.swift` |
| Windows | 40 pt = 1 格（120 單位），即每 pt 3 單位 | `receiver/rk-inject/src/win_units.rs` `WHEEL_UNITS_PER_POINT` |
| Linux | 每 pt 1.0 單位；最後一次後 150 ms 結束 | `receiver/rk-inject/src/keysym.rs` `SCROLL_GAIN`、`SCROLL_IDLE` |
| Linux 移動上限 | 每秒最多 120 次 | `keysym.rs` `MOVE_MAX_HZ` |

## 7. 鎖定測試

| 平台 | 測試 |
|---|---|
| Swift Core | `Packages/RemoteKeyboardCore/Tests/RemoteKeyboardCoreTests/TrackpadFeelBaselineTests.swift` |
| Mac Receiver | `macOS/MacReceiverTests/PointerReceiverFeelBaselineTests.swift`、`WifiProbeLinkTests.swift` |
| Rust | `receiver/rk-core/src/pointer.rs`、`receiver/rk-inject/src/keysym.rs`、`receiver/rk-inject/src/win_units.rs`、`receiver/rk-receiver/src/app/tests.rs`、`receiver/rk-receiver/src/wifi.rs` 中名稱含 `feel_baseline` 的測試 |

沒有測試鎖住、只由本表記錄的項目：Wi-Fi 路徑就緒等待 0.5 s（iOS 鍵盤延伸沒有單元測試 target），以及 Mac 捲動「1 pt = 1 像素」（是行為，不是常數）。
