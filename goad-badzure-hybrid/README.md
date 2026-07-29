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

## Installation

Copier `config/lab.env.example` vers `config/lab.env` et renseigner les
valeurs (tenant, abonnement, régions). Ce fichier n'est jamais commité.

## Déployer le lab de zéro

```bash
# 1. Peupler le tenant avec BadZure
cd ../BadZure && python3 BadZure.py build

# 2. Déployer GOAD-Light (variante allégée de GOAD : VMs + configuration du domaine)
cd ../GOAD && python3 goad.py -t install -l GOAD-Light -p azure
```

Si l'étape 2 reste bloquée ou échoue sur un conflit de quota, voir
`docs/troubleshooting.md`.

```bash
# 3. Relier les deux labs
cd ../goad-badzure-hybrid
./scripts/10-migrate-jumpbox.sh    # déplace le jumpbox, libère du quota
./scripts/20-peer-networks.sh      # relie les réseaux GOAD et BadZure
./scripts/21-nsg-rules.sh          # restreint SSH/RDP à votre IP

# 4. Ces deux scripts sont indépendants : l'ordre entre eux n'a pas d'importance
./scripts/40-prepare-entra-connect.sh   # crée le compte sync-admin
./scripts/30-goad-hardening-fix.sh      # sécurise dc01
```

(Les préfixes numériques des scripts suivent l'ordre historique de test du
projet, pas une dépendance stricte entre eux.)

**5. Étape manuelle.** D'abord, se connecter une fois sur
`https://myaccount.microsoft.com` avec le compte `sync-admin` et définir son
mot de passe définitif (un mot de passe temporaire s'affiche dans les logs
de l'étape 4) : sans ça, le wizard échoue. Ensuite, sur dc01 (accès RDP via
le jumpbox), installer Entra Connect et suivre le wizard avec ce compte
`sync-admin`. Détail complet dans `docs/manual-steps.md`.

```bash
# 6. Vérifier que la synchro a fonctionné, puis débloquer les GPO
./scripts/50-goad-gpo-unblock.sh
```

## Usage courant

```bash
./scripts/99-lifecycle.sh stop    # fin de session, économise les coûts Azure
./scripts/99-lifecycle.sh start   # reprise
```

## Pour aller plus loin

- `docs/manual-steps.md` : détail de l'étape 5 (Entra Connect).
- `docs/troubleshooting.md` : problèmes connus et solutions.
- `docs/amont-changes.md` : modifications apportées aux fichiers GOAD.
- `docs/testing-strategy.md` : comment tester un script sans redéployer le
  lab entier.
- `CHANGELOG.md` : historique complet du projet.
- `NOTICE` : attribution des licences (GOAD en GPL-3.0, BadZure en
  Apache-2.0).
