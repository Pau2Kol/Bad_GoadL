#!/usr/bin/env bash
# 99-lifecycle.sh — gère le start/stop courant du lab complet, sur les 3
# régions (ciblage par RG + nom, indépendant de la région : un seul RG GOAD
# couvre denmarkeast ET indiasouthcentral).
#
# Points notables :
# - `stop` utilise `az vm deallocate` : arrête la facturation compute
#   (contrairement à un simple `stop` OS, qui laisse la VM allouée et
#   facturée). Sur un abonnement Free Trial, `deallocate` ne libère pas le
#   quota "Total Regional Cores" d'une région tant que la VM existe encore :
#   seule la suppression complète (`az vm delete`) libère ce quota. À garder
#   en tête si un redéploiement futur a besoin de plus de capacité dans une
#   région déjà occupée par des VM désallouées.
# - `stop`/`start` couvrent aussi les ressources cloud BadZure (Function
#   App, Logic App), qui sinon continuent de consommer même "lab éteint"
#   côté VMs. Cosmos DB serverless n'a pas de notion start/stop : listé pour
#   information uniquement, jamais d'action dessus.
# - Ordre de démarrage : DC (dc01, dc02) d'abord, puis srv02, puis jumpbox,
#   puis les ressources BadZure (VM + Function App + Logic App).
# - Les VM/Function App/Logic App BadZure sont découvertes dynamiquement
#   (`az vm list` / `az functionapp list` / `az resource list` sur
#   $RG_BADZURE) plutôt que nommées en dur : BadZure choisit des noms
#   aléatoires par déploiement (cf. src/entity_generator.py,
#   `f"{vm}-{random_suffix}"`) — un nom en dur casserait sur un redéploiement.
#   Les VM/NSG/noms GOAD, eux, sont stables (template "goad-vm-<host>"), donc
#   nommés en dur ci-dessous.
#
# Sourçable : `source scripts/99-lifecycle.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# lifecycle_start / lifecycle_stop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# vm_start <name> <rg> — idempotent : ignore si la VM n'existe pas (au lieu
# d'échouer), utile si le lab n'est que partiellement déployé.
vm_start() {
  local name="$1" rg="$2"
  if ! vm_exists "$name" "$rg"; then
    log_warn "VM $name introuvable dans $rg, démarrage ignoré."
    return 0
  fi
  run_cmd az vm start --name "$name" --resource-group "$rg" --no-wait
}

# vm_deallocate <name> <rg>
vm_deallocate() {
  local name="$1" rg="$2"
  if ! vm_exists "$name" "$rg"; then
    log_warn "VM $name introuvable dans $rg, désallocation ignorée."
    return 0
  fi
  run_cmd az vm deallocate --name "$name" --resource-group "$rg" --no-wait
}

# get_badzure_vm_names <rg> — lecture pure, indépendante de $DRY_RUN.
get_badzure_vm_names() {
  local rg="$1"
  az vm list --resource-group "$rg" --query "[].name" -o tsv
}

# get_function_app_names <rg> — lecture pure.
get_function_app_names() {
  local rg="$1"
  az functionapp list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null
}

# get_logic_app_names <rg> — lecture pure.
get_logic_app_names() {
  local rg="$1"
  az resource list --resource-group "$rg" --resource-type "Microsoft.Logic/workflows" --query "[].name" -o tsv 2>/dev/null
}

functionapp_start() {
  local name="$1" rg="$2"
  run_cmd az functionapp start --name "$name" --resource-group "$rg"
}

functionapp_stop() {
  local name="$1" rg="$2"
  run_cmd az functionapp stop --name "$name" --resource-group "$rg"
}

# logicapp_set_state <name> <rg> <Enabled|Disabled> — via az resource update
# générique (propriété properties.state), plutôt que l'extension `logic`
# (az logic workflow update) pour éviter une dépendance d'extension
# supplémentaire. Vérifié en lecture (az resource show --query
# properties.state) contre l'infra réelle avant d'écrire ce script.
logicapp_set_state() {
  local name="$1" rg="$2" state="$3"
  run_cmd az resource update \
    --resource-group "$rg" \
    --name "$name" \
    --resource-type "Microsoft.Logic/workflows" \
    --set properties.state="$state"
}

