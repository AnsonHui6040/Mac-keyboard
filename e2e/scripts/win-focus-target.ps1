# Creates (empties) the dedicated test file type-target.txt, opens it in Notepad and brings it to the front.
# Writes only "focus=True" or "focus=False" to -Out: the title of whatever window is in front is never recorded.
# focus=True needs the foreground window title to be exactly "type-target.txt - <Notepad|notepad in zh-TW>" (optional leading *).
# With -KeepContent the file is not emptied and no Notepad is started: an already open matching window is brought to the front
# and checked; when there is none, focus=False is written.
# The window is raised by attaching this thread's input to the foreground window's thread (no key or mouse events are sent), so the foreground lock does not refuse it.
# ASCII only on purpose; the zh-TW app name is built from code points.
param([string]$File = "$env:USERPROFILE\rk-build\e2e\type-target.txt", [string]$Out = "$env:USERPROFILE\rk-build\e2e\focus.txt", [switch]$KeepContent)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ([System.IO.Path]::GetFileName($File).ToLowerInvariant() -ne 'type-target.txt') {
    Write-Output 'refused: -File must be named type-target.txt (the script empties it)'
    exit 2
}
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class FG { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId(); }
"@
$zhApp = ([string][char]0x8A18) + ([string][char]0x4E8B) + ([string][char]0x672C)
$titleRx = '^\*?type-target\.txt - (' + [regex]::Escape($zhApp) + '|Notepad)$'
function Raise-Window([IntPtr]$h) {
    $pid0 = [uint32]0
    $fgThread = [FG]::GetWindowThreadProcessId([FG]::GetForegroundWindow(), [ref]$pid0)
    $cur = [FG]::GetCurrentThreadId()
    $attached = $false
    try {
        if ($fgThread -ne 0 -and $fgThread -ne $cur) { $attached = [FG]::AttachThreadInput($fgThread, $cur, $true) }
        [void][FG]::ShowWindow($h, 9)
        [void][FG]::BringWindowToTop($h)
        [void][FG]::SetForegroundWindow($h)
    } finally {
        if ($attached) { [void][FG]::AttachThreadInput($fgThread, $cur, $false) }
    }
}
function Foreground-Title { $sb = New-Object System.Text.StringBuilder 256; [void][FG]::GetWindowText([FG]::GetForegroundWindow(), $sb, 256); return $sb.ToString() }

$ok = $false
$tries = 40
if ($KeepContent) { $tries = 8 } else {
    [System.IO.File]::WriteAllText($File, "", $utf8)
    Start-Process notepad.exe -ArgumentList ('"' + $File + '"')
}
for ($i = 0; $i -lt $tries -and -not $ok; $i++) {
    Start-Sleep -Milliseconds 250
    $p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match $titleRx } | Select-Object -First 1
    if ($p) { Raise-Window $p.MainWindowHandle }
    if ((Foreground-Title) -match $titleRx) { $ok = $true }
}
[System.IO.File]::WriteAllText($Out, ("focus=" + $ok + "`n"), $utf8)
