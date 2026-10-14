#requires -Version 5.1
# Shared discovery for launching, joining, restoring and the firewall helper.
# This file only reads installation metadata; it never modifies the game.

function ConvertTo-LanGamePath([string]$Path) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expanded)
    $full = [IO.Path]::GetFullPath($resolved)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\','/') }
    return $full
}
function Get-LanUniqueGamePaths([string[]]$Paths) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if (-not $path) { continue }
        try { $canonical = ConvertTo-LanGamePath $path }
        catch { Write-Verbose "Chemin indisponible ignore : $path"; continue }
        if ($seen.Add($canonical)) { $canonical }
    }
}
function Get-LanSteamInstallRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $properties) { continue }
        foreach ($name in @('SteamPath','InstallPath')) {
            $property = $properties.PSObject.Properties[$name]
            if ($property -and $property.Value) { $roots.Add([string]$property.Value) }
        }
    }
    foreach ($programFiles in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) {
        if ($programFiles) { $roots.Add([IO.Path]::Combine($programFiles,'Steam')) }
    }
    Get-LanUniqueGamePaths $roots.ToArray()
}
function Get-LanGameInstallation([string]$Path) {
    $requested = ConvertTo-LanGamePath $Path
    if (-not (Test-Path -LiteralPath $requested)) { throw "Chemin du jeu introuvable : $requested" }
    $item = Get-Item -LiteralPath $requested -Force
    $exe = $null
    if (-not $item.PSIsContainer -and $item.Name -eq 'ChainedTogether-Win64-Shipping.exe') {
        $exe = $item.FullName
    } else {
        if ($item.PSIsContainer) { $directory = $item.FullName }
        elseif ($item.Name -eq 'ChainedTogether.exe') { $directory = $item.DirectoryName }
        else { throw '-GamePath doit designer le dossier du jeu ou un executable ChainedTogether.' }
        foreach ($relative in @('ChainedTogether\Binaries\Win64\ChainedTogether-Win64-Shipping.exe','ChainedTogether-Win64-Shipping.exe')) {
            $candidate = Join-Path $directory $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $exe = (Get-Item -LiteralPath $candidate -Force).FullName
                break
            }
        }
    }
    if (-not $exe) { throw "Executable ChainedTogether-Win64-Shipping.exe absent dans $requested. Terminez l'installation Steam." }
    $root = [IO.Path]::GetDirectoryName($exe)
    if ($root -match '\\ChainedTogether\\Binaries\\Win64$') {
        for ($level = 0; $level -lt 3; $level++) { $root = [IO.Path]::GetDirectoryName($root) }
    }
    return [pscustomobject]@{ Root=(ConvertTo-LanGamePath $root); Exe=(ConvertTo-LanGamePath $exe) }
}
function Get-LanSteamGameRoots {
    $libraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($steamRoot in @(Get-LanSteamInstallRoots)) {
        if (-not (Test-Path -LiteralPath $steamRoot -PathType Container)) { continue }
        $libraries.Add($steamRoot)
        foreach ($relative in @('steamapps\libraryfolders.vdf','config\libraryfolders.vdf')) {
            $vdf = Join-Path $steamRoot $relative
            if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
            try { $content = [IO.File]::ReadAllText($vdf) }
            catch { Write-Verbose "Bibliotheques Steam illisibles : $vdf"; continue }
            # Both modern "path" entries and legacy numbered path entries.
            foreach ($match in [regex]::Matches($content,'"(?:path|[0-9]+)"\s+"([^"\r\n]+)"')) {
                $library = $match.Groups[1].Value.Replace('\\','\')
                if ($library -match '^(?:[a-zA-Z]:[\\/]|\\\\)') { $libraries.Add($library) }
            }
        }
    }
    $games = New-Object 'System.Collections.Generic.List[string]'
    foreach ($library in @(Get-LanUniqueGamePaths $libraries.ToArray())) {
        if (-not (Test-Path -LiteralPath $library -PathType Container)) { continue }
        $manifest = Join-Path $library 'steamapps\appmanifest_2567870.acf'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        try { $content = [IO.File]::ReadAllText($manifest) }
        catch { Write-Verbose "Manifest Steam illisible : $manifest"; continue }
        $appId = [regex]::Match($content,'"appid"\s+"(\d+)"')
        $installDirectory = [regex]::Match($content,'"installdir"\s+"([^"\r\n]+)"')
        if (-not $appId.Success -or $appId.Groups[1].Value -ne '2567870' -or -not $installDirectory.Success) { continue }
        $name = $installDirectory.Groups[1].Value
        if ($name -in @('.','..') -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
        $candidate = Join-Path (Join-Path $library 'steamapps\common') $name
        try { $game = Get-LanGameInstallation $candidate }
        catch { Write-Verbose "Installation incomplete ignoree : $candidate"; continue }
        $games.Add($game.Root)
    }
    Get-LanUniqueGamePaths $games.ToArray()
}
function Get-LanDiskRoots {
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.IsReady -and $drive.DriveType -in @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)) { $drive.RootDirectory.FullName }
        } catch { Write-Verbose 'Disque inaccessible ignore.' }
    }
}
function Test-LanScannedGame($Game) {
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::OpenRead($Game.Exe)
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { return $false }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -gt $stream.Length - 6) { return $false }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { return $false }
    } catch { return $false }
    finally { if ($reader) { $reader.Dispose() }; if ($stream) { $stream.Dispose() } }
    $dlls = @(Get-ChildItem -LiteralPath $Game.Root -Filter 'steam_api64.dll' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$($Game.Root)\.chained-lan\*" } | Select-Object -First 1)
    return $dlls.Count -gt 0
}
function Search-LanGameDirectories([string[]]$Roots,[int]$TimeoutSeconds = 90) {
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in @(Get-LanUniqueGamePaths $Roots)) {
        if (Test-Path -LiteralPath $root -PathType Container) { $queue.Enqueue($root) }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastUpdate = -5
    try {
        while ($queue.Count -gt 0) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds -or $visited.Count -ge 150000) {
                Write-Warning 'La recherche a atteint sa limite. Vous pouvez choisir le dossier du jeu si aucune installation n''est trouvee.'
                break
            }
            $directory = $queue.Dequeue()
            if (-not $visited.Add($directory)) { continue }
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
            if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($clock.Elapsed.TotalSeconds - $lastUpdate -ge 5) {
                Write-Host ("Recherche du jeu : $($visited.Count) dossiers examines...")
                Write-Progress -Activity 'Recherche de Chained Together sur les disques' -Status $directory
                $lastUpdate = $clock.Elapsed.TotalSeconds
            }
            $exe = [IO.Path]::Combine($directory,'ChainedTogether-Win64-Shipping.exe')
            if ([IO.File]::Exists($exe)) {
                try {
                    $game = Get-LanGameInstallation $exe
                    if (Test-LanScannedGame $game) { $found.Add($game.Root) }
                }
                catch { Write-Verbose "Executable inutilisable ignore : $exe" }
            }
            foreach ($child in @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($child.Name -in @('Windows','$Recycle.Bin','System Volume Information','.git','.chained-lan','node_modules') -or
                    ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $queue.Enqueue($child.FullName)
            }
        }
    } finally { Write-Progress -Activity 'Recherche de Chained Together sur les disques' -Completed }
    Get-LanUniqueGamePaths $found.ToArray()
}
function Find-LanGameRoots([string]$PackageRoot) {
    $disks = @(Get-LanDiskRoots)
    $priority = New-Object 'System.Collections.Generic.List[string]'
    $priority.Add($PackageRoot)
    $parent = [IO.Path]::GetDirectoryName((ConvertTo-LanGamePath $PackageRoot))
    if ($parent) { $priority.Add($parent) }
    foreach ($disk in $disks) {
        foreach ($folder in @('SteamLibrary','Steam','Games','Jeux','Program Files (x86)\Steam','Program Files\Steam','Epic Games','XboxGames')) {
            $priority.Add([IO.Path]::Combine($disk,$folder))
        }
    }
    Write-Host 'Installation non declaree par Steam. Recherche des executables dans les dossiers de jeux...'
    $found = @(Search-LanGameDirectories $priority.ToArray() 30)
    if ($found.Count -gt 0) { return $found }
    Write-Host 'Recherche etendue aux disques locaux disponibles (90 secondes maximum)...'
    Search-LanGameDirectories $disks 90
}
function Select-LanGameInstallation([string[]]$Candidates) {
    if ($Candidates.Count -gt 1) {
        Write-Host 'Plusieurs installations du jeu sont disponibles :'
        for ($index = 0; $index -lt $Candidates.Count; $index++) { Write-Host ("[$($index + 1)] $($Candidates[$index])") }
        $choice = Read-Host 'Numero de l''installation a utiliser (ou Entree pour choisir un dossier)'
        $number = 0
        if ([int]::TryParse($choice,[ref]$number) -and $number -ge 1 -and $number -le $Candidates.Count) {
            return (Get-LanGameInstallation $Candidates[$number - 1])
        }
    }
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Choisissez le dossier du jeu contenant ChainedTogether.exe (pas le dossier du lanceur LAN).'
    $picker.ShowNewFolderButton = $false
    try {
        if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Selection annulee. Aucun fichier du jeu ne sera modifie.' }
        return (Get-LanGameInstallation $picker.SelectedPath)
    } finally { $picker.Dispose() }
}
function Save-LanGameLocation([string]$Root) {
    $directory = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $value = @{ schemaVersion=1; gamePath=$Root } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $directory 'game-location.json'),$value,(New-Object Text.UTF8Encoding($false)))
}
function Resolve-LanGameInstallation([string]$RequestedPath,[string]$PackageRoot,[switch]$AllowSelection) {
    # An explicit choice must never silently redirect to a different installation.
    if ($RequestedPath) { return (Get-LanGameInstallation $RequestedPath) }
    $settingsPath = Join-Path $PackageRoot 'launcher-settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            if ($settings -and $settings.PSObject.Properties['gamePath'] -and [string]$settings.gamePath) {
                $savedPath = [Environment]::ExpandEnvironmentVariables([string]$settings.gamePath)
                if (-not [IO.Path]::IsPathRooted($savedPath)) { $savedPath = Join-Path $PackageRoot $savedPath }
                return (Get-LanGameInstallation $savedPath)
            }
        } catch {
            Write-Warning 'Le chemin memorise est indisponible ou invalide. Recherche automatique dans les bibliotheques Steam de ce PC.'
        }
    }
    $localPath = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\game-location.json'
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        try {
            $local = [IO.File]::ReadAllText($localPath) | ConvertFrom-Json
            if ($local -and $local.PSObject.Properties['gamePath'] -and [string]$local.gamePath) {
                return (Get-LanGameInstallation ([string]$local.gamePath))
            }
        } catch { Write-Verbose 'Ancien chemin local ignore ; nouvelle recherche.' }
    }
    $found = @(Get-LanUniqueGamePaths @(Get-LanSteamGameRoots))
    if ($found.Count -eq 0) { $found = @(Find-LanGameRoots $PackageRoot) }
    if ($found.Count -ne 1 -and $AllowSelection) { return (Select-LanGameInstallation $found) }
    if ($found.Count -eq 0) { throw 'Chained Together introuvable apres recherche sur les disques. Indiquez son dossier avec -GamePath ou relancez le raccourci pour choisir son dossier.' }
    if ($found.Count -gt 1) { throw ('Plusieurs installations Chained Together detectees : ' + ($found -join '; ') + '. Choisissez le dossier avec -GamePath.') }
    return (Get-LanGameInstallation $found[0])
}
