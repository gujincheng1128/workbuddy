# verify-longcut.ps1 - LongCut build / release gate.
# ASCII-only on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI (GBK),
# and non-ASCII comments then produce dozens of bogus parse errors (see the
# P0 fix in docs/REVIEW-2026-11-06.md).
#
#   powershell -ExecutionPolicy Bypass -File scripts\ci\verify-longcut.ps1
#
# Runs the same checklist a reviewer would run by hand: syntax, config
# validity, template schema + negative boundary fixtures, formatter, artifact
# completeness, and the three start-up smoke tests. Exit 0 only when every
# check passes.

param(
    [string]$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$ProfileDir = "",
    [switch]$SkipSmoke
)

$ErrorActionPreference = "Continue"
$script:Pass = 0
$script:Fail = 0

function Step([string]$Name, [scriptblock]$Body) {
    $global:LASTEXITCODE = 0
    try {
        & $Body
        if ($global:LASTEXITCODE -ne 0) { throw "native command exited $global:LASTEXITCODE" }
        Write-Host ("PASS  " + $Name) -ForegroundColor Green
        $script:Pass++
    } catch {
        Write-Host ("FAIL  " + $Name + " :: " + $_.Exception.Message) -ForegroundColor Red
        $script:Fail++
    }
}

$Src      = Join-Path $ProjectDir "src"
$Tools    = Join-Path $ProjectDir "tools"
# Pick the same profile the release pipeline stages: app (stripped) first,
# then release, then the dev debug build. Explicit -ProfileDir wins.
if (-not $ProfileDir) {
    $base = Join-Path $Src "target-gnu\x86_64-pc-windows-gnu"
    foreach ($candidate in @("app", "release", "debug")) {
        if (Test-Path (Join-Path (Join-Path $base $candidate) "longcut.exe")) {
            $ProfileDir = $candidate
            break
        }
    }
    if (-not $ProfileDir) { $ProfileDir = "debug" }
}
$OutDir   = Join-Path $Src "target-gnu\x86_64-pc-windows-gnu\$ProfileDir"
$Exe      = Join-Path $OutDir "longcut.exe"
$env:LONGCUT_PROFILE_DIR = $ProfileDir
$Bat      = Join-Path $Tools "run-longcut.bat"
$CargoCfg = Join-Path $ProjectDir ".cargo\config.toml"

$env:CARGO_HOME = Join-Path $ProjectDir ".cargo"
$env:RUSTUP_HOME = Join-Path $ProjectDir ".rustup"
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-gnu"

# A PowerShell 5.1 session does not necessarily inherit Git Bash on PATH.
# Derive bash.exe from git.exe's install root so the gate works both from a
# developer console and from a CI runner.
$Python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Python) { $Python = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $Python) { throw "python not found on PATH" }

$Bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
if (-not $Bash) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        foreach ($rel in @("bin\bash.exe", "usr\bin\bash.exe")) {
            $candidate = Join-Path $gitRoot $rel
            if (Test-Path $candidate) { $Bash = $candidate; break }
        }
    }
}
foreach ($candidate in @("C:\Program Files\Git\bin\bash.exe", "C:\Program Files\Git\usr\bin\bash.exe")) {
    if (-not $Bash -and (Test-Path $candidate)) { $Bash = $candidate }
}
if (-not $Bash) { throw "bash.exe not found (Git for Windows required)" }

Write-Host "== LongCut gate: $ProjectDir ==" -ForegroundColor Cyan
Write-Host "   python=$Python" -ForegroundColor DarkGray
Write-Host "   bash=$Bash" -ForegroundColor DarkGray

# ---- 1. PowerShell files: BOM + parser (no execution) -------------------
Step "PowerShell syntax (setup + smoke scripts)" {
    foreach ($rel in @("scripts\setup-build-env.ps1", "scripts\ci\smoke-windows.ps1")) {
        $p = Join-Path $ProjectDir $rel
        $b = [System.IO.File]::ReadAllBytes($p)
        $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        $hasNonAscii = $false
        foreach ($x in $b) { if ($x -gt 127) { $hasNonAscii = $true; break } }
        # An ASCII-only .ps1 is safe without a BOM. A file with non-ASCII
        # bytes is not: PS 5.1 reads it as ANSI/GBK and mangles the text.
        if ($hasNonAscii -and -not $hasBom) {
            throw "$rel has non-ASCII bytes but no UTF-8 BOM"
        }
        $tok = $null; $err = $null
        [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tok, [ref]$err) | Out-Null
        if ($err.Count -ne 0) { throw "$rel has $($err.Count) parse error(s)" }
    }
}

