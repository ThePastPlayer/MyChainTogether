#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [switch]$Automatic,
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$FunctionsOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:UpdateRepository = 'ThePastPlayer/MyChainTogether'

function Get-LanUpdatePath([string]$Root,[string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Length -gt 240 -or
        $Relative -notmatch '^[A-Za-z0-9][A-Za-z0-9._/\-]*$' -or
        $Relative -match '(^|/)(\.{1,2}|\.git|\.chained-lan)(/|$)' -or
        $Relative -match '(^|/)(identity|player-preferences|launcher-preferences|game-location|launcher-settings|update-check)\.json$' -or
        $Relative -match '\.log$|(^|/)Diagnostic-LAN\.txt$') { throw "Chemin de mise a jour refuse : $Relative" }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative.Replace('/','\')))
    if (-not $path.StartsWith($rootPath + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Mise a jour hors du paquet refusee.' }
    $cursor = $path
    while ($cursor.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Mise a jour via lien/jonction refusee.' }
        }
        if ($cursor.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $path
}
function Read-LanUpdateManifest([string]$Text,[string]$Root) {
    if ($Text.Length -gt 131072) { throw 'Manifest de mise a jour trop volumineux.' }
    $entries = @{}
    foreach ($line in @($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line,'^([a-fA-F0-9]{64})  ([^\r\n]+)$')
        if (-not $match.Success) { throw 'Manifest SHA256 de mise a jour invalide.' }
        $name = $match.Groups[2].Value
        $null = Get-LanUpdatePath $Root $name
        if ($name -eq 'SHA256SUMS.txt' -or $entries.ContainsKey($name)) { throw 'Entree de manifest dupliquee ou recursive.' }
        $entries[$name] = $match.Groups[1].Value.ToLowerInvariant()
    }
    if ($entries.Count -eq 0 -or $entries.Count -gt 128) { throw 'Nombre de fichiers de mise a jour invalide.' }
    return $entries
}
function Get-LanUpdateHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-LanUpdateHeaders {
    $headers = @{ 'User-Agent'='MyChainTogether-Updater'; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28' }
    # Optional fine-grained read-only token for private repositories, never stored or logged.
    if ($env:CHAINED_LAN_GITHUB_TOKEN) { $headers.Authorization = 'Bearer ' + $env:CHAINED_LAN_GITHUB_TOKEN }
    return $headers
}
function Get-LanUpdateCommit {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = 'https://api.github.com/repos/' + $script:UpdateRepository + '/commits/main'
    $commit = Invoke-RestMethod -Uri $url -Headers (Get-LanUpdateHeaders) -TimeoutSec 6
    if (-not $commit.PSObject.Properties['sha'] -or [string]$commit.sha -notmatch '^[a-f0-9]{40}$') { throw 'Commit GitHub invalide.' }
    return [string]$commit.sha
}
function Get-LanRemoteUpdateFile([string]$Commit,[string]$Relative,[string]$Destination) {
    if ($Commit -notmatch '^[a-f0-9]{40}$') { throw 'Revision de mise a jour invalide.' }
    $headers = Get-LanUpdateHeaders
    $headers.Accept = 'application/vnd.github.raw+json'
    $url = 'https://api.github.com/repos/' + $script:UpdateRepository + '/contents/ChainedTogether-LAN/' + $Relative + '?ref=' + $Commit
    $null = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers $headers -TimeoutSec 30 -OutFile $Destination
    if ((Get-Item -LiteralPath $Destination).Length -gt 26214400) { throw 'Fichier de mise a jour trop volumineux.' }
}
function Save-LanUpdateCheck([string]$ManifestHash,[string]$Commit,[string]$Status) {
    $directory = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $path = Join-Path $directory 'update-check.json'
    $value = @{ checkedUtc=[DateTime]::UtcNow.ToString('o'); manifestHash=$ManifestHash; commit=$Commit; status=$Status }
    $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.new'
    [IO.File]::WriteAllText($temporary,($value | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}
function Install-LanPackageUpdate([string]$Root,[string]$Stage,$OldEntries,$NewEntries,[string]$ManifestFile) {
    $actions = New-Object 'System.Collections.Generic.List[object]'
    # Detect manual edits before touching any file. User preferences are never tracked.
    foreach ($name in $OldEntries.Keys) {
        $target = Get-LanUpdatePath $Root $name
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-LanUpdateHash $target) -ne $OldEntries[$name]) { throw "Fichier local modifie : $name. Mise a jour annulee ; sauvegardez vos changements." }
        }
    }
    foreach ($name in @($NewEntries.Keys | Sort-Object)) {
        $target = Get-LanUpdatePath $Root $name
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "La cible est un dossier : $name" }
            if ((Get-LanUpdateHash $target) -eq $NewEntries[$name]) { continue }
            if (-not $OldEntries.ContainsKey($name)) { throw "Fichier local non suivi protege : $name" }
        }
        $source = Get-LanUpdatePath $Stage $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-LanUpdateHash $source) -ne $NewEntries[$name]) { throw "SHA256 de mise a jour incorrect : $name" }
        $actions.Add([pscustomobject]@{ Name=$name; Target=$target; Source=$source; Exists=(Test-Path -LiteralPath $target); Backup=$null; Applied=$false })
    }
    foreach ($name in $OldEntries.Keys) {
        $target = Get-LanUpdatePath $Root $name
        if (-not $NewEntries.ContainsKey($name) -and (Test-Path -LiteralPath $target)) {
            $actions.Add([pscustomobject]@{ Name=$name; Target=$target; Source=$null; Exists=$true; Backup=$null; Applied=$false })
        }
    }
    $manifestPath = Get-LanUpdatePath $Root 'SHA256SUMS.txt'
    $actions.Add([pscustomobject]@{ Name='SHA256SUMS.txt'; Target=$manifestPath; Source=$ManifestFile; Exists=(Test-Path -LiteralPath $manifestPath); Backup=$null; Applied=$false })
    $backupRoot = Join-Path $Stage 'backups'
    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    $index = 0
    foreach ($action in $actions) {
        $index++
        if ($action.Exists) {
            $action.Backup = Join-Path $backupRoot ($index.ToString() + '.bin')
            Copy-Item -LiteralPath $action.Target -Destination $action.Backup
            if ((Get-LanUpdateHash $action.Target) -ne (Get-LanUpdateHash $action.Backup)) { throw 'Sauvegarde de mise a jour invalide.' }
        }
    }
    try {
        foreach ($action in $actions) {
            $action.Applied = $true
            if ($action.Source) {
                $null = New-Item -ItemType Directory -Path (Split-Path $action.Target -Parent) -Force
                Copy-Item -LiteralPath $action.Source -Destination $action.Target -Force
                if ((Get-LanUpdateHash $action.Target) -ne (Get-LanUpdateHash $action.Source)) { throw 'Verification apres mise a jour echouee.' }
            } else { Remove-Item -LiteralPath $action.Target -Force }
        }
    } catch {
        $failure = $_
        try {
            foreach ($action in @($actions | Where-Object { $_.Applied })) {
                if ($action.Exists) {
                    if (-not (Test-Path -LiteralPath $action.Target -PathType Leaf) -or (Get-LanUpdateHash $action.Target) -ne (Get-LanUpdateHash $action.Backup)) {
                        Copy-Item -LiteralPath $action.Backup -Destination $action.Target -Force
                    }
                }
                elseif (Test-Path -LiteralPath $action.Target) { Remove-Item -LiteralPath $action.Target -Force }
                if ($action.Exists -and (Get-LanUpdateHash $action.Target) -ne (Get-LanUpdateHash $action.Backup)) { throw 'Restauration du paquet non verifiee.' }
            }
        } catch {
            $fatal = New-Object InvalidOperationException("Mise a jour et restauration interrompues. Sauvegardes : $backupRoot")
            $fatal.Data['UnsafePackage'] = $true
            throw $fatal
        }
        throw $failure
    }
}
function Invoke-LanPackageUpdate([string]$Root,[switch]$Force,[switch]$CheckOnly) {
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $manifestPath = Get-LanUpdatePath $Root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Manifest local SHA256SUMS.txt absent.' }
    $manifestHash = Get-LanUpdateHash $manifestPath
    $cachePath = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\update-check.json'
    if (-not $Force -and -not $CheckOnly -and (Test-Path -LiteralPath $cachePath)) {
        try {
            $cache = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
            $age = [DateTime]::UtcNow - [DateTime]::Parse($cache.checkedUtc).ToUniversalTime()
            if ($cache.manifestHash -eq $manifestHash -and $age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt 15) { return 'Cached' }
        } catch { Write-Verbose 'Cache de mise a jour invalide ignore.' }
    }
    if (@(Get-Process -Name 'ChainedTogether-Win64-Shipping' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host 'Fermez le jeu pour mettre a jour le lanceur.'
        return 'GameRunning'
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $lockName = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))).Replace('-','') }
    finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false,('Local\ChainedTogetherUpdate-' + $lockName))
    $owned = $false
    $stage = $null
    $keepStage = $false
    $commit = ''
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Une autre mise a jour est en cours.' }
        $commit = Get-LanUpdateCommit
        $stageName = '.lan-update-' + [Guid]::NewGuid().ToString('N')
        $stage = Join-Path $Root $stageName
        $null = New-Item -ItemType Directory -Path $stage
        $remoteManifest = Join-Path $stage 'SHA256SUMS.txt'
        Get-LanRemoteUpdateFile $commit 'SHA256SUMS.txt' $remoteManifest
        $newEntries = Read-LanUpdateManifest ([IO.File]::ReadAllText($remoteManifest)) $Root
        $oldEntries = Read-LanUpdateManifest ([IO.File]::ReadAllText($manifestPath)) $Root
        foreach ($required in @('launcher-version.txt','Launch-LAN.ps1','Start-ChainedTogether-LAN.ps1','Update-LAN.ps1','Player-Names.ps1','Game-Paths.ps1','payload/steam_api64.dll','payload/provenance.json')) {
            if (-not $newEntries.ContainsKey($required)) { throw "Paquet distant incomplet : $required" }
        }
        if ((Get-LanUpdateHash $remoteManifest) -eq $manifestHash) {
            if (-not $CheckOnly) { Save-LanUpdateCheck $manifestHash $commit 'Current' }
            return 'Current'
        }
        if ($CheckOnly) { Write-Host "Mise a jour disponible : $($commit.Substring(0,7))."; return 'Available' }
        Write-Host "Mise a jour du lanceur depuis GitHub ($($commit.Substring(0,7)))..."
        $downloadedBytes = 0L
        foreach ($name in @($newEntries.Keys | Sort-Object)) {
            $local = Get-LanUpdatePath $Root $name
            if ((Test-Path -LiteralPath $local -PathType Leaf) -and (Get-LanUpdateHash $local) -eq $newEntries[$name]) { continue }
            $destination = Get-LanUpdatePath $stage $name
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Get-LanRemoteUpdateFile $commit $name $destination
            if ((Get-LanUpdateHash $destination) -ne $newEntries[$name]) { throw "SHA256 distant incorrect : $name" }
            $downloadedBytes += (Get-Item -LiteralPath $destination).Length
            if ($downloadedBytes -gt 52428800) { throw 'Paquet de mise a jour trop volumineux.' }
        }
        Install-LanPackageUpdate $Root $stage $oldEntries $newEntries $remoteManifest
        Save-LanUpdateCheck (Get-LanUpdateHash $manifestPath) $commit 'Updated'
        Write-Host 'Lanceur mis a jour. Pseudos, preferences et fichiers du jeu conserves.'
        return 'Updated'
    } catch {
        if ($_.Exception.Data['UnsafePackage']) { $keepStage = $true; throw }
        if ($owned -and -not $CheckOnly) { try { Save-LanUpdateCheck $manifestHash $commit 'Unavailable' } catch { } }
        throw
    } finally {
        if ($stage -and -not $keepStage -and (Test-Path -LiteralPath $stage)) {
            $resolved = (Resolve-Path -LiteralPath $stage).Path
            if (-not $resolved.StartsWith($Root + '\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^\.lan-update-[a-f0-9]{32}$') { throw 'Nettoyage de mise a jour hors paquet refuse.' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($FunctionsOnly) { return }
try {
    $result = Invoke-LanPackageUpdate $PackageRoot -Force:$Force -CheckOnly:$CheckOnly
    if (-not $Automatic -and $result -in @('Current','Cached')) { Write-Host 'Le lanceur est a jour.' }
    exit 0
} catch {
    if ($_.Exception.Data['UnsafePackage']) { Write-Error $_ -ErrorAction Continue; exit 2 }
    if ($Automatic) {
        Write-Warning 'Verification GitHub indisponible ou mise a jour refusee. La version locale reste utilisable ; details avec Mettre-A-Jour.cmd.'
        exit 0
    }
    Write-Error $_ -ErrorAction Continue
    Write-Host 'Pour un depot prive, utilisez un acces de lecture dans CHAINED_LAN_GITHUB_TOKEN. Ne partagez jamais ce jeton dans le paquet.'
    exit 1
}
