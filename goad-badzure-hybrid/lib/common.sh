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
  discover_rg_goad
  discover_rg_badzure
  discover_goad_instance_details
}

# repo_root_dir — chemin du dossier parent de goad-badzure-hybrid/, où vivent
# les dossiers frères GOAD/ et BadZure/, résolu relativement à ce fichier
# (indépendant du cwd de l'appelant).
repo_root_dir() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${lib_dir}/../.." && pwd
}

# find_goad_workspace_dir — chemin du dossier d'instance GOAD déployée
# (GOAD/workspace/<instance-id>/), déterminé par le nom de son dossier
# d'instance, pas connaissable à l'avance : goad.py choisit cet identifiant
# aléatoirement à la création. Vide si aucune instance ou plusieurs (auquel
# cas l'opérateur doit renseigner les variables concernées à la main).
find_goad_workspace_dir() {
  local workspace_dir="${GOAD_DIR:-$(repo_root_dir)/GOAD}/workspace"
  local matches=()
  local d
  for d in "$workspace_dir"/*/; do
    [[ -d "$d" ]] && matches+=("${d%/}")
  done
  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "${matches[0]}"
  fi
}

# discover_rg_goad — remplit $RG_GOAD par auto-détection si absente de
# lab.env : son nom dépend de l'ID d'instance choisi par goad.py à la
# création, pas connaissable avant déploiement.
discover_rg_goad() {
  if [[ -n "${RG_GOAD:-}" ]]; then
    return 0
  fi

  local rg
  rg="$(az group list --query "[?starts_with(name, 'GOAD-Light')].name | [0]" -o tsv 2>/dev/null)"
  if [[ -n "$rg" && "$rg" != "None" ]]; then
    log_info "RG_GOAD non renseignée dans lab.env : auto-détectée = $rg"
    RG_GOAD="$rg"
    export RG_GOAD
  fi
}

# discover_rg_badzure — remplit $RG_BADZURE par auto-détection si absente de
# lab.env, depuis terraform.tfvars.json de BadZure (généré par BadZure.py
# build) : BadZure choisit des noms de resource group aléatoires à chaque
# déploiement.
discover_rg_badzure() {
  if [[ -n "${RG_BADZURE:-}" ]]; then
    return 0
  fi

  local tfvars="${BADZURE_DIR:-$(repo_root_dir)/BadZure}/terraform/terraform.tfvars.json"
  if [[ ! -f "$tfvars" ]]; then
    return 0
  fi

  local rg
  rg="$(python3 -c "
import json
with open('$tfvars') as f:
    data = json.load(f)
rgs = list(data.get('resource_groups', {}).keys())
print(rgs[0] if rgs else '')
" 2>/dev/null)"

  if [[ -n "$rg" ]]; then
    log_info "RG_BADZURE non renseignée dans lab.env : auto-détectée = $rg"
    RG_BADZURE="$rg"
    export RG_BADZURE
  fi
}

# discover_goad_instance_details — remplit JUMPBOX_SSH_KEY_PATH,
# DC01_PRIVATE_IP et DC01_ADMIN_PASSWORD par auto-détection si absentes de
# lab.env : elles dépendent toutes du dossier d'instance GOAD (nom
# aléatoire) et, pour les deux dernières, de `terraform output`.
discover_goad_instance_details() {
  local instance_dir
  instance_dir="$(find_goad_workspace_dir)"
  if [[ -z "$instance_dir" ]]; then
    return 0
  fi

  if [[ -z "${JUMPBOX_SSH_KEY_PATH:-}" && -f "${instance_dir}/ssh_keys/ubuntu-jumpbox.pem" ]]; then
    JUMPBOX_SSH_KEY_PATH="${instance_dir}/ssh_keys/ubuntu-jumpbox.pem"
    export JUMPBOX_SSH_KEY_PATH
    log_info "JUMPBOX_SSH_KEY_PATH non renseignée dans lab.env : auto-détectée = $JUMPBOX_SSH_KEY_PATH"
  fi

  if [[ -n "${DC01_PRIVATE_IP:-}" && -n "${DC01_ADMIN_PASSWORD:-}" ]]; then
    return 0
  fi

  local vm_config
  vm_config="$(cd "${instance_dir}/provider" 2>/dev/null && terraform output -json vm-config 2>/dev/null)"
  if [[ -z "$vm_config" ]]; then
    return 0
  fi

  if [[ -z "${DC01_PRIVATE_IP:-}" ]]; then
    DC01_PRIVATE_IP="$(python3 -c "
import json, sys
print(json.loads(sys.argv[1]).get('dc01', {}).get('private_ip_address', ''))
" "$vm_config" 2>/dev/null)"
    if [[ -n "$DC01_PRIVATE_IP" ]]; then
      export DC01_PRIVATE_IP
      log_info "DC01_PRIVATE_IP non renseignée dans lab.env : auto-détectée = $DC01_PRIVATE_IP"
    fi
  fi

  if [[ -z "${DC01_ADMIN_PASSWORD:-}" ]]; then
    DC01_ADMIN_PASSWORD="$(python3 -c "
import json, sys
print(json.loads(sys.argv[1]).get('dc01', {}).get('password', ''))
" "$vm_config" 2>/dev/null)"
    if [[ -n "$DC01_ADMIN_PASSWORD" ]]; then
      export DC01_ADMIN_PASSWORD
      log_info "DC01_ADMIN_PASSWORD non renseignée dans lab.env : auto-détectée depuis terraform output."
    fi
  fi
}

# verify_subscription_context — si $SUBSCRIPTION_ID est renseignée dans
# lab.env, vérifie que la session az CLI active pointe bien vers cet
# abonnement avant de laisser un script continuer. Laissée vide, la
# vérification est ignorée.
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

# detect_public_ip — IP publique sortante de la machine opérateur, via le
# même endpoint que BadZure/src/utils.py get_public_ip(). Fallback utilisé
# par resolve_allowed_ip quand $ALLOWED_IP n'est pas renseignée.
detect_public_ip() {
  curl -sf -4 --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]'
}

# resolve_allowed_ip — remplit $ALLOWED_IP par auto-détection si absente de
# lab.env. L'IP sortante de la machine opérateur change dans le temps ; une
# valeur figée finit par bloquer SSH silencieusement (règle NSG pointant
# vers une IP obsolète, timeout sans message d'erreur explicite). Une valeur
# explicite dans lab.env reste prioritaire (utile pour épingler une IP
# stable, ex. agent CI).
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
# Ne touche jamais aux arguments réellement exécutés, seulement à la
# représentation affichée par run_cmd : sans ça, un secret passé en
# argument littéral (ex. `az rest --headers "Authorization=Bearer $token"`)
# apparaît en clair dans les logs.
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
