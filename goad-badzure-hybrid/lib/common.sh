#!/usr/bin/env bash
# lib/common.sh — helpers partagés pour tous les scripts de scripts/ et test/ :
# logging, chargement de config/lab.env, gardes d'idempotence (resource_exists,
# vm_exists, peering_exists) et l'exécuteur central run_cmd (dry-run aware).
#
# Sourçable sans effet de bord : ne fait aucun appel réseau/Azure, ne change pas de
# répertoire, ne définit que des fonctions et variables. Chaque script appelant est
# responsable de son propre "set -euo pipefail" après le source.
#
# Usage : source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Drapeau global dry-run, lu par run_cmd(). Un script peut aussi le positionner
# directement (DRY_RUN=true) sans passer par parse_common_flags.
DRY_RUN="${DRY_RUN:-false}"

# Rempli par parse_common_flags() avec les arguments non reconnus, à consommer par
# le script appelant via : set -- "${REMAINING_ARGS[@]}"
REMAINING_ARGS=()

# log <niveau> <message...> — impl commune, non appelée directement.
log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >&2
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# parse_common_flags "$@" — extrait --dry-run des arguments d'un script, laisse le
# reste dans REMAINING_ARGS. À utiliser ainsi dans un script appelant :
#   parse_common_flags "$@"
#   set -- "${REMAINING_ARGS[@]}"
parse_common_flags() {
  REMAINING_ARGS=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        DRY_RUN=true
        ;;
      *)
        REMAINING_ARGS+=("$arg")
        ;;
    esac
  done
}

# load_lab_env [chemin] — source config/lab.env (par défaut : lab.env à côté de
# lab.env.example, résolu relativement à ce fichier). Échoue proprement si absent,
# plutôt que de laisser les scripts tourner avec des variables vides.
load_lab_env() {
  local env_file="${1:-}"
  if [[ -z "$env_file" ]]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="${lib_dir}/../config/lab.env"
  fi

  if [[ ! -f "$env_file" ]]; then
    log_error "Fichier d'environnement introuvable : $env_file (copier config/lab.env.example vers config/lab.env et le renseigner)"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$env_file"

  verify_subscription_context || return 1
  resolve_allowed_ip
}

# verify_subscription_context — garde-fou : si $SUBSCRIPTION_ID est
# renseignée dans lab.env, vérifie que la session az CLI active pointe bien
# vers cet abonnement avant de laisser un script continuer. Rien n'utilisait
# cette variable auparavant (déclarée dans lab.env.example mais jamais lue) :
# un opérateur dont la session az pointait vers le mauvais abonnement
# n'aurait eu aucun signal avant qu'un script y écrive réellement. Laissée
# vide, la vérification est simplement ignorée (comportement inchangé).
verify_subscription_context() {
  if [[ -z "${SUBSCRIPTION_ID:-}" ]]; then
    return 0
  fi

  local active_subscription
  active_subscription="$(az account show --query id -o tsv 2>/dev/null)"

  if [[ -z "$active_subscription" ]]; then
    log_error "Impossible de déterminer l'abonnement az actif (az account show a échoué) : vérifier 'az login'."
    return 1
  fi

  if [[ "$active_subscription" != "$SUBSCRIPTION_ID" ]]; then
    log_error "Abonnement az actif ($active_subscription) différent de SUBSCRIPTION_ID dans lab.env ($SUBSCRIPTION_ID) : az account set --subscription $SUBSCRIPTION_ID avant de continuer."
    return 1
  fi
}

# detect_public_ip — IP publique sortante de la machine opérateur (celle qui
# exécute ces scripts), via le même endpoint que BadZure/src/utils.py
# get_public_ip() (api64.ipify.org injoignable dans ce sandbox précis,
# ifconfig.me/ip confirmé fonctionnel). Utilisée uniquement comme fallback
# quand $ALLOWED_IP n'est pas explicitement renseignée dans lab.env — cf.
# resolve_allowed_ip.
detect_public_ip() {
  curl -sf -4 --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]'
}

