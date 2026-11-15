# Builds the release binaries and the Inno Setup installer: dist\RemoteKeyboard-Setup-<version>.exe
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$receiver = Join-Path $repo 'receiver'

Push-Location $receiver
try {
    cargo build --release -p rk-receiver --bins
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

    $meta = cargo metadata --no-deps --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed with exit code $LASTEXITCODE" }
    $version = ($meta.packages | Where-Object { $_.name -eq 'rk-receiver' }).version
    if (-not $version) { throw 'could not read the rk-receiver version' }
} finally {
    Pop-Location
}

$iscc = $null
$onPath = Get-Command iscc -ErrorAction SilentlyContinue
if ($onPath) { $iscc = $onPath.Source }
if (-not $iscc) {
    $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (Test-Path $candidate) { $iscc = $candidate }
}
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found. Install it, for example: choco install innosetup -y' }

& $iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'RemoteKeyboard.iss')
if ($LASTEXITCODE -ne 0) { throw "iscc failed with exit code $LASTEXITCODE" }

$installer = Join-Path $repo "dist\RemoteKeyboard-Setup-$version.exe"
if (-not (Test-Path $installer)) { throw "expected installer not found: $installer" }
Write-Host "Built $installer"
