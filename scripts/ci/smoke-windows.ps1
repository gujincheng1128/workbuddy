# Launches the staged Windows bundle the way a person would, and fails if
# it does not start. Nothing else in the build ever ran what it packaged,
# and 0.2.6 shipped installers whose program would not open: a DLL that
# was not in the folder, an old DirectML.dll found in System32 instead of
# a new one (#303), an instruction an Ivy Bridge does not have (#313).
#
#   powershell -File scripts\ci\smoke-windows.ps1 [-Bundle dist\LongCut-win64-gnu] [-Sde path\to\sde.exe]
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+. A developer
# box without Visual Studio has no dumpbin.exe, so imports are read with
# the MinGW objdump.exe that built this windows-gnu binary instead; the
# two produce the same DLL-name list for the check below.
#
# 1. Every DLL any program or library in the folder imports is either in
#    the folder or one Windows itself provides. A DLL that only happens to
#    be on this machine counts as missing.
# 2. `longcut.exe --version` exits 0 with PATH cut down to Windows' own
#    folders, so every DLL comes from the folder or from System32.
# 3. `longcut.exe --smoke` exits 0 the same way.
# 4. `longcut.exe --whisper-cpu` exits 0 the same way (whisper CPU kernels).
# 5. With -Sde, --version under an emulated Ivy Bridge, then
#    --whisper-cpu under an emulated Sandy Bridge. x86_64 only.
#
# longcut.exe is a GUI program: it has no console, so it is judged by its
# exit code and not by what it prints. Windows' error dialogs are turned
# off for the programs this starts, so a missing DLL is an exit code here
# rather than a dialog waiting for a click on a runner nobody is watching.
param(
  [string]$Bundle = "",
  [string]$Sde = ""
)
$ErrorActionPreference = "Stop"

$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $Bundle) { $Bundle = Join-Path $ProjectDir "dist\LongCut-win64-gnu" }
$bundle = (Resolve-Path $Bundle).Path
$exe = Join-Path $bundle "longcut.exe"

function Say($text) { Write-Host ""; Write-Host "== $text" }
function Fail($text) {
  if ($env:GITHUB_ACTIONS) { Write-Host "::error::$text" }
  throw $text
}

# No error dialogs for this process or the ones it starts: a child takes
# its error mode from its parent. SEM_FAILCRITICALERRORS and
# SEM_NOGPFAULTERRORBOX. Add-Type may be unavailable on a stripped host;
# the checks below still work, they just may pop a dialog on a crash.
try {
  Add-Type -Namespace Smoke -Name Native -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
"@ -ErrorAction Stop
  [void][Smoke.Native]::SetErrorMode(0x0001 -bor 0x0002)
} catch {
  Write-Host "  (SetErrorMode unavailable; continuing)"
}

$meanings = @{
  [int]0xC0000135 = "STATUS_DLL_NOT_FOUND: a DLL it imports is nowhere to be found"
  [int]0xC0000139 = "STATUS_ENTRYPOINT_NOT_FOUND: a DLL it found is not the one it was built against"
  [int]0xC000007B = "STATUS_INVALID_IMAGE_FORMAT: a DLL for another architecture, or a damaged one"
  [int]0xC000001D = "STATUS_ILLEGAL_INSTRUCTION: an instruction this CPU does not have"
  [int]0xC0000005 = "STATUS_ACCESS_VIOLATION: a crash"
  [int]0xC0000409 = "STATUS_STACK_BUFFER_OVERRUN: a fail-fast, which is how a Rust panic aborts"
  [int]0xC0E90002 = "a code integrity block (Smart App Control) on an unsigned or untrusted file"
}

