@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-LAN.ps1" -Role Host -Interactive -LogPath "%~dp0Heberger-LAN.log" %*
set "LAN_EXIT=%ERRORLEVEL%"
if not "%LAN_EXIT%"=="0" pause
exit /b %LAN_EXIT%
