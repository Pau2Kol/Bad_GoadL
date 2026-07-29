# SPEC — Automatisation du lab hybride GOAD + BadZure

Document de spécification pour l'agent d'implémentation. Il décrit **quoi produire** : les modifications à apporter aux fichiers de déploiement existants et les scripts à écrire. L'objectif est de rendre un redéploiement du lab hybride **reproductible et documenté**, à partir de deux projets (GOAD, BadZure) et d'un ensemble de customisations qui aujourd'hui n'existent que sous forme d'actions manuelles.

---

## 0. Règles générales pour l'agent

- **Toujours vérifier avant d'agir.** Avant de modifier un fichier, le lire et confirmer que son contenu correspond à ce que cette spec décrit. Si un écart est constaté (structure différente, valeur déjà changée, fichier absent), **s'arrêter et le signaler** plutôt que de forcer.
- **Documenter chaque changement.** Tout fichier créé ou modifié doit être accompagné d'une entrée dans un `CHANGELOG.md` à la racine du projet d'orchestration : quoi, où, pourquoi. Les scripts doivent être commentés (chaque bloc explique son intention).
- **L'agent ne déploie rien.** Il n'exécute ni `terraform apply/plan/destroy`, ni `ansible-playbook`, ni `BadZure.py build/destroy`, ni aucune commande Azure d'écriture. Il écrit du code et modifie des fichiers. Le déploiement reste à l'opérateur humain.
- **Ne jamais committer de secrets.** `.gitignore` doit exclure `*.tfstate`, `*.tfvars.json`, `terraform.tfvars`, `*.env`, tout fichier de credentials. Les valeurs sensibles (tenant_id, subscription_id, IP, app_id) sont des **variables d'entrée**, jamais hardcodées.
- **Idempotence obligatoire.** Chaque script est rejouable sans casser un état déjà partiellement en place : vérifier l'existence d'une ressource avant de la créer (`az ... show` en garde), sortir proprement si déjà fait. Le lab sera redéployé plusieurs fois.
- **Distinguer le vérifié du supposé.** Si une commande ou une syntaxe n'est pas certaine (option d'un outil, comportement d'une version), le signaler explicitement dans un commentaire `# À VÉRIFIER` plutôt que d'improviser.
- **Testabilité obligatoire (voir §10).** Tout script aval doit : (a) supporter un flag `--dry-run` qui logue chaque commande d'écriture au lieu de l'exécuter, avec les variables déjà interpolées ; (b) être structuré en **fonctions sourçables** (`source script.sh` sans effet de bord, chaque action encapsulée dans une fonction appelable isolément) plutôt qu'en un flot de commandes de haut en bas. Ces deux exigences permettent de tester sans redéployer le lab entier.

---

## 1. Contexte de l'infrastructure cible

Lab de cybersécurité hybride sur **Azure Free Trial** (quota strict : 4 vCPU par région). Deux projets fusionnés :