function Show-Crash($file, $since) {
  $name = [IO.Path]::GetFileName($file)
  for ($try = 0; $try -lt 10; $try++) {
    $event = Get-WinEvent -FilterHashtable @{ LogName = "Application"; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match [regex]::Escape($name) } | Select-Object -First 1
    if ($event) {
      Say "what Windows recorded about the crash"
      $event.Message -split "`n" | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
      return
    }
    Start-Sleep -Milliseconds 500
  }
  Write-Host "  (Windows recorded no Application Error event for $name)"
}

# ProcessStartInfo.ArgumentList is .NET Core / PS 7 only; PS 5.1 (the
# .NET Framework host) has just Arguments. All arguments used here are
# plain ASCII flags, so quoting them is enough on both.
function Start-Checked($file, [string[]]$arguments, $path, $seconds, $workdir) {
  # PS 5.1 (.NET Framework) returns null for
  # ProcessStartInfo.EnvironmentVariables, so setting ["PATH"] there throws
  # "Cannot index into a null array". A child inherits the parent's
  # environment at CreateProcess time, so narrowing our own PATH works on
  # both 5.1 and 7. Restore it in finally, whatever happens.
  $oldPath = $env:PATH
  try {
    $env:PATH = $path
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $file
    $quoted = @()
    foreach ($a in $arguments) { $quoted += '"' + $a + '"' }
    $info.Arguments = ($quoted -join " ")
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Not the bundle: the program has to find its DLLs beside itself, not
    # in the folder it was started from. Stays inside the project (no C:).
    $info.WorkingDirectory = $workdir
    $started = Get-Date
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($seconds * 1000)) {
      try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
      throw "still running after $seconds s"
    }
    $process.WaitForExit()
    $out = ($stdout.Result + $stderr.Result).Trim()
    if ($out) { $out -split "`n" | Select-Object -Last 60 | ForEach-Object { Write-Host "  $_" } }
    return @{ Code = $process.ExitCode; Started = $started }
  } finally {
    $env:PATH = $oldPath
  }
}

function Expect-Ok($what, $file, [string[]]$arguments, $path, $seconds, $workdir) {
  $r = Start-Checked $file $arguments $path $seconds $workdir
  if ($r.Code -ne 0) {
    Show-Crash $file $r.Started
    $meaning = $meanings[[int]$r.Code]
    Fail ("${what}: exited with 0x{0:X8}{1}" -f $r.Code, $(if ($meaning) { " - $meaning" } else { "" }))
  }
  Write-Host "  exited 0"
}

# Returns the DLL names one PE imports, from dumpbin or objdump.
function Get-Imports($pePath) {
  $names = @()
  if ($script:dumpbin) {
    $lines = & $script:dumpbin /nologo /dependents $pePath
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $pePath" }
    $reading = $false
    foreach ($line in $lines) {
      if ($line -match "Image has the following .*dependencies") { $reading = $true; continue }
      if ($line -match "^\s*Summary") { $reading = $false; continue }
      if (-not $reading) { continue }
      $dll = ([string]$line).Trim()
      if ($dll -match "(?i)\.dll$") { $names += $dll }
    }
  } else {
    $lines = & $script:objdump -p $pePath 2>$null
    if ($LASTEXITCODE -ne 0) { throw "objdump failed on $pePath" }
    foreach ($line in $lines) {
      $m = [regex]::Match([string]$line, '(?i)DLL Name:\s*(\S+\.dll)')
      if ($m.Success) { $names += $m.Groups[1].Value }
    }
  }
  return ($names | Sort-Object -Unique)
}

