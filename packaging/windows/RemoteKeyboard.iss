; Remote Keyboard receiver installer (Inno Setup 6, needs ISPP for #define).
; Build: iscc /DAppVersion=<version> RemoteKeyboard.iss   (packaging/windows/build-installer.ps1 does this)
; ChineseTraditional.isl is the unofficial translation shipped with Inno Setup, copied unmodified from
; https://raw.githubusercontent.com/jrsoftware/issrc/is-6_7_3/Files/Languages/Unofficial/ChineseTraditional.isl
; (tag is-6_7_3, commit 4adf37ed7f3fd2bd11c6836ba056e3de170fbabf).

#ifndef AppVersion
  #define AppVersion "0.2.0-alpha.1"
#endif
#define AppExe "rk-receiver.exe"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define RunValue "RemoteKeyboard"

[Setup]
AppId={{1485469A-3CB5-4B8D-BD88-D06D95B213F3}
AppName=Remote Keyboard
AppVersion={#AppVersion}
AppPublisher=Remote Keyboard
DefaultDirName={localappdata}\Programs\RemoteKeyboard
DefaultGroupName=Remote Keyboard
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=Local\RemoteKeyboardReceiver
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\..\receiver\rk-receiver\assets\connected.ico
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\..\dist
OutputBaseFilename=RemoteKeyboard-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zhtw"; MessagesFile: "ChineseTraditional.isl"

[CustomMessages]
en.AutoStart=Start when I sign in
zhtw.AutoStart=開機時自動啟動

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"

[Files]
Source: "..\..\receiver\target\release\rk-receiver.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\receiver\target\release\rk-diag.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Remote Keyboard"; Filename: "{app}\{#AppExe}"

[Registry]
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\{#AppExe}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Remote Keyboard}"; Flags: nowait postinstall skipifsilent

; Settings, keys and pairing live in %APPDATA%\RemoteKeyboard and %LOCALAPPDATA%\RemoteKeyboard\logs.
; No [UninstallDelete] entry touches them, so a reinstall does not need to pair again.

[Code]
// The Run value can exist without the autostart task: the program writes it itself when the user turns
// "start when I sign in" on in the tray menu, and an earlier install may have created it. The [Registry]
// uninsdeletevalue flag only covers a value this install created, so remove it on every uninstall.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, '{#RunKey}', '{#RunValue}');
end;
