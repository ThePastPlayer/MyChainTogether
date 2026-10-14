#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$originalLocalAppData = $env:LOCALAPPDATA
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureName = 'ChainedTogether-NameTests-' + [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $temporaryRoot $fixtureName
$script:NameChecks = 0
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:MenuRelativePaths = @('ChainedTogether\Content\Paks\CTLAN-AutoMenu_Host_P.pak','ChainedTogether\Content\Paks\CTLAN-AutoMenu_Join_P.pak')
$leo = 'L' + [char]0xe9 + 'o'
$idA = '76561198000000001'
$idB = '76561198000000002'

function Assert-NameCheck([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ECHEC : $Message" }
    $script:NameChecks++
}
function Assert-NameRejected([scriptblock]$Action,[string]$Pattern) {
    $rejected = $false
    try { $null = & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $rejected = $true
    }
    Assert-NameCheck $rejected "Refus attendu : $Pattern"
}
function Write-NameFixture([string]$Path,[string]$Text) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [IO.File]::WriteAllText($Path,$Text,$script:Utf8)
}
function Set-Users([string]$Text) { Write-NameFixture (Join-Path $script:SteamRoots[0] 'config\loginusers.vdf') $Text }
function Invoke-NameWrapper([string]$Package,[string]$Wrapper,[string]$Arguments,[string]$Profile,[string]$InputText='') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c ""' + (Join-Path $Package $Wrapper) + '" -PrepareOnly ' + $Arguments + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['LOCALAPPDATA'] = $Profile
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $worker = New-Object Diagnostics.Process
    $worker.StartInfo = $info
    try {
        $null = $worker.Start()
        $stdout = $worker.StandardOutput.ReadToEndAsync(); $stderr = $worker.StandardError.ReadToEndAsync()
        $worker.StandardInput.WriteLine($InputText); $worker.StandardInput.Close()
        if (-not $worker.WaitForExit(20000)) { $worker.Kill(); throw 'Fixture launcher timeout.' }
        return [pscustomobject]@{ ExitCode=$worker.ExitCode; Output=($stdout.Result + $stderr.Result) }
    } finally { $worker.Dispose() }
}

try {
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'Profile'
    . (Join-Path $sourceRoot 'Game-Paths.ps1')
    . (Join-Path $sourceRoot 'Player-Names.ps1')
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'Start-ChainedTogether-LAN.ps1'),[ref]$tokens,[ref]$errors)
    Assert-NameCheck ($errors.Count -eq 0) 'Launcher syntax.'
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:SteamRoots = @((Join-Path $fixtureRoot 'Steam'))
    $script:ActiveAccount = 0L
    function Get-LanSteamInstallRoots { $script:SteamRoots }
    function Get-ItemProperty { param($LiteralPath,$ErrorAction) return [pscustomobject]@{ ActiveUser=$script:ActiveAccount } }
    $script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    $script:PromptCount = 0
    function Read-Host { param($Prompt) $script:PromptCount++; return $script:Answers.Dequeue() }

    Assert-NameCheck ((ConvertTo-LanPlayerName (' ' + $leo + ' ')) -ceq $leo) 'UTF-8 name and trimming.'
    Assert-NameCheck ((ConvertTo-LanPlayerName ([string][char]0xfeff + $leo)) -ceq $leo) 'UTF-8 console BOM does not become part of the nickname.'
    foreach ($invalid in @('', '   ', 'A#B', 'A=B', 'A[B]', ('A' + [char]27 + 'B'), ('A' * 49))) {
        Assert-NameRejected { ConvertTo-LanPlayerName $invalid } 'Pseudo invalide'
    }
    Assert-NameCheck ((ConvertTo-LanPlayerName 'Steam [name];#' -FromSteam) -eq 'Steam _name___') 'INI metacharacters sanitized only for Steam.'
    Assert-NameCheck ((ConvertTo-LanPlayerName ('A' * 49) -FromSteam).Length -eq 48) 'Long Steam names trimmed.'
    $emoji = [char]::ConvertFromUtf32(0x1f600)
    Assert-NameCheck ((ConvertTo-LanPlayerName (('A' * 47) + $emoji) -FromSteam).Length -eq 47) 'No truncated surrogate pair.'
    $escaped = ConvertFrom-LanSteamUsersVdf '// comment