- **GOAD-Light** : AD on-prem simulé. VMs Windows `dc01` (hostname KINGSLANDING, domaine `sevenkingdoms.local`), `dc02`, `srv02` + un `jumpbox` Linux (bastion, seul point d'entrée public).
- **BadZure** : misconfigurations Entra ID + ressources Azure, dans le **même tenant** que GOAD.

**Topologie 3 régions** (contournement du quota 4 vCPU/région — chaque région a son propre quota) :

| Région | Contenu | vCPU |
|---|---|---|
| `denmarkeast` | GOAD : dc01 (Standard_B2s), dc02 (Standard_B1ms), srv02 (Standard_B1ms) | 4/4 |
| `indiasouthcentral` | jumpbox GOAD (Standard_B1ms) | 1/4 |
| `westus` | BadZure : 1 VM (Standard_D2s_v3) + ressources cloud (Key Vault, Storage, Cosmos DB, Function App, Logic App) | 2/4 |

**Ponts** :
- Identité : Microsoft Entra Connect synchronise l'AD GOAD vers le tenant (semi-manuel, wizard).
- Réseau : peering VNet BadZure↔GOAD et GOAD↔jumpbox (pas de peering jumpbox↔BadZure — non transitif, non requis).

**Ordre de déploiement** : BadZure d'abord (peuple le tenant), puis GOAD (sync dedans).

**Régions figées** : `westus`, `denmarkeast`, `indiasouthcentral` — déterminées empiriquement comme les seules combinant quota + disponibilité SKU pour cet abonnement Free Trial. Le lab est final : ces régions sont des constantes assumées, pas à redécouvrir dynamiquement.

---

## 2. Répartition amont / aval (décisions figées)

Résultat de l'analyse des points d'extension des deux projets. **Ne pas ré-arbitrer ces choix**, ils sont tranchés.

### AMONT — modifications dans les fichiers projet

| # | Customisation | Fichier | Nature |
|---|---|---|---|
| A1 | Sizing dc01 = B2s | `GOAD/ad/GOAD-Light/providers/azure/windows.tf` | Le champ `size` est déjà par-machine. Corriger la valeur pour `dc01`. |
| A2 | Région BadZure = westus (optionnel) | `BadZure/badzure.yml` | Figer la région explicitement si souhaité (sinon hardcodée `West US` dans le `.py`). |

### AVAL — scripts externes (`az` / PowerShell via pypsrp)

| # | Customisation | Raison de l'aval |
|---|---|---|
| B1 | Migration cross-région jumpbox (denmarkeast → indiasouthcentral) | GOAD a `location` en variable **globale unique**, pas de région par machine. Le jumpbox naît dans le VNet des DC ; le déplacer nécessite snapshot → copie cross-région → recréation. |
| B2 | Peering VNet (BadZure↔GOAD, GOAD↔jumpbox) | Aucun concept de peering dans les deux projets, states Terraform indépendants. |
| B3 | Règle NSG WinRM 5985 + restriction SSH/RDP à une IP | GOAD crée un NSG minimal (SSH `*`). Ajout/restriction en post-déploiement. |
| B4 | Crypto fix GOAD (registre Provider Type 24 + ACL MachineKeys) | **Décision : aval**, via pypsrp après provisioning. La version manuelle aval a fait ses preuves ; l'intégrer en task Ansible amont risque un mauvais séquencement (les GPO de durcissement GOAD réécrasent le fix — cause du bug d'origine). Robustesse > élégance. |
| B5 | Blocage/déblocage héritage GPO (OU Domain Controllers) | Idem B4 : aval, couplé au crypto fix. |
| B6 | Prep Entra Connect (SP app-only + sync-admin) | Hors périmètre des deux projets. |
| B7 | Install Entra Connect (MSI) + wizard ABA | Wizard interactif obligatoire (voir §5). |

---

## 3. Travail AMONT — modifications de fichiers

### A1 — Sizing dc01

Fichier : `GOAD/ad/GOAD-Light/providers/azure/windows.tf`

Localiser l'entrée de map correspondant à `dc01` dans la structure `vm_config` (ou équivalent). Le champ `size` vaut actuellement `"Standard_B1ms"`. Le passer à `"Standard_B2s"`.

**Vérifier avant** : confirmer que la structure est bien un map par-machine avec un champ `size`, et que dc01 y est identifiable sans ambiguïté. Si la structure diffère de la description, signaler.

**Raison** (à documenter dans le CHANGELOG) : dc01 héberge Entra Connect, dont l'installation de SQL LocalDB échoue (erreur 25009, mémoire insuffisante) sous 4 Go. B2s (2 vCPU / 4 Go) est le minimum viable. Ce resize avait été fait manuellement en `az vm resize` sans être reporté dans le fichier source — ce changement supprime ce drift.

