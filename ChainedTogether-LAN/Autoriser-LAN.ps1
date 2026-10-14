#requires -Version 5.1
# Optional helper. Never called automatically by the game launcher.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$GamePath,[switch]$Remove,[switch]$Elevated,[string]$ResultFile,[switch]$Interactive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:FirewallHelperPath = $PSCommandPath
$script:FirewallHelperRoot = $PSScriptRoot
$script:FirewallGroup = 'ChainedTogether-LAN-Launcher-v1'
. (Join-Path $PSScriptRoot 'Game-Paths.ps1')

function Resolve-FirewallShippingExe([string]$Requested,[switch]$AllowSelection) {
    return (Resolve-LanGameInstallation $Requested $script:FirewallHelperRoot -AllowSelection:$AllowSelection).Exe
}
function Get-LanFirewallNames([string]$Exe) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Exe.ToLowerInvariant()))).Replace('-','').Substring(0,16) }
    finally { $hasher.Dispose() }
    return @("ChainedTogether-LAN-v1-$hash-TCP47584","ChainedTogether-LAN-v1-$hash-UDP47584")
}
function Test-FirewallAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}
function Write-FirewallMessage([string]$Message,[string]$LogFile) {
    Write-Host $Message
    if ($LogFile) { [IO.File]::AppendAllText($LogFile,$Message+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false))) }
}
function Quote-FirewallArgument([string]$Argument) {
    # These arguments are canonical Windows file paths, which cannot contain a quote.
    if ($Argument.Contains('"')) { throw 'Guillemet inattendu dans un chemin.' }
    return '"' + $Argument + '"'
}
function Invoke-LanFirewall {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$GamePath,[switch]$Remove,[switch]$Elevated,[string]$ResultFile,[switch]$Interactive)
    $exe = Resolve-FirewallShippingExe $GamePath -AllowSelection:($Interactive -and -not $WhatIfPreference)
    $names = @(Get-LanFirewallNames $exe)
    $protocols = @('TCP','UDP')
    $operation = if ($Remove) { 'Supprimer les regles de ce helper' } else { 'Autoriser les connexions entrantes LAN privees' }
    Write-FirewallMessage "Jeu : $exe" $ResultFile
    if ($WhatIfPreference) {
        foreach ($name in $names) { $null = $PSCmdlet.ShouldProcess($name,$operation) }
        Write-FirewallMessage 'Simulation : programme shipping uniquement, TCP et UDP locaux 47584, profil Private, sources LocalSubnet. Aucun UAC et aucune regle modifiee.' $ResultFile
        return
    }
    if (-not (Test-FirewallAdministrator)) {
        if ($Elevated) { throw 'Les droits administrateur Windows sont absents apres elevation.' }
        $temporaryLog = Join-Path ([IO.Path]::GetTempPath()) ('ChainedTogether-LAN-firewall-' + [Guid]::NewGuid().ToString('N') + '.log')
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-FirewallArgument $script:FirewallHelperPath),'-GamePath',(Quote-FirewallArgument $exe),'-Elevated','-ResultFile',(Quote-FirewallArgument $temporaryLog))
        if ($Remove) { $arguments += '-Remove' }
        Write-FirewallMessage 'Windows va demander les droits administrateur pour ce helper de pare-feu uniquement.' $ResultFile
        $worker = $null
        try {
            $elevationInfo = New-Object Diagnostics.ProcessStartInfo
            $elevationInfo.FileName = 'powershell.exe'
            $elevationInfo.Arguments = $arguments -join ' '
            $elevationInfo.UseShellExecute = $true
            $elevationInfo.Verb = 'runas'
            $elevationInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $worker = New-Object Diagnostics.Process
            $worker.StartInfo = $elevationInfo
            if (-not $worker.Start()) { throw 'Impossible de lancer le helper eleve.' }
            $null = $worker.Handle
            $worker.WaitForExit()
            if (Test-Path -LiteralPath $temporaryLog -PathType Leaf) { Get-Content -LiteralPath $temporaryLog | ForEach-Object { Write-FirewallMessage $_ $ResultFile } }
            if ($worker.ExitCode -ne 0) { throw 'Le helper eleve a echoue. Voir les messages ci-dessus.' }
        } finally {
            if ($worker) { $worker.Dispose() }
            if (Test-Path -LiteralPath $temporaryLog -PathType Leaf) { Remove-Item -LiteralPath $temporaryLog -Force }
        }
        return
    }
    $created = New-Object 'System.Collections.Generic.List[string]'
    try {
        for ($index=0; $index -lt 2; $index++) {
            $name = $names[$index]
            $protocol = $protocols[$index]
            $existing = @(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)
            foreach ($rule in $existing) {
                if ($rule.Name -ne $name -or $rule.Group -ne $script:FirewallGroup) {
                    throw "Une regle portant ce nom n'appartient pas au helper. Aucun remplacement : $name"
                }
            }
            if ($Remove) {
                foreach ($rule in $existing) {
                    if ($PSCmdlet.ShouldProcess($name,'Supprimer la regle creee par ce helper')) { Remove-NetFirewallRule -Name $name -ErrorAction Stop }
                }
                Write-FirewallMessage "Regle retiree ou absente : $name" $ResultFile
                continue
            }
            if ($existing.Count -gt 0) {
                foreach ($rule in $existing) {
                    $application = $rule | Get-NetFirewallApplicationFilter
                    $port = $rule | Get-NetFirewallPortFilter
                    $address = $rule | Get-NetFirewallAddressFilter
                    $expectedProtocol = if ($protocol -eq 'TCP') { @('TCP','6') } else { @('UDP','17') }
                    if ($application.Program -ne $exe -or $expectedProtocol -notcontains [string]$port.Protocol -or
                        [string]$port.LocalPort -ne '47584' -or [string]$address.RemoteAddress -ne 'LocalSubnet' -or
                        [string]$rule.Profile -ne 'Private' -or [string]$rule.Direction -ne 'Inbound' -or
                        [string]$rule.Action -ne 'Allow' -or [string]$rule.Enabled -ne 'True') {
                        throw "La regle existante differe de la portee prevue. Aucun remplacement : $name"
                    }
                }
                Write-FirewallMessage "Regle conforme deja presente : $name" $ResultFile
                continue
            }
            if ($PSCmdlet.ShouldProcess($name,"Creer Allow Inbound $protocol 47584 Private LocalSubnet pour le jeu")) {
                New-NetFirewallRule -Name $name -DisplayName "Chained Together LAN - $protocol 47584" -Group $script:FirewallGroup -Description 'Regle optionnelle du lanceur LAN, limitee au programme shipping et au sous-reseau local prive.' -Program $exe -Direction Inbound -Action Allow -Enabled True -Profile Private -Protocol $protocol -LocalPort 47584 -RemoteAddress LocalSubnet -EdgeTraversalPolicy Block -ErrorAction Stop | Out-Null
                $created.Add($name)
                Write-FirewallMessage "Regle ajoutee : $protocol 47584, Private, LocalSubnet." $ResultFile
            }
        }
    } catch {
        # Undo only the rules created by this invocation if the second addition fails.
        foreach ($name in $created) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue }
        throw
    }
    Write-FirewallMessage 'Operation terminee. Le profil reseau et les reglages globaux du pare-feu sont inchanges.' $ResultFile
}

# Dot-sourcing imports functions for isolated mocks without performing an action.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-LanFirewall @PSBoundParameters; exit 0 }
    catch {
        Write-FirewallMessage ('ERREUR : '+$_.Exception.Message) $ResultFile
        exit 1
    }
}
