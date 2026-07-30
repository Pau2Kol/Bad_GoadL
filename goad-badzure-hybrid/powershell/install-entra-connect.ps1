<#
.SYNOPSIS
    install-entra-connect.ps1 — télécharge et installe Azure AD Connect en
    mode silencieux sur dc01.

.DESCRIPTION
    Le canal WinRM de ce projet (pypsrp) ne peut pas transférer un fichier
    aussi gros que l'installeur Azure AD Connect (~100 Mo) : dc01 le
    télécharge donc lui-même depuis internet (accès sortant vérifié
    fonctionnel), via une simple commande PowerShell — aucun transfert de
    fichier binaire n'a besoin de passer par le tunnel WinRM.

    N'installe QUE le produit lui-même (mode silencieux, supporté par le
    setup). La configuration ABA (Azure AD Connect Authentication) qui suit
    passe obligatoirement par le wizard graphique en RDP (Conditional Access
    du tenant bloque tout login scripté) : hors périmètre de ce script,
    cf. docs/manual-steps.md.

    Idempotent : si AzureADConnect.exe existe déjà (signature d'un setup déjà
    installé), ne fait rien. Le service ADSync, lui, n'existe qu'APRÈS le
    wizard de configuration (pas après ce simple msiexec) : ne peut donc pas
    servir de critère ici, vérifié en conditions réelles (installation
    confirmée par la présence du dossier Program Files, alors qu'ADSync était
    encore absent).

.PARAMETER InstallerUrl
    URL de téléchargement direct du fichier .msi. Par défaut l'URL stable du
    CDN Microsoft. Ne PAS utiliser https://aka.ms/aadconnect ici : cet alias
    redirige vers la page HTML du Microsoft Download Center (details.aspx),
    pas vers le fichier lui-même — testé, Invoke-WebRequest télécharge alors
    une page HTML de ~120 Ko au lieu du vrai installeur (~145 Mo), et
    msiexec échoue ensuite avec le code 1620 (paquet invalide).

.PARAMETER InstallerPath
    Chemin local de téléchargement sur dc01.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]
    $InstallerUrl = 'https://download.microsoft.com/download/B/0/0/B00291D0-5A83-4DE7-86F5-980BC00DE05A/AzureADConnect.msi',

    [string]
    $InstallerPath = 'C:\Windows\Temp\AzureADConnect.msi'
)

$ErrorActionPreference = 'Stop'

function Test-EntraConnectInstalled {
    # AzureADConnect.exe (le wizard lui-même) est déposé par le setup dès
    # l'installation, avant même de le lancer : présence = signature fiable
    # que le msiexec a déjà été fait, sans dépendre du wizard.
    return Test-Path 'C:\Program Files\Microsoft Azure Active Directory Connect\AzureADConnect.exe'
}

function Test-ValidInstallerFile {
    # Garde-fou : une URL qui redirige vers une page HTML (Microsoft
    # Download Center, aka.ms mal configuré...) plutôt que le fichier produit
    # un .msi de quelques dizaines de Ko commençant par "<!DOCTYPE"/"<html",
    # que msiexec refuse ensuite avec le code 1620 (paquet invalide) —
    # symptôme confus sans ce contrôle explicite. Appelé aussi bien sur un
    # fichier tout juste téléchargé que sur un fichier déjà présent (un run
    # précédent a pu laisser un fichier invalide, l'idempotence ne doit pas
    # le faire passer pour valide sans vérification).
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    $size = (Get-Item -Path $Path).Length
    $head = [System.IO.File]::ReadAllBytes($Path) | Select-Object -First 15
    $headText = [System.Text.Encoding]::ASCII.GetString($head)
    return -not ($size -lt 1MB -or $headText -match '^\s*<')
}

function Get-EntraConnectInstaller {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]
        $Url,

        [Parameter(Mandatory)]
        [string]
        $Path
    )

    if (Test-Path -Path $Path) {
        if (Test-ValidInstallerFile -Path $Path) {
            Write-Output "$Path déjà présent et valide, téléchargement ignoré."
            return
        }
        Write-Warning "$Path présent mais invalide (téléchargement précédent incomplet/corrompu), suppression avant nouvelle tentative."
        Remove-Item -Path $Path -Force
    }

    if ($PSCmdlet.ShouldProcess($Url, "Invoke-WebRequest -> $Path")) {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing

        if (-not (Test-ValidInstallerFile -Path $Path)) {
            $size = (Get-Item -Path $Path).Length
            Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
            throw "Le téléchargement depuis $Url n'est pas un fichier .msi valide (taille=$size octets) : probablement une page HTML au lieu du binaire."
        }

        Write-Output "Installeur téléchargé : $Path."
    }
}

function Install-EntraConnect {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'msiexec /quiet /norestart')) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$Path`" /quiet /norestart" -Wait -PassThru

        # 3010 = succès, redémarrage requis (courant pour ce type d'installeur,
        # pas une erreur) ; tout autre code non nul est un vrai échec.
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "msiexec a échoué (code $($proc.ExitCode))."
        }

        Write-Output "Azure AD Connect installé (code $($proc.ExitCode))."
        if ($proc.ExitCode -eq 3010) {
            Write-Warning "Redémarrage de dc01 requis avant de lancer le wizard ABA."
        }
    }
}

if (Test-EntraConnectInstalled) {
    Write-Output "Azure AD Connect déjà installé (AzureADConnect.exe présent) : rien à faire."
    exit 0
}

Get-EntraConnectInstaller -Url $InstallerUrl -Path $InstallerPath
Install-EntraConnect -Path $InstallerPath