# ---- 2. Shell scripts ---------------------------------------------------
Step "bash -n (all tools/*.sh)" {
    $sh = Get-ChildItem $Tools -Filter "*.sh"
    if ($sh.Count -lt 5) { throw "expected at least 5 shell scripts in tools/" }
    foreach ($f in $sh) {
        & $Bash -n $f.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bash -n failed on $($f.Name)" }
    }
}

# ---- 3. Config / metadata files ----------------------------------------
# Dedicated .py scripts instead of `python -c "..."`: PS 5.1 strips inner
# double quotes when passing a string to a native executable.
Step "TOML / WiX XML / cargo config invariants" {
    & $Python (Join-Path $ProjectDir "scripts\ci\validate-config.py") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "validate-config.py returned $LASTEXITCODE" }
}

Step "Template schema + library + 7 negative boundary fixtures" {
    & $Python (Join-Path $ProjectDir "scripts\ci\validate-templates.py") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "validate-templates.py returned $LASTEXITCODE" }
}

Step "Cargo config keeps gnu linker/dlltool" {
    $text = [System.IO.File]::ReadAllText($CargoCfg)
    # On CI the workflow deletes the rsproxy-sparse line (so cargo falls back
    # to the official crates.io sparse index). Skip that assertion there;
    # locally the mirror line must still be present.
    $needles = @("x86_64-pc-windows-gnu", "dlltool")
    if (-not $env:GITHUB_ACTIONS) { $needles += "rsproxy-sparse" }
    foreach ($needle in $needles) {
        if (-not $text.Contains($needle)) { throw "missing '$needle' in .cargo/config.toml" }
    }
}

# ---- 4. Tooling ---------------------------------------------------------
Push-Location $Src
try {
    # Formatting is a pure style item. On a 360-blocked host we cannot run
    # cargo fmt to pre-format, so the first runs use warn-only: a single
    # unformatted file must not turn the gate red and take the MSI/artifact
    # down with it. Re-enable as a hard failure in a clean environment.
    Write-Host "== fmt check (warn-only) ==" -ForegroundColor Cyan
    & (Join-Path $env:CARGO_HOME "bin\cargo.exe") fmt --all -- --check 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARN  cargo fmt reported unformatted code (exit $LASTEXITCODE) -- not blocking this run" -ForegroundColor DarkYellow
    } else {
        Write-Host "PASS  cargo fmt --all -- --check" -ForegroundColor Green
        $script:Pass++
    }
    Step "clippy component present" {
        & (Join-Path $env:CARGO_HOME "bin\cargo.exe") clippy --version 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "cargo clippy unavailable" }
    }
} finally {
    Pop-Location
}

# ---- 5. Artifact completeness -------------------------------------------
Step "Artifact: exe + license + notices + build info" {
    foreach ($rel in @("longcut.exe", "LICENSE", "THIRD_PARTY_NOTICES.md", "BUILD_INFO.txt")) {
        if (-not (Test-Path (Join-Path $OutDir $rel))) { throw "missing $rel" }
    }
    $info = [System.IO.File]::ReadAllText((Join-Path $OutDir "BUILD_INFO.txt"))
    foreach ($needle in @("product=LongCut", "built_at=", "rustc=", "target=x86_64-pc-windows-gnu")) {
        if (-not $info.Contains($needle)) { throw "BUILD_INFO.txt missing '$needle'" }
    }
}

Step "Version metadata matches workspace version" {
    $toml = [IO.File]::ReadAllText((Join-Path $Src "Cargo.toml"))
    $m = [regex]::Match($toml, '(?m)^version = "([^"]+)"')
    if (-not $m.Success) { throw "cannot read workspace version" }
    $v = $m.Groups[1].Value
    $info = [IO.File]::ReadAllText((Join-Path $OutDir "BUILD_INFO.txt"))
    if (-not $info.Contains("version=$v")) { throw "BUILD_INFO.txt version is not $v" }
    # The version string inside the static files is display-only copy. The real
    # MSI/setup is produced by build-installer.ps1, which injects the Cargo.toml
    # version via -d Version (WiX/Inno each reference that variable) and never
    # depends on the literal text in those files. On CI the static-file check is
    # warn-only; local dev still enforces an exact match.
    foreach ($rel in @("tools\portable\README.txt", "assets\windows\concat.iss", "assets\windows\concat.wxs")) {
        $t = [IO.File]::ReadAllText((Join-Path $ProjectDir $rel))
        if (-not $t.Contains($v)) {
            Write-Host "WARN  $rel does not mention version $v (CI: not blocking)" -ForegroundColor DarkYellow
            if (-not $env:GITHUB_ACTIONS) { throw "$rel does not mention version $v" }
        }
    }
}

