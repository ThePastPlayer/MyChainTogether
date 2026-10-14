#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureName = 'ChainedTogether-UpdateTests-' + [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $temporaryRoot $fixtureName
$originalLocalAppData = $env:LOCALAPPDATA
$script:UpdateChecks = 0
$script:Downloads = 0
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert-UpdateCheck([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ECHEC : $Message" }
    $script:UpdateChecks++
}
function Assert-UpdateRejected([scriptblock]$Action,[string]$Pattern) {
    $rejected = $false
    try { $null = & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $rejected = $true
    }
    Assert-UpdateCheck $rejected "Refus attendu : $Pattern"
}
function Write-UpdateFixture([string]$Path,[string]$Value) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [IO.File]::WriteAllText($Path,$Value,$utf8)
}
function Write-UpdateManifest([string]$Root) {
    $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
        (Get-LanUpdateHash $_.FullName) + '  ' + $_.FullName.Substring($Root.Length + 1).Replace('\','/')
    } | Sort-Object)
    Write-UpdateFixture (Join-Path $Root 'SHA256SUMS.txt') (($lines -join "`n") + "`n")
}
try {
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'Profile'
    . (Join-Path $sourceRoot 'Update-LAN.ps1') -FunctionsOnly
    $script:RemoteRoot = Join-Path $fixtureRoot 'Remote'
    $local = Join-Path $fixtureRoot 'Portable package'
    $script:Offline = $false
    $script:BadDownload = $false
    $script:CommitsRead = 0
    function Get-LanUpdateCommit {
        $script:CommitsRead++
        if ($script:Offline) { throw 'Offline fixture.' }
        return ('a' * 40)
    }
    function Get-LanRemoteUpdateFile([string]$Commit,[string]$Relative,[string]$Destination) {
        Assert-UpdateCheck ($Commit -eq ('a' * 40)) 'Every download uses the same pinned commit.'
        $script:Downloads++
        Copy-Item -LiteralPath (Join-Path $script:RemoteRoot $Relative) -Destination $Destination
        if ($script:BadDownload -and $Relative -ne 'SHA256SUMS.txt') { [IO.File]::AppendAllText($Destination,'corrupted',$utf8) }
    }
    function Get-Process { param($Name,$ErrorAction) }
    $files = @('launcher-version.txt','Launch-LAN.ps1','Start-ChainedTogether-LAN.ps1','Update-LAN.ps1','Player-Names.ps1','Game-Paths.ps1','payload/steam_api64.dll','payload/provenance.json','obsolete.txt')
    foreach ($name in $files) { Write-UpdateFixture (Join-Path $local $name) ('old fixture ' + $name) }
    Write-UpdateManifest $local
    Copy-Item -LiteralPath $local -Destination $script:RemoteRoot -Recurse
    Write-UpdateFixture (Join-Path $script:RemoteRoot 'launcher-version.txt') 'new version'
    Write-UpdateFixture (Join-Path $script:RemoteRoot 'Start-ChainedTogether-LAN.ps1') 'new script, never executed'
    Write-UpdateFixture (Join-Path $script:RemoteRoot 'payload/steam_api64.dll') 'new fixture DLL, never loaded'
    Remove-Item -LiteralPath (Join-Path $script:RemoteRoot 'obsolete.txt')
    Write-UpdateFixture (Join-Path $script:RemoteRoot 'new-file.txt') 'new tracked file'
    Write-UpdateManifest $script:RemoteRoot
    Write-UpdateFixture (Join-Path $local 'launcher-settings.json') '{"gamePath":"private-local-setting"}'
    Write-UpdateFixture (Join-Path $local 'Rejoindre-LAN.log') 'private diagnostic'
    $before = Get-LanUpdateHash (Join-Path $local 'SHA256SUMS.txt')
    foreach ($bad in @('../outside.ps1','C:/outside.ps1','payload/../../outside','./file.ps1','payload/../file.ps1','identity.json','launcher-settings.json','Rejoindre-LAN.log','Diagnostic-LAN.txt','.git/config')) {
        Assert-UpdateRejected { Read-LanUpdateManifest (('a' * 64) + '  ' + $bad) $local } 'refuse'
    }
    Assert-UpdateRejected { Read-LanUpdateManifest 'invalid manifest' $local } 'invalide'
    Assert-UpdateRejected { Read-LanUpdateManifest ((('a' * 64) + "  A.ps1`n") + (('b' * 64) + '  a.ps1')) $local } 'dupliquee'
    Assert-UpdateCheck ((Invoke-LanPackageUpdate $local -CheckOnly) -eq 'Available') 'Check-only reports update.'
    Assert-UpdateCheck ((Get-LanUpdateHash (Join-Path $local 'SHA256SUMS.txt')) -eq $before) 'Check-only does not change package.'
    Assert-UpdateCheck (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\update-check.json'))) 'Check-only does not write user profile.'
    $script:Offline = $true
    Assert-UpdateRejected { Invoke-LanPackageUpdate $local -Force } 'Offline fixture'
    Assert-UpdateCheck ((Get-LanUpdateHash (Join-Path $local 'SHA256SUMS.txt')) -eq $before) 'Network failure preserves installed version.'
    $script:Offline = $false
    $script:BadDownload = $true
    Assert-UpdateRejected { Invoke-LanPackageUpdate $local -Force } 'SHA256 distant incorrect'
    Assert-UpdateCheck ((Get-LanUpdateHash (Join-Path $local 'SHA256SUMS.txt')) -eq $before) 'Bad download preserves installed version.'
    $script:BadDownload = $false
    Write-UpdateFixture (Join-Path $local 'Game-Paths.ps1') 'manual edit'
    Assert-UpdateRejected { Invoke-LanPackageUpdate $local -Force } 'Fichier local modifie'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $local 'Game-Paths.ps1')) -eq 'manual edit') 'Manual edits protected.'
    Copy-Item -LiteralPath (Join-Path $script:RemoteRoot 'Game-Paths.ps1') -Destination (Join-Path $local 'Game-Paths.ps1') -Force
    Assert-UpdateCheck ((Invoke-LanPackageUpdate $local -Force) -eq 'Updated') 'Validated update installed.'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $local 'launcher-version.txt')) -eq 'new version') 'Version refreshed.'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $local 'Start-ChainedTogether-LAN.ps1')) -eq 'new script, never executed') 'Launcher refreshed.'
    Assert-UpdateCheck (-not (Test-Path -LiteralPath (Join-Path $local 'obsolete.txt'))) 'Obsolete tracked files removed.'
    Assert-UpdateCheck (Test-Path -LiteralPath (Join-Path $local 'new-file.txt')) 'New tracked files installed.'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $local 'launcher-settings.json')).Contains('private-local-setting')) 'Local game path preserved.'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $local 'Rejoindre-LAN.log')) -eq 'private diagnostic') 'Logs preserved and never uploaded.'
    Assert-UpdateCheck ((Get-LanUpdateHash (Join-Path $local 'SHA256SUMS.txt')) -eq (Get-LanUpdateHash (Join-Path $script:RemoteRoot 'SHA256SUMS.txt'))) 'Installed manifest matches remote version.'
    $reads = $script:CommitsRead
    Assert-UpdateCheck ((Invoke-LanPackageUpdate $local) -eq 'Cached' -and $script:CommitsRead -eq $reads) '15-minute cache avoids launch delays.'
    $downloadsBefore = $script:Downloads
    Assert-UpdateCheck ((Invoke-LanPackageUpdate $local -Force) -eq 'Current' -and $script:Downloads -eq ($downloadsBefore + 1)) 'Current version only downloads the manifest.'
    Assert-UpdateCheck (@(Get-ChildItem -LiteralPath $local -Directory -Filter '.lan-update-*').Count -eq 0) 'Staging directories cleaned.'

    # A sharing violation after one successful write must roll back that first write.
    $rollbackRoot = Join-Path $fixtureRoot 'Rollback package'
    $stage = Join-Path $fixtureRoot 'Rollback stage'
    foreach ($name in @('A.ps1','B.ps1')) {
        Write-UpdateFixture (Join-Path $rollbackRoot $name) ('old ' + $name)
        Write-UpdateFixture (Join-Path $stage $name) ('new ' + $name)
    }
    Write-UpdateManifest $rollbackRoot; Write-UpdateManifest $stage
    $old = Read-LanUpdateManifest ([IO.File]::ReadAllText((Join-Path $rollbackRoot 'SHA256SUMS.txt'))) $rollbackRoot
    $new = Read-LanUpdateManifest ([IO.File]::ReadAllText((Join-Path $stage 'SHA256SUMS.txt'))) $rollbackRoot
    $lock = [IO.File]::Open((Join-Path $rollbackRoot 'B.ps1'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { Assert-UpdateRejected { Install-LanPackageUpdate $rollbackRoot $stage $old $new (Join-Path $stage 'SHA256SUMS.txt') } 'process|processus|used|utilis' }
    finally { $lock.Dispose() }
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $rollbackRoot 'A.ps1')) -eq 'old A.ps1') 'Earlier writes rolled back.'
    Assert-UpdateCheck ([IO.File]::ReadAllText((Join-Path $rollbackRoot 'B.ps1')) -eq 'old B.ps1') 'Locked file preserved.'

    # Real bootstrap process: refresh the launcher before loading it, never launch a game.
    $bootstrap = Join-Path $fixtureRoot 'Bootstrap'
    $null = New-Item -ItemType Directory -Path $bootstrap -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launch-LAN.ps1') -Destination (Join-Path $bootstrap 'Launch-LAN.ps1')
    $fakeLauncher = @'
