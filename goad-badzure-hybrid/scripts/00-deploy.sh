#!/usr/bin/env bash
# 00-deploy.sh : orchestrateur. Enchaîne les scripts de ce dossier au lieu
# de les lancer un par un à la main. Coupé exactement au point réellement
# manuel du déploiement (le wizard Entra Connect).
#
# Sous-commandes :
#   goad    Déploie GOAD-Light (VMs + configuration du domaine). La jumpbox
#           est créée directement dans $REGION_JUMPBOX (cf.
#           GOAD/template/provider/azure/jumpbox.tf), pas migrée après coup.
#   link    Relie GOAD et BadZure : peering réseau, règles NSG, préparation
#           Entra Connect, hardening dc01. S'arrête avant le wizard (étape
#           manuelle) et affiche quoi faire ensuite.
#   finish  À lancer après le wizard : vérifie que la synchro est stable,
#           puis débloque les GPO. Refuse de continuer si la synchro n'est
#           pas confirmée.
#   creds   Affiche les identifiants du lab : secrets à révélation unique
#           enregistrés pendant le déploiement (config/credentials.local.txt)
#           et valeurs re-découvrables (DC01_ADMIN_PASSWORD, clé SSH jumpbox...).
#
# Sourçable : `source scripts/00-deploy.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite d'une
# des fonctions deploy_*.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/winrm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/winrm.sh"
# shellcheck source=20-peer-networks.sh disable=SC1091
source "${SCRIPT_DIR}/20-peer-networks.sh"
# shellcheck source=21-nsg-rules.sh disable=SC1091
source "${SCRIPT_DIR}/21-nsg-rules.sh"
# shellcheck source=30-goad-hardening-fix.sh disable=SC1091
source "${SCRIPT_DIR}/30-goad-hardening-fix.sh"
# shellcheck source=40-prepare-entra-connect.sh disable=SC1091
source "${SCRIPT_DIR}/40-prepare-entra-connect.sh"
# shellcheck source=50-goad-gpo-unblock.sh disable=SC1091
source "${SCRIPT_DIR}/50-goad-gpo-unblock.sh"

# deploy_goad — lance goad.py directement, attaché au terminal courant
# (jamais de stdin pipé : c'est ce qui évite le bug de prompt bloquant entre
# goad.py et son propre appel à terraform, documenté dans
# docs/troubleshooting.md). TF_VAR_jumpbox_location/TF_VAR_jumpbox_allowed_ip
# sont exportées avant l'appel : Terraform (lancé en sous-processus par
# goad.py, qui hérite de l'environnement) crée la jumpbox directement dans
# $REGION_JUMPBOX au lieu de la région des DC — évite le conflit de quota
# documenté dans docs/amont-changes.md (dc01+dc02+srv02+jumpbox y dépasserait
# le quota Azure Free Trial). goad.py ne renvoie PAS un code retour non nul
# quand do_provide()/Terraform échoue (il logue juste "Providing error stop"
# et continue) : on vérifie donc l'état réel de dc01 dans Azure plutôt que le
# code retour, pour détecter un éventuel échec (prompt Terraform bloqué,
# quota insuffisant pour une autre raison, etc.) — le message d'erreur pointe
# alors vers docs/troubleshooting.md.
deploy_goad() {
  local goad_dir="${GOAD_DIR:-${SCRIPT_DIR}/../../GOAD}"
  local instance="${GOAD_INSTANCE_ID:-}"

  if [[ ! -d "$goad_dir" ]]; then
    log_error "Dossier GOAD introuvable : $goad_dir (variable GOAD_DIR dans config/lab.env si besoin)."
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] TF_VAR_jumpbox_location=$REGION_JUMPBOX TF_VAR_jumpbox_allowed_ip=$ALLOWED_IP cd $goad_dir && python3 goad.py -t install -l GOAD-Light -p azure ${instance:+-i $instance}"
    return 0
  fi

  require_vars REGION_JUMPBOX ALLOWED_IP || return 1

  log_info "Lancement de goad.py (interactif, attaché au terminal courant)."
  (
    export TF_VAR_jumpbox_location="$REGION_JUMPBOX"
    export TF_VAR_jumpbox_allowed_ip="$ALLOWED_IP"
    cd "$goad_dir" || exit 1
    if [[ -n "$instance" ]]; then
      python3 goad.py -t install -l GOAD-Light -p azure -i "$instance"
    else
      python3 goad.py -t install -l GOAD-Light -p azure
    fi
  )

  discover_rg_goad
  if [[ -z "${RG_GOAD:-}" ]] || ! vm_exists "goad-vm-dc01" "$RG_GOAD"; then
    log_error "Échec du déploiement GOAD-Light (dc01 non créé). Si c'est un prompt Terraform bloqué, voir docs/troubleshooting.md."
    return 1
  fi

  log_info "GOAD-Light déployé."
}

