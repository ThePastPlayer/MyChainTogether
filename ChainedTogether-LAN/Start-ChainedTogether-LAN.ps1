#requires -Version 5.1
<#
  Goldberg LAN launcher. It never downloads or bypasses antivirus.
  Upstream source: Detanup01/gbe_fork post_build/README.release.md and
  post_build/steam_settings.EXAMPLE/configs.{main,user}.EXAMPLE.ini.
  offline=0 preserves BLoggedOn(); this setting does not require Internet.
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$SteamDllPath,
    [ValidatePattern('^[^\r\n=\[\];#]{1,48}$')][string]$PlayerName,
    [switch]$AskPlayerName,
    [string[]]$PeerIP = @(),
    [ValidateSet('Manual','Host','Join')][string]$Role = 'Manual',
    [switch]$PrepareOnly,
    [switch]$Diagnose,
    [switch]$Restore,
    [switch]$Interactive,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PackageRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Game-Paths.ps1')
. (Join-Path $PSScriptRoot 'Player-Names.ps1')
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:MenuRelativePaths = @(
    'ChainedTogether\Content\Paks\CTLAN-AutoMenu_Host_P.pak',
    'ChainedTogether\Content\Paks\CTLAN-AutoMenu_Join_P.pak'
)

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Write-Utf8([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}
function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = $Path + '.new'
    Write-Utf8 $temporary ($Value | ConvertTo-Json -Depth 12)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-CanonicalPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}
