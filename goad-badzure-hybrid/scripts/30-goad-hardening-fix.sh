#!/usr/bin/env bash
# 30-goad-hardening-fix.sh — établit le tunnel
# SSH->WinRM (jumpbox -> dc01:5985) puis pilote, via lib/run_powershell.py
# (pypsrp), l'exécution sur dc01 de :
#   1. powershell/gpo-inheritance.ps1 -Block  (empêche les GPO de durcissement
#      GOAD d'écraser le fix crypto — ordre critique, cause du bug d'origine)
#   2. powershell/crypto-fix.ps1              (registre Provider Type 24 +
#      ACL MachineKeys)
#
# Le déblocage de l'héritage GPO est un script
# séparé : scripts/50-goad-gpo-unblock.sh, appelé seulement après validation
# de la synchro Entra Connect — pas enchaîné automatiquement ici.
#
# NON TESTABLE SUR FIXTURES (cf. test/README.md) : nécessite un vrai DC
# Windows durci par GOAD. Même sous --dry-run, get_jumpbox_public_ip (lecture
# seule) interroge réellement Azure ; le tunnel SSH et les invocations
# PowerShell, eux, sont entièrement mockés.
#
# Sourçable : `source scripts/30-goad-hardening-fix.sh` ne fait que définir
# les fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# apply_hardening_fix.
#
# Toutes les commandes d'écriture (y compris l'exécution PowerShell distante
# via lib/run_powershell.py) passent par run_cmd (lib/common.sh), qui
# respecte --dry-run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/winrm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/winrm.sh"

# apply_hardening_fix — orchestration complète du blocage GPO + crypto
# fix. Le déblocage GPO (fin) est un script séparé
# (scripts/50-goad-gpo-unblock.sh).
apply_hardening_fix() {
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

  local gpo_script="${SCRIPT_DIR}/../powershell/gpo-inheritance.ps1"
  local crypto_fix_script="${SCRIPT_DIR}/../powershell/crypto-fix.ps1"

  log_info "Étape 1/2 : blocage de l'héritage GPO (avant le crypto fix, ordre critique)."
  run_remote_powershell "$gpo_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD" -Block || return 1

  log_info "Étape 2/2 : application du crypto fix (Provider Type 24 + ACL MachineKeys)."
  run_remote_powershell "$crypto_fix_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD" || return 1

  log_info "Hardening fix appliqué. Suite : étapes manuelles (installation Entra Connect, wizard ABA) — cf. docs/manual-steps.md."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  apply_hardening_fix
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
