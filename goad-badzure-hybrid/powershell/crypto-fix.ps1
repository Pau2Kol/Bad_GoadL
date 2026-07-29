<#
.SYNOPSIS
    crypto-fix.ps1 — B4 : répare le fournisseur cryptographique Provider Type 24
    (RSA/AES) sur dc01, cause suspectée du blocage de l'installation de SQL
    LocalDB par Entra Connect (erreur 25009 côté SQL, symptôme d'un problème
    crypto sous-jacent, probablement provoqué par une GPO de durcissement GOAD).

.DESCRIPTION
    À VÉRIFIER (important, cf. spec §4/B4 et CHANGELOG.md) : ce script
    reproduit un fix qui a fonctionné MANUELLEMENT sur ce lab précis. Une
    recherche documentaire (Microsoft Learn + web) n'a trouvé AUCUN KB ou
    article officiel couvrant ce scénario exact ("Provider Type 24 corrompu
    par un durcissement GPO empêchant SQL LocalDB de démarrer"). Seul point
    confirmé par la documentation officielle Microsoft : Provider Type 24
    (PROV_RSA_AES) correspond au nom de fournisseur
    "Microsoft Enhanced RSA and AES Cryptographic Provider" (constante
    MS_ENH_RSA_AES_PROV), cf.
    https://learn.microsoft.com/windows/win32/seccrypto/cryptographic-provider-names
    Tout le reste (ACL exacte requise, critère de détection d'un conteneur de
    clé "corrompu") est une reconstruction raisonnable, pas une certitude. À
    valider par l'opérateur sur un dc01 réel avant tout run non-interactif.

    Trois réparations, dans cet ordre :
    1. Registre : force la valeur "Name" des clés Provider Type 24 (64-bit ET
       WOW6432Node/32-bit) à "Microsoft Enhanced RSA and AES Cryptographic
       Provider".
    2. ACL : accorde Administrators + SYSTEM en contrôle total (récursif) sur
       C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys.
    3. Purge des conteneurs de clés de taille 0 octet dans MachineKeys
       (signature la plus courante d'un conteneur tronqué/corrompu).

    Exécuté sur dc01 via pypsrp, APRÈS gpo-inheritance.ps1 -Block (cf.
    scripts/30-goad-hardening-fix.sh — ordre critique, cause du bug
    d'origine : les GPO de durcissement GOAD réécrasent ce fix si l'héritage
    n'est pas bloqué avant).

    Idempotent : relit l'état actuel avant de modifier quoi que ce soit.
    Supporte -WhatIf/-Confirm (SupportsShouldProcess).

.PARAMETER MachineKeysPath
    Répertoire des conteneurs de clés RSA machine. Par défaut le chemin
    standard Windows.

.PARAMETER ProviderName
    Nom de fournisseur à écrire dans les clés Provider Type 24.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]
    $MachineKeysPath = 'C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys',

    [string]
    $ProviderName = 'Microsoft Enhanced RSA and AES Cryptographic Provider'
)

$ErrorActionPreference = 'Stop'

$script:ProviderType24Paths = @(
    'HKLM:\SOFTWARE\Microsoft\Cryptography\Defaults\Provider Types\Type 024',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Defaults\Provider Types\Type 024'
)

function Repair-ProviderType24Registry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]
        $RegistryPaths,

        [Parameter(Mandatory)]
        [string]
        $ProviderName
    )

    foreach ($path in $RegistryPaths) {
        if (-not (Test-Path -Path $path)) {
            if ($PSCmdlet.ShouldProcess($path, 'New-Item (clé Provider Type 24 absente)')) {
                New-Item -Path $path -Force | Out-Null
                Write-Warning "$path : clé absente, créée."
            }
        }

        $current = (Get-ItemProperty -Path $path -Name 'Name' -ErrorAction SilentlyContinue).Name

        if ($current -eq $ProviderName) {
            Write-Output "$path : valeur 'Name' déjà correcte ('$ProviderName')."
            continue
        }

        if ($PSCmdlet.ShouldProcess($path, "Set-ItemProperty Name='$ProviderName' (actuel : '$current')")) {
            Set-ItemProperty -Path $path -Name 'Name' -Value $ProviderName -Type String
            Write-Output "$path : 'Name' corrigé -> '$ProviderName' (était '$current')."
        }
    }
}

function Repair-MachineKeysAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Warning "$Path introuvable, réparation ACL ignorée."
        return
    }

    # À VÉRIFIER : Administrators + SYSTEM en FullControl récursif est la
    # remédiation la plus courante documentée pour ce type de problème d'ACL
    # sur MachineKeys, mais pas confirmée spécifiquement pour CE lab. Ajuster
    # si la procédure manuelle d'origine accordait des droits différents.
    if ($PSCmdlet.ShouldProcess($Path, "icacls : grant Administrators + SYSTEM FullControl (recurse)")) {
        $result = & icacls.exe $Path /grant 'BUILTIN\Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' /T 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "icacls a échoué sur $Path (code $LASTEXITCODE) : $result"
        }
        Write-Output "$Path : ACL réparée (Administrators + SYSTEM, FullControl, récursif)."
    }
}

function Remove-CorruptedKeyContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    # À VÉRIFIER : critère de détection d'un conteneur de clé "corrompu". La
    # spec (§4/B4) demande de "purger les conteneurs de clés corrompus si
    # présents" sans préciser le critère. Ici : fichiers de taille 0 octet
    # (signature la plus courante d'un conteneur tronqué). À confirmer avant
    # un run réel sur dc01 — un faux positif supprimerait une clé valide.
    if (-not (Test-Path -Path $Path)) {
        Write-Warning "$Path introuvable, purge des conteneurs ignorée."
        return
    }

    # -Force est nécessaire : les conteneurs de clés sous MachineKeys sont
    # habituellement marqués avec l'attribut Système (parfois aussi Caché), et
    # Get-ChildItem les ignore silencieusement sans -Force (aucune erreur,
    # juste un résultat incomplet) — sans ce commutateur, la purge pourrait ne
    # jamais rien trouver alors que des conteneurs corrompus sont bien présents.
    $corrupted = Get-ChildItem -Path $Path -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq 0 }

    if (-not $corrupted) {
        Write-Output "$Path : aucun conteneur de clé de taille 0 octet trouvé."
        return
    }

    foreach ($file in $corrupted) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove-Item (conteneur de clé corrompu, taille 0 octet)')) {
            Remove-Item -Path $file.FullName -Force
            Write-Output "Supprimé : $($file.FullName)"
        }
    }
}

Repair-ProviderType24Registry -RegistryPaths $script:ProviderType24Paths -ProviderName $ProviderName
Repair-MachineKeysAcl -Path $MachineKeysPath
Remove-CorruptedKeyContainer -Path $MachineKeysPath
