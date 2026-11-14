param([string]$File = "$env:USERPROFILE\rk-build\e2e\type-target.txt", [string]$Out = "$env:USERPROFILE\rk-build\e2e\focus.txt")
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class FG { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@
[System.IO.File]::WriteAllText($File, "")
Start-Process notepad.exe -ArgumentList ('"' + $File + '"')
$name = [System.IO.Path]::GetFileName($File)
$ok = $false
for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
  Start-Sleep -Milliseconds 250
  $p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "$name*" } | Select -First 1
  if ($p) { [void][FG]::ShowWindow($p.MainWindowHandle, 9); [void][FG]::SetForegroundWindow($p.MainWindowHandle) }
  $sb = New-Object System.Text.StringBuilder 256; [void][FG]::GetWindowText([FG]::GetForegroundWindow(), $sb, 256)
  if ($sb.ToString() -like "$name*") { $ok = $true }
}
$sb = New-Object System.Text.StringBuilder 256; [void][FG]::GetWindowText([FG]::GetForegroundWindow(), $sb, 256)
("focus=" + $ok + " title=" + $sb.ToString()) | Out-File $Out -Encoding utf8
