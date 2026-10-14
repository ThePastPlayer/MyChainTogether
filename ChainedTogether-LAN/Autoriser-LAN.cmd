@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Autoriser-LAN.ps1" -Interactive %*
set "LAN_EXIT=%ERRORLEVEL%"
pause
exit /b %LAN_EXIT%
