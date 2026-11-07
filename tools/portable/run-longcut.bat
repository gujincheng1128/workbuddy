@echo off
REM LongCut portable launcher (windows-gnu x86_64).
REM PATH is deliberately reduced to this folder plus Windows' own directories:
REM a missing runtime DLL then shows up as a non-zero exit code instead of
REM being silently satisfied by a developer machine's global PATH.
REM No project path is baked into this file; the whole folder is relocatable.
setlocal
set "PATH=%~dp0;%SystemRoot%\System32;%SystemRoot%"
"%~dp0longcut.exe" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
