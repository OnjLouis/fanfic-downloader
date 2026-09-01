@echo off
setlocal

set "APP_DIR=%~dp0"
set "SCRIPT=%APP_DIR%Download AO3 with FanFicFare.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