try {
  if (-not (Test-Path $exe)) { throw "$exe is not there" }

  # -- 0. Pick an import reader ------------------------------------------
  $script:dumpbin = ""
  $script:objdump = ""
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $found = & $vswhere -latest -products * -find "VC\Tools\MSVC\**\bin\Host*\*\dumpbin.exe" | Select-Object -First 1
    if ($found -and (Test-Path $found)) { $script:dumpbin = $found }
  }
  if (-not $script:dumpbin) {
    $script:objdump = Join-Path $ProjectDir "tools\mingw\mingw64\bin\objdump.exe"
    if (-not (Test-Path $script:objdump)) { throw "neither dumpbin.exe nor tools/mingw/.../objdump.exe is available" }
  }
  Say "reading PE imports with $(if ($script:dumpbin) { 'dumpbin' } else { 'objdump' })"

  # -- 1. Every import is in the folder or Windows' own -------------------
  Say "every DLL the bundle imports is in it, or is Windows' own"
  $mustShip = @(
    "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll",
    "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
    "concrt140.dll", "vccorlib140.dll", "vcomp140.dll",
    "directml.dll", "onnxruntime.dll", "onnxruntime_providers_shared.dll"
  )
  $system = Join-Path $env:SystemRoot "System32"
  $inBundle = @{}
  Get-ChildItem $bundle -Recurse -File | ForEach-Object { $inBundle[$_.Name.ToLowerInvariant()] = $true }
  $missing = @()
  $pes = @(Get-ChildItem $bundle -Recurse -File | Where-Object { $_.Extension -in @(".exe", ".dll") })
  foreach ($pe in $pes) {
    foreach ($dll in (Get-Imports $pe.FullName)) {
      $name = $dll.ToLowerInvariant()
      if ($inBundle.ContainsKey($name)) { continue }
      if ($name -match "^(api|ext)-ms-") { continue }
      if ($mustShip -contains $name) { $missing += "$($pe.Name) -> $dll (must ship with the program)"; continue }
      if (-not (Test-Path (Join-Path $system $dll))) { $missing += "$($pe.Name) -> $dll (not in the folder or in System32)" }
    }
  }
  if ($missing.Count -gt 0) {
    $missing | ForEach-Object { Write-Host "  $_" }
    Fail "the bundle imports DLLs it does not carry"
  }
  Write-Host "  $($pes.Count) PE files: every import resolves to the folder or to Windows"

  # Windows' own folders and nothing else.
  $bare = @($system, $env:SystemRoot, (Join-Path $system "Wbem"), (Join-Path $system "WindowsPowerShell\v1.0")) -join ";"
  $workdir = Join-Path $ProjectDir "tools\_tmp"
  if (-not (Test-Path $workdir)) { New-Item -ItemType Directory -Path $workdir -Force | Out-Null }

  # -- 2..4. Clean-PATH smoke --------------------------------------------
  Say "longcut.exe --version, with only Windows on the path"
  Expect-Ok "longcut.exe --version" $exe @("--version") $bare 60 $workdir

  Say "longcut.exe --smoke, with only Windows on the path"
  Expect-Ok "longcut.exe --smoke" $exe @("--smoke") $bare 180 $workdir

  Say "longcut.exe --whisper-cpu, with only Windows on the path"
  Expect-Ok "longcut.exe --whisper-cpu" $exe @("--whisper-cpu") $bare 180 $workdir

  # -- 5. On an emulated older CPU ---------------------------------------
  if ($Sde) {
    $sdeExe = (Resolve-Path $Sde).Path
    $path = (Split-Path $sdeExe) + ";" + $bare
    Say "longcut.exe --version on an emulated Ivy Bridge"
    Expect-Ok "longcut.exe --version under SDE -ivb" $sdeExe @("-ivb", "--", $exe, "--version") $path 600 $workdir
    Say "longcut.exe --whisper-cpu on an emulated Sandy Bridge"
    Expect-Ok "longcut.exe --whisper-cpu under SDE -snb" $sdeExe @("-snb", "--", $exe, "--whisper-cpu") $path 600 $workdir
  }

  Say "ok"
  exit 0
} catch {
  Write-Host ""
  Write-Host "SMOKE FAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "  at: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkYellow
  Write-Host "  stack: $($_.ScriptStackTrace)" -ForegroundColor DarkYellow
  if ($env:GITHUB_ACTIONS) { Write-Host "::error::$($_.Exception.Message)" }
  exit 1
}
