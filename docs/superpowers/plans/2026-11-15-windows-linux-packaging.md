# Windows／Linux 落地（WL12 打包與文件）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 11 用 Inno Setup 安裝程式、Ubuntu 26.04 用 `.deb`，由 CI 在打 tag 時產生，放進 GitHub Release 草稿；同時補齊三平台的安裝文件。發佈本身等使用者說「發佈」。

**Architecture:** 打包定義放在 `packaging/windows/`（`.iss`）與 `receiver/rk-receiver/Cargo.toml` 的 `[package.metadata.deb]`（cargo-deb）。`.github/workflows/release-receiver.yml` 在 `v*` tag 上建置兩個安裝檔並建立 draft release；Mac App 與 iPhone IPA 仍由本機腳本在發佈時上傳。

**執行順序：** PK1 → PK2 → PK3 依序（共用 `package-receiver.yml` 與 `Cargo.toml`，一次一個寫入者）；PK4 只改文件，與 PK1 並行。

**Tech Stack:** Rust（既有 `rk-receiver`、`rk-diag`）、Inno Setup 6（GitHub `windows-latest` 已內建 `iscc`）、cargo-deb、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-11-10-windows-linux-receiver-design.md`（§2 目標 4、§10、§14）；原計畫 `docs/superpowers/plans/2026-11-10-windows-linux-receiver-implementation.md` Task WL12。

**使用者決定（2026-11-15）：** Windows 用 Inno Setup 安裝程式；Linux 用 `.deb`；版本號 `v0.2.0-alpha.1`。

## Global Constraints

- 支援範圍：Windows 11 x64、Ubuntu 26.04 x86_64（GNOME Wayland）。Windows 10、KDE、X11、ARM 不寫進手冊。
- 不簽章（spec §2 非目標）；文件要說明 SmartScreen 警告。
- Windows 安裝位置 `{localappdata}\Programs\RemoteKeyboard`，`PrivilegesRequired=lowest`（不需要管理員），與目前測試機的手動安裝相同，可直接覆蓋升級。
- Windows 自動啟動沿用程式自己的登錄值：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名稱 `RemoteKeyboard`，內容為帶引號的 exe 路徑。
- Windows 單一執行個體 mutex：`Local\RemoteKeyboardReceiver`（安裝程式的 `AppMutex` 用同一個名字）。
- Linux 安裝 `/usr/bin/rk-receiver`、`/usr/bin/rk-diag`；自動啟動檔仍是 `~/.config/autostart/remote-keyboard.desktop`（程式自己寫）。
- 版本號：`Cargo.toml` `0.2.0-alpha.1`；`.deb` 版本 `0.2.0~alpha.1`；Windows `AppVersion` `0.2.0-alpha.1`。
- log 不得含文字內容；安裝檔與文件不得含個人路徑或主機名稱。
- 成品文件用台灣繁體中文，另有英文版；不得出現 AI 推理或備註。
- 發佈（把 draft 改成正式 release、上傳 Mac／iPhone 檔）等使用者說「發佈」。

## Review Focus

1. **覆蓋舊的手動安裝**：rk-win 已有 `%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-receiver.exe` 在執行。安裝程式要先關掉它（`AppMutex` + `CloseApplications`），覆蓋後設定、金鑰、配對都保留。→ PK1 實機驗證項。
2. **Linux 從 `~/.local/bin` 換到 `.deb`**：舊的 autostart 檔指向 `~/.local/bin/rk-receiver`。程式啟動時若自動啟動已開而檔案指向的 exe 不是自己，要改寫成自己的路徑。→ PK2 測試 `autostart_file_is_rewritten_when_it_points_to_another_exe`。
3. **解除安裝後的殘留**：Windows 解除安裝要刪掉 `Run` 值，否則登入時會找不到 exe；設定與金鑰保留（重裝不必重配）。→ PK1 `.iss` `[UninstallRegistry]`／`[Registry] Flags: uninsdeletevalue` 與實機驗證。
4. **非管理員帳號**：Windows 安裝不能要求 UAC。→ `PrivilegesRequired=lowest`，CI 以 `/VERYSILENT /CURRENTUSER` 安裝驗證。
5. **Linux 缺少執行期依賴**：沒有 zenity、portal 或 keyring 會在配對或注入時才失敗。→ `.deb` `depends` 列出，CI 以 `apt-get install ./x.deb` 驗證依賴可解。

---

### Task PK1: Windows 安裝程式

**Files:**
- Create: `packaging/windows/RemoteKeyboard.iss`
- Create: `packaging/windows/build-installer.ps1`（cargo build --release 兩個 bin，再 `iscc`，輸出 `dist/RemoteKeyboard-Setup-<version>.exe`）
- Modify: `receiver/rk-receiver/Cargo.toml`（version `0.2.0-alpha.1`）
- Modify: `receiver/rk-receiver/src/bin/rk-diag.rs`：加 `--version`，印出 `rk-diag 0.2.0-alpha.1`（`rk-receiver --version` 已存在）
- Test: `version_flag_prints_the_package_version`（兩個 bin 都要涵蓋）
- Create: `.github/workflows/package-receiver.yml`（PR 觸發，`paths` 含 `receiver/**`、`packaging/**`；本 Task 只放 `windows-installer` job）

**`.iss` 要點：** `AppId` 固定 GUID；`DefaultDirName={localappdata}\Programs\RemoteKeyboard`；`PrivilegesRequired=lowest`；`AppMutex=Local\RemoteKeyboardReceiver`；`CloseApplications=yes`；開始功能表捷徑「Remote Keyboard」；Task「開機時自動啟動」（預設勾選）寫 `HKCU\...\Run` 值 `RemoteKeyboard`=`"{app}\rk-receiver.exe"`，`Flags: uninsdeletevalue`；安裝完成頁「立即啟動」；語言繁體中文與英文（Inno 的 ChineseTraditional 非官方翻譯檔放在 `packaging/windows/`）；圖示用 `receiver/rk-receiver/assets/connected.ico`。

- [ ] Step 1：`--version` 測試（RED）→ 實作 → GREEN。
- [ ] Step 2：寫 `.iss` 與 `build-installer.ps1`。
- [ ] Step 3：CI（`package-receiver.yml` 的 `windows-installer` job）上 `iscc` 成功；同一 job 以 `/VERYSILENT /CURRENTUSER /SUPPRESSMSGBOXES /NORESTART` 安裝，檢查 exe 存在、`Run` 值存在、`rk-receiver.exe --version` 輸出正確；再以 `unins000.exe /VERYSILENT` 解除安裝，檢查 exe 與 `Run` 值都消失。
- [ ] Step 4：實機（rk-win，可連線時）：在舊版執行中直接安裝 → 舊程式被關、新版啟動、配對仍在、iPhone 可打字。標 TBD 直到做完。

### Task PK2: Linux `.deb`

**Files:**
- Modify: `receiver/rk-receiver/Cargo.toml`：`[package.metadata.deb]`（name `remote-keyboard`、maintainer、depends、assets）
- Create: `packaging/linux/remote-keyboard.desktop`（選單項目，`Exec=/usr/bin/rk-receiver`）
- Create: `packaging/linux/remote-keyboard.png`（256×256，由現有 App 圖示轉出）
- Modify: `receiver/rk-receiver/src/platform/linux_logic.rs`（自動啟動檔指向別的 exe 時改寫）
- Test: `linux_logic` 測試 `autostart_file_is_rewritten_when_it_points_to_another_exe`、`autostart_file_is_left_alone_when_disabled_or_already_ours`

**depends：** `zenity, xdg-desktop-portal, xdg-desktop-portal-gnome, gnome-keyring, libdbus-1-3, bluez`（實作者以 `ldd`／`dpkg-shlibdeps` 核對，`$auto` 可用）。

- [ ] Step 1：autostart 改寫測試（RED）→ 實作 `fn ensure_autostart_points_to(file: &Path, exe: &Path) -> bool`（只在檔案存在且 `Exec=` 不是 `exe` 時改寫；回傳是否改寫）→ 在 Linux 外殼啟動時呼叫 → GREEN。
- [ ] Step 2：`cargo deb -p rk-receiver` 產生 `remote-keyboard_0.2.0~alpha.1_amd64.deb`；`lintian` 無 error。
- [ ] Step 3：CI（在 `package-receiver.yml` 加 `linux-deb` job，ubuntu-latest）：`sudo apt-get install -y ./dist/*.deb` 成功、`dpkg -L remote-keyboard` 含兩個 bin、desktop 檔、圖示；`rk-receiver --version` 正確；`apt-get remove` 乾淨。
- [ ] Step 4：實機（rk-linux）：移除 `~/.local/bin` 版、安裝 `.deb`、重新登入，自動啟動用 `/usr/bin` 版、配對仍在、可打字。標 TBD。

### Task PK3: Release workflow

**Files:**
- Modify: `.github/workflows/package-receiver.yml`：加 `push: tags: ['v*']`、`workflow_dispatch` 與 `draft-release` job（只在 tag 時跑）
- Modify: `.github/workflows/receiver.yml`（`paths` 加 `packaging/**`）

**行為：** PK1、PK2 已建好的 `windows-installer`、`linux-deb` job 各上傳 artifact；job `draft-release` 下載兩者，`gh release create "$TAG" --draft --prerelease --title "Remote Keyboard $TAG" --notes-file release-notes/$TAG.md`，附上兩個安裝檔與 `SHA256SUMS.txt`。`permissions: contents: write` 只給 `draft-release`。

- [ ] Step 1：寫 workflow；`actionlint`（若有）無錯。
- [ ] Step 2：在 PR 上 `workflow_dispatch` 跑一次（不建 release，`draft-release` 只在 tag 時跑），兩個 artifact 都產生。
- [ ] Step 3：tag 與 draft 留待使用者說「發佈」。

### Task PK4: 文件

**Files:**
- Modify: `README.md`、`README.en.md`（需求、如何取得：三平台）
- Create: `docs/manual/04b-install-windows-receiver.md`、`docs/manual/04c-install-linux-receiver.md` 與 `docs/manual/en/` 對應英文版
- Modify: `docs/manual/README.md`、`docs/manual/en/README.md`（目錄）、`docs/manual/05-pairing.md`（Windows／Linux 配對對話框）、`docs/manual/10-troubleshooting.md`（連到 `docs/troubleshooting-receiver.md`）
- Create: `release-notes/v0.2.0-alpha.1.md`
- Modify: 主 App 教學頁文字（實作者以 `grep -rn "Mac Receiver" iOS/` 找出提到只有 Mac 的教學字串）

**必須涵蓋：** 三平台安裝步驟；從 v0.1 升級要重新配對（協定 v4）；SmartScreen「其他資訊 → 仍要執行」；Windows／Linux 沒有焦點安全閘（打字會送到目前前景視窗，包括密碼欄）；Windows 管理員權限的視窗收不到輸入；Linux 第一次要授權「遠端桌面」、非 ASCII 用貼上模式的代價（會覆蓋剪貼簿）；Linux 短連線間隔需要 root 的選用指令（列出，不代執行）；支援範圍。

- [ ] Step 1：寫文件。
- [ ] Step 2：`grep -rn` 檢查禁用字（`n=`、個人路徑、主機名稱、AI 備註）為 0；中英版章節對應。

---

完成 PK1–PK4 後做原計畫 Task WL11（三主機整合驗收），在安裝檔裝好的版本上跑。
