# build-installer.ps1 - turn the staged portable folder into installers.
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
#   powershell -ExecutionPolicy Bypass -File tools\build-installer.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build-installer.ps1 -Version 0.2.10
#
# WiX 4 is installed as a dotnet tool inside tools/wix (no C: writes).
# Inno Setup is optional: pass -Inno <path-to-ISCC.exe> to also emit a
# setup.exe. Every path is derived from this script's location.
param(
    [string]$Version = "",
    [string]$Stage = "",
    [string]$Out = "",
    [string]$Inno = ""
)

$ErrorActionPreference = "Stop"
$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $Stage) { $Stage = Join-Path $ProjectDir "dist\LongCut-win64-gnu" }
if (-not $Out)   { $Out   = Join-Path $ProjectDir "dist" }
$Stage = (Resolve-Path $Stage).Path
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
$Out = (Resolve-Path $Out).Path

if (-not $Version) {
    $toml = [IO.File]::ReadAllText((Join-Path $ProjectDir "src\Cargo.toml"))
    $m = [regex]::Match($toml, '(?m)^version = "([^"]+)"')
    if (-not $m.Success) { throw "cannot read workspace version from src/Cargo.toml" }
    $Version = $m.Groups[1].Value
}
if (-not (Test-Path (Join-Path $Stage "longcut.exe"))) {
    throw "stage has no longcut.exe: $Stage (run tools/stage-portable.sh first)"
}

# The .wxs lists the staged files explicitly (WiX 4.0.5 has no <Files>
# harvest). Fail early, with a useful message, when stage-portable.sh gains
# a runtime DLL but the installer source was not updated to match.
$wxs = Join-Path $ProjectDir "assets\windows\concat.wxs"
$wxsText = [IO.File]::ReadAllText($wxs)
$declared = @()
foreach ($m in [regex]::Matches($wxsText, 'Source="\$\(var\.Stage\)\\([^"]+)"')) {
    $declared += $m.Groups[1].Value
}
if ($declared.Count -lt 10) { throw "no staged file list parsed from concat.wxs" }
foreach ($name in $declared) {
    if (-not (Test-Path (Join-Path $Stage $name))) {
        throw "concat.wxs lists $name but the stage is missing it (sync tools/stage-portable.sh)"
    }
}
$extra = @(Get-ChildItem $Stage -File | Where-Object { $declared -notcontains $_.Name })
if ($extra.Count -gt 0) {
    Write-Host "  note: stage has $($extra.Count) file(s) not in the .msi: $($extra.Name -join ', ')" -ForegroundColor DarkYellow
}

$results = @()

# ---- WiX .msi -----------------------------------------------------------
$wix = Join-Path $ProjectDir "tools\wix\wix.exe"
if (-not (Test-Path $wix)) {
    throw "WiX tool missing: $wix (install with: dotnet tool install --tool-path tools/wix --version 4.0.5 wix)"
}
$msi = Join-Path $Out "LongCut-$Version-win64-gnu.msi"
Write-Host "== WiX: $msi ==" -ForegroundColor Cyan
& $wix build -arch x64 `
    -d "Version=$Version" -d "Root=$ProjectDir" -d "Stage=$Stage" `
    -o $msi $wxs
if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE)" }
if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 10000) { throw "msi missing or too small: $msi" }
$results += "MSI  $msi  $([math]::Round((Get-Item $msi).Length / 1MB, 2)) MB"

# ---- Inno Setup .exe (optional) -----------------------------------------
$iscc = $Inno
if (-not $iscc) {
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
    $local = Join-Path $ProjectDir "tools\innosetup\ISCC.exe"
    if (Test-Path $local) { $iscc = $local }
}
if ($iscc -and (Test-Path $iscc)) {
    Write-Host "== Inno Setup: $iscc ==" -ForegroundColor Cyan
    & $iscc "/DVersion=$Version" "/DArch=x64compatible" "/DSuffix=win64-gnu" `
        "/DStage=$Stage" "/DOut=$Out" (Join-Path $ProjectDir "assets\windows\concat.iss")
    if ($LASTEXITCODE -ne 0) { throw "iscc failed (exit $LASTEXITCODE)" }
    $setup = Join-Path $Out "LongCut-$Version-windows-win64-gnu-setup.exe"
    if (Test-Path $setup) { $results += "EXE  $setup  $([math]::Round((Get-Item $setup).Length / 1MB, 2)) MB" }
} else {
    Write-Host "== Inno Setup skipped (no ISCC.exe; pass -Inno to enable) ==" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "== installer result ==" -ForegroundColor Green
$results | ForEach-Object { Write-Host "  $_" }
if ($results.Count -eq 0) { throw "no installer produced" }
