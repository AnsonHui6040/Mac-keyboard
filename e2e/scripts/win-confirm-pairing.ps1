<#
Waits for the Remote Keyboard receiver's pairing question (a MessageBox, title "Remote Keyboard", with a 6-digit code),
writes the digits to -ResultPath and answers it. Say what to expect, explicitly:
  -ExpectSas <6 digits>  presses Yes only when the dialog's code matches, otherwise No (anything but exactly 6 digits is an error)
  -AnyCode               presses Yes whatever the code is
With neither it stops with an error. It only acts on a message box (class #32770) titled "Remote Keyboard" that has both a
Yes and a No button and holds exactly one standalone 6-digit code (123456 or 123 456), never a longer digit run.
Must run in the interactive desktop session (a scheduled task with /IT), not over plain OpenSSH.
Exit codes: 0 answered Yes, 3 answered No (code mismatch), 2 no dialog within the timeout, 1 error (also: bad arguments).
#>
param(
    [int]$TimeoutSeconds = 120,
    [string]$ResultPath = (Join-Path $env:TEMP 'rk-pair-result.txt'),
    [string]$ExpectSas = '',
    [switch]$AnyCode
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$yesNames = @([string][char]0x662F, 'Yes')
$noNames = @([string][char]0x5426, 'No')
$codeRx = '(?<!\d)(\d{6}|\d{3} \d{3})(?!\d)'

function Find-Dialog {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Remote Keyboard')),
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')))
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        $texts = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))
        $all = ($texts | ForEach-Object { $_.Current.Name }) -join "`n"
        $codes = @([regex]::Matches($all, $codeRx) | ForEach-Object { $_.Groups[1].Value -replace ' ', '' } | Select-Object -Unique)
        if ($codes.Count -ne 1) { continue }
        if (-not (Find-Button $w '6' $yesNames) -or -not (Find-Button $w '7' $noNames)) { continue }
        return [pscustomobject]@{ Window = $w; Digits = $codes[0] }
    }
    return $null
}

function Find-Button($window, [string]$autoId, [string[]]$names) {
    $buttons = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
    foreach ($b in $buttons) { if ($b.Current.AutomationId -eq $autoId) { return $b } }
    foreach ($b in $buttons) { foreach ($n in $names) { if ($b.Current.Name -like "$n*") { return $b } } }
    return $null
}

if (-not $AnyCode) {
    if ($ExpectSas -notmatch '^(\d{6}|\d{3} \d{3})$') { Write-Output 'RKWIN error: pass -ExpectSas with exactly 6 digits, or -AnyCode'; exit 1 }
    $ExpectSas = $ExpectSas -replace ' ', ''
} elseif ($ExpectSas -ne '') { Write-Output 'RKWIN error: -ExpectSas and -AnyCode together'; exit 1 }

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $found = $null
    while ((Get-Date) -lt $deadline) {
        $found = Find-Dialog
        if ($found) { break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $found) { Write-Output 'RKWIN no-dialog'; exit 2 }

    $yes = $AnyCode -or ($ExpectSas -eq $found.Digits)
    if ($yes) { $button = Find-Button $found.Window '6' $yesNames }
    else { $button = Find-Button $found.Window '7' $noNames }
    if (-not $button) { Write-Output 'RKWIN button-not-found'; exit 1 }

    Set-Content -Path $ResultPath -Value ("sas=" + $found.Digits + "`nanswer=" + $(if ($yes) { 'yes' } else { 'no' })) -Encoding ASCII
    ([System.Windows.Automation.InvokePattern]$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    Write-Output ("RKWIN sas=" + $found.Digits + " answer=" + $(if ($yes) { 'yes' } else { 'no' }))
    if ($yes) { exit 0 } else { exit 3 }
} catch {
    Write-Output ("RKWIN error " + $_.Exception.Message)
    exit 1
}
