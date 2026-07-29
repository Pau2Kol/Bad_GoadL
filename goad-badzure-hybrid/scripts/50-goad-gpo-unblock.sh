#!/usr/bin/env bash
# 50-goad-gpo-unblock.sh — débloque l'héritage GPO sur
# l'OU Domain Controllers (powershell/gpo-inheritance.ps1 -Unblock, qui
# enchaîne lui-même gpupdate /force), UNIQUEMENT après validation manuelle que
# la synchronisation Entra Connect est stable (cf. docs/manual-steps.md,
# étape 3 : Get-ADSyncScheduler + user GOAD visible dans le tenant). Ne pas
# enchaîner automatiquement après scripts/30-goad-hardening-fix.sh.
#
# Après déblocage, vérifie via powershell/check-adsync.ps1 que le service
# ADSync tourne toujours et que le Provider Type 24 tient toujours (le
# durcissement GPO qui vient d'être réactivé ne doit pas recasser le crypto
# fix — c'est exactement le bug d'origine que ce projet corrige).
#
# NON TESTABLE SUR FIXTURES (cf. test/README.md) : nécessite un
# vrai DC Windows durci par GOAD, avec une synchro Entra Connect réellement
# en cours. Ne pas exécuter sans validation explicite préalable de
# l'opérateur (cf. scripts/30-goad-hardening-fix.sh pour le même
# avertissement sur le tunnel SSH réel même sous --dry-run pour la partie
# lecture de get_jumpbox_public_ip).
#
# Sourçable : `source scripts/50-goad-gpo-unblock.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# unblock_gpo_inheritance.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/winrm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/winrm.sh"

# unblock_gpo_inheritance — orchestration complète du déblocage.
unblock_gpo_inheritance() {
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
  local check_script="${SCRIPT_DIR}/../powershell/check-adsync.ps1"

  log_info "Déblocage de l'héritage GPO sur l'OU Domain Controllers (+ gpupdate /force, inclus dans le script)."
  run_remote_powershell "$gpo_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD" -Unblock || return 1

  log_info "Vérification post-déblocage : le durcissement GPO réactivé ne doit pas recasser le crypto fix ni le service ADSync."
  if ! run_remote_powershell "$check_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD"; then
    log_error "check-adsync a détecté une régression après déblocage GPO (service ADSync arrêté et/ou Provider Type 24 réécrasé). Ne pas considérer ce déblocage comme terminé sans investigation — cf. docs/manual-steps.md."
    return 1
  fi

  log_info "Déblocage GPO terminé, ADSync et crypto fix confirmés intacts."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  unblock_gpo_inheritance
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
