# Fixtures de test

Le lab complet (GOAD + BadZure) est long et coûteux à redéployer. La plupart
des scripts réseau/infra n'ont pourtant pas besoin du vrai lab pour être
testés — seulement de ressources Azure ressemblantes. `setup-fixtures.sh`
monte un environnement factice minimal (~2 min, deux VNets + deux petites VM
Linux dans deux régions), `teardown-fixtures.sh` le détruit.

**Principe central : les fixtures utilisent les mêmes fonctions que les
scripts réels.** Aucune logique de test dupliquée — un test de peering
appelle la vraie fonction `create_peering` (`scripts/20-peer-networks.sh`),
seulement avec les VNets factices en argument au lieu des VNets GOAD/BadZure
réels. Un bug corrigé dans la fonction réelle profite donc immédiatement à
son test sur fixtures, et inversement un test sur fixtures exerce le code
qui tournera réellement en production — pas une réplique.

## Testable sur fixtures ou sur le vrai lab uniquement

| Script | Testable sur fixtures ? | Raison |
|---|---|---|
| `10-migrate-jumpbox.sh` (B1) | Oui | Ne teste que snapshot/copie cross-région/recréation de VM Linux — les fixtures suffisent |
| `20-peer-networks.sh` (B2) | Oui | Ne teste que la liaison de VNets |
| `21-nsg-rules.sh` (B3) | Oui | Ne teste que des règles NSG |
| `30-goad-hardening-fix.sh` (B4/B5, blocage) | Non | Nécessite un vrai DC Windows durci par GOAD |
| `50-goad-gpo-unblock.sh` (B5, déblocage) | Non | Idem — dépend d'un vrai DC + d'une synchro Entra Connect réelle |
| `40-prepare-entra-connect.sh` (B6) | Non | Nécessite le vrai tenant + la politique Conditional Access réelle |
| `99-lifecycle.sh` | Partiellement | La logique start/stop/deallocate des VM se teste sur fixtures ; la partie ressources cloud BadZure (Function App/Logic App/Cosmos DB) ne se teste pas (n'existent pas dans les fixtures, qui n'ont pas vocation à répliquer BadZure) |

## Utilisation

```bash
# 1. Monter les fixtures (~2 min)
./test/setup-fixtures.sh
# ou en dry-run d'abord :
./test/setup-fixtures.sh --dry-run

# 2. Exercer une fonction réelle contre les fixtures (exemples ci-dessous)

# 3. Détruire les fixtures
./test/teardown-fixtures.sh
```

Variables (optionnelles, sinon valeurs par défaut ci-dessous) :
`FIXTURE_RG` (défaut `hybrid-fixtures-rg`), `FIXTURE_REGION_A` (défaut
`$REGION_JUMPBOX` si `config/lab.env` est chargé, sinon `indiasouthcentral`),
`FIXTURE_REGION_B` (défaut `$REGION_BADZURE`, sinon `westus`), `FIXTURE_VM_SIZE`
(défaut `Standard_B1s`), `FIXTURE_VM_IMAGE` (défaut une image Ubuntu 22.04
Canonical). Ces deux régions sont choisies par défaut car connues avec de la
marge de quota vCPU réelle sur cet abonnement (contrairement à
`denmarkeast`, saturé 4/4 — cf. `infra-inventory.md`). Tout vit dans un seul
resource group dédié, jamais `$RG_GOAD`/`$RG_BADZURE` : aucun risque de
toucher à l'infra réelle.

**Constaté en conditions réelles** : `Standard_B1s` peut être temporairement
indisponible dans une région donnée (`SkuNotAvailable` / restriction de
capacité Azure ponctuelle — distincte du quota vCPU d'abonnement, qui lui
est bien disponible). Rencontré sur `westus` lors d'un test réel de ce lot.
Si `setup-fixtures.sh` échoue avec `SkuNotAvailable`, relancer avec une autre
taille (`FIXTURE_VM_SIZE=Standard_B2s ./test/setup-fixtures.sh`) ou une autre
région (`FIXTURE_REGION_B=...`) plutôt que d'y voir un bug du script.

### Exemple — tester `create_peering` (B2) sur les fixtures

```bash
source lib/common.sh
source scripts/20-peer-networks.sh

RG=hybrid-fixtures-rg
VNET_A_ID="$(az network vnet show --name fixture-vnet-a --resource-group "$RG" --query id -o tsv)"
VNET_B_ID="$(az network vnet show --name fixture-vnet-b --resource-group "$RG" --query id -o tsv)"

create_peering "fixture-peer-a-to-b" "fixture-vnet-a" "$RG" "$VNET_B_ID"
create_peering "fixture-peer-b-to-a" "fixture-vnet-b" "$RG" "$VNET_A_ID"
verify_peering_connected "fixture-peer-a-to-b" "fixture-vnet-a" "$RG"
```

### Exemple — tester `ensure_nsg_rule` (B3) sur les fixtures

Les fixtures n'ont pas de NSG par défaut (VNets "vides", cf.
`setup-fixtures.sh`) ; en créer un minimal avant de tester la fonction :

```bash
source lib/common.sh
source scripts/21-nsg-rules.sh

RG=hybrid-fixtures-rg
az network nsg create --name fixture-nsg-a --resource-group "$RG" --location indiasouthcentral

ensure_nsg_rule "fixture-nsg-a" "$RG" "AllowSSHTest" 100 22 "203.0.113.10"
```

### Exemple — tester une fonction de `10-migrate-jumpbox.sh` (B1) sur les fixtures

Les fonctions bas niveau (`snapshot_source_disk`, `create_disk_from_snapshot`,
`create_target_public_ip`, `create_target_nic`, ...) sont directement
appelables avec les ressources fixtures en argument, exactement comme
`setup-fixtures.sh` le fait déjà pour `create_target_network`. Pour un test
de migration complet, il faudrait un point de départ supplémentaire non
fourni par `setup-fixtures.sh` (une VM/disque dans une "région source" à
migrer vers une "région cible") — au-delà du périmètre minimal de ce Lot ;
les fonctions individuelles suffisent pour valider chaque étape isolément.

## Notes

- `setup-fixtures.sh` et `teardown-fixtures.sh` sont tous les deux
  idempotents : relancer `setup-fixtures.sh` sur des fixtures déjà en place
  ne recrée rien (chaque garde `resource_exists`/`vm_exists` le confirme) ;
  relancer `teardown-fixtures.sh` sur un environnement déjà détruit ne fait
  rien.
- Aucun GOAD, aucun BadZure, aucun Windows dans les fixtures — uniquement
  des VNets et VM Linux `Standard_B1s` génériques (la taille la plus petite
  et la moins chère disponible), pour un coût et un temps de mise en place
  minimaux.
- `--no-wait` est utilisé pour la création des VM : `setup-fixtures.sh` peut
  rendre la main avant que les VM soient pleinement provisionnées côté
  Azure — attendre quelques dizaines de secondes avant de tester une
  fonction qui dépend de leur disque OS (ex. B1).
