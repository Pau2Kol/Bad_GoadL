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

# load_lab_env [chemin] — source config/lab.env (par défaut : lab.env, résolu
# relativement à ce fichier). Suivi directement dans le dépôt (vide, tout est
# auto-détecté) : sa présence après un clone est donc garantie. Échoue
# proprement si absent (supprimé à la main), plutôt que de laisser les
# scripts tourner avec des variables vides.
load_lab_env() {
  local env_file="${1:-}"
  if [[ -z "$env_file" ]]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="${lib_dir}/../config/lab.env"
  fi

  if [[ ! -f "$env_file" ]]; then
    log_error "Fichier d'environnement introuvable : $env_file (restaurer avec git checkout config/lab.env — rien à y renseigner, tout est auto-détecté)"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$env_file"

  discover_account_context
  verify_subscription_context || return 1
  default_lab_settings
  resolve_allowed_ip
  discover_rg_goad
  discover_rg_badzure
  discover_goad_instance_details
}

# discover_account_context — remplit SUBSCRIPTION_ID, TENANT_ID et
# TENANT_DOMAIN par auto-détection si absentes de lab.env, depuis la
# session az CLI active. Une valeur explicite dans lab.env reste
# prioritaire.
discover_account_context() {
  if [[ -z "${SUBSCRIPTION_ID:-}" ]]; then
    local sub_id
    sub_id="$(az account show --query id -o tsv 2>/dev/null)"
    if [[ -n "$sub_id" ]]; then
      log_info "SUBSCRIPTION_ID non renseignée dans lab.env : auto-détectée = $sub_id"
      SUBSCRIPTION_ID="$sub_id"
      export SUBSCRIPTION_ID
    fi
  fi

  if [[ -z "${TENANT_ID:-}" ]]; then
    local tid
    tid="$(az account show --query tenantId -o tsv 2>/dev/null)"
    if [[ -n "$tid" ]]; then
      log_info "TENANT_ID non renseignée dans lab.env : auto-détectée = $tid"
      TENANT_ID="$tid"
      export TENANT_ID
    fi
  fi

  if [[ -z "${TENANT_DOMAIN:-}" ]]; then
    local domain
    domain="$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization" --query "value[0].verifiedDomains[?isDefault]|[0].name" -o tsv 2>/dev/null)"
    if [[ -n "$domain" ]]; then
      log_info "TENANT_DOMAIN non renseignée dans lab.env : auto-détectée = $domain"
      TENANT_DOMAIN="$domain"
      export TENANT_DOMAIN
    fi
  fi
}

# default_lab_settings — remplit JUMPBOX_SSH_USER et les régions par des
# valeurs par défaut sensées si absentes de lab.env : ce sont des choix de
# configuration, pas des secrets, aucune raison d'exiger une saisie
# manuelle. Une valeur explicite dans lab.env reste prioritaire.
default_lab_settings() {
  if [[ -z "${JUMPBOX_SSH_USER:-}" ]]; then
    JUMPBOX_SSH_USER="goad"
    export JUMPBOX_SSH_USER
  fi

  if [[ -z "${DC01_ADMIN_USER:-}" ]]; then
    DC01_ADMIN_USER="goadmin"
    export DC01_ADMIN_USER
  fi

  if [[ -z "${REGION_GOAD:-}" ]]; then
    log_info "REGION_GOAD non renseignée dans lab.env : valeur par défaut = denmarkeast"
    REGION_GOAD="denmarkeast"
    export REGION_GOAD
  fi

  if [[ -z "${REGION_JUMPBOX:-}" ]]; then
    log_info "REGION_JUMPBOX non renseignée dans lab.env : valeur par défaut = indiasouthcentral"
    REGION_JUMPBOX="indiasouthcentral"
    export REGION_JUMPBOX
  fi

  if [[ -z "${REGION_BADZURE:-}" ]]; then
    log_info "REGION_BADZURE non renseignée dans lab.env : valeur par défaut = westus"
    REGION_BADZURE="westus"
    export REGION_BADZURE
  fi
}