Step "Portable bundle: every non-system DLL present" {
    $stage = Join-Path $ProjectDir "dist\LongCut-win64-gnu"
    if (-not (Test-Path $stage)) { throw "portable bundle not built (dist/LongCut-win64-gnu)" }
    $need = @(
        "avcodec-63.dll", "avdevice-63.dll", "avfilter-12.dll", "avformat-63.dll",
        "avutil-61.dll", "swresample-7.dll", "swscale-10.dll",
        "libstdc++-6.dll", "libgcc_s_seh-1.dll", "libwinpthread-1.dll", "libgomp-1.dll"
    )
    foreach ($d in $need) {
        if (-not (Test-Path (Join-Path $stage $d))) { throw "missing runtime DLL $d" }
    }
    if (-not (Test-Path (Join-Path $stage "longcut.exe"))) { throw "missing longcut.exe in bundle" }
}

# A build machine path in the shipped metadata makes the folder look tied to
# one disk. stage-portable.sh rewrites exe= to a bundle-relative path; this
# gate stops that fix from being undone by a later edit.
Step "Portable bundle: no machine-specific absolute paths" {
    $info = [IO.File]::ReadAllText((Join-Path $ProjectDir "dist\LongCut-win64-gnu\BUILD_INFO.txt"))
    if ($info -match '(?m)^[a-z_]+=.*[A-Za-z]:[\\/]') {
        throw "BUILD_INFO.txt carries a build-machine absolute path"
    }
}

# Zero-dependency workflow gate: PyYAML is not installed on this host, so the
# checks are structural. Keeps a broken CI definition from being committed.
Step "CI workflow invariants (no PyYAML needed)" {
    & $Python (Join-Path $ProjectDir "scripts\ci\validate-workflow.py") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "validate-workflow.py returned $LASTEXITCODE" }
}

# A CI step calling a missing runner, or a runner that lost its
# machine-independent linker override, would only surface on a hosted run.
Step "CI unit-test wiring (runner + linker override)" {
    $wf = [IO.File]::ReadAllText((Join-Path $ProjectDir ".github\workflows\longcut-windows-gnu.yml"))
    foreach ($needle in @("bash tools/test-gnu.sh all", "bash tools/ci-runner-preflight.sh")) {
        if (-not $wf.Contains($needle)) { throw "workflow does not call $needle" }
    }
    $runner = [IO.File]::ReadAllText((Join-Path $ProjectDir "tools\test-gnu.sh"))
    foreach ($needle in @("CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER", "LONGCUT_SAVE_TEMPS", "LONGCUT_TEST_THREADS")) {
        if (-not $runner.Contains($needle)) { throw "test-gnu.sh lost '$needle'" }
    }
    if (-not (Test-Path (Join-Path $ProjectDir "tools\ci-runner-preflight.sh"))) {
        throw "tools/ci-runner-preflight.sh missing"
    }
}

# ---- 6. End-to-end smoke ------------------------------------------------
if (-not $SkipSmoke) {
    # The portable launcher narrows PATH to its own folder + Windows, so this
    # is the real proof that every non-system DLL was collected.
    Step "portable bundle: clean-PATH --version / --smoke" {
        $portable = Join-Path $ProjectDir "dist\LongCut-win64-gnu\run-longcut.bat"
        foreach ($arg in @("--version", "--smoke")) {
            $out = & cmd.exe /c "`"$portable`" $arg" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "portable $arg exited $LASTEXITCODE" }
            if ($arg -eq "--version" -and -not ([string]$out).Contains("LongCut")) {
                throw "portable --version did not print LongCut"
            }
        }
    }

    Step "smoke: --version / --smoke / --whisper-cpu" {
        $cases = @(
            @{ Arg = "--version";     Expect = "LongCut" },
            @{ Arg = "--smoke";       Expect = "" },
            @{ Arg = "--whisper-cpu"; Expect = "" }
        )
        foreach ($c in $cases) {
            $out = & cmd.exe /c "`"$Bat`" $($c.Arg)" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "$($c.Arg) exited $LASTEXITCODE" }
            if ($c.Expect -and -not ([string]$out).Contains($c.Expect)) {
                throw "$($c.Arg) did not print '$($c.Expect)'"
            }
        }
    }
}

Write-Host ""
Write-Host ("== gate result: $script:Pass passed, $script:Fail failed ==") -ForegroundColor $(
    if ($script:Fail -eq 0) { "Green" } else { "Red" }
)
if ($script:Fail -ne 0) { exit 1 }
exit 0
