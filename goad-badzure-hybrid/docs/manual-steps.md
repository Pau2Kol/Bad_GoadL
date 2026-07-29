# Étapes manuelles — installation et validation d'Entra Connect

Ce document couvre les maillons du redéploiement qui ne peuvent pas être
automatisés par les scripts de ce projet, essentiellement parce qu'ils
nécessitent un login interactif dans un navigateur (contournement de la
politique de Conditional Access du tenant, erreur `530035`, qui bloque tout
login interactif/device-code scripté depuis une machine non enregistrée).

Se référer à `README.md` pour la place de ces étapes dans l'ordre
d'exécution global.

---

## Prérequis à ne pas oublier

**Avant de lancer le wizard (étape 2 ci-dessous)**, le compte
`sync-admin@$TENANT_DOMAIN` doit déjà exister, être activé, et avoir le rôle
**Hybrid Identity Administrator** — c'est le rôle de `scripts/40-prepare-entra-connect.sh`
(B6), qui a besoin d'un service principal app-only
(`GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET` dans `config/lab.env`) pour toute
écriture Graph, la Conditional Access du tenant bloquant les écritures
interactives.

**Ce bootstrap est maintenant scripté, pas manuel** : si
`GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET` sont absents de `config/lab.env`,
`scripts/40-prepare-entra-connect.sh` crée lui-même l'app registration, le
service principal, les 2 permissions Graph applicatives et leur
consentement admin, puis génère un secret et l'affiche une fois dans ses
logs — à noter immédiatement dans `config/lab.env`. Idempotent : relancé
avec les identifiants déjà renseignés, ce bootstrap est entièrement ignoré ;
relancé sans eux alors que le SP existe déjà, il détecte l'app/le SP/les
permissions existants (ne les recrée pas) et ne génère qu'un nouveau secret
(un secret client Azure AD n'étant jamais récupérable après coup).

Le SP créé lors des tests de ce projet existe déjà dans ce tenant :
- Nom : `goad-badzure-hybrid-automation`
- App ID (client ID) : `438e6c4d-693c-431f-aee6-349929a5875a`
- Permissions applicatives Graph, avec consentement admin déjà accordé :
  `User.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`
- Le secret client n'est **pas** stocké dans ce dépôt — à conserver par
  l'opérateur dans un gestionnaire de mots de passe. En cas de perte,
  relancer `scripts/40-prepare-entra-connect.sh` sans
  `GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET` dans `config/lab.env` : il détecte
  ce SP existant et régénère un nouveau secret automatiquement.

Sur un tout premier déploiement (nouveau tenant, aucun SP existant), le même
script crée tout depuis zéro — aucune étape manuelle nécessaire pour ce
bootstrap.

**Validation du mot de passe temporaire de sync-admin** : si
`scripts/40-prepare-entra-connect.sh` a dû créer le compte (cas d'un tenant
neuf), il affiche un mot de passe temporaire une seule fois dans ses logs
(`forceChangePasswordNextSignIn=true`). Se connecter une fois au portail
(https://myaccount.microsoft.com ou portal.azure.com) avec ce compte pour
définir le mot de passe définitif — **avant** de lancer le wizard ABA
ci-dessous, sans quoi le wizard échouera sur l'exigence de changement de mot
de passe au premier login.

---

## 1. Installation d'Entra Connect sur dc01

Télécharger et exécuter `AzureADConnect.msi` sur dc01 (accès via RDP/console
— le canal WinRM/pypsrp de ce projet n'est pas prévu pour transférer et
lancer un installeur interactif de cette taille).

Le binaire lui-même supporte une installation silencieuse (`/quiet`), mais
la **configuration ABA (Azure AD Connect Authentication)** qui suit
l'installation passe obligatoirement par le wizard graphique : c'est le seul
canal qui contourne la Conditional Access du tenant (le wizard ouvre un
navigateur embarqué pour le login interactif, distinct d'un appel API
scripté). Ne pas chercher à scripter cette partie.

## 2. Wizard ABA (Azure AD Connect Authentication)

Dans le wizard :
- Se connecter avec `sync-admin@$TENANT_DOMAIN`.
- **Ne JAMAIS utiliser le compte MSA personnel** (`...@outlook.fr` ou
  équivalent), même s'il fonctionne pour un login interactif classique.
  Cause racine documentée sur ce lab : un compte MSA personnel casse la
  validation par certificat lors du provisioning (`AADSTS700016`), même
  après un login interactif réussi. Le compte doit être cloud-only natif,
  `userType Member` — exactement ce que crée `scripts/40-prepare-entra-connect.sh`.
- Suivre le wizard jusqu'à la fin (sélection des OU à synchroniser —
  `sevenkingdoms.local`, cf. `data/inventory` GOAD-Light — filtres de
  synchronisation par défaut suffisants pour ce lab).

## 3. Vérification post-wizard

Avant de considérer la synchro comme stable, se connecter sur dc01 (WinRM,
via `scripts/30-goad-hardening-fix.sh` peut servir de modèle de tunnel — ou
directement) et exécuter `powershell/check-adsync.ps1`, ou manuellement :

```powershell
Get-ADSyncScheduler
# Attendu : SyncCycleInProgress: False, NextSyncCyclePolicyType: Delta
```

Puis vérifier côté tenant (portail Entra ID, ou lecture Graph) qu'au moins un
utilisateur GOAD (ex. un compte du domaine `sevenkingdoms.local`) est bien
apparu — test de bout en bout du merge GOAD/BadZure dans le même tenant.

**Ne pas passer à l'étape 4 tant que ces deux vérifications ne sont pas
concluantes.**

## 4. Déblocage de l'héritage GPO

Une fois la synchro confirmée stable (étape 3 concluante), lancer :

```bash
./scripts/50-goad-gpo-unblock.sh
```

Ce script débloque l'héritage GPO sur l'OU Domain Controllers, force un
`gpupdate`, puis vérifie automatiquement (via `check-adsync.ps1`) que le
service ADSync tourne toujours et que le registre Provider Type 24 n'a pas
été réécrasé par le durcissement GPO qui vient d'être réactivé — c'est
exactement le mécanisme du bug d'origine que ce projet corrige. Si cette
vérification échoue, le script s'arrête en erreur : ne pas ignorer ce
signal, cf. section suivante.

---

## En cas de régression après déblocage GPO

Si `check-adsync.ps1` signale que le service ADSync est arrêté ou que
Provider Type 24 a été réécrasé après le déblocage :
1. Rebloquer l'héritage immédiatement :
   `pwsh` sur dc01 (ou via le tunnel) : `powershell/gpo-inheritance.ps1 -Block`.
2. Réappliquer le crypto fix : `powershell/crypto-fix.ps1`.
3. Investiguer quelle GPO précise du durcissement GOAD réécrase le registre
   ou les ACL (comparer l'état avant/après un `gpupdate /force` ciblé) avant
   de retenter un déblocage — ceci n'a pas été creusé plus loin dans ce
   projet, cf. `# À VÉRIFIER` dans `powershell/crypto-fix.ps1`.

---

## Nettoyage des apps de provisioning résiduelles

Si un redéploiement laisse plusieurs apps `ConnectSyncProvisioning_*` dans le
tenant (conflit de certificat documenté par Microsoft),
`scripts/40-prepare-entra-connect.sh` en conserve automatiquement une seule
(la plus récente) et supprime les autres — à condition que
`GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET` soient renseignés. **Ne jamais**
supprimer manuellement un certificat `CN=kingslanding.sevenkingdoms.local`
si vous tombez dessus dans un listing de certificats plus large — c'est le
certificat LDAPS/auth du DC, à conserver impérativement.
