<#
.SYNOPSIS
    check-adsync.ps1 — vérifie l'état de la synchronisation Entra Connect sur dc01.

.DESCRIPTION
    Script de diagnostic pur (aucune modification d'état). Utilisé à trois
    moments :
    1. Manuellement par l'opérateur après le wizard ABA, pour confirmer que
       la synchro initiale est stable avant de lancer
       scripts/50-goad-gpo-unblock.sh.
    2. Automatiquement par scripts/00-deploy.sh finish, juste avant
       d'appeler le déblocage GPO : refuse de continuer si la synchro
       n'est pas confirmée stable.
    3. Automatiquement par scripts/50-goad-gpo-unblock.sh lui-même, juste
       après le déblocage de l'héritage GPO, pour confirmer que le
       durcissement GOAD n'a pas recassé le crypto fix (cause du bug
       d'origine).

    Vérifie :
    - Get-ADSyncScheduler : SyncCycleInProgress (attendu False) et
      NextSyncCyclePolicyType (attendu Delta après le cycle initial).
    - Service ADSync : doit être Running.
    - Registre Provider Type 24 (64-bit + WOW6432Node) : doit toujours
      contenir "Microsoft Enhanced RSA and AES Cryptographic Provider" (même
      vérification que crypto-fix.ps1, mais en lecture seule ici — aucune
      réparation, ce script ne fait que constater une régression éventuelle).

    Échoue (throw, remonte comme erreur via pypsrp/execute_ps) si le service
    ADSync n'est pas démarré ou si le registre Provider Type 24 a régressé —
    ce sont des signaux de régression franche. SyncCycleInProgress=True n'est
    qu'un avertissement (peut simplement signifier qu'un cycle est en cours).

.PARAMETER ExpectedProviderName
    Valeur attendue de la clé Provider Type 24 (même défaut que crypto-fix.ps1).
#>

[CmdletBinding()]
param(
    [string]
    $ExpectedProviderName = 'Microsoft Enhanced RSA and AES Cryptographic Provider'
)

$ErrorActionPreference = 'Stop'

$script:ProviderType24Paths = @(
    'HKLM:\SOFTWARE\Microsoft\Cryptography\Defaults\Provider Types\Type 024',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Defaults\Provider Types\Type 024'
)

function Test-AdSyncScheduler {
    Import-Module ADSync -ErrorAction Stop
    $scheduler = Get-ADSyncScheduler

    Write-Output "SyncCycleInProgress    : $($scheduler.SyncCycleInProgress)"
    Write-Output "NextSyncCyclePolicyType : $($scheduler.NextSyncCyclePolicyType)"

    if ($scheduler.SyncCycleInProgress) {
        Write-Warning 'Un cycle de synchronisation est en cours (SyncCycleInProgress=True) — pas forcément un problème, mais à reconfirmer une fois terminé.'
    }
    if ($scheduler.NextSyncCyclePolicyType -ne 'Delta') {
        Write-Warning "NextSyncCyclePolicyType = '$($scheduler.NextSyncCyclePolicyType)' (attendu 'Delta' après un cycle initial réussi)."
    }
}

function Test-AdSyncService {
    $service = Get-Service -Name 'ADSync' -ErrorAction SilentlyContinue

    if (-not $service) {
        throw "Service ADSync introuvable sur cette machine."
    }

    Write-Output "Service ADSync : $($service.Status)"

    if ($service.Status -ne 'Running') {
        throw "Service ADSync n'est pas démarré (état actuel : $($service.Status)) — régression probable du durcissement GPO."
    }
}

function Test-ProviderType24Registry {
    param(
        [Parameter(Mandatory)]
        [string[]]
        $RegistryPaths,

        [Parameter(Mandatory)]
        [string]
        $ExpectedProviderName
    )

    foreach ($path in $RegistryPaths) {
        $current = (Get-ItemProperty -Path $path -Name 'Name' -ErrorAction SilentlyContinue).Name
        Write-Output "$path -> Name = '$current'"

        if ($current -ne $ExpectedProviderName) {
            throw "$path : valeur 'Name' = '$current', attendu '$ExpectedProviderName' — le crypto fix a été écrasé (régression du durcissement GPO)."
        }
    }
}

Test-AdSyncScheduler
Test-AdSyncService
Test-ProviderType24Registry -RegistryPaths $script:ProviderType24Paths -ExpectedProviderName $ExpectedProviderName

Write-Output 'check-adsync : toutes les vérifications critiques sont passées (service ADSync actif, Provider Type 24 intact).'