# note_cosmos_db_accounts <rg> — Cosmos DB serverless n'a pas de start/stop
# applicable : listé pour information uniquement, aucune action.
note_cosmos_db_accounts() {
  local rg="$1"
  local accounts
  accounts="$(az cosmosdb list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null)"
  if [[ -n "$accounts" ]]; then
    log_info "Comptes Cosmos DB dans $rg (serverless, pas de start/stop applicable, aucune action) : $(tr '\n' ' ' <<< "$accounts")"
  fi
}

# lifecycle_start — ordre : DC d'abord, puis srv02, puis jumpbox, puis
# BadZure (VM + Function App + Logic App).
lifecycle_start() {
  require_vars RG_GOAD RG_BADZURE || return 1

  log_info "1/4 : démarrage des contrôleurs de domaine (dc01, dc02)."
  vm_start "goad-vm-dc01" "$RG_GOAD"
  vm_start "goad-vm-dc02" "$RG_GOAD"

  log_info "2/4 : démarrage de srv02."
  vm_start "goad-vm-srv02" "$RG_GOAD"

  log_info "3/4 : démarrage du jumpbox."
  vm_start "${JUMPBOX_VM_NAME:-ubuntu-jumpbox}" "$RG_GOAD"

  log_info "4/4 : démarrage des ressources BadZure ($RG_BADZURE)."
  local vm_name
  while IFS= read -r vm_name; do
    [[ -n "$vm_name" ]] && vm_start "$vm_name" "$RG_BADZURE"
  done < <(get_badzure_vm_names "$RG_BADZURE")

  local app_name
  while IFS= read -r app_name; do
    [[ -n "$app_name" ]] && functionapp_start "$app_name" "$RG_BADZURE"
  done < <(get_function_app_names "$RG_BADZURE")

  local logic_name
  while IFS= read -r logic_name; do
    [[ -n "$logic_name" ]] && logicapp_set_state "$logic_name" "$RG_BADZURE" "Enabled"
  done < <(get_logic_app_names "$RG_BADZURE")

  note_cosmos_db_accounts "$RG_BADZURE"

  log_info "Démarrage terminé (--no-wait : les VM Azure peuvent encore être en cours de démarrage)."
}

# lifecycle_stop — désalloue toutes les VM (GOAD + BadZure) et arrête les
# ressources cloud BadZure arrêtables. Ordre non critique pour l'arrêt.
lifecycle_stop() {
  require_vars RG_GOAD RG_BADZURE || return 1

  log_info "Désallocation des VM GOAD (dc01, dc02, srv02, jumpbox)."
  vm_deallocate "goad-vm-dc01" "$RG_GOAD"
  vm_deallocate "goad-vm-dc02" "$RG_GOAD"
  vm_deallocate "goad-vm-srv02" "$RG_GOAD"
  vm_deallocate "${JUMPBOX_VM_NAME:-ubuntu-jumpbox}" "$RG_GOAD"

  log_info "Désallocation des VM BadZure + arrêt des ressources cloud BadZure ($RG_BADZURE)."
  local vm_name
  while IFS= read -r vm_name; do
    [[ -n "$vm_name" ]] && vm_deallocate "$vm_name" "$RG_BADZURE"
  done < <(get_badzure_vm_names "$RG_BADZURE")

  local app_name
  while IFS= read -r app_name; do
    [[ -n "$app_name" ]] && functionapp_stop "$app_name" "$RG_BADZURE"
  done < <(get_function_app_names "$RG_BADZURE")

  local logic_name
  while IFS= read -r logic_name; do
    [[ -n "$logic_name" ]] && logicapp_set_state "$logic_name" "$RG_BADZURE" "Disabled"
  done < <(get_logic_app_names "$RG_BADZURE")

  note_cosmos_db_accounts "$RG_BADZURE"

  log_info "Arrêt terminé (--no-wait pour les VM : désallocation en cours côté Azure)."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env

  local action="${1:-}"
  case "$action" in
    start)
      lifecycle_start
      ;;
    stop)
      lifecycle_stop
      ;;
    *)
      log_error "Usage : $0 [--dry-run] start|stop"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
