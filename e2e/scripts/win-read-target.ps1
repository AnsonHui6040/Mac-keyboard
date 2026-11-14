# Reads the text of the dedicated test file (type-target.txt) from Notepad and writes it to -Out.
# It refuses (writes a line starting with "refused", exit 2) unless ALL of these hold:
#   - -Name is exactly type-target.txt
#   - exactly one Notepad window has the exact title "type-target.txt - <Notepad|notepad in zh-TW>" (optionally with a leading *)
#   - that window's selected tab is named type-target.txt
#   - the title and the selected tab are still the same after the text was read
# ASCII only on purpose (Windows PowerShell 5.1 misreads other encodings): the zh-TW app name is built from code points.
param([string]$Name = "type-target.txt", [string]$Out = "$env:USERPROFILE\rk-build\e2e\np.txt")
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Refuse([string]$why) { [System.IO.File]::WriteAllText($Out, "refused: $why`n", $utf8); exit 2 }
if ($Name -ne 'type-target.txt') { Refuse 'only type-target.txt can be read' }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ae = [System.Windows.Automation.AutomationElement]
$zhApp = ([string][char]0x8A18) + ([string][char]0x4E8B) + ([string][char]0x672C)
$titleRx = '^\*?type-target\.txt - (' + [regex]::Escape($zhApp) + '|Notepad)$'

function Find-Target {
    $cond = New-Object System.Windows.Automation.PropertyCondition($ae::ClassNameProperty, 'Notepad')
    $hits = @()
    foreach ($c in $ae::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        if ($c.Current.Name -match $titleRx) { $hits += $c }
    }
    return ,$hits
}

function Selected-Tab-Ok($w) {
    $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
    foreach ($t in $tabs) {
        $sel = $null
        if ($t.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel) -and $sel.Current.IsSelected) {
            return ($t.Current.Name -match '^\*?type-target\.txt')
        }
    }
    return $false
}

$hits = Find-Target
if ($hits.Count -ne 1) { Refuse ("expected exactly one matching Notepad window, found " + $hits.Count) }
$w = $hits[0]
$title = $w.Current.Name
if (-not (Selected-Tab-Ok $w)) { Refuse 'the selected tab is not type-target.txt' }

$doc = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)))
if (-not $doc) { Refuse 'no document control' }
$text = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)

$again = Find-Target
if ($again.Count -ne 1 -or $again[0].Current.Name -ne $title -or -not (Selected-Tab-Ok $again[0])) { Refuse 'the window or tab changed while reading' }
[System.IO.File]::WriteAllText($Out, $text, $utf8)