"users" { "76561198000000001" { "PersonaName" "A \"quote\" {brace} \\slash" } }'
    Assert-NameCheck ($escaped.users[$idA].PersonaName -ceq 'A "quote" {brace} \slash') 'KeyValues quoting, comments and literal braces.'
    foreach ($broken in @('"users" {', '"users" { "a" "b" "a" "c" }', 'garbage', '"users" }')) {
        Assert-NameRejected { ConvertFrom-LanSteamUsersVdf $broken } 'Steam'
    }

    $twoUsers = '"users" { "' + $idA + '" { "PersonaName" "Julien" "Timestamp" "100" } "' + $idB + '" { "PersonaName" "' + $leo + '" "Timestamp" "200" } }'
    Set-Users $twoUsers
    Assert-NameCheck ((Get-LanSteamPlayerName).Name -ceq $leo) 'Latest Steam account without MostRecent.'
    $script:ActiveAccount = [long]$idA - 76561197960265728L
    Assert-NameCheck ((Get-LanSteamPlayerName).Name -ceq 'Julien') 'Active Steam account wins over timestamp.'
    Assert-NameCheck ((Resolve-LanPlayerName $leo -Explicit).Name -ceq $leo) 'Explicit name wins over Steam.'
    Assert-NameRejected { Resolve-LanPlayerName 'bad#name' -Explicit } 'Pseudo invalide'
    $script:ActiveAccount = 1L
    Assert-NameCheck ($null -eq (Get-LanSteamPlayerName)) 'Unknown active account never selects a different player.'
    $script:ActiveAccount = -1L
    Assert-NameCheck ((Get-LanActiveSteamId) -eq '76561202255233023') 'Signed DWORD account IDs converted correctly.'
    $script:ActiveAccount = 0L
    Set-Users ($twoUsers.Replace('"100"','"300"').Replace('"Julien"','"Julien" "MostRecent" "0"').Replace(('"' + $leo + '"'),('"' + $leo + '" "MostRecent" "1"')))
    Assert-NameCheck ((Get-LanSteamPlayerName).Name -ceq $leo) 'MostRecent wins over timestamp.'
    Set-Users ($twoUsers.Replace('"100"','"200"'))
    Assert-NameCheck ($null -eq (Get-LanSteamPlayerName)) 'Tied accounts request a name.'
    Set-Users '"users" { "76561198000000001" { "AccountName" "private-login" } }'
    Assert-NameCheck ($null -eq (Get-LanSteamPlayerName)) 'Login name never used as display name.'
    Set-Users '"users" {'
    Assert-NameCheck ($null -eq (Get-LanSteamPlayerName)) 'Broken metadata ignored.'
    Assert-NameRejected { Resolve-LanPlayerName '' } 'PlayerName'
    $script:Answers.Enqueue('bad#name'); $script:Answers.Enqueue($leo)
    $selected = Resolve-LanPlayerName '' -AllowPrompt
    Assert-NameCheck ($selected.Name -ceq $leo -and $script:PromptCount -eq 2) 'Fallback prompt validates then accepts Unicode.'
    Assert-NameCheck (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\player-preferences.json'))) 'Selection does not save before installation succeeds.'
    Save-LanPlayerName $leo
    Assert-NameCheck ((Get-LanSavedPlayerName) -ceq $leo) 'Manual preference local to this PC.'
    $script:Answers.Enqueue('')
    Assert-NameCheck ((Resolve-LanPlayerName '' -AllowPrompt).Name -ceq $leo) 'Enter keeps previous manual name.'
    Set-Users $twoUsers
    $script:ActiveAccount = [long]$idA - 76561197960265728L
    Assert-NameCheck ((Resolve-LanPlayerName '').Name -ceq 'Julien') 'Steam overrides remembered manual name.'
    $script:Answers.Enqueue('Custom player')
    Assert-NameCheck ((Resolve-LanPlayerName '' -AllowPrompt -Ask).Name -ceq 'Custom player') 'Forced prompt overrides Steam.'

    # Actual Host/Join shortcuts, preparation only, isolated fake game and Steam.
    $identities = @()
    foreach ($role in @('Host','Join')) {
        $pcRoot = Join-Path $fixtureRoot $role
        $package = Join-Path $pcRoot 'Portable LAN'
        $script:PackageRoot = $package
        $steamRoot = Join-Path $pcRoot 'Steam'
        $profile = Join-Path $pcRoot 'Local profile'
        $name = if ($role -eq 'Host') { 'Julien' } else { $leo }
        $null = New-Item -ItemType Directory -Path $package -Force
        foreach ($file in @('Start-ChainedTogether-LAN.ps1','Game-Paths.ps1','Player-Names.ps1','Launch-LAN.ps1','Update-LAN.ps1','Heberger-LAN.cmd','Rejoindre-LAN.cmd','launcher-version.txt')) {
            if (Test-Path -LiteralPath (Join-Path $sourceRoot $file)) { Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $package $file) }
        }
        [IO.File]::AppendAllText((Join-Path $package 'Player-Names.ps1'),("`nfunction Get-LanSteamInstallRoots { '" + $steamRoot.Replace("'","''") + "' }`nfunction Get-LanActiveSteamId { '$idA' }`n"),$script:Utf8)
        Write-NameFixture (Join-Path $steamRoot 'config\loginusers.vdf') ('"users" { "' + $idA + '" { "PersonaName" "' + $name + '" } }')
        $gameRoot = Join-Path $pcRoot 'Library\steamapps\common\ChainedTogether'
        $gameExe = Join-Path $gameRoot 'ChainedTogether\Binaries\Win64\ChainedTogether-Win64-Shipping.exe'
        $dllPath = Join-Path (Split-Path $gameExe -Parent) 'steam_api64.dll'
        $null = New-Item -ItemType Directory -Path (Split-Path $gameExe -Parent) -Force
        $pe = New-Object byte[] 512
        $pe[0]=0x4d; $pe[1]=0x5a; $pe[0x3c]=0x80; $pe[0x80]=0x50; $pe[0x81]=0x45; $pe[0x84]=0x64; $pe[0x85]=0x86
        $interface = [Text.Encoding]::ASCII.GetBytes('SteamFriends017 SteamUtils010')
        [Array]::Copy($interface,0,$pe,256,$interface.Length)
        [IO.File]::WriteAllBytes($gameExe,$pe); [IO.File]::WriteAllBytes($dllPath,$pe)
        Write-NameFixture (Join-Path $pcRoot 'Library\steamapps\appmanifest_2567870.acf') '"AppState" { "appid" "2567870" "installdir" "ChainedTogether" "buildid" "42" }'
        Write-NameFixture (Join-Path $package 'launcher-settings.json') (@{ gamePath=$gameRoot } | ConvertTo-Json)
        $payloadDll = Join-Path $package 'payload\steam_api64.dll'
        $null = New-Item -ItemType Directory -Path (Split-Path $payloadDll -Parent) -Force
        $payloadBytes = $pe.Clone(); $payloadBytes[400]=1
        [IO.File]::WriteAllBytes($payloadDll,$payloadBytes)
        Write-NameFixture (Join-Path $package 'payload\provenance.json') (@{ sha256=(Get-Sha256 $payloadDll); sourceUrl='https://example.invalid/fixture'; releaseTag='fixture' } | ConvertTo-Json)
        $menus = @{}
        foreach ($variant in @('Host','Join')) {
            $pakPath = Join-Path $package ('payload\menu\' + $variant + '.pak')
            Write-NameFixture $pakPath $variant
            $menus[$variant] = @{ sha256=(Get-Sha256 $pakPath) }
        }
        Write-NameFixture (Join-Path $package 'payload\menu\menu-provenance.json') (@{ schemaVersion=1; gameBuildId='42'; gameExeSha256=(Get-Sha256 $gameExe); files=$menus } | ConvertTo-Json -Depth 6)
        $wrapper = if ($role -eq 'Host') { 'Heberger-LAN.cmd' } else { 'Rejoindre-LAN.cmd' }
        $result = Invoke-NameWrapper $package $wrapper '-PlayerName "LAN-OLD-PC"' $profile
        Assert-NameCheck ($result.ExitCode -eq 0) ('Prepare legacy fixture: ' + $result.Output)
        $result = Invoke-NameWrapper $package $wrapper '' $profile
        Assert-NameCheck ($result.ExitCode -eq 0) ('Migrate legacy name: ' + $result.Output)
        $settingsPath = Join-Path (Split-Path $dllPath -Parent) 'steam_settings\configs.user.ini'
        Assert-NameCheck ([IO.File]::ReadAllText($settingsPath).Contains('account_name=' + $name + "`n")) "$role writes the Steam name as UTF-8."
        $statePath = Join-Path $gameRoot '.chained-lan\manifest.json'
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-NameCheck ($state.playerName -ceq $name -and $state.menuRole -eq $role) "$role manifest agrees."
        $identities += $state.steamId
        $created = $state.createdUtc
        $result = Invoke-NameWrapper $package $wrapper '' $profile
        $sameState = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-NameCheck ($result.ExitCode -eq 0 -and $sameState.createdUtc -eq $created) ('Unchanged names reuse prepared files: ' + $result.Output)
        $result = Invoke-NameWrapper $package $wrapper '-AskPlayerName' $profile 'Chosen player'
        Assert-NameCheck ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($settingsPath).Contains('account_name=Chosen player')) ('Prompt in actual wrapper: ' + $result.Output)
        Assert-NameCheck (([IO.File]::ReadAllText((Join-Path $profile 'ChainedTogether-LAN\player-preferences.json')) | ConvertFrom-Json).playerName -eq 'Chosen player') 'Prompt saved in local profile.'
        [IO.File]::AppendAllText($settingsPath,'external change',$script:Utf8)
        $tampered = Get-Sha256 $settingsPath
        $result = Invoke-NameWrapper $package $wrapper '-PlayerName "Another player"' $profile
        Assert-NameCheck ($result.ExitCode -ne 0 -and (Get-Sha256 $settingsPath) -eq $tampered) 'Nickname update protects externally edited game files.'
    }
    Assert-NameCheck ($identities[0] -ne $identities[1]) 'Names do not replace the distinct LAN identity of each PC.'
    Write-Output "OK : $script:NameChecks controles de pseudos. Steam et jeux simules, aucun jeu reel lance ou modifie."
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolved.StartsWith($temporaryRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -ne $fixtureName) { throw 'Nettoyage refuse hors du dossier de test.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
