# Modifications amont — GOAD / BadZure

Documente les modifications apportées directement aux fichiers projet de GOAD
et BadZure (par opposition aux scripts aval du dossier `scripts/`). Voir spec
§2-§3 pour la répartition amont/aval complète.

## A1 — Sizing dc01 (`GOAD/ad/GOAD-Light/providers/azure/windows.tf`)

**Fichier** : `GOAD/ad/GOAD-Light/providers/azure/windows.tf`
**Champ** : `size` de l'entrée `"dc01"` dans la map de configuration des VMs
Windows (consommée par `azurerm_windows_virtual_machine.size` via
`for_each = var.vm_config` dans le template générique
`GOAD/template/provider/azure/windows.tf`).

### Avant / après

```hcl
# avant
size = "Standard B2s"   # invalide : espace au lieu d'un underscore

# après
size = "Standard_B2s"
```

Seule l'entrée `"dc01"` a été modifiée. `dc02` et `srv02` restent en
`Standard_B1ms`, inchangés.

### Écart constaté par rapport à la spec

La spec (§3, A1) décrivait la valeur de départ comme `"Standard_B1ms"`
(c'est-à-dire : le fichier source n'aurait jamais été touché, contrairement
au resize live). La valeur réellement présente dans le fichier était
`"Standard B2s"` — avec un **espace**, pas un underscore. Ce n'est ni la
valeur "avant" attendue, ni une chaîne de taille de VM Azure valide (les SKU
Azure s'écrivent avec des underscores, ex. `Standard_B2s`) ; un
`terraform plan`/`validate` sur cette valeur aurait vraisemblablement échoué
ou provisionné une taille par défaut inattendue.

Hypothèse retenue : une tentative antérieure de reporter le resize manuel
dans le fichier source, avec une faute de frappe (espace au lieu
d'underscore), jamais corrigée depuis.

Cet écart a été signalé à l'opérateur avant toute modification (conformément
à la règle « ne pas trancher seul » de la spec). Décision opérateur
(2026-07-28) : corriger le typo pour obtenir `"Standard_B2s"`, ce qui atteint
exactement l'objectif de la spec (dc01 en B2s) et aligne le fichier source
avec l'état réellement déployé (cf. `infra-inventory.md`, section 2 : VM
`goad-vm-dc01` déjà en `Standard_B2s` en live).

### Raison du changement

dc01 héberge Entra Connect. L'installation de SQL LocalDB (composant
d'Entra Connect) échoue avec l'erreur SQL 25009 (mémoire insuffisante) sous
4 Go de RAM — la taille du template d'origine, `Standard_B1ms` (1 vCPU /
2 Go), en est très en dessous. `Standard_B2s` (2 vCPU / 4 Go) est le minimum
viable observé pour que l'installation aboutisse.

Ce resize avait déjà été appliqué manuellement en production via
`az vm resize`, sans jamais être reporté dans le fichier Terraform source —
un drift classique entre l'infrastructure réellement déployée et sa
définition déclarative. Ce changement supprime ce drift : un redéploiement
`terraform apply` from-scratch produira désormais directement un dc01 en
`Standard_B2s`, sans étape de resize manuel supplémentaire après
provisioning.

### Impact quota (à noter, aucune action requise ici)

Sur `denmarkeast` : dc01 en B2s (2 vCPU) + dc02 (1 vCPU) + srv02 (1 vCPU) =
**4/4 vCPU**, soit zéro marge. C'est précisément pour cette raison que le
jumpbox DOIT vivre dans une autre région (`indiasouthcentral`, cf. B1/spec
§4) — le déployer dans `denmarkeast` ferait dépasser le quota Azure Free
Trial (4 vCPU/région). Confirmé cohérent avec `infra-inventory.md` (§3 :
`denmarkeast` déjà à 4/4, saturé).

### Non appliqué : A2 — région BadZure

A2 (fixer explicitement `location: westus` dans `BadZure/badzure.yml`,
plutôt que de dépendre du hardcodage `"West US"` dans
`src/entity_generator.py`) est une décision explicitement laissée à
l'opérateur (spec §3/§9). **Non appliqué dans ce lot**, en attente d'une
décision séparée.
