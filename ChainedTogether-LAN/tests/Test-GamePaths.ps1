#requires -Version 5.1
# Isolated fixtures only. No game launch, real game writes or firewall changes.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$fixtureName = 'ChainedTogether-PathTests-' + [Guid]::NewGuid().ToString('N')
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot $fixtureName
$originalLocation = (Get-Location).Path
$originalLocalAppData = $env:LOCALAPPDATA
$script:PathChecks = 0
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:MenuRelativePaths = @('ChainedTogether\Content\Paks\CTLAN-AutoMenu_Host_P.pak','ChainedTogether\Content\Paks\CTLAN-AutoMenu_Join_P.pak')

function Assert-PathCheck([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ECHEC : $Message" }
    $script:PathChecks++
}
function Assert-PathRejected([scriptblock]$Action,[string]$Pattern) {
    $rejected = $false
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $rejected = $true
    }
    Assert-PathCheck $rejected "Le chemin devrait etre refuse : $Pattern"
}
function Write-FixtureText([string]$Path,[string]$Content) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [IO.File]::WriteAllText($Path,$Content,$script:Utf8)
}
function Write-FixtureJson([string]$Path,$Value) {
    Write-FixtureText $Path ($Value | ConvertTo-Json -Depth 8)
}
function New-FixtureGame([string]$Library,[bool]$Complete = $true) {
    $root = Join-Path $Library 'steamapps\common\ChainedTogether'
    $null = New-Item -ItemType Directory -Path $root -Force
    Write-FixtureText (Join-Path $Library 'steamapps\appmanifest_2567870.acf') '"AppState" { "appid" "2567870" "installdir" "ChainedTogether" "buildid" "42" }'
    $exe = Join-Path $root 'ChainedTogether\Binaries\Win64\ChainedTogether-Win64-Shipping.exe'
    $dll = Join-Path (Split-Path $exe -Parent) 'steam_api64.dll'
    if ($Complete) {
        $null = New-Item -ItemType Directory -Path (Split-Path $exe -Parent) -Force
        $pe = New-Object byte[] 256
        $pe[0] = 0x4d; $pe[1] = 0x5a; $pe[0x3c] = 0x80
        $pe[0x80] = 0x50; $pe[0x81] = 0x45; $pe[0x84] = 0x64; $pe[0x85] = 0x86
        [IO.File]::WriteAllBytes($exe,$pe)
        [IO.File]::WriteAllBytes($dll,$pe)
        Write-FixtureText (Join-Path $root 'ChainedTogether.exe') 'Fixture bootstrap, never executed.'
    }
    return [pscustomobject]@{ Root=$root; Exe=$exe; Dll=$dll }
}
function Write-FixtureLibraries([string[]]$Libraries,[switch]$Legacy) {
    $entries = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $Libraries.Count; $index++) {
        $escaped = $Libraries[$index].Replace('\','\\')
        if ($Legacy) { $entries.Add('"' + $index + '" "' + $escaped + '"') }
        else { $entries.Add('"' + $index + '" { "path" "' + $escaped + '" "apps" { "2567870" "12345" } }') }
    }
    foreach ($relative in @('steamapps\libraryfolders.vdf','config\libraryfolders.vdf')) {
        $path = Join-Path $script:FixtureSteamRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    $relative = if ($Legacy) { 'config\libraryfolders.vdf' } else { 'steamapps\libraryfolders.vdf' }
    Write-FixtureText (Join-Path $script:FixtureSteamRoot $relative) ('"libraryfolders" { ' + ($entries -join ' ') + ' }')
}
function Assert-BothResolvers([string]$Requested,$Expected) {
    $game = Resolve-Game $Requested
    Assert-PathCheck ($game.Root -eq $Expected.Root) 'Racine du lanceur incorrecte.'
    Assert-PathCheck ($game.Exe -eq $Expected.Exe) 'Executable du lanceur incorrect.'
    Assert-PathCheck ((Resolve-FirewallShippingExe $Requested) -eq $Expected.Exe) 'Executable du helper incorrect.'
}

try {
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'Local profile'
    $script:PackageRoot = Join-Path $fixtureRoot 'Portable package'
    $script:FixtureSteamRoot = Join-Path $fixtureRoot 'Steam'
    $libraryA = Join-Path $fixtureRoot 'Library One'
    $libraryB = Join-Path $fixtureRoot 'Library Two'
    $null = New-Item -ItemType Directory -Path $script:PackageRoot,$script:FixtureSteamRoot -Force
    $gameA = New-FixtureGame $libraryA
    $gameB = New-FixtureGame $libraryB $false
    foreach ($name in @('Game-Paths.ps1','Player-Names.ps1','Launch-LAN.ps1','Start-ChainedTogether-LAN.ps1','Autoriser-LAN.ps1','Heberger-LAN.cmd','Rejoindre-LAN.cmd','Lancer-LAN.cmd','Restaurer-Steam.cmd','Autoriser-LAN.cmd','Diagnostic-LAN.cmd','launcher-version.txt')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $script:PackageRoot $name)
    }
    . (Join-Path $sourceRoot 'Game-Paths.ps1')
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'Start-ChainedTogether-LAN.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-PathCheck ($parseErrors.Count -eq 0) 'Syntaxe du lanceur.'
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    . (Join-Path $sourceRoot 'Autoriser-LAN.ps1')
    $script:FirewallHelperRoot = $script:PackageRoot

    # Exercise different registry casing/separators before isolating discovery.
    function Get-ItemProperty([string]$LiteralPath,[string]$ErrorAction) {
        if ($LiteralPath -like 'HKCU:*') { return [pscustomobject]@{ SteamPath=$script:FixtureSteamRoot.ToLowerInvariant().Replace('\','/') } }
        return [pscustomobject]@{ InstallPath=$script:FixtureSteamRoot.ToUpperInvariant() }
    }
    $registryRoots = @(Get-LanSteamInstallRoots | Where-Object { $_ -eq $script:FixtureSteamRoot })
    Assert-PathCheck ($registryRoots.Count -eq 1) 'Doublons entre HKCU/HKLM.'
    function Get-LanSteamInstallRoots { $script:FixtureSteamRoot }
    $unique = @(Get-LanUniqueGamePaths @($gameA.Root,($gameA.Root.ToUpperInvariant() + '\'),$gameA.Root.Replace('\','/')))
    Assert-PathCheck ($unique.Count -eq 1) 'Doublons de casse, separateurs ou barre finale.'
    $driveRoot = [IO.Path]::GetPathRoot($gameA.Root)
    Assert-PathCheck ((ConvertTo-LanGamePath $driveRoot) -eq $driveRoot) 'La racine du disque doit conserver sa barre finale.'

    # A stale/missing volume must not stop discovery of an available library.
    $missingDrive = 'Z:\ChainedTogether-Missing-' + [Guid]::NewGuid().ToString('N')
    Write-FixtureLibraries @($libraryA,$libraryA.ToUpperInvariant(),$libraryA.Replace('\','/'),$missingDrive,$libraryB)
    Assert-PathCheck (@(Get-LanSteamGameRoots).Count -eq 1) 'VDF moderne, doublons, volume absent et installation incomplete.'
    Assert-BothResolvers '' $gameA
    Write-FixtureLibraries @($libraryA,$missingDrive) -Legacy
    Assert-BothResolvers '' $gameA
    Write-FixtureLibraries @($libraryA,$libraryB)

    # The same game must resolve from its folder, bootstrap, shipping EXE or Win64 folder.
    foreach ($path in @($gameA.Root,(Join-Path $gameA.Root 'ChainedTogether.exe'),$gameA.Exe,(Split-Path $gameA.Exe -Parent))) {
        Assert-BothResolvers $path $gameA
    }
    $settingsPath = Join-Path $script:PackageRoot 'launcher-settings.json'
    Write-FixtureJson $settingsPath @{ gamePath=(Join-Path $fixtureRoot 'Old moved game') }
    Assert-BothResolvers '' $gameA
    Write-FixtureText $settingsPath '{invalid json'
    Assert-BothResolvers '' $gameA
    Write-FixtureJson $settingsPath @{ gamePath='..\Library One\steamapps\common\ChainedTogether' }
    Assert-BothResolvers '' $gameA
    Remove-Item -LiteralPath $settingsPath -Force
    Assert-PathRejected { Resolve-Game (Join-Path $fixtureRoot 'Explicit missing game') } 'introuvable'
    Assert-PathRejected { Resolve-FirewallShippingExe (Join-Path $fixtureRoot 'Explicit missing game') } 'introuvable'
    $randomExe = Join-Path $fixtureRoot 'Other.exe'
    Write-FixtureText $randomExe 'Never executed.'
    Assert-PathRejected { Resolve-Game $randomExe } '-GamePath'
    Assert-PathRejected { Resolve-FirewallShippingExe $randomExe } '-GamePath'

    $gameB = New-FixtureGame $libraryB
    Assert-PathRejected { Resolve-Game '' } 'Plusieurs installations'
    Assert-PathRejected { Resolve-FirewallShippingExe '' } 'Plusieurs installations'
    Assert-BothResolvers $gameB.Root $gameB
    # Manifest traversal must not add an installation outside steamapps/common.
    Write-FixtureText (Join-Path $libraryB 'steamapps\appmanifest_2567870.acf') '"AppState" { "appid" "2567870" "installdir" ".." }'
    Assert-BothResolvers '' $gameA
    Write-FixtureText (Join-Path $libraryB 'steamapps\appmanifest_2567870.acf') '"AppState" { "appid" "999" "installdir" "ChainedTogether" }'
    Assert-BothResolvers '' $gameA

    # Test the actual CMD wrappers from another working directory, in a package with spaces.
    Write-FixtureJson $settingsPath @{ gamePath=$gameA.Root }
    $payloadRoot = Join-Path $script:PackageRoot 'payload'
    $null = New-Item -ItemType Directory -Path $payloadRoot -Force
    Copy-Item -LiteralPath $gameA.Dll -Destination (Join-Path $payloadRoot 'steam_api64.dll')
    $exeHash = (Get-FileHash -LiteralPath $gameA.Exe -Algorithm SHA256).Hash.ToLowerInvariant()
    $dllHash = (Get-FileHash -LiteralPath $gameA.Dll -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureJson (Join-Path $payloadRoot 'provenance.json') @{ sha256=$dllHash; sourceUrl='https://example.invalid/test-fixture'; releaseTag='fixture' }
    $menuFiles = @{}
    foreach ($role in @('Host','Join')) {
        $pak = Join-Path $payloadRoot ('menu\' + $role + '.pak')
        Write-FixtureText $pak ($role + ' fixture, never loaded by a game.')
        $menuFiles[$role] = @{ sha256=(Get-FileHash -LiteralPath $pak -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $originalContent = 'Original fixture content.'
    $basePakRelative = 'ChainedTogether\Content\Paks\ChainedTogether-Windows.pak'
    Write-FixtureText (Join-Path $gameA.Root $basePakRelative) $originalContent
    $basePak = Get-Item -LiteralPath (Join-Path $gameA.Root $basePakRelative)
    $contentFiles = @(@{ relative=$basePakRelative; size=$basePak.Length; sha256=(Get-FileHash -LiteralPath $basePak.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    Write-FixtureJson (Join-Path $payloadRoot 'menu\menu-provenance.json') @{ schemaVersion=1; gameExeSha256=$exeHash; gameBuildId='42'; files=$menuFiles; gameContentFiles=$contentFiles }
    Set-Location -LiteralPath $fixtureRoot
    foreach ($name in @('Heberger-LAN.cmd','Rejoindre-LAN.cmd','Lancer-LAN.cmd','Restaurer-Steam.cmd','Autoriser-LAN.cmd')) {
        $argument = if ($name -eq 'Autoriser-LAN.cmd') { '-WhatIf' } else { '-Diagnose' }
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = $env:ComSpec
        $processInfo.Arguments = '/d /s /c ""' + (Join-Path $script:PackageRoot $name) + '" ' + $argument + ' <nul"'
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $worker = New-Object Diagnostics.Process
        $worker.StartInfo = $processInfo
        try {
            $null = $worker.Start()
            $stdout = $worker.StandardOutput.ReadToEndAsync()
            $stderr = $worker.StandardError.ReadToEndAsync()
            $worker.WaitForExit()
            $output = ($stdout.Result + $stderr.Result) -split '\r?\n'
            $exitCode = $worker.ExitCode
        } finally { $worker.Dispose() }
        Assert-PathCheck ($exitCode -eq 0) ("$name : " + ($output -join [Environment]::NewLine))
        Assert-PathCheck (($output -join [Environment]::NewLine) -match [regex]::Escape($gameA.Root)) "$name doit utiliser le dossier detecte."
        if ($name -eq 'Heberger-LAN.cmd') { Assert-PathCheck (($output -join ' ') -match 'Menu Host :') 'Le raccourci Host doit verifier son menu.' }
        if ($name -eq 'Rejoindre-LAN.cmd') { Assert-PathCheck (($output -join ' ') -match 'Menu Join :') 'Le raccourci Join doit verifier son menu.' }
        Write-Output "OK : $name $argument"
    }
    Assert-PathCheck (-not (Test-Path -LiteralPath (Join-Path $gameA.Root '.chained-lan'))) 'Les diagnostics ne doivent pas preparer le jeu.'
    Assert-PathCheck ((Get-FileHash -LiteralPath $gameA.Exe -Algorithm SHA256).Hash.ToLowerInvariant() -eq $exeHash) 'Executable fixture modifie.'
    Assert-PathCheck ((Get-FileHash -LiteralPath $gameA.Dll -Algorithm SHA256).Hash.ToLowerInvariant() -eq $dllHash) 'DLL fixture modifiee.'

    # A second PC with no Steam registration, no manifest and an arbitrary game folder.
    $otherPc = Join-Path $fixtureRoot 'Other PC'
    $customRoot = Join-Path $otherPc 'Mes installations\Titre quelconque'
    $otherPackage = Join-Path $otherPc 'Portable LAN package'
    $null = New-Item -ItemType Directory -Path (Split-Path $customRoot -Parent) -Force
    Copy-Item -LiteralPath $gameA.Root -Destination $customRoot -Recurse
    Copy-Item -LiteralPath $script:PackageRoot -Destination $otherPackage -Recurse
    Remove-Item -LiteralPath (Join-Path $otherPackage 'launcher-settings.json') -Force
    $script:PackageRoot = $otherPackage
    $script:FirewallHelperRoot = $otherPackage
    $script:FixtureScanRoot = $otherPc
    function Get-LanSteamGameRoots { }
    function Get-LanDiskRoots { $script:FixtureScanRoot }
    $customGame = [pscustomobject]@{ Root=$customRoot; Exe=(Join-Path $customRoot 'ChainedTogether\Binaries\Win64\ChainedTogether-Win64-Shipping.exe') }
    # A stray file with the same name must not be mistaken for a complete game.
    Write-FixtureText (Join-Path $otherPc 'ChainedTogether-Win64-Shipping.exe') 'Not a Windows executable.'
    $scanned = @(Search-LanGameDirectories @($otherPc) 10)
    Assert-PathCheck ($scanned.Count -eq 1 -and $scanned[0] -eq $customRoot) 'Scan du vrai executable sans registre ni manifeste, nom de dossier quelconque.'
    Assert-BothResolvers '' $customGame
    Assert-PathCheck ($null -ne (Get-VerifiedMenuPayload $customGame 'Host')) 'Menu Host sans manifeste, contenu conforme.'
    Assert-PathCheck ($null -ne (Get-VerifiedMenuPayload $customGame 'Join')) 'Menu Join sans manifeste, contenu conforme.'
    Write-FixtureText (Join-Path $customRoot $basePakRelative) 'Tampered fixture content.'
    Assert-PathRejected { Get-VerifiedMenuPayload $customGame 'Join' } 'contenu du jeu ne correspond'
    Write-FixtureText (Join-Path $customRoot $basePakRelative) $originalContent
    Write-FixtureText (Join-Path $libraryA 'steamapps\appmanifest_2567870.acf') '"AppState" { "appid" "2567870" "installdir" "ChainedTogether" "buildid" "43" }'
    Assert-PathRejected { Get-VerifiedMenuPayload $gameA 'Join' } 'Build Steam 43 different'

    # Child processes use the copied production scanner with only the drive inventory isolated.
    $isolatedRoot = $otherPc.Replace("'","''")
    [IO.File]::AppendAllText((Join-Path $otherPackage 'Game-Paths.ps1'),("`r`nfunction Get-LanSteamGameRoots { }`r`nfunction Get-LanDiskRoots { '" + $isolatedRoot + "' }`r`n"),$script:Utf8)
    foreach ($name in @('Rejoindre-LAN.cmd','Heberger-LAN.cmd','Diagnostic-LAN.cmd')) {
        $argument = if ($name -eq 'Diagnostic-LAN.cmd') { '' } else { '-Diagnose' }
        $processInfo.Arguments = '/d /s /c ""' + (Join-Path $otherPackage $name) + '" ' + $argument + ' <nul"'
        $worker = New-Object Diagnostics.Process
        $worker.StartInfo = $processInfo
        try {
            $null = $worker.Start()
            $stdout = $worker.StandardOutput.ReadToEndAsync(); $stderr = $worker.StandardError.ReadToEndAsync()
            $worker.WaitForExit()
            $output = $stdout.Result + $stderr.Result
            Assert-PathCheck ($worker.ExitCode -eq 0) ("$name sans Steam : " + $output)
            Assert-PathCheck ($output -match [regex]::Escape($customRoot)) "$name doit scanner le dossier du jeu sans configuration."
            $expectedVersion = [IO.File]::ReadAllText((Join-Path $sourceRoot 'launcher-version.txt')).Trim()
            Assert-PathCheck ($output -match [regex]::Escape($expectedVersion)) 'Le paquet doit afficher sa nouvelle version.'
            Write-Output "OK : $name sans Steam ni manifeste, scan automatique et menus verifies."
        } finally { $worker.Dispose() }
    }
    Assert-PathCheck (Test-Path -LiteralPath (Join-Path $otherPackage 'Diagnostic-LAN.txt')) 'Le diagnostic doit produire un rapport partageable.'
    Assert-PathCheck (-not (Test-Path -LiteralPath (Join-Path $customRoot '.chained-lan'))) 'Le scan et le diagnostic ne doivent pas preparer le jeu.'
    Save-LanGameLocation $customRoot
    Assert-BothResolvers '' $customGame
    $cache = [IO.File]::ReadAllText((Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\game-location.json')) | ConvertFrom-Json
    Assert-PathCheck ($cache.gamePath -eq $customRoot) 'Le chemin trouve doit etre memorise dans le profil local, hors du paquet.'
    Assert-BothResolvers $gameA.Root $gameA
    Write-FixtureJson (Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\game-location.json') @{ gamePath=(Join-Path $otherPc 'Ancien dossier deplace') }
    Assert-BothResolvers '' $customGame

    # The game is on another disk inventory entry, outside every priority folder.
    $emptyDisk = Join-Path $fixtureRoot 'Simulated empty disk'
    $farDisk = Join-Path $fixtureRoot 'Simulated second disk'
    $incoming = Join-Path $fixtureRoot 'Incoming archive only\LAN'
    $null = New-Item -ItemType Directory -Path $emptyDisk,$incoming -Force
    $farLibrary = Join-Path $farDisk 'Archives non standard\Deep install'
    $farGame = New-FixtureGame $farLibrary
    Remove-Item -LiteralPath (Join-Path $farLibrary 'steamapps\appmanifest_2567870.acf') -Force
    $script:FixtureScanDisks = @($emptyDisk,$farDisk)
    function Get-LanDiskRoots { $script:FixtureScanDisks }
    $script:PackageRoot = $incoming
    $script:FirewallHelperRoot = $incoming
    $extended = @(Find-LanGameRoots $incoming)
    Assert-PathCheck ($extended.Count -eq 1 -and $extended[0] -eq $farGame.Root) 'Le scan etendu doit trouver le jeu sur le second disque, hors des dossiers habituels.'
    Assert-BothResolvers '' $farGame
    Remove-Item -LiteralPath $farGame.Exe -Force
    Assert-PathRejected { Resolve-Game '' } 'introuvable apres recherche'
    Assert-PathRejected { Resolve-FirewallShippingExe '' } 'introuvable apres recherche'
    Write-Output ("OK : $script:PathChecks controles de chemins sous PowerShell " + $PSVersionTable.PSVersion + '. Aucun jeu lance ni pare-feu modifie.')
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    Set-Location -LiteralPath $originalLocation
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixture.StartsWith($temporaryRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedFixture) -ne $fixtureName) { throw "Nettoyage refuse hors du dossier temporaire : $resolvedFixture" }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
