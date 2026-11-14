param([string]$Name = "type-target.txt", [string]$Out = "$env:USERPROFILE\rk-build\e2e\np.txt")
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Notepad')
$w = $null
foreach ($c in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) { if ($c.Current.Name -like "$Name*" -or $c.Current.Name -like "*$Name*") { $w = $c } }
# Only read when the window title (= the selected tab) is the dedicated test file; never read any other document.
if (-not $w -or -not ($w.Current.Name -like "$Name*" -or $w.Current.Name -like "`*$Name*")) { 'refused: test file is not the selected tab' | Out-File $Out -Encoding utf8; exit 2 }
$doc = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)))
$t = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
[System.IO.File]::WriteAllText($Out, $t, (New-Object System.Text.UTF8Encoding($false)))
