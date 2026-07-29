#!/usr/bin/env bash
# 20-peer-networks.sh — B2 : établit les peerings VNet bidirectionnels
# BadZure ($REGION_BADZURE) <-> GOAD ($REGION_GOAD) et GOAD <-> jumpbox
# ($REGION_JUMPBOX), avec --allow-vnet-access et --allow-forwarded-traffic
# (requis pour le pivoting depuis le jumpbox).
#
# Pas de peering jumpbox <-> BadZure (non transitif, non requis — décision
# figée, cf. spec §4/B2).
#
# Pas de règle NSG supplémentaire nécessaire pour le trafic inter-VNet peeré :
# la règle par défaut AllowVnetInBound (tag VirtualNetwork) couvre déjà les
# VNets peerés.
#
# Sourçable : `source scripts/20-peer-networks.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# peer_networks (ou de create_peering isolément, pour les tests sur fixtures
# — cf. test/README.md, spec §10).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# create_peering <peering_name> <local_vnet> <local_rg> <remote_vnet_id>
create_peering() {
  local peering_name="$1" local_vnet="$2" local_rg="$3" remote_vnet_id="$4"

  if peering_exists "$peering_name" "$local_vnet" "$local_rg"; then
    log_info "Peering $peering_name sur $local_vnet déjà présent, réutilisation."
    return 0
  fi

  run_cmd az network vnet peering create \
    --name "$peering_name" \
    --vnet-name "$local_vnet" \
    --resource-group "$local_rg" \
    --remote-vnet "$remote_vnet_id" \
    --allow-vnet-access \
    --allow-forwarded-traffic
}

# verify_peering_connected <peering_name> <local_vnet> <local_rg> — vérifie
# peeringState == Connected. C'est une lecture pure (indépendante de
# $DRY_RUN) : elle ne s'exécute que si le peering existe déjà (créé lors d'un
# run précédent, ou par run_cmd juste avant en mode réel) ; sinon rien à
# vérifier (dry-run sur infra pas encore provisionnée, par ex.).
verify_peering_connected() {
  local peering_name="$1" local_vnet="$2" local_rg="$3"

  if ! peering_exists "$peering_name" "$local_vnet" "$local_rg"; then
    log_info "Peering $peering_name sur $local_vnet : pas (encore) créé, vérification ignorée."
    return 0
  fi

  local state
  state="$(az network vnet peering show --name "$peering_name" --vnet-name "$local_vnet" --resource-group "$local_rg" --query peeringState -o tsv)"
  if [[ "$state" != "Connected" ]]; then
    log_warn "Peering $peering_name sur $local_vnet : état = $state (attendu Connected)."
    return 1
  fi
  log_info "Peering $peering_name sur $local_vnet : Connected."
}

# peer_networks — orchestration complète de B2. Les noms de VNet ont un
# défaut correspondant à la convention observée sur cette infra :
# - GOAD/jumpbox : dérivés du "lab_name" GOAD-Light, stable (pas de suffixe
#   aléatoire, cf. GOAD/template/provider/azure/network.tf).
# - BadZure : dérivé de $RG_BADZURE lui-même. À la différence de GOAD, le nom
#   du resource group BadZure est choisi aléatoirement par
#   generate_resource_groups (BadZure/src/entity_generator.py) à chaque
#   déploiement — donc PAS de nom de VNet en dur ici : le nom réel est
#   "${RG_BADZURE}-vnet" (cf. BadZure/terraform/main.tf, ressource
#   azurerm_virtual_network.vm_vnets : name = "${resource_group_name}-vnet").
peer_networks() {
  require_vars RG_GOAD RG_BADZURE || return 1

  local goad_rg="$RG_GOAD"
  local badzure_rg="$RG_BADZURE"
  # Le jumpbox vit dans le même resource group que le reste de GOAD (seule la
  # région diffère) : GOAD n'a qu'un RG pour toutes ses régions, cf.
  # infra-inventory.md §10 (azure.sh cible par RG, indépendant de la région).
  local jumpbox_rg="$goad_rg"

  local goad_vnet="${GOAD_VNET_NAME:-GOAD-Light-virtual-network}"
  local jumpbox_vnet="${JUMPBOX_VNET_NAME:-vnet-jumpbox-c}"
  local badzure_vnet="${BADZURE_VNET_NAME:-${badzure_rg}-vnet}"

  local goad_vnet_id badzure_vnet_id jumpbox_vnet_id
  goad_vnet_id="$(az network vnet show --name "$goad_vnet" --resource-group "$goad_rg" --query id -o tsv)"
  badzure_vnet_id="$(az network vnet show --name "$badzure_vnet" --resource-group "$badzure_rg" --query id -o tsv)"
  jumpbox_vnet_id="$(az network vnet show --name "$jumpbox_vnet" --resource-group "$jumpbox_rg" --query id -o tsv)"

  create_peering "peering-badzure-to-goad" "$badzure_vnet" "$badzure_rg" "$goad_vnet_id"
  create_peering "peering-goad-to-badzure" "$goad_vnet" "$goad_rg" "$badzure_vnet_id"
  create_peering "peer-a-to-c" "$goad_vnet" "$goad_rg" "$jumpbox_vnet_id"
  create_peering "peer-c-to-a" "$jumpbox_vnet" "$jumpbox_rg" "$goad_vnet_id"

  verify_peering_connected "peering-badzure-to-goad" "$badzure_vnet" "$badzure_rg"
  verify_peering_connected "peering-goad-to-badzure" "$goad_vnet" "$goad_rg"
  verify_peering_connected "peer-a-to-c" "$goad_vnet" "$goad_rg"
  verify_peering_connected "peer-c-to-a" "$jumpbox_vnet" "$jumpbox_rg"
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  peer_networks
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
