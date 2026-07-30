# Modifications amont : GOAD / BadZure

Documente les modifications apportées directement aux fichiers de GOAD et
BadZure eux-mêmes (par opposition aux scripts de ce projet, dans
`scripts/`).

## Taille de dc01 (`GOAD/ad/GOAD-Light/providers/azure/windows.tf`)

**Champ modifié** : `size` de l'entrée `"dc01"` dans la configuration des VM
Windows.

```hcl
# avant
size = "Standard B2s"   # invalide : espace au lieu d'un underscore

# après
size = "Standard_B2s"
```

Seule l'entrée `"dc01"` a été changée. `dc02` et `srv02` restent en
`Standard_B1ms`.

### Pourquoi

dc01 héberge Entra Connect. L'installation de SQL LocalDB (composant
d'Entra Connect) échoue avec l'erreur SQL 25009 (mémoire insuffisante) en
dessous de 4 Go de RAM, ce que `Standard_B1ms` (1 vCPU, 2 Go) n'atteint pas.
`Standard_B2s` (2 vCPU, 4 Go) est la taille minimale qui fonctionne.

Ce resize avait déjà été appliqué manuellement en production (`az vm
resize`), sans jamais être reporté dans le fichier Terraform source : un
déploiement from scratch aurait recréé dc01 en `Standard_B1ms`, trop petit.
Ce changement corrige la source pour qu'un `terraform apply` produise
directement la bonne taille.

### Impact sur le quota

Sur `denmarkeast` : dc01 en B2s (2 vCPU) + dc02 (1 vCPU) + srv02 (1 vCPU) =
**4/4 vCPU**, sans marge. C'est pour cette raison que le jumpbox doit vivre
dans une autre région (`indiasouthcentral`, cf. `scripts/10-migrate-jumpbox.sh`) :
le laisser dans `denmarkeast` dépasserait le quota Azure Free Trial
(4 vCPU/région).

## Service principal Exchange Online (`BadZure/terraform/main.tf`)

**Champ modifié** : `display_name` du data source
`azuread_service_principal.exchange_online`.

```hcl
# avant
display_name = "Office 365 Exchange Online"

# après
display_name = "Microsoft Graph"
```

### Pourquoi

Ce data source est évalué à chaque `terraform apply`, même quand aucun
attack path actif n'utilise réellement les permissions Exchange (il n'est
référencé conditionnellement que si `api_type == "exchange"` sur une
assignation). Sur ce tenant, "Office 365 Exchange Online" n'existe pas
comme service principal (Exchange Online non licencié dans ce tenant), ce
qui fait échouer `terraform apply` avec "Service principal not found",
avant même d'atteindre un attack path qui en aurait besoin.

"Microsoft Graph" existe dans tous les tenants Entra ID : la valeur n'est
consommée que si un attack path avec `api_type = "exchange"` est
réellement configuré (non testé dans ce lab), auquel cas revenir à
"Office 365 Exchange Online" sur un tenant qui l'a réellement provisionné.

## Jumpbox déployée directement dans sa propre région (`GOAD/template/provider/azure/jumpbox.tf`, `variables.tf`)

**Champs ajoutés** : variables `jumpbox_location` et `jumpbox_allowed_ip`
(`variables.tf`), VNet/subnet/NSG dédiés au jumpbox + peering bidirectionnel
avec le VNet des DC (`jumpbox.tf`). Les ressources jumpbox (VM, NIC, IP
publique) utilisent désormais `var.jumpbox_location` au lieu de
`azurerm_resource_group.resource_group.location`.

### Pourquoi

dc01 (`Standard_B2s`, 2 vCPU) + dc02 + srv02 (`Standard_B1ms`, 1 vCPU
chacune) = 4 vCPU, tout le quota Azure Free Trial de la région des DC (cf.
section précédente). La jumpbox (1 vCPU) ne peut donc pas coexister, même
brièvement, dans la même région : un `terraform apply` qui tenterait de créer
les 4 VM ensemble échouerait systématiquement sur dc01 (dernière créée) avec
un conflit de quota.

Avant ce changement, la jumpbox naissait dans la région des DC (comme le
prévoit le template GOAD standard) puis était déplacée après coup vers une
autre région (`scripts/10-migrate-jumpbox.sh`, snapshot cross-région + NSG +
VNet + peering recréés à la main via `az`). Cette approche ne résout rien
pour le tout premier déploiement : au moment du premier `terraform apply`,
goad.py essaie de créer les 4 VM en une fois, donc le conflit de quota se
produit de toute façon avant que la migration ne puisse intervenir.

Ce changement place directement la jumpbox dans `var.jumpbox_location` (=
`$REGION_JUMPBOX`, exportée en `TF_VAR_jumpbox_location` par
`scripts/00-deploy.sh` avant d'appeler `goad.py`, cf. `deploy_goad`), avec son
propre VNet/subnet peeré au VNet des DC dès la création : le quota de la
région des DC n'a plus jamais à supporter que 4 vCPU (dc01+dc02+srv02), la
jumpbox comptant sur le quota de sa propre région. Le peering est nécessaire
dès cette étape car le provisioning Ansible de `goad.py` (juste après
l'apply) se connecte depuis la jumpbox vers dc01 en WinRM.

`scripts/10-migrate-jumpbox.sh` n'est plus appelé par l'orchestrateur mais
reste dans le dépôt : utilitaire générique de migration cross-région d'une VM
Linux, potentiellement réutile pour d'autres besoins.

## Non appliqué : région explicite pour BadZure

Idée envisagée : fixer explicitement `location: westus` dans
`BadZure/badzure.yml`, plutôt que de dépendre de la valeur par défaut
codée dans `src/entity_generator.py`. Décision laissée à l'opérateur, non
appliquée pour l'instant.
