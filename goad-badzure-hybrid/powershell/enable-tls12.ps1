<#
.SYNOPSIS
    enable-tls12.ps1 — active TLS 1.2 (SCHANNEL + .NET Framework) sur dc01.

.DESCRIPTION
    Le wizard Azure AD Connect refuse de démarrer avec l'erreur "Incorrect
    version of TLS : TLS 1.2 is not configured on this server" tant que deux
    réglages registre ne sont pas faits, même sur un OS (Windows Server 2019)
    qui supporte TLS 1.2 nativement :
    1. SCHANNEL : activation explicite du protocole TLS 1.2 (client + serveur).
    2. .NET Framework : SchUseStrongCrypto, sans quoi les apps .NET
       (l'installeur/wizard Entra Connect en fait partie) négocient un TLS
       plus faible par défaut, indépendamment du support OS.

    Un redémarrage de dc01 est nécessaire APRÈS ce script SI une valeur a
    réellement été modifiée (SCHANNEL est chargé par LSASS au boot, ce
    changement registre seul ne suffit pas tant que le service n'a pas
    rechargé sa config) : dans ce cas, affiche "REBOOT_REQUIRED" sur une
    ligne dédiée (signal consommé par scripts/35-install-entra-connect.sh) en
    plus du warning humain. Rien n'est affiché si tout était déjà correct
    (idempotent, pas de redémarrage inutile à chaque run).

    Supporte -WhatIf/-Confirm (SupportsShouldProcess).
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$script:Changed = $false

function Set-RegistryDword {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [int] $Value
    )

    if (-not (Test-Path -Path $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'New-Item (clé absente)')) {
            New-Item -Path $Path -Force | Out-Null
        }
    }

    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name

    if ($current -eq $Value) {
        Write-Output "$Path\$Name : déjà correct ($Value)."
        return
    }

    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set-ItemProperty $Value (actuel : $current)")) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord
        Write-Output "$Path\$Name : corrigé -> $Value (était $current)."
        $script:Changed = $true
    }
}

# 1. SCHANNEL : TLS 1.2 client + serveur.
$tls12Client = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
$tls12Server = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server'

foreach ($path in @($tls12Client, $tls12Server)) {
    Set-RegistryDword -Path $path -Name 'Enabled' -Value 1
    Set-RegistryDword -Path $path -Name 'DisabledByDefault' -Value 0
}

# 2. .NET Framework : SchUseStrongCrypto (64-bit ET WOW6432Node/32-bit).
$netFrameworkPaths = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
)

foreach ($path in $netFrameworkPaths) {
    Set-RegistryDword -Path $path -Name 'SchUseStrongCrypto' -Value 1
    Set-RegistryDword -Path $path -Name 'SystemDefaultTlsVersions' -Value 1
}

if ($script:Changed) {
    Write-Output "REBOOT_REQUIRED"
    Write-Warning "Redémarrage de dc01 requis avant de relancer le wizard Azure AD Connect (SCHANNEL chargé au boot par LSASS)."
} else {
    Write-Output "TLS 1.2 déjà configuré (SCHANNEL + .NET Framework), rien à faire, pas de redémarrage nécessaire."
}
