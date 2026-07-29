#!/usr/bin/env bash
# setup-fixtures.sh — monte un environnement Azure factice minimal (~2 min)
# pour tester B1/B2/B3 sans dépendre du vrai GOAD/BadZure (spec §10, Niveau 3).
#
# Crée, dans UN SEUL resource group dédié (facilite un teardown propre) :
# - 2 VNets vides (juste VNet + subnet, CIDR non chevauchants) dans 2 régions
#   différentes, imitant la topologie GOAD (région A) / jumpbox (région B).
# - 1 VM Linux Standard_B1s (la plus petite/moins chère) par région, imitant
#   goad-vm-* / ubuntu-jumpbox.
# Aucun GOAD, aucun BadZure, aucun Windows — uniquement des ressources Azure
# génériques.
#
# Réutilise directement create_target_network (scripts/10-migrate-jumpbox.sh)
# plutôt que de dupliquer la création de VNet : conforme à la spec §10, "les
# fixtures utilisent les mêmes fonctions que les scripts réels".
#
# Régions par défaut : $REGION_JUMPBOX/$REGION_BADZURE si déjà exportés
# (config/lab.env), sinon indiasouthcentral/westus — PAS denmarkeast, qui est
# saturé (4/4 vCPU, cf. infra-inventory.md) et ferait échouer la création de
# VM. Resource group séparé de $RG_GOAD/$RG_BADZURE : ne touche jamais à
# l'infra réelle.
#
# Sourçable : `source test/setup-fixtures.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# setup_fixtures.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${TEST_DIR}/../lib/common.sh"
# shellcheck source=../scripts/10-migrate-jumpbox.sh disable=SC1091
source "${TEST_DIR}/../scripts/10-migrate-jumpbox.sh"

# Pas de `readonly` ici : `source test/setup-fixtures.sh` doit pouvoir être
# rejoué plusieurs fois dans le même shell (ex. session interactive de debug)
# sans erreur "variable en lecture seule" sur ce deuxième sourcing.
#
# Surchargeables (${VAR:-défaut}) : constaté en conditions réelles que
# Standard_B1s peut être temporairement indisponible (SkuNotAvailable, quota
# de capacité Azure ponctuel, distinct du quota vCPU d'abonnement) dans une
# région donnée à un instant donné — permet de relancer avec une autre taille
# sans modifier le script.
FIXTURE_VM_IMAGE="${FIXTURE_VM_IMAGE:-Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest}"
FIXTURE_VM_SIZE="${FIXTURE_VM_SIZE:-Standard_B1s}"

# create_fixture_rg <rg> <region>
create_fixture_rg() {
  local rg="$1" region="$2"
  if resource_exists group show --name "$rg"; then
    log_info "Resource group fixtures $rg déjà présent, réutilisation."
    return 0
  fi
  run_cmd az group create --name "$rg" --location "$region"
}

# create_fixture_nic <nic_name> <rg> <region> <vnet_name> <subnet_name>
create_fixture_nic() {
  local nic_name="$1" rg="$2" region="$3" vnet_name="$4" subnet_name="$5"
  if resource_exists network nic show --name "$nic_name" --resource-group "$rg"; then
    log_info "NIC $nic_name déjà présente, réutilisation."
    return 0
  fi
  run_cmd az network nic create \
    --name "$nic_name" \
    --resource-group "$rg" \
    --location "$region" \
    --vnet-name "$vnet_name" \
    --subnet "$subnet_name"
}