# deploy_link — relie GOAD et BadZure, s'arrête avant le wizard Entra
# Connect (étape manuelle).
deploy_link() {
  log_info "=== 1/4 : peering réseau ==="
  peer_networks || return 1

  log_info "=== 2/4 : règles NSG ==="
  apply_nsg_hardening || return 1

  log_info "=== 3/4 : préparation Entra Connect (compte sync-admin) ==="
  prepare_entra_connect || return 1

  log_info "=== 4/4 : hardening dc01 (blocage GPO + crypto fix) ==="
  apply_hardening_fix || return 1

  log_info "Terminé. Étape manuelle suivante : installer Entra Connect et suivre le wizard sur dc01 (cf. docs/manual-steps.md). Lancer '$0 finish' une fois la synchro validée."
}

# check_sync_stable — pré-vérification avant de débloquer les GPO : ouvre
# le tunnel WinRM et lance check-adsync.ps1. Sépare de
# unblock_gpo_inheritance (qui, lui, vérifie APRÈS déblocage) pour ne
# jamais tenter le déblocage si la synchro n'est pas déjà stable au départ.
check_sync_stable() {
  require_vars RG_GOAD DC01_PRIVATE_IP DC01_ADMIN_USER DC01_ADMIN_PASSWORD JUMPBOX_SSH_USER JUMPBOX_SSH_KEY_PATH || return 1

  local rg="$RG_GOAD"
  local jumpbox_vm_name="${JUMPBOX_VM_NAME:-ubuntu-jumpbox}"
  local local_port="${WINRM_TUNNEL_LOCAL_PORT:-15985}"
  local remote_port=5985

  local jumpbox_public_ip
  jumpbox_public_ip="$(get_jumpbox_public_ip "$jumpbox_vm_name" "$rg")"
  if [[ -z "$jumpbox_public_ip" ]]; then
    log_error "IP publique du jumpbox introuvable (VM $jumpbox_vm_name, RG $rg)."
    return 1
  fi

  TUNNEL_PID=""
  trap 'close_ssh_tunnel "$TUNNEL_PID"' EXIT

  open_ssh_tunnel "$JUMPBOX_SSH_USER" "$JUMPBOX_SSH_KEY_PATH" "$jumpbox_public_ip" "$local_port" "$DC01_PRIVATE_IP" "$remote_port" || return 1

  local check_script="${SCRIPT_DIR}/../powershell/check-adsync.ps1"
  run_remote_powershell "$check_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD"
}

# deploy_finish — à lancer une fois le wizard Entra Connect terminé.
# Refuse de débloquer les GPO si la synchro n'est pas confirmée stable.
deploy_finish() {
  log_info "Vérification de la synchro avant déblocage des GPO."
  if ! check_sync_stable; then
    log_error "Synchro non confirmée stable : ne pas débloquer les GPO maintenant. Terminer d'abord le wizard Entra Connect et sa vérification (cf. docs/manual-steps.md)."
    return 1
  fi

  log_info "Synchro confirmée, déblocage des GPO."
  unblock_gpo_inheritance || return 1
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env

  local action="${1:-}"
  case "$action" in
    goad)
      deploy_goad
      ;;
    link)
      deploy_link
      ;;
    finish)
      deploy_finish
      ;;
    creds)
      show_credentials
      ;;
    *)
      log_error "Usage : $0 [--dry-run] goad|link|finish|creds"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
