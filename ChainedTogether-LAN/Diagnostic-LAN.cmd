@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ChainedTogether-LAN.ps1" -Role Join -Diagnose -LogPath "%~dp0Diagnostic-LAN.txt" %*
set "LAN_EXIT=%ERRORLEVEL%"
pause
exit /b %LAN_EXIT%
