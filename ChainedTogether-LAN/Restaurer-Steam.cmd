@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ChainedTogether-LAN.ps1" -Restore -Interactive -LogPath "%~dp0Restaurer-Steam.log" %*
set "LAN_EXIT=%ERRORLEVEL%"
pause
exit /b %LAN_EXIT%