# repo_root_dir — chemin du dossier parent de goad-badzure-hybrid/, où vivent
# les dossiers frères GOAD/ et BadZure/, résolu relativement à ce fichier
# (indépendant du cwd de l'appelant).
repo_root_dir() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${lib_dir}/../.." && pwd
}

# credentials_file — chemin du fichier local (jamais commité, cf.
# .gitignore : *credential*) qui centralise les identifiants du lab.
credentials_file() {
  echo "$(repo_root_dir)/goad-badzure-hybrid/config/credentials.local.txt"
}

# persist_lab_env_var <clé> <valeur> — écrit/remplace une variable dans
# config/lab.env. Réservé aux valeurs qui ne sont PAS re-détectables après
# coup (GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET) : à la différence de RG_GOAD,
# DC01_ADMIN_PASSWORD, etc., qui se re-découvrent à chaque run sans jamais
# rien écrire dans ce fichier, un secret généré une seule fois doit y être
# persisté pour ne pas être régénéré inutilement (et sans délai de
# propagation Azure AD à répéter) au prochain run.
persist_lab_env_var() {
  local key="$1" value="$2"
  local env_file
  env_file="$(repo_root_dir)/goad-badzure-hybrid/config/lab.env"

  python3 - "$env_file" "$key" "$value" <<'PYEOF'
import re, sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()

pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
replacement = f"{key}={value}"

if pattern.search(content):
    content = pattern.sub(replacement, content, count=1)
else:
    content = content.rstrip("\n") + f"\n{replacement}\n"

with open(path, "w") as f:
    f.write(content)
PYEOF
}

# record_credential <label> <valeur> — ajoute une ligne horodatée au fichier
# local de creds. Réservé au mot de passe temporaire sync-admin : une fois
# affiché en log, il n'est plus jamais récupérable auprès d'Entra ID,
# contrairement aux valeurs auto-détectables à la demande (DC01_ADMIN_PASSWORD,
# etc.), donc écrit ici au moment exact de sa génération plutôt que
# reconstruit après coup.
record_credential() {
  local label="$1" value="$2"
  local file
  file="$(credentials_file)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${label} = ${value}" >> "$file"
}

