<#
Waits for the Remote Keyboard receiver's pairing question (a MessageBox, title "Remote Keyboard", with a 6-digit code),
writes the digits to -ResultPath and presses Yes. With -ExpectSas it presses Yes only when the digits match, otherwise No.
Must run in the interactive desktop session (a scheduled task with /IT), not over plain OpenSSH.
Exit codes: 0 answered Yes, 3 answered No (code mismatch), 2 no dialog within the timeout, 1 error.
#>
param(
    [int]$TimeoutSeconds = 120,
    [string]$ResultPath = (Join-Path $env:TEMP 'rk-pair-result.txt'),
    [string]$ExpectSas = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Find-Dialog {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Remote Keyboard')
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        $texts = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))
        $all = ($texts | ForEach-Object { $_.Current.Name }) -join "`n"
        if ($all -match '(\d{3})\s?(\d{3})') {
            return [pscustomobject]@{ Window = $w; Digits = $Matches[1] + $Matches[2] }
        }
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

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $found = $null
    while ((Get-Date) -lt $deadline) {
        $found = Find-Dialog
        if ($found) { break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $found) { Write-Output 'RKWIN no-dialog'; exit 2 }

    $yes = ($ExpectSas -eq '') -or ($ExpectSas -replace '\D', '') -eq $found.Digits
    if ($yes) { $button = Find-Button $found.Window '6' @([string][char]0x662F, 'Yes') }
    else { $button = Find-Button $found.Window '7' @([string][char]0x5426, 'No') }
    if (-not $button) { Write-Output 'RKWIN button-not-found'; exit 1 }

    Set-Content -Path $ResultPath -Value ("sas=" + $found.Digits + "`nanswer=" + $(if ($yes) { 'yes' } else { 'no' })) -Encoding ASCII
    ([System.Windows.Automation.InvokePattern]$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    Write-Output ("RKWIN sas=" + $found.Digits + " answer=" + $(if ($yes) { 'yes' } else { 'no' }))
    if ($yes) { exit 0 } else { exit 3 }
} catch {
    Write-Output ("RKWIN error " + $_.Exception.Message)
    exit 1
}
