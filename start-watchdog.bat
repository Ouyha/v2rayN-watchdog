@echo off
cd /d "%~dp0"
rem Prefer PowerShell 7 (faster); fall back to Windows PowerShell 5.1
set "PS=powershell.exe"
set "PSARGS=-NoProfile -ExecutionPolicy Bypass"
where pwsh.exe >nul 2>nul
if not errorlevel 1 (
    set "PS=pwsh.exe"
    set "PSARGS=-NoProfile"
)
"%PS%" %PSARGS% -File "%~dp0watchdog.ps1"