# ensure_fixture_ssh_key — génère (une seule fois par run) une paire de clés
# SSH éphémère dédiée aux fixtures, dans un répertoire temporaire hors du
# repo. Trouvé en testant ce lot pour de vrai (spec §10, étape 4) :
# `az vm create --generate-ssh-keys` réutilise silencieusement une clé privée
# déjà présente à l'emplacement par défaut (~/.ssh/id_rsa) plutôt que d'en
# générer une nouvelle si le fichier existe déjà — et échoue platement
# ("Valid PEM but no BEGIN/END delimiters for a private key found") si ce
# fichier existe mais n'est pas dans un format que az cli sait parser (vécu en
# conditions réelles sur cet environnement). Indépendamment de ce bug,
# provisionner la clé privée personnelle de l'opérateur sur une VM jetable
# n'est de toute façon pas souhaitable : on génère donc systématiquement une
# clé dédiée, à usage unique, via --ssh-key-value plutôt que
# --generate-ssh-keys.
ensure_fixture_ssh_key() {
  if [[ -n "${FIXTURE_SSH_PUBLIC_KEY_PATH:-}" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    FIXTURE_SSH_PUBLIC_KEY_PATH="/tmp/fixture-ssh-key.pub"
    log_info "[DRY-RUN] Génération de la clé SSH éphémère des fixtures ignorée."
    return 0
  fi

  local key_dir
  key_dir="$(mktemp -d)"
  ssh-keygen -t rsa -b 2048 -N "" -f "${key_dir}/fixture_id_rsa" -q -C "hybrid-fixtures"
  FIXTURE_SSH_PUBLIC_KEY_PATH="${key_dir}/fixture_id_rsa.pub"
  log_info "Clé SSH éphémère des fixtures générée : $FIXTURE_SSH_PUBLIC_KEY_PATH (usage jetable, hors repo)."
}

# create_fixture_vm <vm_name> <rg> <region> <vnet_name> <subnet_name> — VM
# Linux minimale fraîche (pas de disque à attacher, contrairement à
# create_vm_from_disk du script B1 qui recrée depuis un snapshot).
create_fixture_vm() {
  local vm_name="$1" rg="$2" region="$3" vnet_name="$4" subnet_name="$5"
  local nic_name="${vm_name}-nic"

  create_fixture_nic "$nic_name" "$rg" "$region" "$vnet_name" "$subnet_name"

  if vm_exists "$vm_name" "$rg"; then
    log_info "VM $vm_name existe déjà, création ignorée."
    return 0
  fi

  ensure_fixture_ssh_key

  run_cmd az vm create \
    --name "$vm_name" \
    --resource-group "$rg" \
    --location "$region" \
    --nics "$nic_name" \
    --image "$FIXTURE_VM_IMAGE" \
    --size "$FIXTURE_VM_SIZE" \
    --admin-username "${FIXTURE_VM_ADMIN_USERNAME:-fixtureadmin}" \
    --ssh-key-value "$FIXTURE_SSH_PUBLIC_KEY_PATH" \
    --no-wait
}

# setup_fixtures — orchestration complète.
setup_fixtures() {
  local rg="${FIXTURE_RG:-hybrid-fixtures-rg}"
  local region_a="${FIXTURE_REGION_A:-${REGION_JUMPBOX:-indiasouthcentral}}"
  local region_b="${FIXTURE_REGION_B:-${REGION_BADZURE:-westus}}"

  log_info "Fixtures : RG=$rg, région A=$region_a, région B=$region_b."

  create_fixture_rg "$rg" "$region_a"

  create_target_network "fixture-vnet-a" "fixture-subnet-a" "$rg" "$region_a" "10.250.0.0/16" "10.250.1.0/24"
  create_fixture_vm "fixture-vm-a" "$rg" "$region_a" "fixture-vnet-a" "fixture-subnet-a"

  create_target_network "fixture-vnet-b" "fixture-subnet-b" "$rg" "$region_b" "10.251.0.0/16" "10.251.1.0/24"
  create_fixture_vm "fixture-vm-b" "$rg" "$region_b" "fixture-vnet-b" "fixture-subnet-b"

  log_info "Fixtures prêtes (--no-wait : les VM peuvent encore être en cours de création côté Azure)."
  log_info "Voir test/README.md pour comment exercer create_peering/ensure_nsg_rule/migrate_jumpbox contre ces fixtures."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  setup_fixtures
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