function Get-ContainedPath([string]$Root, [string]$Relative) {
    if ([System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Chemin relatif invalide dans la configuration : $Relative"
    }
    $full = Get-CanonicalPath (Join-Path $Root $Relative)
    if (-not $full.StartsWith((Get-CanonicalPath $Root) + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Le chemin sort du dossier du jeu : $Relative"
    }
    # Do not write through junctions/symlinks to an unexpected location.
    $cursor = $full
    while ($cursor -and $cursor.Length -ge $Root.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Lien/jonction non pris en charge : $cursor"
            }
        }
        if ($cursor.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [System.IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Get-RelativePath([string]$Root, [string]$Path) {
    $full = Get-CanonicalPath $Path
    if (-not $full.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin hors du jeu.' }
    return $full.Substring($Root.Length + 1)
}
function Assert-Amd64Pe([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Fichier PE invalide : $Path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -gt ($stream.Length - 6)) { throw "En-tete PE invalide : $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Un executable/DLL Windows x64 est requis : $Path"
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Resolve-Game([string]$RequestedPath,[switch]$AllowSelection) {
    $installation = Resolve-LanGameInstallation $RequestedPath $script:PackageRoot -AllowSelection:$AllowSelection
    $root = $installation.Root
    $exe = $installation.Exe
    $exe = Get-ContainedPath $root (Get-RelativePath $root $exe)
    Assert-Amd64Pe $exe
    $dlls = @(Get-ChildItem -LiteralPath $root -Filter steam_api64.dll -Recurse -File | Where-Object {
        $_.FullName -notlike "$root\.chained-lan\*"
    } | ForEach-Object { Get-ContainedPath $root (Get-RelativePath $root $_.FullName) })
    if ($dlls.Count -eq 0) { throw 'steam_api64.dll absent. Installation incomplete ou version non prise en charge.' }
    foreach ($dll in $dlls) { Assert-Amd64Pe $dll }
    return [pscustomobject]@{ Root=$root; Exe=$exe; Dlls=$dlls }
}
function Select-TargetDlls($Game, [string]$ExplicitPath) {
    if ($ExplicitPath) {
        if ([System.IO.Path]::IsPathRooted($ExplicitPath)) {
            $relative = Get-RelativePath $Game.Root $ExplicitPath
        } else { $relative = $ExplicitPath }
        $explicit = Get-ContainedPath $Game.Root $relative
        if ($Game.Dlls -notcontains $explicit) { throw "-SteamDllPath doit designer une steam_api64.dll presente dans ce jeu : $ExplicitPath" }
        return @($explicit)
    }
    if ($Game.Dlls.Count -eq 1) { return @($Game.Dlls) }
    $layoutPath = Join-Path $script:PackageRoot 'game-layout.json'
    if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) {
        throw ('Plusieurs steam_api64.dll detectees. Aucun remplacement automatique : ' + ($Game.Dlls -join '; ') + '. Une configuration game-layout.json issue de l''analyse est requise.')
    }
    $layout = [IO.File]::ReadAllText($layoutPath) | ConvertFrom-Json
    if (-not $layout.PSObject.Properties['steamDllRelativePaths'] -or @($layout.steamDllRelativePaths).Count -eq 0) {
        throw 'game-layout.json doit contenir steamDllRelativePaths.'
    }
    $selected = @(Get-LanUniqueGamePaths @($layout.steamDllRelativePaths | ForEach-Object { Get-ContainedPath $Game.Root ([string]$_) }))
    foreach ($dll in $selected) {
        if ($Game.Dlls -notcontains $dll) { throw "La DLL analysee n'existe pas dans cette installation : $dll" }
    }
    if (-not $layout.PSObject.Properties['evidence'] -or -not [string]$layout.evidence) { throw 'game-layout.json doit documenter la preuve de selection (evidence).' }
    return $selected
}
function Get-VerifiedPayload {
    $dll = Join-Path $script:PackageRoot 'payload\steam_api64.dll'
    $provenancePath = Join-Path $script:PackageRoot 'payload\provenance.json'
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf) -or -not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        throw 'Payload Goldberg absent. Rien ne sera telecharge, installe ou lance. Le paquet doit contenir payload\steam_api64.dll et sa provenance SHA256 verifiee.'
    }
    $provenance = [IO.File]::ReadAllText($provenancePath) | ConvertFrom-Json
    foreach ($field in @('sha256','sourceUrl','releaseTag')) {
        if (-not $provenance.PSObject.Properties[$field] -or -not [string]$provenance.$field) { throw "Provenance incomplete : $field" }
    }
    if ([string]$provenance.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-Sha256 $dll) -ne ([string]$provenance.sha256).ToLowerInvariant()) {
        throw 'Le SHA256 du payload ne correspond pas a sa provenance. Arret sans modification.'
    }
    Assert-Amd64Pe $dll
    return [pscustomobject]@{ Path=$dll; Provenance=$provenance }
}
function Get-VerifiedMenuPayload($Game, [string]$RequestedRole) {
    if ($RequestedRole -eq 'Manual') { return $null }
    $menuRoot = Join-Path $script:PackageRoot 'payload\menu'
    $provenancePath = Join-Path $menuRoot 'menu-provenance.json'
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        throw 'Module de menu automatique absent. Utilisez -Role Manual ou un paquet contenant payload\menu verifie. Aucun fichier du jeu ne sera modifie.'
    }
    $provenance = [IO.File]::ReadAllText($provenancePath) | ConvertFrom-Json
    if (-not $provenance.PSObject.Properties['schemaVersion'] -or $provenance.schemaVersion -ne 1 -or
        -not $provenance.PSObject.Properties['gameExeSha256'] -or
        [string]$provenance.gameExeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        -not $provenance.PSObject.Properties['gameBuildId'] -or -not [string]$provenance.gameBuildId -or
        -not $provenance.PSObject.Properties['files']) {
        throw 'Provenance du module menu incomplete ou invalide.'
    }
    if ((Get-Sha256 $Game.Exe) -ne ([string]$provenance.gameExeSha256).ToLowerInvariant()) {
        throw 'Cette version du jeu ne correspond pas au module menu analyse. Utilisez -Role Manual ; aucun fichier ne sera modifie.'
    }
    # A game update can change packaged Blueprint assets without changing the EXE.
    # Use the Steam build when available, otherwise verify the actual game content.
    $commonDirectory = [System.IO.Path]::GetDirectoryName($Game.Root)
    $steamAppsDirectory = [System.IO.Path]::GetDirectoryName($commonDirectory)
    $manifestPath = if ($steamAppsDirectory) { Join-Path $steamAppsDirectory 'appmanifest_2567870.acf' } else { $null }
    $hasSteamManifest = [IO.Path]::GetFileName($commonDirectory) -eq 'common' -and
        [IO.Path]::GetFileName($steamAppsDirectory) -eq 'steamapps' -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    if ($hasSteamManifest) {
        $steamManifest = [System.IO.File]::ReadAllText($manifestPath)
        $appId = [regex]::Match($steamManifest, '"appid"\s+"(\d+)"')
        $installDirectory = [regex]::Match($steamManifest, '"installdir"\s+"([^"\r\n]+)"')
        $buildId = [regex]::Match($steamManifest, '"buildid"\s+"(\d+)"')
        if (-not $appId.Success -or $appId.Groups[1].Value -ne '2567870' -or
            -not $installDirectory.Success -or
            -not $installDirectory.Groups[1].Value.Equals([IO.Path]::GetFileName($Game.Root),[StringComparison]::OrdinalIgnoreCase) -or
            -not $buildId.Success) {
            throw 'Manifest Steam incoherent ou incomplet pour cette installation. Utilisez -Role Manual ; aucun fichier ne sera modifie.'
        }
        if ($buildId.Groups[1].Value -ne [string]$provenance.gameBuildId) {
            throw "Build Steam $($buildId.Groups[1].Value) different du build menu analyse $($provenance.gameBuildId). Utilisez -Role Manual ; aucun fichier ne sera modifie."
        }
    } else {
        if (-not $provenance.PSObject.Properties['gameContentFiles'] -or @($provenance.gameContentFiles).Count -eq 0) {
            throw 'Installation trouvee, mais version des menus inverifiable sans manifeste ni empreintes du contenu. Utilisez -Role Manual.'
        }
        Write-Host 'Installation sans manifeste Steam : verification SHA256 du contenu du jeu. Cela peut prendre quelques minutes...'
        foreach ($contentFile in @($provenance.gameContentFiles)) {
            if (-not $contentFile.PSObject.Properties['relative'] -or -not $contentFile.PSObject.Properties['sha256'] -or
                -not $contentFile.PSObject.Properties['size'] -or [long]$contentFile.size -le 0 -or
                [string]$contentFile.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Empreinte du contenu du jeu invalide dans la provenance.' }
            $contentPath = Get-ContainedPath $Game.Root ([string]$contentFile.relative)
            if (-not (Test-Path -LiteralPath $contentPath -PathType Leaf) -or
                (Get-Item -LiteralPath $contentPath).Length -ne [long]$contentFile.size -or
                (Get-Sha256 $contentPath) -ne ([string]$contentFile.sha256).ToLowerInvariant()) {
                throw 'Le contenu du jeu ne correspond pas aux menus de ce paquet. Utilisez la meme version sur les deux PC ou -Role Manual ; aucun fichier ne sera modifie.'
            }
        }
    }
    foreach ($variant in @('Host','Join')) {
        $metadata = $provenance.files.PSObject.Properties[$variant]
        $path = Join-Path $menuRoot ($variant + '.pak')
        if (-not $metadata -or -not $metadata.Value.PSObject.Properties['sha256'] -or
            [string]$metadata.Value.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Sha256 $path) -ne ([string]$metadata.Value.sha256).ToLowerInvariant()) {
            throw "Module menu $variant absent ou SHA256 incorrect. Aucun fichier du jeu ne sera modifie."
        }
    }
    $relative = if ($RequestedRole -eq 'Host') { $script:MenuRelativePaths[0] } else { $script:MenuRelativePaths[1] }
    return [pscustomobject]@{ Path=(Join-Path $menuRoot ($RequestedRole + '.pak')); Relative=$relative;
        Sha256=([string]$provenance.files.$RequestedRole.sha256).ToLowerInvariant(); Provenance=$provenance }
}
function Get-RolePreference {
    $path = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\launcher-preferences.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'Manual' }
    $preference = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if (-not $preference.PSObject.Properties['schemaVersion'] -or $preference.schemaVersion -ne 1 -or
        -not $preference.PSObject.Properties['lastRole'] -or [string]$preference.lastRole -notin @('Manual','Host','Join')) {
        throw "Preference de role invalide : $path"
    }
    return [string]$preference.lastRole
}
function Save-RolePreference([string]$SelectedRole) {
    $directory = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Write-JsonAtomic (Join-Path $directory 'launcher-preferences.json') ([pscustomobject]@{
        schemaVersion=1; lastRole=$SelectedRole; updatedUtc=[DateTime]::UtcNow.ToString('o')
    })
}
function Assert-MenuFilesOwned($Game, $Manifest) {
    foreach ($relative in $script:MenuRelativePaths) {
        $target = Get-ContainedPath $Game.Root $relative
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $entry = $null
        if ($Manifest) { $entry = @($Manifest.entries | Where-Object { $_.relative -eq $relative } | Select-Object -First 1) }
        if (-not $entry -or -not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-Sha256 $target) -ne $entry[0].installedSha256) {
            throw "Module menu existant non reconnu par la sauvegarde : $target. Aucun remplacement ou retrait automatique."
        }
    }
}
function Assert-PeerIps([string[]]$Ips) {
    foreach ($ip in $Ips) {
        $parsed = $null
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
            -not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed) -or
            $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Adresse IPv4 invalide : $ip"
        }
        $bytes = $parsed.GetAddressBytes()
        if (-not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254))) {
            throw "L'adresse du partenaire doit appartenir au LAN prive : $ip"
        }
    }
}
function Get-Identity {
    $identityRoot = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN'
    $identityPath = Join-Path $identityRoot 'identity.json'
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        $identity = [IO.File]::ReadAllText($identityPath) | ConvertFrom-Json
        $id = [UInt64]0
        if (-not $identity.PSObject.Properties['steamId'] -or -not [UInt64]::TryParse([string]$identity.steamId, [ref]$id) -or
            $id -le [UInt64]76561197960265728 -or $id -ge [UInt64]76561202255233023) {
            throw "Identite locale invalide : $identityPath"
        }
        return $identity
    }
    $buffer = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    $accountId = [BitConverter]::ToUInt32($buffer, 0)
    if ($accountId -eq 0 -or $accountId -eq [UInt32]::MaxValue) { $accountId = [UInt32]1234567 }
    $identity = [pscustomobject]@{ steamId=([UInt64]76561197960265728 + [UInt64]$accountId).ToString(); createdUtc=[DateTime]::UtcNow.ToString('o') }
    New-Item -ItemType Directory -Path $identityRoot -Force | Out-Null
    Write-JsonAtomic $identityPath $identity
    return $identity
}
function Get-Interfaces([string]$OriginalDll) {
    # Matches the upstream generate_interfaces.cpp, including its SteamClient017 special case.
    $patterns = @('STEAMAPPS_INTERFACE_VERSION\d+','SteamApps\d+','STEAMAPPLIST_INTERFACE_VERSION\d+',
        'STEAMAPPTICKET_INTERFACE_VERSION\d+','SteamClient\d+','STEAMCONTROLLER_INTERFACE_VERSION','SteamController\d+',
        'SteamFriends\d+','SteamGameServerStats\d+','SteamGameCoordinator\d+','SteamGameServer\d+',
        'STEAMHTMLSURFACE_INTERFACE_VERSION_\d+','STEAMHTTP_INTERFACE_VERSION\d+','SteamInput\d+',
        'STEAMINVENTORY_INTERFACE_V\d+','SteamMatchMakingServers\d+','SteamMatchMaking\d+','SteamMatchGameSearch\d+',
        'SteamParties\d+','STEAMMUSIC_INTERFACE_VERSION\d+','STEAMMUSICREMOTE_INTERFACE_VERSION\d+',
        'SteamNetworkingMessages\d+','SteamNetworkingSockets\d+','SteamNetworkingUtils\d+','SteamNetworking\d+',
        'STEAMPARENTALSETTINGS_INTERFACE_VERSION\d+','STEAMREMOTEPLAY_INTERFACE_VERSION\d+',
        'STEAMREMOTESTORAGE_INTERFACE_VERSION\d+','STEAMSCREENSHOTS_INTERFACE_VERSION\d+','STEAMTIMELINE_INTERFACE_V\d+',
        'STEAMUGC_INTERFACE_VERSION\d+','SteamUser\d+','STEAMUSERSTATS_INTERFACE_VERSION\d+','SteamUtils\d+',
        'STEAMVIDEO_INTERFACE_V\d+','STEAMUNIFIEDMESSAGES_INTERFACE_VERSION\d+','SteamMasterServerUpdater\d+')
    $binaryText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($OriginalDll))
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pattern in $patterns) {
        $matched = @([regex]::Matches($binaryText, $pattern) | ForEach-Object { $_.Value })
        if ($pattern -eq 'SteamClient\d+' -and $matched.Count -gt 1 -and $matched -contains 'SteamClient017') {
            $matched = @($matched | Where-Object { $_ -eq 'SteamClient017' })
        }
        foreach ($value in $matched) { $values.Add($value) }
    }
    if ($values.Count -eq 0) { throw "Aucune interface Steam trouvee dans la DLL d'origine : $OriginalDll" }
    return (($values | Select-Object -Unique) -join "`n") + "`n"
}
function Assert-GameStopped($Game) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Game.Exe)
    foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = $process.Path } catch { }
        if (-not $processPath -or $processPath.Equals($Game.Exe, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fermez Chained Together avant de preparer ou restaurer les fichiers.'
        }
    }
}
function Read-Manifest([string]$StateRoot, [string]$GameRoot) {
    $path = Join-Path $StateRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or -not ([string]$manifest.gameRoot).Equals($GameRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'La sauvegarde LAN appartient a une autre installation ou version de format.'
    }
    foreach ($entry in @($manifest.entries)) {
        $null = Get-ContainedPath $GameRoot ([string]$entry.relative)
        $backup = Get-ContainedPath $StateRoot ([string]$entry.backupRelative)
        if ($entry.originalExists -and (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Sha256 $backup) -ne $entry.originalSha256)) {
            throw "Sauvegarde originale absente ou alteree : $($entry.relative)"
        }
    }
    return $manifest
}
function Assert-InstalledHashes($Manifest, [string]$GameRoot) {
    foreach ($entry in @($Manifest.entries)) {
        $target = Get-ContainedPath $GameRoot ([string]$entry.relative)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-Sha256 $target) -ne $entry.installedSha256) {
            throw "Fichier modifie depuis la preparation LAN : $($entry.relative). Restauration/relancement refuse pour proteger vos changements."
        }
    }
}
function Restore-Manifest($Manifest, [string]$StateRoot, [string]$GameRoot, [switch]$Rollback) {
    if (-not $Rollback) { Assert-InstalledHashes $Manifest $GameRoot }
    $restoreEntries = @($Manifest.entries)
    if ($Rollback) {
        $restoreEntries = @($restoreEntries | Where-Object { $_.applyStarted })
        foreach ($entry in $restoreEntries) {
            $target = Get-ContainedPath $GameRoot ([string]$entry.relative)
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $hash = Get-Sha256 $target
                if ($hash -ne $entry.installedSha256 -and (-not $entry.originalExists -or $hash -ne $entry.originalSha256)) {
                    throw "Fichier change pendant preparation : $target. Rollback refuse pour proteger ce changement."
                }
            }
        }
    }
    # Check rollback sources before beginning any restoration writes.
    foreach ($entry in $restoreEntries) {
        $stage = Get-ContainedPath $StateRoot ([string]$entry.stageRelative)
        if (-not (Test-Path -LiteralPath $stage -PathType Leaf) -or (Get-Sha256 $stage) -ne $entry.installedSha256) {
            throw "Copie de recuperation LAN absente ou alteree : $($entry.relative)"
        }
    }
    $restored = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in $restoreEntries) {
            $target = Get-ContainedPath $GameRoot ([string]$entry.relative)
            $backup = Get-ContainedPath $StateRoot ([string]$entry.backupRelative)
            if ($entry.originalExists) {
                Copy-Item -LiteralPath $backup -Destination $target -Force
                $restored.Add($entry)
                if ((Get-Sha256 $target) -ne $entry.originalSha256) { throw "Verification de restauration echouee : $target" }
            } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force
                $restored.Add($entry)
            }
        }
    } catch {
        $restoreFailure = $_
        if (-not $Rollback) {
            foreach ($entry in $restored) {
                $target = Get-ContainedPath $GameRoot ([string]$entry.relative)
                Copy-Item -LiteralPath (Get-ContainedPath $StateRoot ([string]$entry.stageRelative)) -Destination $target -Force
                if ((Get-Sha256 $target) -ne $entry.installedSha256) { throw "Echec de restauration et recuperation LAN : $target. Sauvegardes dans $StateRoot" }
            }
        }
        throw $restoreFailure
    }
    foreach ($relative in (@($Manifest.createdDirectories) | Sort-Object Length -Descending)) {
        $directory = Get-ContainedPath $GameRoot ([string]$relative)
        if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    $Manifest.status = 'Restored'
    Write-JsonAtomic (Join-Path $StateRoot 'manifest.json') $Manifest
}
function Install-Lan($Game, [string[]]$Dlls, $Payload, $Identity, [string]$Name, [string[]]$Peers, [string]$StateRoot, [string]$SelectedRole, $MenuPayload) {
    $existing = Read-Manifest $StateRoot $Game.Root
    Assert-MenuFilesOwned $Game $(if ($existing -and $existing.status -eq 'Prepared') { $existing } else { $null })
    if ($existing -and $existing.status -eq 'Prepared') {
        Assert-InstalledHashes $existing $Game.Root
        $requestedDlls = @($Dlls | ForEach-Object { Get-RelativePath $Game.Root $_ })
        if (-not $existing.PSObject.Properties['dllRelativePaths'] -or
            (@($existing.dllRelativePaths) -join '|') -ne ($requestedDlls -join '|')) {
            throw 'Selection DLL differente de la preparation existante. Restaurez avant de changer de DLL.'
        }
        if ($existing.payloadSha256 -ne $Payload.Provenance.sha256.ToLowerInvariant()) { throw 'Payload different : restaurez avant de changer de version.' }
        if ((@($existing.peerIPs) -join ',') -ne ($Peers -join ',')) {
            throw 'Adresses differentes de la preparation existante. Utilisez -Restore avant de changer ces options.'
        }
        if ($existing.steamId -ne $Identity.steamId) { throw 'Identite locale changee. Restaurez avant de preparer a nouveau.' }
        $previousRole = if ($existing.PSObject.Properties['menuRole']) { [string]$existing.menuRole } else { 'Manual' }
        if ($previousRole -eq $SelectedRole) {
            if ($MenuPayload -and (-not $existing.PSObject.Properties['menuPakSha256'] -or
                $existing.menuPakSha256 -ne $MenuPayload.Sha256)) { throw 'Module menu different : restaurez avant de changer sa version.' }
            if ($existing.playerName -ceq $Name) { return $existing }
        }
        # A role or nickname change restores verified entries before a new transaction.
        # Previous transaction backups remain available beneath .chained-lan.
        Restore-Manifest $existing $StateRoot $Game.Root
        $existing = $null
    }
    if ($existing -and $existing.status -eq 'Preparing') { throw 'Preparation interrompue : recuperation manuelle requise depuis .chained-lan avant toute modification.' }
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $transaction = [Guid]::NewGuid().ToString('N')
    $backupRoot = Join-Path $StateRoot (Join-Path 'backups' $transaction)
    $stageRoot = Join-Path $StateRoot (Join-Path 'staging' $transaction)
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $files = New-Object 'System.Collections.Generic.List[object]'
    $createdDirectories = New-Object 'System.Collections.Generic.List[string]'
    $main = "[main::connectivity]`ndisable_networking=0`ndisable_lobby_creation=0`nlisten_port=47584`noffline=0`n"
    $user = "[user::general]`naccount_name=$Name`naccount_steamid=$($Identity.steamId)`nlanguage=french`n"
    foreach ($dll in $Dlls) {
        $relative = Get-RelativePath $Game.Root $dll
        $files.Add([pscustomobject]@{ Relative=$relative; Source=$Payload.Path; Content=$null })
        $settingsDirectory = Join-Path ([System.IO.Path]::GetDirectoryName($dll)) 'steam_settings'
        if (-not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) { $createdDirectories.Add((Get-RelativePath $Game.Root $settingsDirectory)) }
        $interfaceText = Get-Interfaces $dll
        $configuration = [ordered]@{ 'configs.main.ini'=$main; 'configs.user.ini'=$user; 'steam_appid.txt'="2567870`n"; 'steam_interfaces.txt'=$interfaceText; 'custom_broadcasts.txt'=(($Peers -join "`n") + "`n") }
        foreach ($configName in $configuration.Keys) {
            $files.Add([pscustomobject]@{ Relative=(Get-RelativePath $Game.Root (Join-Path $settingsDirectory $configName)); Source=$null; Content=$configuration[$configName] })
        }
    }
    if ($MenuPayload) {
        $files.Add([pscustomobject]@{ Relative=$MenuPayload.Relative; Source=$MenuPayload.Path; Content=$null })
        $directory = [System.IO.Path]::GetDirectoryName((Get-ContainedPath $Game.Root $MenuPayload.Relative))
        while (-not (Test-Path -LiteralPath $directory -PathType Container) -and
            -not $directory.Equals($Game.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $createdDirectories.Add((Get-RelativePath $Game.Root $directory))
            $directory = [System.IO.Path]::GetDirectoryName($directory)
        }
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    foreach ($file in $files) {
        $target = Get-ContainedPath $Game.Root $file.Relative
        $index++
        $stagePath = Join-Path $stageRoot "$index.bin"
        if ($file.Source) { Copy-Item -LiteralPath $file.Source -Destination $stagePath } else { Write-Utf8 $stagePath $file.Content }
        $backupPath = Join-Path $backupRoot "$index.bin"
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        $originalHash = $null
        if ($exists) {
            $originalHash = Get-Sha256 $target
            Copy-Item -LiteralPath $target -Destination $backupPath
            if ((Get-Sha256 $backupPath) -ne $originalHash) { throw "Sauvegarde non conforme : $target" }
        } elseif (Test-Path -LiteralPath $target) { throw "Le fichier cible est un dossier : $target" }
        $entries.Add([pscustomobject]@{ relative=$file.Relative; originalExists=$exists; originalSha256=$originalHash;
            installedSha256=(Get-Sha256 $stagePath); backupRelative=(Get-RelativePath $StateRoot $backupPath); stageRelative=(Get-RelativePath $StateRoot $stagePath); applyStarted=$false })
    }
    $manifest = [pscustomobject]@{ schemaVersion=1; gameRoot=$Game.Root; launchExe=$Game.Exe; status='Preparing';
        createdUtc=[DateTime]::UtcNow.ToString('o'); payloadSha256=$Payload.Provenance.sha256.ToLowerInvariant();
        provenance=$Payload.Provenance; playerName=$Name; steamId=$Identity.steamId; peerIPs=@($Peers);
        menuRole=$SelectedRole; menuPakSha256=$(if ($MenuPayload) { $MenuPayload.Sha256 } else { $null });
        menuProvenance=$(if ($MenuPayload) { $MenuPayload.Provenance } else { $null });
        dllRelativePaths=@($Dlls | ForEach-Object { Get-RelativePath $Game.Root $_ });
        createdDirectories=$createdDirectories.ToArray(); entries=$entries.ToArray() }
    Write-JsonAtomic (Join-Path $StateRoot 'manifest.json') $manifest
    try {
        foreach ($entry in $entries) {
            $target = Get-ContainedPath $Game.Root $entry.relative
            if ($entry.originalExists -and (Get-Sha256 $target) -ne $entry.originalSha256) { throw "Fichier modifie pendant preparation : $target" }
            if (-not $entry.originalExists -and (Test-Path -LiteralPath $target)) { throw "Fichier apparu pendant preparation : $target" }
            New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            $entry.applyStarted = $true
            Copy-Item -LiteralPath (Get-ContainedPath $StateRoot $entry.stageRelative) -Destination $target -Force
            if ((Get-Sha256 $target) -ne $entry.installedSha256) { throw "Copie non conforme : $target" }
        }
        $manifest.status = 'Prepared'
        Write-JsonAtomic (Join-Path $StateRoot 'manifest.json') $manifest
        return $manifest
    } catch {
        $initialFailure = $_
        try { Restore-Manifest $manifest $StateRoot $Game.Root -Rollback } catch { throw "Echec de preparation ET rollback : $initialFailure ; $_. Sauvegardes : $backupRoot" }
        throw "Preparation annulee, fichiers originaux restaures : $initialFailure"
    }
}

$mutex = $null
$mutexOwned = $false
$transcriptStarted = $false
try {
    if ($LogPath) {
        try { $null = Start-Transcript -LiteralPath $LogPath -Force; $transcriptStarted = $true }
        catch { Write-Warning "Journal impossible a creer : $LogPath" }
    }
    $versionPath = Join-Path $script:PackageRoot 'launcher-version.txt'
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) { Write-Host ('Lanceur LAN : ' + [IO.File]::ReadAllText($versionPath).Trim()) }
    if ($PrepareOnly -and ($Diagnose -or $Restore)) { throw '-PrepareOnly ne peut pas etre combine avec -Diagnose ou -Restore.' }
    if (-not $PSBoundParameters.ContainsKey('Role') -and -not $PrepareOnly -and -not $Diagnose -and -not $Restore) {
        $Role = Get-RolePreference
    }
    Assert-PeerIps $PeerIP
    $game = Resolve-Game $GamePath -AllowSelection:($Interactive -and -not $Diagnose)
    $stateRoot = Join-Path $game.Root '.chained-lan'
    if ($Diagnose) {
        Write-Host "Jeu : $($game.Root)"
        Write-Host "Executable : $($game.Exe)"
        Write-Host ('DLL Steam detectees : ' + $game.Dlls.Count)
        foreach ($dll in $game.Dlls) { Write-Host ((Get-RelativePath $game.Root $dll) + ' SHA256=' + (Get-Sha256 $dll)) }
        $manifest = Read-Manifest $stateRoot $game.Root
        if ($manifest) { Write-Host "Etat LAN : $($manifest.status)" } else { Write-Host 'Etat LAN : aucun fichier du jeu prepare' }
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' } |
                ForEach-Object { Write-Host "IPv4 locale : $($_.IPAddress) ($($_.InterfaceAlias))" }
        }
        $null = Get-VerifiedPayload
        if (-not $Restore) {
            $null = Select-TargetDlls $game $SteamDllPath
            $verifiedMenu = Get-VerifiedMenuPayload $game $Role
            if ($verifiedMenu) { Write-Host "Menu $Role : version du jeu et SHA256 verifies." }
        }
        Write-Host 'Payload local x64 et SHA256 verifie. Aucune modification ni lancement.'
        exit 0
    }
    Assert-GameStopped $game
    $pathHasher = [System.Security.Cryptography.SHA256]::Create()
    try { $lockId = [BitConverter]::ToString($pathHasher.ComputeHash($script:Utf8.GetBytes($game.Root.ToLowerInvariant()))).Replace('-','') } finally { $pathHasher.Dispose() }
    $mutex = New-Object System.Threading.Mutex($false, ('Local\ChainedTogetherLAN-' + $lockId))
    try { $mutexOwned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }
    if (-not $mutexOwned) { throw 'Une autre preparation/restauration LAN est en cours.' }
    if ($Restore) {
        $manifest = Read-Manifest $stateRoot $game.Root
        if (-not $manifest -or $manifest.status -eq 'Restored') { Write-Host 'Rien a restaurer.'; exit 0 }
        if ($manifest.status -ne 'Prepared') { throw 'Preparation interrompue. Recuperation manuelle requise : sauvegardes dans .chained-lan. Aucun fichier ne sera ecrase sans verification.' }
        Restore-Manifest $manifest $stateRoot $game.Root
        Write-Host 'Fichiers originaux restaures et SHA256 verifies. Les sauvegardes sont conservees dans .chained-lan.'
        exit 0
    }
    $dlls = @(Select-TargetDlls $game $SteamDllPath)
    $payload = Get-VerifiedPayload
    $menuPayload = Get-VerifiedMenuPayload $game $Role
    $previousManifest = Read-Manifest $stateRoot $game.Root
    Assert-MenuFilesOwned $game $(if ($previousManifest -and $previousManifest.status -eq 'Prepared') { $previousManifest } else { $null })
    if ($previousManifest -and $previousManifest.status -eq 'Prepared') {
        if (-not $PSBoundParameters.ContainsKey('PeerIP')) { $PeerIP = @($previousManifest.peerIPs | ForEach-Object { [string]$_ }) }
    }
    Assert-PeerIps $PeerIP
    $selectedName = Resolve-LanPlayerName $PlayerName -Explicit:($PSBoundParameters.ContainsKey('PlayerName')) -AllowPrompt:$Interactive -Ask:$AskPlayerName
    $PlayerName = $selectedName.Name
    Write-Host ("Pseudo LAN : $PlayerName (" + $selectedName.Source + ').')
    $identity = Get-Identity
    $null = Install-Lan $game $dlls $payload $identity $PlayerName @($PeerIP | Select-Object -Unique) $stateRoot $Role $menuPayload
    if ($selectedName.Source -eq 'Manual') { Save-LanPlayerName $PlayerName }
    if (-not $PrepareOnly) { Save-LanGameLocation $game.Root }
    Write-Host "LAN prepare : joueur=$PlayerName ; SteamID=$($identity.steamId) ; port=47584."
    if ($PrepareOnly) { Write-Host 'Preparation terminee. Jeu non lance.'; exit 0 }
    $previousAppId = [Environment]::GetEnvironmentVariable('SteamAppId','Process')
    $previousGameId = [Environment]::GetEnvironmentVariable('SteamGameId','Process')
    try {
        [Environment]::SetEnvironmentVariable('SteamAppId','2567870','Process')
        [Environment]::SetEnvironmentVariable('SteamGameId','2567870','Process')
        $launchedGame = Start-Process -FilePath $game.Exe -WorkingDirectory ([System.IO.Path]::GetDirectoryName($game.Exe)) -PassThru
    } finally {
        [Environment]::SetEnvironmentVariable('SteamAppId',$previousAppId,'Process')
        [Environment]::SetEnvironmentVariable('SteamGameId',$previousGameId,'Process')
    }
    Save-RolePreference $Role
    switch ($Role) {
        'Host' { Write-Host 'Jeu lance : ouverture automatique du menu de creation de partie.' }
        'Join' { Write-Host 'Jeu lance : ouverture automatique du menu pour rejoindre une partie.' }
        default { Write-Host 'Jeu lance. Creez une partie sur un PC, puis rejoignez-la depuis le menu du second PC.' }
    }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($mutexOwned -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($transcriptStarted) { $null = Stop-Transcript -ErrorAction SilentlyContinue; Write-Host "Journal : $LogPath" }
}
