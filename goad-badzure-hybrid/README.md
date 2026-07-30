# goad-badzure-hybrid

Scripts qui déploient et relient, dans le même tenant Microsoft Entra ID,
deux labs de cybersécurité tiers :

- **[GOAD](../GOAD)** : Active Directory on-prem vulnérable (`dc01`, `dc02`,
  `srv02`, domaine `sevenkingdoms.local`, plus un jumpbox Linux comme seul
  point d'entrée public).
- **[BadZure](../BadZure)** : misconfigurations Entra ID et ressources Azure.

Ce dossier ne contient pas le code de GOAD ni de BadZure : seulement ce qui
pilote leur déploiement combiné (peering réseau, hardening, Entra Connect,
cycle de vie).

## Prérequis

- `az` (Azure CLI), déjà connecté (`az login`).
- `bash` 4+.
- `python3` avec le paquet `pypsrp` (`pip install pypsrp`).
- `ssh`.
- `terraform`.

Rien à installer ni à configurer avant de déployer. Une valeur explicite
dans `config/lab.env` reste toujours prioritaire sur l'auto-détection.

## Déployer le lab de zéro

Quatre commandes, une étape manuelle au milieu :

```bash
# 1. Peupler le tenant avec BadZure (badzure.yml n'a pas besoin d'être rempli :
#    ces variables d'environnement sont prioritaires sur sa config)
export BADZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
export BADZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export BADZURE_DOMAIN=$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization" --query "value[0].verifiedDomains[?isDefault]|[0].name" -o tsv)
cd ../BadZure && python3 BadZure.py build

# 2. Déployer GOAD-Light (VMs + configuration du domaine, jumpbox directement
#    dans sa propre région)
cd ../goad-badzure-hybrid && ./scripts/00-deploy.sh goad

# 3. Relier GOAD et BadZure : peering réseau, règles NSG, création du compte
#    sync-admin, hardening de dc01
./scripts/00-deploy.sh link
```

**4. Étape manuelle.** D'abord, se connecter une fois sur
`https://myaccount.microsoft.com` avec le compte `sync-admin` et définir son
mot de passe définitif (un mot de passe temporaire s'affiche dans les logs
de l'étape 3) : sans ça, le wizard échoue. Ensuite, sur dc01 (accès RDP via
le jumpbox), installer Entra Connect et suivre le wizard avec ce compte
`sync-admin`. Détail complet dans `docs/manual-steps.md`.

```bash
# 5. Une fois la synchro vérifiée, débloquer les GPO
./scripts/00-deploy.sh finish
```

`finish` vérifie lui-même que la synchro est stable avant de continuer : il
refuse d'agir si ce n'est pas le cas.

## Usage courant

```bash
./scripts/99-lifecycle.sh stop    # fin de session, économise les coûts Azure
./scripts/99-lifecycle.sh start   # reprise
./scripts/reset-goad.sh           # supprime le déploiement GOAD-Light en cours pour repartir de zéro
```

## Pour aller plus loin

- `docs/manual-steps.md` : détail de l'étape 4 (Entra Connect).
- `docs/troubleshooting.md` : problèmes connus et solutions.
- `docs/amont-changes.md` : modifications apportées aux fichiers GOAD.
- `NOTICE` : attribution des licences (GOAD en GPL-3.0, BadZure en
  Apache-2.0).