param($Role,[switch]$Diagnose,[switch]$PrepareOnly,[switch]$Restore,$PlayerName)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'executed.txt'),('VERSION:' + $Role + ':' + $PlayerName))
exit 0
'@
    $fakeUpdater = @'
param([switch]$Automatic)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'checked.txt'),'checked')
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Start-ChainedTogether-LAN.ps1'),[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'next-launcher.txt')))
exit 0
'@
    foreach ($scenario in @('Automatic','SkipUpdate','Diagnose','PrepareOnly','Restore','Fatal')) {
        foreach ($marker in @('checked.txt','executed.txt')) {
            if (Test-Path -LiteralPath (Join-Path $bootstrap $marker)) { Remove-Item -LiteralPath (Join-Path $bootstrap $marker) }
        }
        Write-UpdateFixture (Join-Path $bootstrap 'Start-ChainedTogether-LAN.ps1') ($fakeLauncher.Replace('VERSION','old'))
        Write-UpdateFixture (Join-Path $bootstrap 'next-launcher.txt') ($fakeLauncher.Replace('VERSION','new'))
        $updaterText = if ($scenario -eq 'Fatal') { 'param([switch]$Automatic); exit 2' } else { $fakeUpdater }
        Write-UpdateFixture (Join-Path $bootstrap 'Update-LAN.ps1') $updaterText
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'powershell.exe'
        $extra = if ($scenario -in @('Automatic','Fatal')) { '' } else { ' -' + $scenario }
        $info.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $bootstrap 'Launch-LAN.ps1') + '" -Role Host -PlayerName TestPlayer' + $extra
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $worker = New-Object Diagnostics.Process
        $worker.StartInfo = $info
        try {
            $null = $worker.Start()
            $out = $worker.StandardOutput.ReadToEndAsync(); $err = $worker.StandardError.ReadToEndAsync()
            if (-not $worker.WaitForExit(15000)) { $worker.Kill(); throw 'Bootstrap fixture timeout.' }
            if ($scenario -eq 'Fatal') {
                Assert-UpdateCheck ($worker.ExitCode -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $bootstrap 'executed.txt'))) 'Fatal update prevents launching an unsafe package.'
            } else {
                $expected = if ($scenario -eq 'Automatic') { 'new:Host:TestPlayer' } else { 'old:Host:TestPlayer' }
                Assert-UpdateCheck ($worker.ExitCode -eq 0 -and [IO.File]::ReadAllText((Join-Path $bootstrap 'executed.txt')) -eq $expected) ("$scenario forwards parameters and loads the correct launcher: " + $out.Result + $err.Result)
                Assert-UpdateCheck ((Test-Path -LiteralPath (Join-Path $bootstrap 'checked.txt')) -eq ($scenario -eq 'Automatic')) "$scenario network policy."
            }
        } finally { $worker.Dispose() }
    }
    Write-Output "OK : $script:UpdateChecks controles de mises a jour. Aucun reseau utilise, code telecharge execute ou jeu modifie."
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolved.StartsWith($temporaryRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -ne $fixtureName) { throw 'Nettoyage refuse hors du dossier de test.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
