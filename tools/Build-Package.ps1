#requires -Version 5.1
[CmdletBinding()]
param([switch]$RefreshHashes,[string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$distributionRoot = Join-Path $repoRoot 'ChainedTogether-LAN'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
. (Join-Path $distributionRoot 'Update-LAN.ps1') -FunctionsOnly
$rootNames = @('ANALYSE.txt','README.txt','launcher-version.txt','validation.json','game-layout.json')
$relativeNames = @($rootNames) + @(Get-ChildItem -LiteralPath $distributionRoot -File | Where-Object { $_.Extension -in @('.ps1','.cmd') } | ForEach-Object { $_.Name })
foreach ($folder in @('payload','tests')) {
    $relativeNames += @(Get-ChildItem -LiteralPath (Join-Path $distributionRoot $folder) -Recurse -File | Where-Object { $_.Extension -in @('.txt','.json','.dll','.pak','.ps1') } | ForEach-Object { $_.FullName.Substring($distributionRoot.Length + 1).Replace('\','/') })
}
$relativeNames = @($relativeNames | Sort-Object -Unique)
$manifestPath = Join-Path $distributionRoot 'SHA256SUMS.txt'
if ($RefreshHashes) {
    $lines = @($relativeNames | ForEach-Object { (Get-LanUpdateHash (Get-LanUpdatePath $distributionRoot $_)) + '  ' + $_ })
    [IO.File]::WriteAllText($manifestPath,(($lines -join "`n") + "`n"),(New-Object Text.UTF8Encoding($false)))
}
$entries = Read-LanUpdateManifest ([IO.File]::ReadAllText($manifestPath)) $distributionRoot
if ($entries.Count -ne $relativeNames.Count) { throw 'Le manifest ne correspond pas aux fichiers distribues ; utilisez -RefreshHashes.' }
foreach ($name in $relativeNames) {
    if (-not $entries.ContainsKey($name) -or (Get-LanUpdateHash (Get-LanUpdatePath $distributionRoot $name)) -ne $entries[$name]) { throw "Empreinte de distribution incorrecte : $name" }
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $OutputDirectory 'ChainedTogether-LAN.zip'
$stream = [IO.File]::Create($zipPath)
$archive = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in (@($relativeNames) + @('SHA256SUMS.txt'))) {
        $path = Get-LanUpdatePath $distributionRoot $name
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$path,('ChainedTogether-LAN/' + $name),[IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose(); $stream.Dispose() }
[pscustomobject]@{ archive=$zipPath; sha256=(Get-LanUpdateHash $zipPath); entries=($relativeNames.Count + 1); version=[IO.File]::ReadAllText((Join-Path $distributionRoot 'launcher-version.txt')).Trim() } | ConvertTo-Json