**Impact quota à noter** : dc01 en B2s (2 vCPU) + dc02 (1) + srv02 (1) = 4/4 sur denmarkeast. Aucune marge. Le jumpbox DOIT être dans une autre région (d'où B1), sinon dépassement.

### A2 — Région BadZure (optionnel, à confirmer avec l'opérateur)

Fichier : `BadZure/badzure.yml`

La région des ressources BadZure est actuellement hardcodée à `West US` dans `src/entity_generator.py` (fonction `generate_resource_groups`, mode compteur simple utilisé par `resource_groups: 2`). 

**Deux options** — demander à l'opérateur laquelle avant d'agir :
- **Ne rien changer** : la région reste `westus` par le comportement par défaut du code. Simple, cohérent avec l'infra actuelle.
- **Expliciter** : réécrire `resource_groups:` sous forme de liste détaillée avec un champ `location: westus` par entrée (la fonction `generate_resource_groups_targeted` le supporte). Plus explicite mais modifie la structure de `badzure.yml`.

Recommandation par défaut : **ne rien changer** (option 1), sauf demande contraire. Documenter le choix.

---

## 4. Travail AVAL — scripts à écrire

Tous les scripts vont dans le projet d'orchestration (nouveau repo, structure en §6). Bash pour l'orchestration Azure, PowerShell (exécuté via pypsrp/tunnel WinRM) pour ce qui touche l'intérieur des VMs Windows. Variables d'entrée via un fichier `config/lab.env` (gitignored, un `.example` fourni).

### Variables d'entrée communes (`config/lab.env.example`)

```
SUBSCRIPTION_ID=
TENANT_ID=
TENANT_DOMAIN=          # <...>.onmicrosoft.com
RG_GOAD=GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE
RG_BADZURE=AI-ML-Services-RG
REGION_GOAD=denmarkeast
REGION_JUMPBOX=indiasouthcentral
REGION_BADZURE=westus
ALLOWED_IP=             # IP publique de l'opérateur, pour les règles NSG SSH/RDP
DC01_PRIVATE_IP=10.200.10.10
```

### B1 — Migration cross-région du jumpbox

Script : `scripts/10-migrate-jumpbox.sh`

Séquence validée par l'expérience (respecter l'ordre et les gates) :

