# Étapes manuelles : installation et validation d'Entra Connect

Ce document couvre le wizard ABA et sa validation, qui ne peuvent pas être
automatisés (la Conditional Access du tenant bloque tout login scripté dans
un navigateur), ainsi que les prérequis à ne pas oublier avant de les lancer.

Voir `README.md` pour la place de ces étapes dans l'ordre global.

---

## Prérequis à ne pas oublier

**Avant de lancer le wizard (étape 2)**, le compte
`sync-admin@$TENANT_DOMAIN` doit déjà exister, être activé, et avoir le rôle
**Hybrid Identity Administrator**. C'est ce que fait
`scripts/40-prepare-entra-connect.sh`.

Si `scripts/40-prepare-entra-connect.sh` a dû créer le compte sync-admin
(cas d'un tenant neuf), il affiche un mot de passe temporaire une seule fois
dans ses logs. Se connecter une fois au portail
(https://myaccount.microsoft.com) avec ce compte pour définir le mot de
passe définitif, **avant** de lancer le wizard ABA : sinon le wizard échoue
sur l'exigence de changement de mot de passe au premier login.

Le script crée aussi lui-même le service principal app-only nécessaire
(`goad-badzure-hybrid-automation`) si `GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET`
sont absents de `config/lab.env` : aucune étape manuelle requise pour ça. Le
secret généré est automatiquement écrit dans `config/lab.env` (plus rien à
noter à la main). En cas de perte, relancer le script sans ces deux
variables : il détecte le SP existant et en régénère un nouveau.

---

## 1. Installation d'Entra Connect sur dc01 (automatisée)

`./scripts/00-deploy.sh link` télécharge et installe silencieusement
`AzureADConnect.msi` sur dc01 (`scripts/35-install-entra-connect.sh`) : dc01
télécharge lui-même l'installeur depuis internet (accès sortant vérifié
fonctionnel) via une commande PowerShell, le canal WinRM de ce projet ne
pouvant pas transférer un fichier aussi gros (~145 Mo). Rien de manuel ici.

La configuration ABA (Azure AD Connect Authentication) qui suit passe en
revanche obligatoirement par le wizard graphique : c'est le seul canal qui
contourne la Conditional Access du tenant. Ne pas chercher à scripter cette
partie.

## 2. Wizard ABA

Dans le wizard :
- Se connecter avec `sync-admin@$TENANT_DOMAIN`.
- **Ne jamais utiliser un compte personnel** (`...@outlook.fr` ou
  équivalent), même s'il fonctionne pour un login classique : un compte
  personnel casse la validation par certificat lors du provisioning
  (erreur `AADSTS700016`), même après un login réussi.
- Suivre le wizard jusqu'à la fin, en sélectionnant l'OU `sevenkingdoms.local`
  à synchroniser (filtres par défaut suffisants pour ce lab).

## 3. Vérification post-wizard

Avant de continuer, se connecter sur dc01 (WinRM) et exécuter
`powershell/check-adsync.ps1`, ou manuellement :

```powershell
Get-ADSyncScheduler
# Attendu : SyncCycleInProgress: False, NextSyncCyclePolicyType: Delta
```

Puis vérifier côté tenant (portail Entra ID, ou Graph) qu'au moins un
utilisateur GOAD (un compte du domaine `sevenkingdoms.local`) est bien
apparu.

**Ne pas passer à l'étape 4 tant que ces deux vérifications ne sont pas
concluantes.**

## 4. Déblocage de l'héritage GPO

Une fois la synchro confirmée stable :

```bash
./scripts/50-goad-gpo-unblock.sh
```

Ce script débloque l'héritage GPO sur l'OU Domain Controllers, force un
`gpupdate`, puis vérifie que le service ADSync tourne toujours et que le
crypto fix n'a pas été écrasé par le durcissement GPO réactivé. Si cette
vérification échoue, le script s'arrête en erreur : ne pas l'ignorer, voir
la section suivante.

---

## En cas de régression après déblocage GPO

Si le service ADSync s'est arrêté ou que le crypto fix a été écrasé après le
déblocage :

1. Rebloquer l'héritage immédiatement : `powershell/gpo-inheritance.ps1 -Block`
   sur dc01.
2. Réappliquer le crypto fix : `powershell/crypto-fix.ps1`.
3. Investiguer quelle GPO précise du durcissement GOAD réécrase le registre
   ou les ACL (comparer l'état avant/après un `gpupdate /force` ciblé) avant
   de retenter un déblocage.

---

## Nettoyage des apps de provisioning résiduelles

Si un redéploiement laisse plusieurs apps `ConnectSyncProvisioning_*` dans
le tenant, `scripts/40-prepare-entra-connect.sh` en conserve automatiquement
une seule (la plus récente) et supprime les autres.

**Ne jamais** supprimer manuellement un certificat
`CN=kingslanding.sevenkingdoms.local` si vous en croisez un dans un listing
plus large : c'est le certificat LDAPS/auth du DC, à conserver
impérativement.
