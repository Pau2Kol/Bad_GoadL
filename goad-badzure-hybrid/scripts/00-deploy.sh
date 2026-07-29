#!/usr/bin/env bash
# 00-deploy.sh : orchestrateur. Enchaîne les scripts de ce dossier au lieu
# de les lancer un par un à la main. Coupé exactement au point réellement
# manuel du déploiement (le wizard Entra Connect).
#
# Sous-commandes :
#   goad    Déploie GOAD-Light (VMs + configuration du domaine).
#   link    Relie GOAD et BadZure : migration jumpbox, peering réseau,
#           règles NSG, préparation Entra Connect, hardening dc01. S'arrête
#           avant le wizard (étape manuelle) et affiche quoi faire ensuite.
#   finish  À lancer après le wizard : vérifie que la synchro est stable,
#           puis débloque les GPO. Refuse de continuer si la synchro n'est
#           pas confirmée.
#
# Sourçable : `source scripts/00-deploy.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite d'une
# des fonctions deploy_*.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/winrm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/winrm.sh"
# shellcheck source=10-migrate-jumpbox.sh disable=SC1091
source "${SCRIPT_DIR}/10-migrate-jumpbox.sh"
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
# docs/troubleshooting.md). Sur un premier déploiement, dc01 (le plus gros
# gabarit, cf. docs/amont-changes.md) échoue systématiquement pour conflit de
# quota tant que la jumpbox n'a pas été déplacée hors de la région des DC :
# ce cas précis est détecté et corrigé automatiquement. Les autres échecs
# (prompt Terraform bloqué notamment) restent des contournements manuels :
# le message d'erreur pointe vers docs/troubleshooting.md plutôt que de
# retenter automatiquement contre de l'infrastructure réelle.
deploy_goad() {
  local goad_dir="${GOAD_DIR:-${SCRIPT_DIR}/../../GOAD}"
  local instance="${GOAD_INSTANCE_ID:-}"

  if [[ ! -d "$goad_dir" ]]; then
    log_error "Dossier GOAD introuvable : $goad_dir (variable GOAD_DIR dans config/lab.env si besoin)."
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] cd $goad_dir && python3 goad.py -t install -l GOAD-Light -p azure ${instance:+-i $instance}"
    return 0
  fi

  run_goad_install "$goad_dir" "$instance"
  local result=$?

  if [[ $result -ne 0 ]]; then
    discover_rg_goad
    if [[ -n "${RG_GOAD:-}" ]] && vm_exists "ubuntu-jumpbox" "$RG_GOAD" && ! vm_exists "goad-vm-dc01" "$RG_GOAD"; then
      log_info "dc01 manquant, jumpbox présente : conflit de quota connu (cf. docs/amont-changes.md). Migration de la jumpbox puis reprise ciblée."
      if recover_from_dc01_quota_conflict "$goad_dir" "$instance"; then
        result=0
      fi
    fi
  fi

  if [[ $result -ne 0 ]]; then
    log_error "Échec du déploiement GOAD-Light. Si c'est un prompt Terraform bloqué, voir docs/troubleshooting.md."
    return 1
  fi

  log_info "GOAD-Light déployé."
}

# run_goad_install <goad_dir> <instance> — un essai de goad.py -t install,
# attaché au terminal courant.
run_goad_install() {
  local goad_dir="$1" instance="$2"
  log_info "Lancement de goad.py (interactif, attaché au terminal courant)."
  (
    cd "$goad_dir" || exit 1
    if [[ -n "$instance" ]]; then
      python3 goad.py -t install -l GOAD-Light -p azure -i "$instance"
    else
      python3 goad.py -t install -l GOAD-Light -p azure
    fi
  )
}

# recover_from_dc01_quota_conflict <goad_dir> <instance> — jumpbox+dc02+srv02
# saturent le quota régional avant que dc01 ne soit créé (cf.
# docs/amont-changes.md). La migration de la jumpbox libère le vCPU
# nécessaire, mais relancer un `goad.py -t install` complet referait un apply
# Terraform intégral : celui-ci verrait la jumpbox migrée (déplacée hors de
# son contrôle par des commandes az directes) comme manquante et tenterait de
# la recréer dans la région des DC, annulant la migration et resaturant le
# quota (cf. docs/troubleshooting.md, "Un nouveau terraform apply recrée le
# jumpbox après sa migration"). On cible donc l'apply sur dc01 uniquement,
# puis on reprend le provisioning Ansible directement (sans repasser par
# do_provide), avec le même mécanisme que le contournement documenté pour un
# prompt Terraform bloqué.
recover_from_dc01_quota_conflict() {
  local goad_dir="$1" instance="$2"

  migrate_jumpbox || return 1

  local instance_dir="${instance:+$goad_dir/workspace/$instance}"
  [[ -z "$instance_dir" ]] && instance_dir="$(find_goad_workspace_dir)"
  if [[ -z "$instance_dir" || ! -d "$instance_dir/provider" ]]; then
    log_error "Dossier d'instance GOAD introuvable pour reprendre le déploiement de dc01."
    return 1
  fi
  instance="$(basename "$instance_dir")"

  log_info "Apply Terraform ciblé sur dc01."
  if ! (cd "$instance_dir/provider" && terraform apply -auto-approve -target='azurerm_windows_virtual_machine.goad-vm["dc01"]'); then
    log_error "L'apply ciblé sur dc01 a échoué."
    return 1
  fi

  local jumpbox_ip
  jumpbox_ip="$(az vm show -d --name ubuntu-jumpbox --resource-group "$RG_GOAD" --query publicIps -o tsv)"
  if [[ -z "$jumpbox_ip" ]]; then
    log_error "IP publique de la jumpbox introuvable après migration."
    return 1
  fi

  log_info "Reprise du provisioning Ansible (dc01 créé, sans repasser par l'apply Terraform complet)."
  (
    cd "$goad_dir" || exit 1
    python3 - "$instance" "$jumpbox_ip" <<'PYEOF'
import sys, os, importlib.util

goad_dir = os.path.abspath(".")
sys.path.insert(0, goad_dir)
spec = importlib.util.spec_from_file_location("goad_cli", os.path.join(goad_dir, "goad.py"))
goad_cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(goad_cli)

instance, jumpbox_ip = sys.argv[1], sys.argv[2]
sys.argv = ["goad.py", "-i", instance, "-l", "GOAD-Light", "-p", "azure"]
args = goad_cli.parse_args()
g = goad_cli.Goad(args)
g.do_load(instance)

provisioner = g.lab_manager.get_current_instance_provisioner()
provisioner.prepare_jumpbox(jumpbox_ip)
if not provisioner.run():
    sys.exit(1)
g.lab_manager.get_current_instance().set_status(goad_cli.READY)
PYEOF
  )
}

# deploy_link — B1 à B4/B6 : relie GOAD et BadZure, s'arrête avant le
# wizard Entra Connect (étape manuelle).
deploy_link() {
  log_info "=== 1/5 : migration du jumpbox ==="
  migrate_jumpbox || return 1

  log_info "=== 2/5 : peering réseau ==="
  peer_networks || return 1

  log_info "=== 3/5 : règles NSG ==="
  apply_nsg_hardening || return 1

  log_info "=== 4/5 : préparation Entra Connect (compte sync-admin) ==="
  prepare_entra_connect || return 1

  log_info "=== 5/5 : hardening dc01 (blocage GPO + crypto fix) ==="
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
    *)
      log_error "Usage : $0 [--dry-run] goad|link|finish"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