1. **Snapshot incrémental** du disque OS du jumpbox. Le snapshot source DOIT être créé avec `--incremental true` dès le départ, sinon `--copy-start` échoue ensuite (`CreateOption.CopyStart is only supported for an incremental snapshot`).
2. **Copie cross-région** : `az snapshot create --source <snap> --location $REGION_JUMPBOX --copy-start true --incremental true`. **Gate bloquante** : poller `completionPercent` jusqu'à 100 — PAS `provisioningState: Succeeded` qui ne reflète pas le transfert de données.
3. **Disque** dans la région cible depuis le snapshot copié.
4. **Réseau** dans la région cible : VNet + subnet avec CIDR **non chevauchant** (le lab GOAD est en `10.200.10.0/24`, utiliser `10.201.0.0/16` + subnet `10.201.1.0/24`) + NSG explicite (un subnet créé from scratch n'a aucun NSG → `DenyAllInBound` implicite bloque tout ; il faut une règle SSH inbound explicite, cf. B3).
5. **IP publique** statique + NIC dans la région cible.
6. **VM** via `az vm create --attach-os-disk` avec le disque copié.
7. **Supprimer l'ancienne VM** (`az vm delete`) — nécessaire pour libérer le quota vCPU (Azure compte les VMs désallouées aussi).
8. **Nettoyer les orphelins** de l'ancienne région : ancien disque OS (Unattached), ancienne IP publique, ancienne NIC — sinon facturation résiduelle.

**Idempotence** : si le jumpbox est déjà dans `$REGION_JUMPBOX`, ne rien faire. Vérifier l'existence de chaque ressource avant création (snapshot, disque, VNet, NIC, VM portant le nom cible).

**Note** : ce script n'est nécessaire que pour un redéploiement from-scratch où GOAD a créé le jumpbox dans la région des DC. Si l'infra actuelle est déjà migrée, le script détecte l'état final et sort.

### B2 — Peering VNet

Script : `scripts/20-peer-networks.sh`

Deux peerings bidirectionnels :
- VNet BadZure (westus) ↔ VNet GOAD (denmarkeast)
- VNet GOAD (denmarkeast) ↔ VNet jumpbox (indiasouthcentral)

Pour chaque sens : `az network vnet peering create` avec `--allow-vnet-access --allow-forwarded-traffic` (`--allow-forwarded-traffic` requis pour le pivoting depuis le jumpbox).

**Pas de peering jumpbox↔BadZure** (décision figée).

**Pas de règle NSG supplémentaire nécessaire pour le trafic inter-VNet peeré** : la règle par défaut `AllowVnetInBound` (tag `VirtualNetwork`) couvre déjà les VNets peerés.

**Prérequis à vérifier** : CIDR non chevauchants entre les 3 VNets (déjà le cas : 10.0.0.0/16 BadZure, 10.200.10.0/24 GOAD, 10.201.0.0/16 jumpbox). Vérifier `peeringState == Connected` en sortie.

**Idempotence** : vérifier l'existence de chaque peering avant création.

### B3 — Règles NSG

Script : `scripts/21-nsg-rules.sh`

1. **WinRM 5985** : règle inbound autorisant le subnet jumpbox (10.201.0.0/16) vers dc01 sur 5985, sur le NSG GOAD. Techniquement le trafic passe déjà via `AllowVnetInBound`, mais une règle explicite de priorité maîtrisée sécurise le canal pypsrp contre une future règle de blocage. **À VÉRIFIER** : selon la politique de sécurité voulue, cette règle peut être jugée superflue — la proposer, laisser l'opérateur décider.
2. **Restriction SSH** : sur les NSG jumpbox et GOAD, remplacer les règles SSH source `*` par `$ALLOWED_IP`. L'infra actuelle expose SSH à tout Internet (anomalie relevée). Le jumpbox étant le seul point d'entrée public d'un lab volontairement vulnérable, cette restriction est importante.
3. **RDP** éventuel : si une règle RDP temporaire existe, la restreindre à `$ALLOWED_IP` également.

**Idempotence** : `az network nsg rule create` échoue si la règle existe → vérifier avant, ou utiliser `update`.

### B4 + B5 — Crypto fix + GPO toggle (PowerShell via pypsrp)

Scripts : `powershell/crypto-fix.ps1`, `powershell/gpo-inheritance.ps1`, pilotés par `scripts/30-goad-hardening-fix.sh`

Le script Bash établit le tunnel SSH→WinRM (`ssh -L 15985:$DC01_PRIVATE_IP:5985 <user>@<jumpbox_public_ip>`) et exécute les PowerShell sur dc01 via pypsrp (Python).

**Ordre critique** (raison du bug d'origine) :
1. `gpo-inheritance.ps1 -Block` : `Set-GPInheritance -Target "OU=Domain Controllers,DC=sevenkingdoms,DC=local" -IsBlocked Yes`. Empêche les GPO de durcissement GOAD de réécraser le fix crypto.
2. `crypto-fix.ps1` :
   - Réparer les clés du Provider Type 24 (RSA/AES) dans le registre, en **64-bit** (`HKLM:\SOFTWARE\Microsoft\Cryptography\Defaults\Provider Types\Type 024`) **et** 32-bit (`HKLM:\SOFTWARE\WOW6432Node\...`).
   - Réattribuer aux administrateurs et ouvrir les droits sur `C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys` (via `icacls` ou `win_acl` équivalent PowerShell). Purger les conteneurs de clés corrompus si présents.
3. **[Étape manuelle opérateur]** : installation + wizard Entra Connect (voir §5).
4. **Après synchro confirmée stable** : `gpo-inheritance.ps1 -Unblock` : `Set-GPInheritance ... -IsBlocked No` puis `gpupdate /force`. Vérifier ensuite que le Provider Type 24 tient toujours et que le service ADSync tourne (le durcissement ne doit pas recasser le crypto).

**Le déblocage GPO (étape 4) est un script séparé** (`scripts/50-goad-gpo-unblock.sh`), appelé seulement après validation de la synchro — pas dans la foulée du fix.

**À VÉRIFIER** : les chemins de registre exacts et la procédure de réparation des clés dépendent de l'état précis du durcissement GOAD. Reproduire ce qui a fonctionné manuellement ; ne pas inventer de clés.

### B6 — Préparation Entra Connect

Script : `scripts/40-prepare-entra-connect.sh`

**Contrainte d'authentification majeure** : une politique de Conditional Access du tenant (erreur `530035`) bloque tout login interactif ou device-code depuis une machine non enregistrée. **Ne pas utiliser** `az login` interactif / `Connect-MgGraph -UseDeviceAuthentication` pour les opérations scriptées. Utiliser un **service principal app-only** (cert ou secret) pour les appels Graph.

Étapes :
1. **Vérifier/créer le service principal app-only** utilisé pour l'automatisation Graph. Si sa création elle-même bute sur le Conditional Access, la documenter comme prérequis manuel (à créer une fois via le portail par l'opérateur). **À VÉRIFIER** : l'état initial d'authentification dont dispose l'agent/opérateur.
2. **Créer le compte de synchronisation cloud-only** : `sync-admin@$TENANT_DOMAIN`, via Graph (SP app-only). C'est la **cause racine du fix ABA** : un compte MSA personnel (`...@outlook.fr`) casse la validation par certificat (AADSTS700016) même s'il fonctionne pour le login interactif. Le compte doit être **cloud-only natif, userType Member**.
3. **Assigner le rôle Hybrid Identity Administrator** à ce compte (suffisant, préférable à Global Administrator).
4. Se connecter une fois au portail avec ce compte pour valider le mot de passe / purger l'exigence de changement au premier login — **étape manuelle**, à documenter.

**Idempotence** : vérifier si `sync-admin` existe déjà (et est Member, activé, avec le bon rôle) avant de le recréer.

### Nettoyage des apps de provisioning résiduelles

Inclure une fonction utilitaire (dans `40-prepare-entra-connect.sh` ou un script à part) qui liste et permet de supprimer les apps `ConnectSyncProvisioning_*` en doublon (conflit de certificat documenté par Microsoft). Un seul déploiement doit laisser une seule app. **Ne jamais supprimer** le certificat DC `CN=kingslanding.sevenkingdoms.local` s'il apparaît dans un listing de certificats — c'est le certificat LDAPS/auth du DC, à conserver.

---

## 5. Étapes manuelles (documentation) — `docs/manual-steps.md`

L'agent produit une doc opérateur claire pour les maillons non automatisables :

1. **Install Entra Connect** : `AzureADConnect.msi` sur dc01. L'installation silencieuse (`/quiet`) est possible pour le binaire, mais la **configuration ABA passe par le wizard graphique** (login navigateur embarqué — seul canal qui contourne le Conditional Access). À documenter comme étape manuelle.
2. **Wizard ABA** : utiliser le compte `sync-admin@$TENANT_DOMAIN` (JAMAIS le compte MSA personnel). Cause racine documentée : le MSA casse la validation certificat.
3. **Vérification post-wizard** : `Get-ADSyncScheduler` doit montrer `SyncCycleInProgress: False`, `NextSyncCyclePolicyType: Delta` (cycle initial OK). Vérifier qu'un user GOAD apparaît dans le tenant (test de bout en bout du merge).
4. **Déblocage GPO** : seulement après la synchro stable, lancer `scripts/50-goad-gpo-unblock.sh`.
5. **Prérequis à ne pas oublier** : compte sync-admin créé et validé (§B6) AVANT de lancer le wizard.

---

## 6. Structure du projet d'orchestration

```
goad-badzure-hybrid/
├── .gitignore                      # tfstate, tfvars, *.env, secrets, logs
├── README.md                       # vue d'ensemble, ordre d'exécution
├── CHANGELOG.md                    # journal de tous les changements de l'agent
├── NOTICE                          # attribution GOAD (GPL-3.0) / BadZure (Apache 2.0)
├── config/
│   └── lab.env.example
├── lib/
│   └── common.sh                   # helpers : logging, checks d'idempotence, chargement env
├── scripts/
│   ├── 10-migrate-jumpbox.sh       # B1
│   ├── 20-peer-networks.sh         # B2
│   ├── 21-nsg-rules.sh             # B3
│   ├── 30-goad-hardening-fix.sh    # B4+B5 (block GPO + crypto fix, via pypsrp)
│   ├── 40-prepare-entra-connect.sh # B6
│   ├── 50-goad-gpo-unblock.sh      # B5 (déblocage, post-synchro)
│   └── 99-lifecycle.sh             # start/stop/deallocate 3 régions + ressources cloud BadZure
├── powershell/
│   ├── crypto-fix.ps1
│   ├── gpo-inheritance.ps1         # -Block / -Unblock
│   └── check-adsync.ps1
└── docs/
    ├── manual-steps.md
    └── amont-changes.md            # ce qui a été modifié dans GOAD/BadZure (A1, A2)
```

### 99-lifecycle.sh — remplaçant de `azure.sh`

Le `azure.sh` actuel gère `start`/`stop` des VMs par RG, mais **ne touche pas aux ressources cloud BadZure** (Function App, Logic App) qui continuent de consommer même "lab éteint". Le nouveau lifecycle doit :
- `start` / `stop` : utiliser `deallocate` (pas `stop` — le quota compte les VMs allouées ET désallouées ; seul `deallocate` libère réellement, et arrête la facturation compute).
- Couvrir les 3 régions (ciblage par RG + nom, indépendant de la région).
- **Gérer aussi les ressources cloud BadZure** arrêtables (Function App / Logic App : stopper le plan ou désactiver, selon ce qui est applicable). Cosmos DB serverless n'a pas de start/stop — le noter.
- Ordre de `start` cohérent : DC d'abord, puis srv02, puis jumpbox.

---

## 7. Ordre d'exécution global (pour le README)

Redéploiement complet, du vierge au lab hybride fonctionnel :

1. **[Amont, une fois]** Appliquer les modifications de fichiers A1 (et A2 si retenu) dans GOAD/BadZure.
2. **[Opérateur]** Déployer BadZure (`BadZure.py build`) — peuple le tenant.
3. **[Opérateur]** Déployer GOAD-Light (via `goad.py`, provider azure) — crée les VMs (dc01 déjà en B2s grâce à A1).
4. `10-migrate-jumpbox.sh` — déplace le jumpbox vers indiasouthcentral, libère le quota denmarkeast.
5. `20-peer-networks.sh` — établit les deux peerings.
6. `21-nsg-rules.sh` — WinRM + restriction SSH/RDP.
7. `40-prepare-entra-connect.sh` — SP app-only + sync-admin.
8. `30-goad-hardening-fix.sh` — bloque GPO + applique le crypto fix sur dc01.
9. **[Opérateur, manuel]** Install + wizard Entra Connect avec sync-admin (cf. `docs/manual-steps.md`).
10. **[Opérateur]** Vérifier la synchro (`check-adsync.ps1`, user GOAD visible dans le tenant).
11. `50-goad-gpo-unblock.sh` — débloque les GPO une fois la synchro stable.

Gestion courante ensuite : `99-lifecycle.sh start|stop`.

---

## 8. Livrables attendus de l'agent

1. Les modifications amont (A1, obligatoire ; A2 selon choix opérateur), avec entrées CHANGELOG.
2. Tous les scripts de §4 et §6, idempotents, commentés, sans secrets hardcodés, **avec `--dry-run` et structure en fonctions sourçables** (cf. §10).
3. Les PowerShell de `powershell/`.
4. Les fixtures de test `test/setup-fixtures.sh`, `test/teardown-fixtures.sh`, `test/README.md` (cf. §10, Lot 6).
5. La documentation `docs/manual-steps.md` et `docs/amont-changes.md`.
6. `README.md` (ordre d'exécution §7 + workflow de validation §10), `CHANGELOG.md`, `NOTICE`, `.gitignore`, `config/lab.env.example`.
7. Un rapport final listant : ce qui a été fait, ce qui reste manuel, et tous les points marqués `# À VÉRIFIER` qui nécessitent une décision ou une validation de l'opérateur.

## 9. Points explicitement laissés à l'opérateur (ne pas trancher seul)

- A2 (région BadZure explicite ou non).
- B3 règle WinRM explicite (utile ou superflue selon politique de sécurité).
- L'identité d'authentification initiale pour les opérations Graph (SP pré-existant ? à créer manuellement ?).
- Toute divergence entre l'état réel des fichiers et cette spec.

---

## 10. Stratégie de test

Le lab complet est long et coûteux à déployer (provisioning GOAD = 30-45 min, quota Free Trial serré). Les scripts ne doivent PAS exiger un redéploiement complet pour être validés. Trois niveaux de test, du moins cher au plus cher.

### Niveau 1 — Validation statique (instantané, zéro Azure)

Applicable à chaque itération. L'agent doit produire un code qui passe :
- `bash -n <script>` (syntaxe) et `shellcheck <script>` (linter) pour tout Bash — le code doit être **shellcheck-clean** (variables quotées, pas de `SC2086`, etc.).
- `Invoke-ScriptAnalyzer` clean pour tout PowerShell.
- Pour les modifs Terraform GOAD : le résultat doit passer `terraform validate`, et un `terraform plan` ne doit montrer QUE le changement voulu (ex. pour A1 : un seul diff sur `size` de dc01, rien d'autre). Si le plan touche autre chose, c'est un bug.

### Niveau 2 — Dry-run et test unitaire (minutes, Azure lecture seule)

- **`--dry-run`** : chaque script aval, lancé avec ce flag, affiche la séquence exacte des commandes d'écriture qu'il exécuterait (variables interpolées) sans rien modifier. Permet de relire la logique sur l'infra réelle sans risque.
- **Fonctions sourçables** : parce que chaque script est structuré en fonctions, l'opérateur peut `source` le script et appeler une seule fonction (ex. `create_peering_goad_badzure`) pour la tester isolément, sans exécuter le script entier ni reconstruire de prérequis.

### Niveau 3 — Test sur fixtures jetables (le levier principal)

La plupart des scripts réseau/infra (B1 migration, B2 peering, B3 NSG) n'ont PAS besoin du vrai GOAD pour être testés — seulement de ressources Azure ressemblantes. D'où le **Lot 6** :

Créer sous `test/` :
- **`setup-fixtures.sh`** : monte un environnement factice minimal en ~2 min — deux VNets vides avec CIDR non chevauchants dans deux régions + une VM Linux `Standard_B1s` (la plus petite/moins chère) par région, imitant la topologie GOAD/jumpbox. Aucun GOAD, aucun BadZure, aucun Windows.
- **`teardown-fixtures.sh`** : détruit tout l'environnement factice (idempotent, sûr à relancer).
- **`test/README.md`** : tableau indiquant, pour chaque script aval, s'il se teste **sur fixtures** ou **sur le vrai lab uniquement** :

| Script | Testable sur fixtures ? | Raison |
|---|---|---|
| B1 migration jumpbox | Oui | Ne teste que snapshot/copie/recréation de VM Linux — les fixtures suffisent |
| B2 peering | Oui | Ne teste que la liaison de VNets |
| B3 NSG | Oui | Ne teste que des règles NSG |
| B4/B5 crypto fix + GPO | Non | Nécessite un vrai DC Windows durci par GOAD |
| B6 Entra Connect prep | Non | Nécessite le vrai tenant + Conditional Access |
| 99 lifecycle | Partiellement | La logique start/stop/deallocate se teste sur fixtures ; la partie ressources cloud BadZure non |

**Les fixtures utilisent les mêmes fonctions que les scripts réels** (pas de duplication de logique de test) : un test de peering appelle la vraie fonction `create_peering`, seulement avec des VNets factices en argument.

### Workflow de validation par script (pour le README)

1. `shellcheck` + `bash -n` (ou `Invoke-ScriptAnalyzer`).
2. Relecture du code.
3. `--dry-run` sur l'infra réelle → relire les commandes générées.
4. Si testable sur fixtures : `setup-fixtures.sh` → exécuter le script/la fonction pour de vrai → vérifier → `teardown-fixtures.sh`.
5. Marquer validé.

Le déploiement complet réel (niveaux combinés) n'est fait qu'**une fois en fin de projet**, comme test d'acceptation, et par étapes avec points de contrôle — jamais comme moyen de debug d'un script individuel.
