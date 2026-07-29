# Points d'extension GOAD + BadZure — amont vs aval

Reconnaissance en lecture seule, 2026-07-27. Aucun fichier de déploiement exécuté (`terraform apply/plan`, `ansible-playbook`, `BadZure.py build/destroy`). Contenu de `*.tfstate`/`*.tfvars.json` jamais affiché — uniquement leur présence et structure (noms de clés).

---

## 1. Stack technique de chaque projet

**GOAD** (`/home/mat/cloud/GOAD`) :
- Orchestrateur Python (`goad.py`, `goad.sh`) qui pilote Terraform + Ansible + Vagrant/Packer selon le provider choisi (VMware, VirtualBox, Proxmox, Ludus, AWS, Azure).
- Templates Terraform génériques par provider dans `template/provider/<provider>/*.tf` (moteur de templating type Jinja — placeholders `{{...}}`).
- Définitions de labs spécifiques dans `ad/<NomDuLab>/` (ex. `ad/GOAD-Light/`), avec :
  - `data/config.json` : inventaire des hosts, rôles, vulnérabilités à activer par machine.
  - `providers/<provider>/windows.tf` / `linux.tf` : fragments injectés dans le template générique (ex. la liste des VMs Windows avec leurs attributs).
- Provisioning post-déploiement via Ansible (`ansible/roles/`, ~45 rôles).
- Rendu final par instance dans `workspace/<lab_identifier>/` (le Terraform réellement appliqué, généré à partir du template + des fragments du lab).

