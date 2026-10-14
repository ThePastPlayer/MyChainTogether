#requires -Version 5.1
# Local Steam display names only: no network requests, login names or credentials.

function ConvertTo-LanPlayerName([string]$Name, [switch]$FromSteam) {
    if ($FromSteam) {
        $Name = [regex]::Replace($Name, '[\p{Cc}=\[\];#]', '_').Trim()
        if ($Name.Length -gt 48) {
            $Name = $Name.Substring(0,48)
            if ([char]::IsHighSurrogate($Name[$Name.Length - 1])) { $Name = $Name.Substring(0,$Name.Length - 1) }
        }
    } else { $Name = $Name.Trim() }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 48 -or $Name -match '[\p{Cc}=\[\];#]') {
        throw 'Pseudo invalide : utilisez 1 a 48 caracteres, sans retour a la ligne ni = [ ] ; #.'
    }
    return $Name
}

function ConvertFrom-LanSteamUsersVdf([string]$Text) {
    # Parse nested KeyValues instead of matching PersonaName across account blocks.
    if ($Text.Length -gt 2097152) { throw 'Fichier des comptes Steam trop volumineux.' }
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $pattern = [regex]'\G(?:\s+|//[^\r\n]*|"((?:\\.|[^"\\])*)"|([{}]))'
    $position = 0
    while ($position -lt $Text.Length) {
        $match = $pattern.Match($Text,$position)
        if (-not $match.Success) { throw 'Format du fichier des comptes Steam invalide.' }
        if ($match.Groups[1].Success) {
            $value = [regex]::Replace($match.Groups[1].Value, '\\[\\"nrt]', {
                param($escaped)
                switch ($escaped.Value) {
                    '\\' { return '\' }
                    '\"' { return '"' }
                    '\n' { return "`n" }
                    '\r' { return "`r" }
                    '\t' { return "`t" }
                }
            })
            # Prefix quoted strings to distinguish literal braces from structure.
            $tokens.Add('S' + $value)
        } elseif ($match.Groups[2].Success) { $tokens.Add($match.Groups[2].Value) }
        $position += $match.Length
    }
    $cursor = @{ Index=0 }
    function Read-LanSteamUserBlock([int]$Depth) {
        if ($Depth -gt 12) { throw 'Imbrication Steam invalide.' }
        $block = @{}
        while ($cursor.Index -lt $tokens.Count) {
            $key = $tokens[$cursor.Index]; $cursor.Index++
            if ($key -eq '}') {
                if ($Depth -eq 0) { throw 'Accolade Steam inattendue.' }
                return $block
            }
            if (-not $key.StartsWith('S') -or $cursor.Index -ge $tokens.Count) { throw 'Cle Steam incomplete.' }
            $key = $key.Substring(1)
            if ($block.ContainsKey($key)) { throw 'Cle Steam dupliquee.' }
            $value = $tokens[$cursor.Index]; $cursor.Index++
            if ($value -eq '{') { $block[$key] = Read-LanSteamUserBlock ($Depth + 1) }
            elseif ($value.StartsWith('S')) { $block[$key] = $value.Substring(1) }
            else { throw 'Valeur Steam invalide.' }
        }
        if ($Depth -gt 0) { throw 'Bloc Steam incomplet.' }
        return $block
    }
    return (Read-LanSteamUserBlock 0)
}

function Get-LanActiveSteamId {
    $properties = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue
    if (-not $properties -or -not $properties.PSObject.Properties['ActiveUser']) { return $null }
    $accountId = 0L
    if (-not [long]::TryParse([string]$properties.ActiveUser,[ref]$accountId)) { return $null }
    if ($accountId -lt 0 -and $accountId -ge -2147483648L) { $accountId += 4294967296L }
    if ($accountId -gt 0 -and $accountId -le 4294967295L) {
        return ([long]76561197960265728 + $accountId).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Get-LanSteamPlayerName {
    $accounts = @{}
    foreach ($steamRoot in @(Get-LanSteamInstallRoots)) {
        $path = Join-Path $steamRoot 'config\loginusers.vdf'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $file = Get-Item -LiteralPath $path
            if ($file.Length -gt 2097152) { continue }
            $document = ConvertFrom-LanSteamUsersVdf ([IO.File]::ReadAllText($path))
            if (-not $document.ContainsKey('users') -or $document['users'] -isnot [hashtable]) { continue }
            foreach ($id in $document['users'].Keys) {
                $record = $document['users'][$id]
                $numericId = 0L
                if (-not [long]::TryParse([string]$id,[ref]$numericId) -or $numericId -le 76561197960265728L -or
                    $numericId -gt 76561202255233023L -or $record -isnot [hashtable]) { continue }
                $timestamp = 0L
                $null = [long]::TryParse([string]$record['Timestamp'],[ref]$timestamp)
                $candidate = [pscustomobject]@{ SteamId=$id; PersonaName=[string]$record['PersonaName'];
                    Recent=([string]$record['MostRecent'] -eq '1'); Timestamp=$timestamp }
                if (-not $accounts.ContainsKey($id) -or $timestamp -gt $accounts[$id].Timestamp) { $accounts[$id] = $candidate }
            }
        } catch { Write-Verbose "Pseudo Steam illisible : $path" }
    }
    if ($accounts.Count -eq 0) { return $null }
    $activeId = Get-LanActiveSteamId
    $selected = $null
    if ($activeId) {
        # Never substitute a different saved account for a currently active one.
        if ($accounts.ContainsKey($activeId)) { $selected = $accounts[$activeId] }
    } else {
        $recent = @($accounts.Values | Where-Object { $_.Recent })
        if ($recent.Count -eq 1) { $selected = $recent[0] }
        elseif ($recent.Count -eq 0) {
            $ordered = @($accounts.Values | Sort-Object Timestamp -Descending)
            if ($ordered.Count -eq 1 -or ($ordered[0].Timestamp -gt 0 -and $ordered[0].Timestamp -gt $ordered[1].Timestamp)) { $selected = $ordered[0] }
        }
    }
    if ($null -eq $selected) { return $null }
    try { $name = ConvertTo-LanPlayerName $selected.PersonaName -FromSteam }
    catch { return $null }
    return [pscustomobject]@{ Name=$name; Source='Steam' }
}

function Get-LanSavedPlayerName {
    $path = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN\player-preferences.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($saved.schemaVersion -ne 1) { return $null }
        return (ConvertTo-LanPlayerName ([string]$saved.playerName))
    } catch { Write-Verbose 'Ancien pseudo local invalide ignore.'; return $null }
}

function Resolve-LanPlayerName([string]$RequestedName, [switch]$Explicit, [switch]$AllowPrompt, [switch]$Ask) {
    if ($Explicit) { return [pscustomobject]@{ Name=(ConvertTo-LanPlayerName $RequestedName); Source='Manual' } }
    $steam = Get-LanSteamPlayerName
    if ($steam -and -not $Ask) { return $steam }
    $previous = Get-LanSavedPlayerName
    if ($steam -and -not $previous) { $previous = $steam.Name }
    if (-not $AllowPrompt) {
        if ($previous -and -not $Ask) { return [pscustomobject]@{ Name=$previous; Source='Saved' } }
        throw 'Pseudo Steam introuvable ou choix manuel demande. Lancez avec -Interactive ou indiquez -PlayerName "Votre pseudo".'
    }
    Write-Host 'Choisissez le pseudo affiche aux autres joueurs LAN.'
    while ($true) {
        $prompt = if ($previous) { "Pseudo (Entree = $previous)" } else { 'Pseudo' }
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer) -and $previous) { $answer = $previous }
        if ([string]::IsNullOrWhiteSpace($answer) -and [Console]::IsInputRedirected) {
            throw 'Aucun pseudo saisi. Relancez dans une console ou indiquez -PlayerName "Votre pseudo".'
        }
        try { return [pscustomobject]@{ Name=(ConvertTo-LanPlayerName $answer); Source='Manual' } }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function Save-LanPlayerName([string]$Name) {
    $directory = Join-Path $env:LOCALAPPDATA 'ChainedTogether-LAN'
    $null = New-Item -ItemType Directory -Path $directory -Force
    Write-JsonAtomic (Join-Path $directory 'player-preferences.json') ([pscustomobject]@{
        schemaVersion=1; playerName=(ConvertTo-LanPlayerName $Name)
    })
}
