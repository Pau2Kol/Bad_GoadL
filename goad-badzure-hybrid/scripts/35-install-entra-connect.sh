#!/usr/bin/env bash
# 35-install-entra-connect.sh — établit le tunnel SSH->WinRM (jumpbox ->
# dc01:5985) puis pilote, via lib/run_powershell.py (pypsrp) :
#   1. powershell/enable-tls12.ps1  (SCHANNEL + .NET Framework — sans ça, le
#      wizard échoue avec "Incorrect version of TLS", jamais configuré par
#      défaut sur l'image Windows Server ; redémarre dc01 si nécessaire)
#   2. powershell/install-entra-connect.ps1  (téléchargement + installation
#      silencieuse d'Azure AD Connect)
#
# Le canal WinRM ne peut pas transférer l'installeur lui-même (~145 Mo) :
# dc01 le télécharge donc lui-même depuis internet (accès sortant vérifié
# fonctionnel), une simple commande PowerShell suffit à déclencher ça.
#
# N'installe QUE le produit (mode silencieux). La configuration ABA qui suit
# passe obligatoirement par le wizard graphique en RDP (Conditional Access
# du tenant bloque tout login scripté) : hors périmètre de ce script,
# cf. docs/manual-steps.md.
#
# NON TESTABLE SUR FIXTURES : nécessite un vrai DC Windows avec un accès
# internet sortant réel.
#
# Sourçable : `source scripts/35-install-entra-connect.sh` ne fait que
# définir les fonctions ci-dessous ; rien n'est exécuté avant l'appel
# explicite de install_entra_connect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/winrm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/winrm.sh"

# wait_for_dc01_winrm <script> <local_port> <user> <password> <tentatives>
# <délai_secondes> — réessaie <script> via WinRM jusqu'à succès. Utilisé
# après un redémarrage de dc01 : le tunnel SSH vers la jumpbox reste ouvert
# (dc01 est en aval, sur le port distant du tunnel), mais WinRM sur dc01
# lui-même met du temps à répondre le temps que Windows redémarre.
wait_for_dc01_winrm() {
  local script="$1" local_port="$2" user="$3" password="$4" attempts="$5" delay="$6"

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    log_info "Attente que dc01 réponde via WinRM après redémarrage (tentative $attempt/$attempts)."
    if run_remote_powershell "$script" "$local_port" "$user" "$password" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

# install_entra_connect — orchestration complète : active TLS 1.2 (requis par
# le wizard, redémarre dc01 si nécessaire), puis télécharge et installe
# Azure AD Connect en mode silencieux.
install_entra_connect() {
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

  local tls_script="${SCRIPT_DIR}/../powershell/enable-tls12.ps1"
  local install_script="${SCRIPT_DIR}/../powershell/install-entra-connect.ps1"

  # Le wizard Azure AD Connect échoue avec "Incorrect version of TLS" tant que
  # TLS 1.2 (SCHANNEL + .NET Framework) n'est pas explicitement activé sur
  # cette image Windows Server — jamais configuré par défaut, rencontré en
  # conditions réelles. Vérifié/corrigé avant l'installation elle-même.
  log_info "Vérification/activation de TLS 1.2 sur dc01 (requis par le wizard Azure AD Connect)."
  local tls_output
  tls_output="$(run_remote_powershell "$tls_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD")" || return 1
  echo "$tls_output"

  if [[ "$tls_output" == *"REBOOT_REQUIRED"* ]]; then
    log_info "Redémarrage de dc01 (goad-vm-dc01) pour appliquer TLS 1.2 (SCHANNEL chargé au boot par LSASS)."
    run_cmd az vm restart --name "goad-vm-dc01" --resource-group "$rg" || return 1

    if ! wait_for_dc01_winrm "$tls_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD" 20 15; then
      log_error "dc01 ne répond toujours pas via WinRM après redémarrage (5 min). Réessayer plus tard : ./scripts/00-deploy.sh link."
      return 1
    fi
    log_info "dc01 de nouveau disponible après redémarrage."
  fi

  log_info "Téléchargement et installation silencieuse d'Azure AD Connect sur dc01 (peut prendre quelques minutes)."
  run_remote_powershell "$install_script" "$local_port" "$DC01_ADMIN_USER" "$DC01_ADMIN_PASSWORD" || return 1

  log_info "Azure AD Connect installé. Suite : wizard ABA en RDP (étape manuelle, cf. docs/manual-steps.md)."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  install_entra_connect
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
