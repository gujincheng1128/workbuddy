@echo off
REM LongCut launcher (windows-gnu build). Defaults to the stripped --profile
REM app binary when present, else the dev debug one; set LONGCUT_PROFILE_DIR
REM to pick a profile explicitly (debug / release / app).
REM The exe links FFmpeg dynamically and needs MinGW's runtime DLLs, so put
REM both tool bin directories on PATH before starting it. All arguments are
REM forwarded, e.g. run-longcut.bat --smoke / --version / --mcp.
REM The project root is derived from this script's own location, not hardcoded.
setlocal
for %%I in ("%~dp0..") do set "PRJ=%%~fI"
set "PROFILE=%LONGCUT_PROFILE_DIR%"
if not defined PROFILE (
  if exist "%PRJ%\src\target-gnu\x86_64-pc-windows-gnu\app\longcut.exe" (
    set "PROFILE=app"
  ) else (
    set "PROFILE=debug"
  )
)
set "EXE=%PRJ%\src\target-gnu\x86_64-pc-windows-gnu\%PROFILE%\longcut.exe"
if not exist "%EXE%" (
  echo [LongCut] longcut.exe not found: "%EXE%" 1>&2
  exit /b 1
)

REM Prefer the unpacked FFmpeg path recorded by the bootstrap script; fall
REM back to the conventional directory name when that file is missing.
set "FFDIR=%PRJ%\tools\ffmpeg\ffmpeg-master-latest-win64-gpl-shared"
if exist "%PRJ%\tools\ffmpeg\FFMPEG_DIR.txt" (
  for /f "usebackq delims=" %%A in ("%PRJ%\tools\ffmpeg\FFMPEG_DIR.txt") do set "FFDIR=%%A"
)
set "FFDIR=%FFDIR:/=\%"
set "PATH=%FFDIR%\bin;%PRJ%\tools\mingw\mingw64\bin;%PATH%"

"%EXE%" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
