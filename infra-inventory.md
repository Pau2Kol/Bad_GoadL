# Inventaire infrastructure — Lab hybride GOAD + BadZure

Audit en lecture seule, réalisé le 2026-07-27. Toutes les commandes ci-dessous sont des lectures (`show`/`list`/`get`/`query`), aucune écriture. Les valeurs sensibles sont remplacées par des placeholders `<...>` — voir la table de correspondance en fin de fichier (section "Secrets — NE PAS COMMITTER").

Note d'état : au moment de cet audit, toutes les VMs étaient **désallouées** (arrêtées volontairement). Cela n'affecte pas les sections 1 à 8 (métadonnées ARM, indépendantes de l'état runtime). La section 9 (état interne du service ADSync) s'appuie sur les dernières valeurs connues, capturées plus tôt dans la même session pendant que `dc01` tournait — non re-vérifiées ici pour éviter de redémarrer une VM inutilement.

---

## Section 1 — Contexte d'abonnement et identité

```bash
az account show --query "{SubscriptionId:id, TenantId:tenantId, State:state, User:user.name, UserType:user.type}" -o json
```
```json
{
  "SubscriptionId": "<SUBSCRIPTION_ID>",
  "TenantId": "<TENANT_ID>",
  "State": "Enabled",
  "User": "<USER_MSA_UPN>",
  "UserType": "user"
}
```

```bash
az account list -o table
```
→ 1 seul abonnement : "Azure subscription 1", tenant `<TENANT_ID>`, IsDefault=True.

```bash
az rest --method GET --url "https://management.azure.com/tenants?api-version=2022-12-01" ...
```
→ **1 seul tenant accessible** à ce compte : `<TENANT_ID>` / `<TENANT_DOMAIN>` ("Répertoire par défaut").

**Constat** : le compte connecté est un compte Microsoft personnel (MSA, `<USER_MSA_UPN>`), pas un compte Entra ID natif. C'est le compte utilisé pour l'administration Azure (rôle Owner niveau souscription, confirmé lors d'une session précédente). Un compte séparé, cloud-only natif, a dû être créé pour contourner une limitation MSA sur la validation Entra Connect (voir section 9).

---

## Section 2 — Inventaire des VMs

```bash
az vm list -d --query "[].{Name:name, RG:resourceGroup, Size:hardwareProfile.vmSize, Location:location, PowerState:powerState, OsType:storageProfile.osDisk.osType, PrivateIP:privateIps, PublicIP:publicIps}" -o table
```

| Name | RG | Size | Location | OsType | PrivateIP | PublicIP |
|---|---|---|---|---|---|---|
| Comp-Vault-01-a3 | AI-ML-Services-RG | Standard_D2s_v3 | westus | Linux | 10.0.1.4 | `<PIP_BADZURE>` |
| ubuntu-jumpbox | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | Standard_B1ms | indiasouthcentral | Linux | 10.201.1.4 | `<PIP_JUMPBOX_NEW>` |
| goad-vm-dc01 | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | **Standard_B2s** | denmarkeast | Windows | 10.200.10.10 | — |
| goad-vm-dc02 | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | Standard_B1ms | denmarkeast | Windows | 10.200.10.11 | — |
| goad-vm-srv02 | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | Standard_B1ms | denmarkeast | Windows | 10.200.10.22 | — |

Toutes désallouées au moment de l'audit.

**Topologie 3 régions CONFIRMÉE RÉELLE** :
- `westus` → BadZure (1 VM)
- `indiasouthcentral` → jumpbox GOAD (1 VM, isolé du reste du lab GOAD)
- `denmarkeast` → les 3 serveurs GOAD (dc01/dc02/srv02)

Détail NIC/disque par VM (`az vm show ... --query "{NICs, OsDiskSku, OsDiskSizeGb}"`) : tous en `Standard_LRS` sauf le jumpbox en `StandardSSD_LRS`. `OsDiskSizeGb` renvoie systématiquement `null` (taille héritée de l'image, non fixée explicitement sur le disque managé).

---

## Section 3 — Quota et disponibilité SKU par région

```bash
az vm list-usage --location <region> --query "[?contains(name.value,'cores') || ...]" -o table
```

| Région | Total Regional vCPUs | Standard Bsv2 Family vCPUs |
|---|---|---|
| denmarkeast | **4 / 4** (saturé) | 0 / 4 |
| indiasouthcentral | 1 / 4 | 0 / 4 |
| westus | 2 / 4 | 0 / 4 |

```bash
az vm list-skus --location <region> --all --query "[?name=='Standard_B2s' || name=='Standard_B1ms' || name=='Standard_D2s_v3'].{Restrictions:restrictions[].reasonCode}" -o table
```
→ **Aucune restriction** (`NotAvailableForSubscription` ou autre) sur `Standard_B1ms`, `Standard_B2s`, `Standard_D2s_v3` dans les 3 régions utilisées. Cohérent avec le fait que ces VMs tournent déjà dessus.

**Marge réelle** : `denmarkeast` est à 0 vCPU de marge (4/4) — tout resize ou ajout de VM y est bloqué sans suppression préalable. `indiasouthcentral` et `westus` ont respectivement 3 et 2 vCPU de marge.

---

## Section 4 — Topologie réseau et peerings

```bash
az network vnet list --query "[].{Name, RG, Location, AddressSpace, Subnets}" -o json
```

| VNet | RG | Région | CIDR | Subnet |
|---|---|---|---|---|
| AI-ML-Services-RG-vnet | AI-ML-Services-RG | westus | 10.0.0.0/16 | Comp-Vault-01-a3-subnet (10.0.1.0/24) |
| GOAD-Light-virtual-network | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | 10.200.10.0/24 | GOAD-Light-vm-subnet (10.200.10.0/24) |
| vnet-jumpbox-c | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | indiasouthcentral | 10.201.0.0/16 | snet-jump (10.201.1.0/24) |

**Aucun chevauchement de CIDR** — prérequis peering respecté.

### Peerings réels (`az network vnet peering list`)

| VNet source | Peering | Remote | State | AllowForwarded | AllowVnetAccess | AllowGatewayTransit |
|---|---|---|---|---|---|---|
| AI-ML-Services-RG-vnet (BadZure) | peering-badzure-to-goad | GOAD-Light-virtual-network | **Connected** | True | True | False |
| GOAD-Light-virtual-network (GOAD) | peering-goad-to-badzure | AI-ML-Services-RG-vnet | **Connected** | True | True | False |
| GOAD-Light-virtual-network (GOAD) | peer-a-to-c | vnet-jumpbox-c | **Connected** | True | True | False |
| vnet-jumpbox-c (jumpbox) | peer-c-to-a | GOAD-Light-virtual-network | **Connected** | True | True | False |

**Peering jumpbox ↔ BadZure : ABSENT.** Ni direct, ni indirect (le peering VNet Azure n'est pas transitif — GOAD ne fait pas office de hub même s'il est peeré aux deux). Le jumpbox ne peut donc pas atteindre les ressources réseau BadZure (westus) via le réseau actuel.

### Graphe de connectivité réel

```
BadZure (westus) ←──Connected──→ GOAD (denmarkeast) ←──Connected──→ jumpbox (indiasouthcentral)
BadZure (westus)  ╳──── pas de lien direct ────╳  jumpbox (indiasouthcentral)
```

---

## Section 5 — NSG et règles

```bash
az network nsg list -o table
```

| NSG | RG | Région | Attaché à |
|---|---|---|---|
| Comp-Vault-01-a3-nsg | AI-ML-Services-RG | westus | NIC (pas le subnet) |
| GOAD-Light-subnet-nsg | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | Subnet GOAD-Light-vm-subnet |
| jumpbox-nsg-c | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | indiasouthcentral | Subnet snet-jump |

Règles (`az network nsg rule list`) :

**Comp-Vault-01-a3-nsg** (BadZure) :
| Name | Priority | Access | Protocol | Source | Port |
|---|---|---|---|---|---|
| Allow-RDP | 1000 | Allow | Tcp | `<HOME_IP_1>` | 3389 |
| Allow-SSH | 1001 | Allow | TCP | `<HOME_IP_2>` | 22 |

**GOAD-Light-subnet-nsg** (GOAD, denmarkeast) :
| Name | Priority | Access | Protocol | Source | Port |
|---|---|---|---|---|---|
| AllowSSHInboundOnly | 100 | Allow | Tcp | **`*`** | 22 |
| rdp_temporaire | 110 | Allow | * | `<HOME_IP_2>` | 3389 |

**jumpbox-nsg-c** (jumpbox, indiasouthcentral) :
| Name | Priority | Access | Protocol | Source | Port |
|---|---|---|---|---|---|
| AllowSSHInbound | 100 | Allow | Tcp | **`*`** | 22 |

**Anomalies relevées** :
- SSH ouvert à `*` (tout Internet) sur `GOAD-Light-subnet-nsg` **et** `jumpbox-nsg-c` — contraste avec BadZure qui restreint ses règles à des IP précises. À restreindre.
- La règle `AllowSSHInboundOnly` sur `GOAD-Light-subnet-nsg` est probablement **vestige** : elle datait de l'époque où le jumpbox vivait dans ce VNet/subnet ; il en est parti (migré vers `vnet-jumpbox-c`), donc plus aucune VM de ce subnet n'a besoin de SSH entrant (ce sont des VMs Windows).
- **Aucune règle explicite WinRM (5985/5986)** nulle part. Le pilotage PowerShell à distance (pypsrp) depuis le jumpbox vers `dc01` fonctionne uniquement grâce à la règle implicite `AllowVnetInBound` (tag `VirtualNetwork`, qui couvre les VNets peerés). C'est fonctionnel mais fragile : toute règle explicite de priorité plus basse qui bloquerait le trafic inter-VNet casserait ce canal sans avertissement.

---

## Section 6 — IP publiques

```bash
az network public-ip list -o table
```

| Name | RG | Région | IP | Allocation | Associée à |
|---|---|---|---|---|---|
| Comp-Vault-01-a3-public-ip | AI-ML-Services-RG | westus | `<PIP_BADZURE>` | Static | NIC BadZure (en usage) |
| ubuntu-public-ip | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | `<PIP_JUMPBOX_OLD>` | Static | NIC `ubuntu-jumbox-nic` — **orpheline** |
| jumpbox-pip-c | GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE | indiasouthcentral | `<PIP_JUMPBOX_NEW>` | Static | NIC jumpbox (en usage) |

**`ubuntu-public-ip` est orpheline** : reste de l'ancien jumpbox avant sa migration cross-région. Associée à une NIC (`ubuntu-jumbox-nic`) elle-même sans VM attachée. Facturée pour rien (Static IP SKU Standard facturée même non attachée à une VM active).

---

## Section 7 — Disques et snapshots

```bash
az disk list -g <RG> -o table
```

| Disque | RG | Région | SKU | État | Attaché à |
|---|---|---|---|---|---|
| Comp-Vault-01-a3_OsDisk_1_... | AI-ML-Services-RG | westus | Standard_LRS | Reserved | Comp-Vault-01-a3 |
| jumpbox-osdisk-c | GOAD-Light-cd2eec-goad-light-azure | indiasouthcentral | StandardSSD_LRS | Reserved | ubuntu-jumpbox |
| goad-vm-dc01_OsDisk_1_... | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | Standard_LRS | Reserved | goad-vm-dc01 |
| goad-vm-dc02_OsDisk_1_... | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | Standard_LRS | Reserved | goad-vm-dc02 |
| goad-vm-srv02_OsDisk_1_... | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | Standard_LRS | Reserved | goad-vm-srv02 |
| **ubuntu-jumpbox_OsDisk_1_...** | GOAD-Light-cd2eec-goad-light-azure | denmarkeast | Standard_LRS | **Unattached** | — |

**Disque orphelin confirmé** : `ubuntu-jumpbox_OsDisk_1_...` (denmarkeast, ~30 Go) — disque OS de l'ancien jumpbox, jamais supprimé après la migration cross-région. Facturé pour du stockage inutilisé.

```bash
az snapshot list -g <RG> -o table
```
→ **Vide dans les deux RG concernés.** Le nettoyage des snapshots de migration (`jumpbox-snap`, `jumpbox-snap-c`) effectué précédemment est confirmé complet — aucun résidu.

---

## Section 8 — Ressources BadZure (Terraform)

```bash
az group list -o table
```

| RG | Région | Rôle |
|---|---|---|
| Enterprise-Resources-RG | westus | BadZure |
| AI-ML-Services-RG | westus | BadZure |
| ai_func-pipeline-trigger-wfgu-insights_..._managed | westus | Auto-géré (Function App), normal |
| NetworkWatcherRG | westus | Auto-créé par Azure, normal |
| GOAD-Light-cd2eec-goad-light-azure | denmarkeast | GOAD |

```bash
az resource list -g AI-ML-Services-RG -o table
```
Contenu (17 ressources) : 2 comptes de stockage, 1 Key Vault (`Mktg-Shared-KVlcwr`), 1 Logic App, 1 Function App + son plan + Application Insights, 2 comptes Cosmos DB, la VM `Comp-Vault-01-a3` + NIC + NSG + IP publique, une clé SSH publique nommée "Badzure", un groupe d'actions de monitoring.

```bash
az resource list -g Enterprise-Resources-RG -o table
```
Contenu (3 ressources) : 1 compte de stockage (`corpprodstorage01vb2`), 1 Key Vault (`Prod-Shared-Vault0j3r`), 1 Automation Account.

**Objets Entra ID BadZure** (d'après le `terraform.tfstate` local, appliqué le 2026-07-16 — reflète le dernier état appliqué, pas nécessairement l'état live actuel) : 10 utilisateurs cloud-only, 5 groupes, 2 administrative units, 15 app registrations + service principals, 10 attributions de rôles d'annuaire (7 sur apps, 3 sur users), 2 service principals liés (Microsoft Graph, Exchange Online).

**Fichiers Terraform locaux présents** (contenu NON affiché — contiennent des secrets) :
- `/home/mat/cloud/BadZure/terraform/terraform.tfstate` (2.4 Mo)
- `/home/mat/cloud/BadZure/terraform/terraform.tfvars.json` (13.5 Ko)

---

## Section 9 — Entra Connect / synchronisation

```bash
az ad app list --filter "startswith(displayName,'ConnectSyncProvisioning')" -o table
```
→ **1 seule app** : `ConnectSyncProvisioning_KINGSLANDING_<suffix>`, AppId `<APP_ID_ADCONNECT>`, créée 2026-07-27T10:45:37Z. Pas de doublon — le nettoyage antérieur est confirmé efficace.

```bash
az rest .../users?$filter=startswith(userPrincipalName,'sync-admin')&$select=userPrincipalName,userType,accountEnabled
```
→ `sync-admin@<TENANT_DOMAIN>` : **userType=Member** (pas Guest), accountEnabled=**true**.

```bash
az rest .../users/<id>/memberOf
```
→ Rôle assigné confirmé : **Hybrid Identity Administrator**.

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/domains" -o table
```

| Domain | Default | Verified |
|---|---|---|
| `<TENANT_DOMAIN>` (`.onmicrosoft.com`) | True | True |
| `<TENANT_DOMAIN_MAIL>` (`.mail.onmicrosoft.com`) | False | True |

Aucun domaine personnalisé — uniquement les domaines `.onmicrosoft.com` par défaut.

**État ADSync côté `dc01`** (dernières valeurs connues, capturées plus tôt dans la session pendant que la VM tournait — non re-vérifiées ici, VMs actuellement désallouées) :
- `Get-ADSyncScheduler` : `SyncCycleInProgress: False`, `NextSyncCyclePolicyType: Delta` → cycle initial terminé avec succès, régime normal.
- `Get-GPInheritance` sur l'OU Domain Controllers : `GpoInheritanceBlocked: False` → héritage réactivé après validation.
- **À reconfirmer en direct** (via pypsrp/tunnel WinRM jumpbox→dc01) la prochaine fois que les VMs seront démarrées, plutôt que de les redémarrer pour cet audit.

---

## Section 10 — Script `azure.sh`

```bash
find / -name "azure.sh" 2>/dev/null
```
→ Trouvé : `/home/mat/cloud/azure.sh`

**Analyse** :
- Gère `start` (démarrage ordonné : DC01/DC02 → SRV02 → Jumpbox → Comp-Vault) et `stop` (désallocation groupée).
- `stop` désalloue **tout** le RG GOAD par ID (`az vm deallocate --ids $(az vm list --resource-group $RG_GOAD --query "[].id")`) — couvre bien le jumpbox même s'il est dans une région différente (ciblage par RG+nom, indépendant de la région).
- Deux variables `LOC_GOAD`/`LOC_JUMPBOX` ajoutées récemment (documentation uniquement, la logique de ciblage ne change pas).
- Couvre bien les 3 régions implicitement (via RG, pas de filtre région).
- Ne gère PAS BadZure au-delà de `Comp-Vault-01-a3` — les autres ressources BadZure (Cosmos DB, Function App, Logic App, Key Vaults) ne sont ni démarrées ni arrêtées par ce script (Cosmos DB/serverless n'a pas de notion start/stop de toute façon, mais Function App/Logic App peuvent continuer à tourner et consommer même RG "arrêté" côté VMs).

---

## Synthèse finale

### 1. Tableau récapitulatif des 3 régions

| Région | Contenu | vCPU utilisés/quota | Marge | SKU utilisés dispo ? |
|---|---|---|---|---|
| **denmarkeast** | GOAD : dc01 (B2s), dc02 (B1ms), srv02 (B1ms) | 4/4 | **0** | Oui, sans restriction |
| **indiasouthcentral** | Jumpbox GOAD (B1ms) | 1/4 | 3 | Oui, sans restriction |
| **westus** | BadZure : Comp-Vault-01-a3 (D2s_v3) + ressources cloud (Cosmos, Storage, KV, Function App, Logic App) | 2/4 | 2 | Oui, sans restriction |

**Topologie 3 régions annoncée → CONFIRMÉE réelle**, pas supposée.

### 2. Graphe de connectivité réel

```
région-BadZure (westus)      ↔ région-GOAD (denmarkeast)      : Connected, forwarded=true, vnet_access=true
région-GOAD (denmarkeast)    ↔ région-jumpbox (indiasouthcentral) : Connected, forwarded=true, vnet_access=true
région-BadZure (westus)      ↔ région-jumpbox (indiasouthcentral) : ABSENT (aucun peering, pas de transitivité)
```

### 3. Écarts / anomalies relevés

| # | Anomalie | Impact | Région |
|---|---|---|---|
| 1 | IP publique orpheline `ubuntu-public-ip` | Facturation inutile | denmarkeast |
| 2 | NIC orpheline `ubuntu-jumbox-nic` | Facturation mineure | denmarkeast |
| 3 | Disque orphelin `ubuntu-jumpbox_OsDisk_1_...` (~30 Go) | Facturation stockage inutile | denmarkeast |
| 4 | Règle SSH `*` (non restreinte) sur `GOAD-Light-subnet-nsg` | Surface d'exposition, + probablement vestige (jumpbox parti) | denmarkeast |
| 5 | Règle SSH `*` (non restreinte) sur `jumpbox-nsg-c` | Surface d'exposition — seul point d'entrée public du lab | indiasouthcentral |
| 6 | Aucune règle NSG explicite pour WinRM (5985/5986) | Fonctionne via règle implicite `AllowVnetInBound` — fragile, pas de garantie explicite | denmarkeast/indiasouthcentral |
| 7 | Pas de peering jumpbox ↔ BadZure | Le jumpbox ne peut pas atteindre les ressources réseau BadZure directement — à clarifier si voulu | — |
| 8 | `azure.sh` ne gère pas les ressources cloud BadZure (Cosmos, Function App, Logic App) | Ces ressources peuvent continuer à consommer même après un `stop` | westus |

Pas d'anomalie trouvée sur : apps `ConnectSyncProvisioning` (une seule, propre), snapshots (aucun résidu), CIDR (pas de chevauchement).

### 4. Ce qui bloque un redéploiement from-scratch reproductible

| Élément manuel | Pourquoi non scriptable en l'état | Piste d'automatisation |
|---|---|---|
| Wizard `AzureADConnect.exe` (login interactif) | Nécessite un navigateur embarqué (OAuth interactif), aucune option non-interactive documentée utilisée ici | Explorer les paramètres silencieux du MSI / cmdlets `ADSyncPrep` dédiés, sinon accepter une étape manuelle scriptée en partie (WinRM pour tout sauf le login) |
| Choix du compte `sync-admin` natif plutôt que le MSA | Découvert par élimination expérimentale (pas un choix a priori dans la doc Microsoft) | Documenter comme prérequis fixe : toujours créer un compte cloud-only dédié avant l'installation ABA, jamais utiliser le compte MSA d'administration |
| Blocage Conditional Access (erreur 530035) sur tout login interactif/device-code depuis machine non enregistrée | Politique tenant, pas contournable en CLI depuis une machine non enregistrée | Utiliser un **service principal app-only** (cert/secret) pour toute création d'objets Entra ID scriptée, plutôt qu'un compte utilisateur interactif |
| Choix de région du jumpbox (`indiasouthcentral`) | Déterminé empiriquement (quota + SKU dispo pour CE Free Trial à CE moment) — pas une constante | Script doit **retester dynamiquement** quota+SKU par région à chaque déploiement, pas hardcoder la région |
| Fix registre "Provider Type 24" + ACL `MachineKeys` (mentionné dans l'historique du projet, antérieur à cette session) | Modification registre + permissions NTFS manuelle | Scriptable en PowerShell (clés de registre + `icacls`), à documenter précisément si besoin de le reproduire |
| Timing du blocage/déblocage de l'héritage GPO | Décision manuelle liée à l'état d'avancement du troubleshooting | Scriptable (`Set-GPInheritance`), mais la logique "bloquer pendant l'install, débloquer après validation de la synchro" doit être encodée comme étape conditionnelle explicite |
| Règles NSG restreintes à une IP spécifique (SSH/RDP) | IP de l'opérateur, différente à chaque déploiement/déployeur | Paramétrer en variable d'entrée du script (`--allowed-ip`) plutôt que hardcoder |

---