**BadZure** (`/home/mat/cloud/BadZure`) :
- CLI Python (Click) : `BadZure.py` + `src/` (`cli.py`, `config_manager.py`, `entity_generator.py`, `attack_path_manager.py`, `assignment_manager.py`, `terraform_manager.py`, `auth.py`, `crypto.py`).
- Config déclarative unique : `badzure.yml` (comptes/comptages d'entités + définitions d'attack paths).
- Le CLI **génère dynamiquement** le Terraform (`terraform/main.tf`, `variables.tf`, `terraform.tfvars.json`) à partir de `badzure.yml`, en piochant des noms réalistes dans `entity_data/*.txt` (wordlists : noms d'apps, de groupes, de RG, prénoms/noms...).
- `terraform_manager.py` encapsule les appels `terraform apply/destroy`.

---

## 2. Tableau amont / aval par customisation

| Customisation | Amont ou Aval ? | Emplacement précis (si amont) | Justification |
|---|---|---|---|
| **Sizing dc01 = B2s** | **Amont** | `GOAD/ad/GOAD-Light/providers/azure/windows.tf`, clé `size` de l'entrée `"dc01"` (actuellement `"Standard_B1ms"`) | Le champ `size` est déjà **par-machine** dans `var.vm_config` (map), directement consommé par `azurerm_windows_virtual_machine.size` dans `template/provider/azure/windows.tf`. Le resize à B2s a été fait uniquement en `az vm resize`, jamais reporté dans ce fichier → drift confirmé. |
| **Répartition 3 régions (jumpbox séparé)** | **Aval** (structurel) | — | `template/provider/azure/variables.tf` déclare `variable "location"` comme **valeur unique globale** (pas un map), utilisée par `azurerm_resource_group.resource_group.location` dans `main.tf`, elle-même référencée par TOUTES les ressources (NIC, VMs Windows, VM Linux, jumpbox) dans `network.tf`/`windows.tf`/`linux.tf`/`jumpbox.tf`. Aucun champ location dans `vm_config` ni `linux_vm_config`. Intégrer ça en amont demanderait de réécrire la structure Terraform (resource group + VNet + peering par région, dans le template lui-même) — pas un simple paramètre. |
| **Crypto fix (registre Provider Type 24 + ACL MachineKeys)** | **Amont possible** | Nouveau rôle `GOAD/ansible/roles/security/crypto_fix/tasks/main.yml` | Modules `ansible.windows.win_regedit` (registre) et `ansible.windows.win_acl` (ACL) déjà utilisés dans le repo pour des cas similaires (`security/maq0_client/tasks/main.yml`, `vulns/permissions/tasks/main.yml`) — patron directement réutilisable. |
| **Config WinRM (5985)** | **Déjà amont — rien à faire** | `template/provider/azure/windows.tf`, ressource `azurerm_virtual_machine_extension.goad-vm-ext` (CustomScriptExtension exécutant `ConfigureRemotingForAnsible.ps1`) | Le service WinRM est **déjà configuré nativement** sur chaque VM Windows par le template (c'est ce qui permet à Ansible de s'y connecter dès le départ). Ce qui manque réellement, c'est une règle NSG Azure explicite pour le port 5985 — ça, c'est une customisation réseau, voir ligne peering ci-dessous. |
| **Blocage/déblocage GPO (héritage OU Domain Controllers)** | **Amont possible** | Nouveau rôle basé sur le patron `GOAD/ansible/roles/settings/gpo_remove/` ou les modules custom `GOAD/ansible/roles/laps/dc/library/win_gpo.ps1` / `win_gpo_link.ps1` | GOAD a déjà des modules Ansible maison pour manipuler les GPO. Un rôle `gpo_inheritance_toggle` suivant ce patron (appel à `Set-GPInheritance` via `ansible.windows.win_shell` ou un module custom) s'intégrerait naturellement. |
| **Création VNet + subnet** | **Déjà amont** | `template/provider/azure/network.tf` | GOAD crée déjà son propre VNet/subnet/NSG à chaque déploiement Azure — rien à ajouter. |
| **Peering BadZure ↔ GOAD** | **Aval** | — | Zéro occurrence de "peering" dans tout le repo GOAD **et** tout le repo BadZure. Les deux projets sont conçus pour être déployés indépendamment, avec des states Terraform séparés. Relier leurs VNets nécessite soit un module Terraform tiers combinant les deux states (changement d'architecture des deux projets), soit rester un script `az network vnet peering create` externe post-déploiement. |
| **Peering GOAD ↔ jumpbox** | **Aval** | — | Dans le template GOAD par défaut, le jumpbox est **dans le même VNet/subnet** que les DC (`jumpbox.tf` : IP `{{ip_range}}.100`, même subnet). Ce peering n'existe que parce que le jumpbox a été migré manuellement vers une autre région après coup — un problème qui disparaîtrait de lui-même si la répartition 3 régions était native (elle ne l'est pas, cf. ligne 2). |
| **Prep Entra Connect (SP app-only + sync-admin)** | **Aval** | — | Aucune trace dans GOAD ni BadZure d'intégration Entra Connect. C'est un pont ajouté manuellement entre les deux projets, hors périmètre de l'un comme de l'autre. |
| **Install Entra Connect (MSI silencieux)** | **Aval** | — | Idem — rien dans les fichiers projet ne référence `AzureADConnect.exe`/MSI. Nécessiterait en plus de résoudre le blocage Conditional Access sur l'auth interactive avant de pouvoir automatiser quoi que ce soit ici. |
| **Config BadZure (attack paths, entités)** | **Amont — déjà le cas** | `BadZure/badzure.yml` | C'est exactement le fichier prévu pour ça, 100% amont par design de l'outil. |
| **Région / tenant BadZure** | **Partiellement amont** | `badzure.yml`, bloc `tenant:` (tenant_id/domain/subscription_id) — région : voir nuance | Le tenant cible est déjà paramétré en amont (`tenant_id`, `domain`, `subscription_id` dans `badzure.yml` — confirmé, pas de création de tenant, un tenant existant est requis). La **région**, elle, est actuellement **hardcodée à "West US"** dans `src/entity_generator.py` (fonction `generate_resource_groups`, mode "compteur simple" — c'est le mode utilisé ici : `resource_groups: 2` dans `badzure.yml`). Une fonction sœur `generate_resource_groups_targeted` existe et supporte un champ `location` par resource group, mais nécessite de réécrire `resource_groups:` dans `badzure.yml` sous forme de liste détaillée plutôt qu'un simple compteur — non utilisé actuellement. |

---

## 3. Réponses aux deux questions décisives

### GOAD supporte-t-il une région par machine nativement ?

**Non, structurellement.**

Preuve : `template/provider/azure/variables.tf` :
```hcl
variable "location" {
  type    = string
  default = "{{config.get_value('azure', 'az_location', 'westeurope')}}"
}
```
Une **seule** valeur, pas un `map`. Utilisée dans `main.tf` :
```hcl
resource "azurerm_resource_group" "resource_group" {
  name     = "{{lab_identifier}}"
  location = var.location
}
```
Puis systématiquement re-référencée comme `azurerm_resource_group.resource_group.location` dans `network.tf` (NICs), `windows.tf` (VMs Windows via `for_each = var.vm_config`), `linux.tf` (VMs Linux génériques) et `jumpbox.tf` (le jumpbox dédié). Aucun des objets `vm_config`/`linux_vm_config` n'a de champ `location`.

**Conséquence** : la migration cross-région du jumpbox restera un travail en aval tant que cette structure Terraform n'est pas réécrite en profondeur (il faudrait un `resource_group` + `virtual_network` + peering par région, directement dans le template) — ce n'est pas l'ajout d'un simple paramètre.

### Où intégrer le crypto fix en task Ansible ?

**Possible en amont.** Emplacement recommandé : nouveau rôle `GOAD/ansible/roles/security/crypto_fix/tasks/main.yml`, sur le modèle exact de :
- `GOAD/ansible/roles/security/maq0_client/tasks/main.yml` pour la syntaxe `ansible.windows.win_regedit` (clés Provider Type 24, en 64-bit et sous `WOW6432Node`) ;
- `GOAD/ansible/roles/vulns/permissions/tasks/main.yml` pour la syntaxe `ansible.windows.win_acl` (ACL sur `C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys`).

Il resterait à déterminer où appeler ce rôle dans la séquence d'exécution (probablement dans le rôle `domain_controller` ou via `playbooks.yml`/`ad/GOAD-Light/data/config.json`) — non investigué en détail ici, à creuser si le travail d'implémentation est lancé.

---

## 4. Fichiers à modifier (futur travail)

| Fichier | Modification |
|---|---|
| `/home/mat/cloud/GOAD/ad/GOAD-Light/providers/azure/windows.tf` | Corriger `size = "Standard_B2s"` pour l'entrée `"dc01"` (actuellement B1ms) |
| `/home/mat/cloud/GOAD/ansible/roles/security/crypto_fix/tasks/main.yml` *(nouveau)* | Tasks `win_regedit` (Provider Type 24, 64-bit + WOW6432Node) + `win_acl` (MachineKeys) |
| `/home/mat/cloud/GOAD/ansible/roles/security/gpo_inheritance_toggle/tasks/main.yml` *(nouveau, ou extension de `settings/gpo_remove`)* | Task(s) pour bloquer/débloquer l'héritage GPO sur l'OU Domain Controllers |
| `/home/mat/cloud/BadZure/badzure.yml` | Si région explicite souhaitée : remplacer `resource_groups: 2` (compteur) par une liste détaillée avec `location:` par entrée |

---

## 5. Ce qui reste forcément en aval

| Élément | Raison technique |
|---|---|
| Répartition 3 régions / migration cross-région du jumpbox | `location` est une variable globale unique dans le template Terraform GOAD (voir section 3) — aucune granularité par machine |
| Peering VNet (BadZure↔GOAD, GOAD↔jumpbox) | Aucun concept de peering dans aucun des deux projets ; states Terraform indépendants, pas de mécanisme de liaison inter-projets |
| Préparation Entra Connect (service principal app-only, compte `sync-admin`) | Hors périmètre de GOAD et BadZure — pont ajouté manuellement entre les deux, aucune trace dans les fichiers d'aucun des deux projets |
| Installation Entra Connect (wizard MSI) | Nécessite un login interactif (navigateur embarqué) — pas de mode silencieux utilisé/documenté ici, et bloqué en plus par la politique Conditional Access du tenant sur toute auth non-interactive depuis une machine non enregistrée |
| Règle NSG explicite WinRM (5985) et restriction des règles SSH/RDP à une IP précise | Le template GOAD crée un NSG minimal (SSH `*` uniquement) ; toute règle additionnelle ou restriction se fait aujourd'hui en `az network nsg rule create/update` post-déploiement |
