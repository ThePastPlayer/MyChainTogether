#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$SteamDllPath,
    [string]$PlayerName,
    [switch]$AskPlayerName,
    [string[]]$PeerIP,
    [ValidateSet('Manual','Host','Join')][string]$Role,
    [switch]$PrepareOnly,
    [switch]$Diagnose,
    [switch]$Restore,
    [switch]$Interactive,
    [string]$LogPath,
    [switch]$SkipUpdate
)
$ErrorActionPreference = 'Stop'
# This bootstrap is parsed before updates; the refreshed launcher is loaded afterwards.
if (-not ($SkipUpdate -or $Diagnose -or $Restore -or $PrepareOnly)) {
    & (Join-Path $PSScriptRoot 'Update-LAN.ps1') -Automatic
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$forwarded = @{}
foreach ($key in $PSBoundParameters.Keys) { if ($key -ne 'SkipUpdate') { $forwarded[$key] = $PSBoundParameters[$key] } }
& (Join-Path $PSScriptRoot 'Start-ChainedTogether-LAN.ps1') @forwarded
exit $LASTEXITCODE