# show_credentials — liste unique des identifiants nécessaires pour se
# connecter au lab (pas les credentials d'automatisation interne comme
# GRAPH_CLIENT_ID/SECRET, cf. config/lab.env pour ceux-là). Suppose
# load_lab_env déjà appelée (variables déjà peuplées par auto-détection).
show_credentials() {
  local jumpbox_ip
  jumpbox_ip="$(az vm list-ip-addresses \
    --name "${JUMPBOX_VM_NAME:-ubuntu-jumpbox}" \
    --resource-group "${RG_GOAD:-}" \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
    -o tsv 2>/dev/null)"

  echo "=== Identifiants du lab ==="
  echo "TENANT_DOMAIN        = ${TENANT_DOMAIN:-<inconnu>}"

  local file
  file="$(credentials_file)"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo "sync-admin : mot de passe temporaire pas encore généré (lancer ./scripts/00-deploy.sh link)."
  fi

  echo "DC01_ADMIN_USER      = ${DC01_ADMIN_USER:-<inconnu>}"
  echo "DC01_ADMIN_PASSWORD  = ${DC01_ADMIN_PASSWORD:-<inconnu>}"
  echo "JUMPBOX_SSH_USER     = ${JUMPBOX_SSH_USER:-<inconnu>}"
  echo "JUMPBOX_SSH_KEY_PATH = ${JUMPBOX_SSH_KEY_PATH:-<inconnu>}"
  echo "JUMPBOX_PUBLIC_IP    = ${jumpbox_ip:-<inconnu>}"

  echo
  echo "=== Connexion ==="
  echo "Jumpbox (SSH, seul point d'entrée public) :"
  echo "  ssh -i \"${JUMPBOX_SSH_KEY_PATH:-<JUMPBOX_SSH_KEY_PATH>}\" ${JUMPBOX_SSH_USER:-<JUMPBOX_SSH_USER>}@${jumpbox_ip:-<JUMPBOX_PUBLIC_IP>}"
  echo
  echo "dc01 (RDP, pas d'IP publique — tunnel via la jumpbox) :"
  echo "  ssh -i \"${JUMPBOX_SSH_KEY_PATH:-<JUMPBOX_SSH_KEY_PATH>}\" -L 3389:${DC01_PRIVATE_IP:-<DC01_PRIVATE_IP>}:3389 ${JUMPBOX_SSH_USER:-<JUMPBOX_SSH_USER>}@${jumpbox_ip:-<JUMPBOX_PUBLIC_IP>}"
  echo "  puis client RDP vers localhost:3389, identifiants DC01_ADMIN_USER/DC01_ADMIN_PASSWORD ci-dessus."
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
# lab.env. Deux méthodes, dans l'ordre :
# 1. terraform.tfvars.json de BadZure (généré par BadZure.py build) : précis,
#    mais seulement présent si BadZure a été construit depuis ce clone.
# 2. Repli Azure direct, utile si BadZure a été déployé depuis un autre
#    clone/session (tfvars.json absent ici, mais les ressources existent
#    réellement) : parmi les resource groups réels du compte, cherche celui
#    dont le nom figure dans la liste de noms utilisée par BadZure
#    (entity_data/resource-groups.txt) ET qui contient un VNet "<rg>-vnet"
#    (BadZure/terraform/main.tf, azurerm_virtual_network.vm_vnets) — BadZure
#    crée plusieurs resource groups par déploiement, un seul héberge le VNet
#    nécessaire au peering.
discover_rg_badzure() {
  if [[ -n "${RG_BADZURE:-}" ]]; then
    return 0
  fi

  local badzure_dir="${BADZURE_DIR:-$(repo_root_dir)/BadZure}"
  local tfvars="${badzure_dir}/terraform/terraform.tfvars.json"

  if [[ -f "$tfvars" ]]; then
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
      return 0
    fi
  fi

  local names_file="${badzure_dir}/entity_data/resource-groups.txt"
  if [[ ! -f "$names_file" ]]; then
    return 0
  fi

  local real_rgs
  real_rgs="$(az group list --query "[].name" -o tsv 2>/dev/null)"

  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if grep -qxF "$candidate" <<< "$real_rgs" \
      && resource_exists network vnet show --name "${candidate}-vnet" --resource-group "$candidate"; then
      log_info "RG_BADZURE non renseignée dans lab.env (terraform.tfvars.json absent) : auto-détectée via Azure = $candidate"
      RG_BADZURE="$candidate"
      export RG_BADZURE
      return 0
    fi
  done < "$names_file"
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

# retry_cmd <tentatives> <délai_secondes> <commande...> — répète une
# commande (via run_cmd, donc --dry-run compatible) jusqu'à succès ou
# épuisement des tentatives. Sert contre la latence de propagation Azure AD :
# une app registration/service principal/secret tout juste créé peut faire
# échouer les tout premiers appels qui l'utilisent (admin-consent, émission
# de jeton), alors que la même commande relancée quelques secondes plus tard
# réussit sans rien changer d'autre.
retry_cmd() {
  local attempts="$1" delay="$2"
  shift 2

  if [[ "$DRY_RUN" == "true" ]]; then
    run_cmd "$@"
    return 0
  fi

  local i
  for ((i = 1; i <= attempts; i++)); do
    if run_cmd "$@"; then
      return 0
    fi
    if [[ "$i" -lt "$attempts" ]]; then
      log_warn "Échec (tentative $i/$attempts), nouvelle tentative dans ${delay}s (latence de propagation Azure AD probable)."
      sleep "$delay"
    fi
  done
  return 1
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
