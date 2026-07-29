# goad-badzure-hybrid

Projet d'orchestration pour un lab de cybersécurité hybride sur Azure Free Trial,
fusionnant deux projets tiers déployés dans le **même tenant Microsoft Entra ID** :

- **[GOAD](../GOAD)** (GPL-3.0) : AD on-prem simulé, VMs Windows `dc01`
  (KINGSLANDING, domaine `sevenkingdoms.local`), `dc02`, `srv02`, plus un jumpbox
  Linux (bastion, seul point d'entrée public).
- **[BadZure](../BadZure)** (Apache-2.0) : misconfigurations Entra ID et ressources
  Azure.

Ce dépôt ne contient ni le code de GOAD ni celui de BadZure : il produit les
scripts et fichiers de configuration qui pilotent leur déploiement combiné
(peering réseau, hardening, préparation Entra Connect, cycle de vie). Voir
`NOTICE` pour l'attribution des licences, `CHANGELOG.md` pour l'historique des
changements, et `docs/amont-changes.md` pour les modifications apportées
directement aux fichiers GOAD.

**Cet agent ne déploie rien** : ni `terraform apply/plan/destroy`, ni
`ansible-playbook`, ni `BadZure.py build/destroy`, ni commande Azure d'écriture.
Tous les scripts sont exécutés par un opérateur humain.

## Prérequis (machine exécutant les scripts)

- `az` (Azure CLI), déjà connecté (`az login`).
- `bash` 4+, `shellcheck` (validation statique).
- `python3` avec le paquet **`pypsrp`** installé (`pip install pypsrp`), requis
  par `lib/run_powershell.py`, utilisé par `scripts/30-goad-hardening-fix.sh`
  et `scripts/50-goad-gpo-unblock.sh` (B4/B5) pour piloter PowerShell sur dc01
  via WinRM. Sans ce paquet, ces deux scripts échouent immédiatement
  (`ModuleNotFoundError`) dès la première tentative de connexion réelle (pas
  d'erreur en `--dry-run`, qui ne l'importe jamais, cf. commentaire dans
  `lib/run_powershell.py`).
- `ssh` (client) pour le tunnel SSH vers WinRM des mêmes scripts B4/B5.
- PowerShell (`pwsh`) et module `PSScriptAnalyzer` uniquement pour la
  validation statique des `.ps1`, pas nécessaire à l'exécution réelle des
  scripts (le PowerShell tourne sur dc01, pas sur la machine opérateur).
- Un service principal app-only Graph pour `scripts/40-prepare-entra-connect.sh`
  (B6), **bootstrappé automatiquement par le script lui-même** si
  `GRAPH_CLIENT_ID`/`GRAPH_CLIENT_SECRET` sont absents de `config/lab.env`
  (aucune étape manuelle). Existe déjà pour ce lab
  (`goad-badzure-hybrid-automation`) : voir `docs/manual-steps.md` pour
  l'App ID et la procédure si le secret est perdu.

## Topologie (3 régions, contournement du quota 4 vCPU/région)

| Région | Contenu | vCPU |
|---|---|---|
| `denmarkeast` | GOAD : dc01 (Standard_B2s), dc02 (Standard_B1ms), srv02 (Standard_B1ms) | 4/4 |
| `indiasouthcentral` | jumpbox GOAD (Standard_B1ms) | 1/4 |
| `westus` | BadZure : VM et ressources cloud (Key Vault, Storage, Cosmos DB, Function App, Logic App) | 2/4 |

## Ordre d'exécution global

Redéploiement complet, du vierge au lab hybride fonctionnel :

1. **[Amont, une fois]** Appliquer les modifications de fichiers A1 (et A2 si
   retenu) dans GOAD/BadZure, voir `docs/amont-changes.md`.
2. **[Opérateur]** Déployer BadZure (`BadZure.py build`), peuple le tenant.
3. **[Opérateur]** Déployer GOAD-Light (`goad.py`, provider azure), crée les
   VMs (dc01 déjà en B2s grâce à A1).

   **Deux pièges réels rencontrés lors du test de redéploiement complet
   (2026-07-28/29, détail dans `CHANGELOG.md`), à connaître avant de lancer
   cette étape :**
   - `goad.py -t install` peut rester bloqué sur la confirmation Terraform
     (`Only 'yes' will be accepted`) même en pipant `y` sur son propre
     prompt : `input()` de Python consomme plus que sa ligne sur le stdin
     partagé, privant le `terraform apply` enfant du `yes` dont il a
     besoin. Contournement : lancer `terraform apply -auto-approve`
     directement dans `workspace/<instance>/provider/`, puis compléter le
     provisioning Ansible manquant (voir point suivant).
   - Si ce contournement est utilisé, `goad.py` n'a pas exécuté sa phase
     Ansible (promotion contrôleur de domaine, GPOs, utilisateurs AD) :
     seules les VM nues existent. Il faut alors lancer manuellement
     `prepare_jumpbox()` puis `provision_lab()` (mêmes méthodes que
     `goad.py`, via un petit script Python les invoquant directement, cf.
     `CHANGELOG.md` pour l'exemple exact utilisé).
   - Si le jumpbox est migré (`10-migrate-jumpbox.sh`) puis qu'un nouveau
     `terraform apply` est nécessaire (ex. retry après un conflit de
     quota sur dc01), Terraform tente de recréer le jumpbox dans
     `$REGION_GOAD` (son state ne connaît pas la migration hors-Terraform).
     Utiliser `terraform apply -target=...` restreint aux ressources
     réellement nécessaires (ex. les VM Windows), ou nettoyer le state
     (`terraform state rm`) pour les ressources jumpbox : non corrigé en
     amont à ce stade (cf. `CHANGELOG.md`, section correspondante).

4. `scripts/10-migrate-jumpbox.sh` : déplace le jumpbox vers
   `$REGION_JUMPBOX`, libère le quota `$REGION_GOAD`.
5. `scripts/20-peer-networks.sh` : établit les deux peerings.
6. `scripts/21-nsg-rules.sh` : WinRM et restriction SSH/RDP.
7. `scripts/40-prepare-entra-connect.sh` : SP app-only et sync-admin.
8. `scripts/30-goad-hardening-fix.sh` : bloque l'héritage GPO et applique le
   crypto fix sur dc01.

   **Note sur la numérotation** : `40` s'exécute avant `30` dans cet ordre.
   Les préfixes numériques suivent l'ordre de test historique du projet, pas
   une dépendance stricte entre ces deux scripts : `30` agit uniquement sur
   dc01 en local (WinRM), `40` agit uniquement sur le tenant Entra ID
   (Graph), ils sont indépendants l'un de l'autre et peuvent être exécutés
   dans l'autre sens sans conséquence. Les deux doivent simplement être
   terminés avant l'étape 9.
9. **[Opérateur, manuel]** Installation et wizard Entra Connect avec
   sync-admin (cf. `docs/manual-steps.md`).
10. **[Opérateur]** Vérifier la synchro (`powershell/check-adsync.ps1`, user
    GOAD visible dans le tenant).
11. `scripts/50-goad-gpo-unblock.sh` : débloque les GPO une fois la synchro
    stable.

Gestion courante ensuite : `scripts/99-lifecycle.sh start|stop`.

## Configuration

Copier `config/lab.env.example` vers `config/lab.env` (gitignored) et
renseigner les valeurs réelles avant d'exécuter un script.

## Stratégie de test et workflow de validation

Le lab complet est long et coûteux à redéployer (provisioning GOAD entre 30 et
45 min, quota Azure Free Trial serré). Aucun script de ce projet ne doit
exiger un redéploiement complet pour être validé. Trois niveaux, du moins
cher au plus cher :

1. **Validation statique** (instantané, zéro Azure) : `bash -n` et
   `shellcheck` (shellcheck-clean, sans exception) pour tout script Bash ;
   `Invoke-ScriptAnalyzer` pour tout PowerShell. Pour une modification
   Terraform GOAD (A1/A2) : `terraform validate` puis `terraform plan` ne doit
   montrer QUE le changement voulu.
2. **Dry-run et test unitaire** (minutes, Azure lecture seule) : chaque
   script aval supporte `--dry-run`, qui logue la séquence exacte des
   commandes d'écriture (variables interpolées) sans rien modifier. Chaque
   script étant structuré en fonctions sourçables, une fonction individuelle
   peut aussi être testée isolément via `source scripts/xx-....sh` puis un
   appel direct, sans exécuter le script entier.
3. **Test sur fixtures jetables** (le levier principal pour les scripts
   réseau/infra B1/B2/B3) : cf. `test/README.md` (Lot 6) pour le détail. Un
   environnement Azure factice minimal (VNets et petites VM Linux) permet de
   tester `10-migrate-jumpbox.sh`, `20-peer-networks.sh`, `21-nsg-rules.sh`
   pour de vrai sans dépendre du lab GOAD/BadZure réel. B4/B5 (crypto fix,
   GPO) et B6 (Entra Connect) ne sont testables que sur le vrai lab (DC
   Windows durci, vrai tenant avec Conditional Access) ; `99-lifecycle.sh` est
   partiellement testable sur fixtures (logique start/stop/deallocate oui,
   ressources cloud BadZure non).

Workflow par script, avant de le considérer validé : `shellcheck`/
`Invoke-ScriptAnalyzer`, puis relecture, puis `--dry-run` sur l'infra réelle,
puis si testable sur fixtures `setup-fixtures.sh`, exécution réelle ciblée,
`teardown-fixtures.sh`. Le déploiement complet réel n'est fait qu'une fois en
fin de projet, comme test d'acceptation par étapes, jamais comme moyen de
debug d'un script individuel.

## État du projet

Ce dépôt est construit lot par lot ; voir `CHANGELOG.md` pour le détail de
chaque lot livré. Tous les scripts sous `scripts/` et `powershell/` sont
implémentés, `shellcheck`/`Invoke-ScriptAnalyzer`-clean, et testés pour de
vrai en conditions réelles lors d'un redéploiement complet from scratch
(destruction puis reconstruction intégrale du lab), y compris les chemins
d'écriture de `40-prepare-entra-connect.sh`, `30-goad-hardening-fix.sh` et
`50-goad-gpo-unblock.sh`. Détail complet du test final dans `CHANGELOG.md`.
