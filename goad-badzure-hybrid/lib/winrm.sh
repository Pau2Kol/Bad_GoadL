#!/usr/bin/env bash
# lib/winrm.sh — helpers partagés pour piloter du PowerShell sur dc01 via un
# tunnel SSH->WinRM depuis le jumpbox (pypsrp, cf. lib/run_powershell.py).
# Utilisé par scripts/30-goad-hardening-fix.sh et scripts/50-goad-gpo-unblock.sh
# (extrait du Lot 3 vers ce fichier au Lot 5 pour éviter de dupliquer une
# logique de transport sensible — tunnel SSH, gestion de process — dans deux
# scripts distincts : un bug corrigé ici profite aux deux appelants).
#
# Sourçable sans effet de bord. Suppose que lib/common.sh est déjà sourcé par
# l'appelant (log_info/log_error/run_cmd/DRY_RUN).

# Chemin vers run_powershell.py, résolu relativement à CE fichier (pas au
# script appelant) : correct quel que soit le script qui source lib/winrm.sh.
WINRM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUN_POWERSHELL_PY="${WINRM_LIB_DIR}/run_powershell.py"

# get_jumpbox_public_ip <vm_name> <rg> — lecture pure, indépendante de $DRY_RUN.
get_jumpbox_public_ip() {
  local vm_name="$1" rg="$2"
  az vm list-ip-addresses \
    --name "$vm_name" \
    --resource-group "$rg" \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
    -o tsv
}

# open_ssh_tunnel <ssh_user> <ssh_key_path> <jumpbox_public_ip> <local_port> <target_private_ip> <remote_port>
# — ouvre un tunnel SSH local en arrière-plan (-N, pas de commande distante),
# attend que le port local réponde avant de continuer. Renseigne la variable
# globale TUNNEL_PID (vide en dry-run) pour permettre à close_ssh_tunnel de
# le fermer proprement (cf. trap EXIT dans le script appelant).
open_ssh_tunnel() {
  local ssh_user="$1" ssh_key_path="$2" jumpbox_public_ip="$3" local_port="$4" target_private_ip="$5" remote_port="$6"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] ssh -N -L ${local_port}:${target_private_ip}:${remote_port} -i ${ssh_key_path} ${ssh_user}@${jumpbox_public_ip}"
    TUNNEL_PID=""
    return 0
  fi

  ssh -N \
    -L "${local_port}:${target_private_ip}:${remote_port}" \
    -i "$ssh_key_path" \
    -o StrictHostKeyChecking=accept-new \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout=15 \
    "${ssh_user}@${jumpbox_public_ip}" &
  TUNNEL_PID=$!

  local wait_iterations=10
  for ((_i = 0; _i < wait_iterations; _i++)); do
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
      log_error "Le tunnel SSH s'est arrêté prématurément (PID $TUNNEL_PID)."
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
      exec 3>&- 3<&-
      log_info "Tunnel SSH prêt sur 127.0.0.1:${local_port} (PID $TUNNEL_PID)."
      return 0
    fi
    sleep 1
  done

  log_error "Le tunnel SSH n'a pas ouvert le port local ${local_port} à temps (${wait_iterations}s)."
  return 1
}

# close_ssh_tunnel <pid> — no-op si vide/déjà terminé. À appeler via trap EXIT
# pour garantir la fermeture même en cas d'échec d'une étape intermédiaire.
close_ssh_tunnel() {
  local pid="$1"
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    log_info "Tunnel SSH fermé (PID $pid)."
  fi
}

# run_remote_powershell <script_local> <local_port> <user> <password> [args...]
# — délègue à lib/run_powershell.py (pypsrp) via run_cmd, donc respecte
# --dry-run comme toute autre commande d'écriture de ce projet. Le mot de
# passe est transmis via la variable d'environnement WINRM_PASSWORD, jamais
# en argument : run_cmd logue "$*" tel quel (cf. lib/common.sh), un
# --password apparaîtrait donc en clair dans les logs et dans `ps aux`.
run_remote_powershell() {
  local script_path="$1" local_port="$2" user="$3" password="$4"
  shift 4
  local -a ps_args=("$@")

  local -a py_args=(
    "$RUN_POWERSHELL_PY"
    --host 127.0.0.1
    --port "$local_port"
    --user "$user"
    --script "$script_path"
  )
  local arg
  for arg in "${ps_args[@]}"; do
    py_args+=("--arg=${arg}")
  done

  WINRM_PASSWORD="$password" run_cmd python3 "${py_args[@]}"
}