# resolve_allowed_ip — remplit $ALLOWED_IP par auto-détection si absente de
# lab.env, plutôt que d'exiger une valeur figée à maintenir à la main.
# Constaté en conditions réelles : l'IP sortante de la machine opérateur
# change (reset d'environnement, itinérance réseau) et une valeur figée dans
# lab.env finit par bloquer silencieusement SSH (règle NSG restrictive vers
# une IP obsolète, timeout de connexion sans message d'erreur explicite côté
# Azure). Une valeur explicite dans lab.env reste prioritaire (utile pour
# épingler une IP stable, ex. agent CI) : l'auto-détection n'intervient que
# si $ALLOWED_IP est vide après le chargement de lab.env.
resolve_allowed_ip() {
  if [[ -n "${ALLOWED_IP:-}" ]]; then
    return 0
  fi

  local detected
  detected="$(detect_public_ip)"
  if [[ -z "$detected" ]]; then
    log_error "ALLOWED_IP absente de lab.env et auto-détection échouée (pas d'accès réseau à ifconfig.me ?) — renseigner ALLOWED_IP manuellement."
    return 1
  fi

  log_info "ALLOWED_IP non renseignée dans lab.env : IP publique opérateur auto-détectée = $detected"
  ALLOWED_IP="$detected"
  export ALLOWED_IP
}

# redact_secrets <chaîne> — masque les motifs de secret connus (jetons Bearer,
# champs "password" JSON, client_secret=...) avant de logger une commande.
# Ne touche jamais aux arguments réellement exécutés (uniquement la
# représentation affichée) — cf. run_cmd. Constaté en conditions réelles
# (Lot 4, test dynamique B6) : un appel `az rest --headers
# "Authorization=Bearer ${token}" --body '{"password": "..."}'` loguait le
# jeton d'accès réel ET le mot de passe temporaire en clair via `log_info
# "[EXEC] $*"` — même catégorie de fuite déjà corrigée pour WINRM_PASSWORD
# (variable d'environnement), mais qui touche ici toute commande passée
# directement à run_cmd avec un secret en argument littéral.
redact_secrets() {
  sed -E \
    -e 's/(Bearer )[A-Za-z0-9_.-]+/\1[REDACTED]/g' \
    -e 's/("password"[[:space:]]*:[[:space:]]*")[^"]*(")/\1[REDACTED]\2/g' \
    -e 's/(client_secret=)[^&[:space:]]+/\1[REDACTED]/g' \
    <<< "$1"
}

# run_cmd <commande> [args...] — exécuteur central respectant $DRY_RUN. En dry-run,
# logue la commande (arguments déjà interpolés par l'appelant) sans l'exécuter.
# Tout script aval qui écrit dans Azure/WinRM DOIT passer par cette fonction plutôt
# que d'appeler directement az/pypsrp/etc. Le log (dry-run ou exec) passe par
# redact_secrets : seule la représentation affichée est assainie, "$@" reçoit
# toujours les valeurs réelles pour l'exécution.
run_cmd() {
  local logged
  logged="$(redact_secrets "$*")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] $logged"
    return 0
  fi
  log_info "[EXEC] $logged"
  "$@"
}

# resource_exists <args az...> — garde d'idempotence générique : vrai si
# `az "$@"` réussit (ex. resource_exists vm show --name x --resource-group y).
# Ne modifie rien : uniquement des commandes de lecture (show/list).
resource_exists() {
  az "$@" >/dev/null 2>&1
}

# vm_exists <nom_vm> <resource_group>
vm_exists() {
  local vm_name="$1" rg="$2"
  resource_exists vm show --name "$vm_name" --resource-group "$rg"
}

# peering_exists <nom_peering> <nom_vnet> <resource_group>
peering_exists() {
  local peering_name="$1" vnet_name="$2" rg="$3"
  resource_exists network vnet peering show \
    --name "$peering_name" \
    --vnet-name "$vnet_name" \
    --resource-group "$rg"
}

# require_vars <NOM_VAR> [NOM_VAR...] — vérifie que chaque variable nommée est
# définie et non vide dans l'environnement courant (typiquement après
# load_lab_env). Logue une erreur listant tout ce qui manque et retourne 1
# plutôt que de laisser un script continuer avec des variables vides.
require_vars() {
  local var_name
  local missing=()
  for var_name in "$@"; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("$var_name")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "Variable(s) manquante(s) : ${missing[*]} (vérifier config/lab.env)"
    return 1
  fi
}
