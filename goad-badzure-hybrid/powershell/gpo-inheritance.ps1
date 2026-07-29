<#
.SYNOPSIS
    gpo-inheritance.ps1 — B5 : bascule l'héritage GPO sur l'OU
    "OU=Domain Controllers,DC=sevenkingdoms,DC=local".

.DESCRIPTION
    -Block   : Set-GPInheritance -IsBlocked Yes. Empêche les GPO de
               durcissement GOAD d'écraser le crypto fix, à exécuter AVANT
               crypto-fix.ps1 (cf. scripts/30-goad-hardening-fix.sh).
    -Unblock : Set-GPInheritance -IsBlocked No, puis gpupdate /force. À
               exécuter uniquement après validation d'une synchro Entra
               Connect stable (cf. scripts/50-goad-gpo-unblock.sh).

    Idempotent : ne modifie rien si l'héritage est déjà dans l'état demandé.
    Supporte -WhatIf/-Confirm (SupportsShouldProcess) en plus du --dry-run
    du script Bash appelant, qui peut passer -WhatIf ici pour une double
    garantie de non-exécution.

.PARAMETER Block
    Bloque l'héritage GPO sur l'OU Domain Controllers.

.PARAMETER Unblock
    Débloque l'héritage GPO sur l'OU Domain Controllers et force un gpupdate.

.PARAMETER TargetOU
    OU cible. Par défaut celle du domaine GOAD-Light
    ("OU=Domain Controllers,DC=sevenkingdoms,DC=local"), surchargeable pour
    tester sur un autre domaine/OU.
#>

[CmdletBinding(DefaultParameterSetName = 'Block', SupportsShouldProcess)]
param(
    [Parameter(ParameterSetName = 'Block')]
    [switch]
    $Block,

    [Parameter(ParameterSetName = 'Unblock')]
    [switch]
    $Unblock,

    [string]
    $TargetOU = 'OU=Domain Controllers,DC=sevenkingdoms,DC=local'
)

$ErrorActionPreference = 'Stop'

Import-Module GroupPolicy -ErrorAction Stop

function Set-DcGpoInheritance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Yes', 'No')]
        [string]
        $IsBlocked,

        [Parameter(Mandatory)]
        [string]
        $TargetOU
    )

    $current = Get-GPInheritance -Target $TargetOU
    $currentlyBlocked = if ($current.GpoInheritanceBlocked) { 'Yes' } else { 'No' }

    if ($currentlyBlocked -eq $IsBlocked) {
        Write-Output "Héritage GPO sur '$TargetOU' déjà dans l'état demandé (IsBlocked=$IsBlocked). Rien à faire."
        return
    }

    if ($PSCmdlet.ShouldProcess($TargetOU, "Set-GPInheritance -IsBlocked $IsBlocked")) {
        Set-GPInheritance -Target $TargetOU -IsBlocked $IsBlocked | Out-Null
        Write-Output "Héritage GPO sur '$TargetOU' réglé sur IsBlocked=$IsBlocked."
    }
}

if ($Block) {
    Set-DcGpoInheritance -IsBlocked 'Yes' -TargetOU $TargetOU
}
elseif ($Unblock) {
    Set-DcGpoInheritance -IsBlocked 'No' -TargetOU $TargetOU

    if ($PSCmdlet.ShouldProcess('localhost', 'gpupdate /force')) {
        Write-Output 'Exécution de gpupdate /force...'
        $gpupdateOutput = & gpupdate.exe /force 2>&1
        Write-Output $gpupdateOutput
        if ($LASTEXITCODE -ne 0) {
            throw "gpupdate /force a échoué (code $LASTEXITCODE)."
        }
        Write-Output 'gpupdate /force terminé.'
    }
}
else {
    throw 'Spécifier -Block ou -Unblock.'
}
