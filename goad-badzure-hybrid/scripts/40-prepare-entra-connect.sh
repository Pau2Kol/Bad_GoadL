#!/usr/bin/env bash
# 40-prepare-entra-connect.sh — préparation Entra Connect.
# - Vérifie/crée le compte de synchronisation cloud-only
#   sync-admin@$TENANT_DOMAIN (userType Member, jamais un compte MSA : cause
#   racine documentée du fix ABA, cf. docs/manual-steps.md).
# - Vérifie/attribue le rôle Hybrid Identity Administrator à ce compte.
# - Nettoie les apps ConnectSyncProvisioning_* en doublon (conflit de
#   certificat documenté par Microsoft).
#
# Contrainte d'authentification : une politique de Conditional Access du
# tenant (erreur 530035) bloque tout login interactif/device-code depuis une
# machine non enregistrée. Toute ÉCRITURE Graph de ce script passe donc par
# un jeton d'application app-only (client credentials, GRAPH_CLIENT_ID +
# GRAPH_CLIENT_SECRET), jamais par la session az cli interactive courante.
# Les LECTURES, elles, utilisent la session az courante (fonctionne sans
# jeton app-only).
#
# Le SP app-only requis pour l'automatisation Graph n'est PLUS un prérequis
# manuel : si GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET sont absents de
# config/lab.env, ce script bootstrappe lui-même l'app registration, le
# service principal, les permissions Graph applicatives (consentement admin
# inclus) et un nouveau secret, via ensure_graph_automation_bootstrap
# (appelée en tête de prepare_entra_connect). Action à fort impact (permissions
# tenant-wide) : voir docs/manual-steps.md pour le détail exact de ce que ça
# crée et régénère.
#
# Sourçable : `source scripts/40-prepare-entra-connect.sh` ne fait que
# définir les fonctions ci-dessous ; rien n'est exécuté avant l'appel
# explicite de prepare_entra_connect (ou d'une fonction individuelle).
#
# Non testable sur fixtures (nécessite le vrai tenant et la Conditional
# Access réelle, cf. test/README.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# Constante universelle Microsoft (identique dans tous les tenants Entra ID),
# pas un secret : roleTemplateId du rôle Hybrid Identity Administrator.
if [[ -z "${HYBRID_IDENTITY_ADMIN_ROLE_TEMPLATE_ID:-}" ]]; then
  readonly HYBRID_IDENTITY_ADMIN_ROLE_TEMPLATE_ID="8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2"
  readonly HYBRID_IDENTITY_ADMIN_ROLE_NAME="Hybrid Identity Administrator"
fi

# ---------------------------------------------------------------------------
# Lecture (session az cli courante — fonctionne sans SP app-only, vérifié)
# ---------------------------------------------------------------------------

# get_sync_admin_state <tenant_domain> — renvoie "id<TAB>userType<TAB>accountEnabled"
# ou "None" si absent.
get_sync_admin_state() {
  local domain="$1"
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/users?\$filter=userPrincipalName eq 'sync-admin@${domain}'&\$select=id,userType,accountEnabled" \
    --query "[value[0].[id,userType,accountEnabled]]" -o tsv
}

# user_has_role <user_id> <role_display_name> — compte (0 ou 1) de correspondances.
user_has_role() {
  local user_id="$1" role_display_name="$2"
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/users/${user_id}/memberOf?\$select=displayName" \
    --query "length(value[?displayName=='${role_display_name}'])" -o tsv
}

# list_connectsync_provisioning_apps — une ligne par app, TSV :
# id<TAB>appId<TAB>displayName<TAB>createdDateTime.
list_connectsync_provisioning_apps() {
  az ad app list --filter "startswith(displayName,'ConnectSyncProvisioning')" \
    --query "[].[id,appId,displayName,createdDateTime]" -o tsv
}

# ---------------------------------------------------------------------------
# Écriture (SP app-only exclusivement — jamais la session interactive)
# ---------------------------------------------------------------------------

# graph_app_credentials_available — vrai si GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET
# sont renseignés dans l'environnement (config/lab.env).
graph_app_credentials_available() {
  [[ -n "${GRAPH_CLIENT_ID:-}" && -n "${GRAPH_CLIENT_SECRET:-}" ]]
}

# ---------------------------------------------------------------------------
# Bootstrap du SP app-only : utilise la session az cli interactive (pas de
# jeton app-only possible ici, chicken-and-egg, c'est justement le SP qu'on
# crée). `az ad app create`/`az ad sp create`/`az ad app permission
# add`/`admin-consent` fonctionnent via la session interactive sans erreur
# 530035, contrairement à la création d'utilisateur et l'attribution de
# rôle, qui exigent le jeton app-only. Seul ce bootstrap utilise donc la
# session interactive pour une écriture ; le reste de ce fichier
# (ensure_sync_admin, cleanup_duplicate_connectsync_apps) exige un jeton
# app-only.
# ---------------------------------------------------------------------------

# Constantes Microsoft Graph, identiques dans tous les tenants, pas des
# secrets.
if [[ -z "${GRAPH_RESOURCE_APP_ID:-}" ]]; then
  readonly GRAPH_RESOURCE_APP_ID="00000003-0000-0000-c000-000000000000"
  readonly GRAPH_ROLE_USER_READWRITE_ALL="741f803b-c850-494e-b5df-cde7c675a1ca"
  readonly GRAPH_ROLE_ROLEMANAGEMENT_READWRITE_DIRECTORY="9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8"
fi

# ensure_graph_automation_app <display_name> — idempotent, renvoie l'App ID
# (client id) sur stdout.
ensure_graph_automation_app() {
  local display_name="$1"
  local app_id
  app_id="$(az ad app list --filter "displayName eq '${display_name}'" --query "[0].appId" -o tsv)"

  if [[ -n "$app_id" && "$app_id" != "None" ]]; then
    log_info "App registration '$display_name' déjà présente (appId=$app_id)."
    echo "$app_id"
    return 0
  fi

  log_info "App registration '$display_name' introuvable, création."
  run_cmd az ad app create --display-name "$display_name" --query appId -o tsv
}

# ensure_graph_automation_sp <app_id> — idempotent, renvoie l'id (object id)
# du service principal sur stdout.
ensure_graph_automation_sp() {
  local app_id="$1"
  local sp_id
  sp_id="$(az ad sp list --filter "appId eq '${app_id}'" --query "[0].id" -o tsv)"

  if [[ -n "$sp_id" && "$sp_id" != "None" ]]; then
    log_info "Service principal pour appId=$app_id déjà présent (id=$sp_id)."
    echo "$sp_id"
    return 0
  fi

  log_info "Service principal pour appId=$app_id introuvable, création."
  run_cmd az ad sp create --id "$app_id" --query id -o tsv
}

# ensure_graph_automation_permissions <app_id> <sp_id> — idempotent : ajoute
# uniquement les rôles applicatifs Graph manquants (détectés via
# appRoleAssignments, qui ne reflète que ce qui est déjà consenti), puis
# relance admin-consent seulement si quelque chose a été ajouté.
ensure_graph_automation_permissions() {
  local app_id="$1" sp_id="$2"
  local assigned_roles
  assigned_roles="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignments" --query "value[].appRoleId" -o tsv 2>/dev/null)"

  local missing=0
  local role_id
  for role_id in "$GRAPH_ROLE_USER_READWRITE_ALL" "$GRAPH_ROLE_ROLEMANAGEMENT_READWRITE_DIRECTORY"; do
    if grep -qx "$role_id" <<< "$assigned_roles"; then
      log_info "Rôle Graph $role_id déjà accordé et consenti."
    else
      log_info "Rôle Graph $role_id manquant : ajout au manifeste de l'app."
      run_cmd az ad app permission add --id "$app_id" --api "$GRAPH_RESOURCE_APP_ID" --api-permissions "${role_id}=Role" >/dev/null
      missing=1
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    run_cmd az ad app permission admin-consent --id "$app_id"
  fi
}

# ensure_graph_automation_bootstrap — orchestration complète, idempotente.
# N'est appelée que si GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET ne sont PAS déjà
# renseignés (l'opérateur a déjà bootstrappé une fois : rien à refaire).
# Affiche le nouveau secret UNE SEULE FOIS s'il vient d'être généré (pas
# re-affichable ensuite) — à noter immédiatement dans config/lab.env.
ensure_graph_automation_bootstrap() {
  if graph_app_credentials_available; then
    log_info "GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET déjà renseignés, bootstrap du SP ignoré."
    return 0
  fi

  local display_name="${GRAPH_AUTOMATION_APP_NAME:-goad-badzure-hybrid-automation}"
  log_warn "GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET absents : bootstrap du SP app-only '$display_name'."

  local app_id sp_id secret
  app_id="$(ensure_graph_automation_app "$display_name")"
  sp_id="$(ensure_graph_automation_sp "$app_id")"
  ensure_graph_automation_permissions "$app_id" "$sp_id"

  secret="$(run_cmd az ad app credential reset --id "$app_id" --append --years 1 --query password -o tsv)"

  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "SP app-only prêt : GRAPH_CLIENT_ID=$app_id"
    log_warn "Nouveau secret client généré (à NOTER MAINTENANT dans config/lab.env, non re-affiché) : $secret"
  fi

  GRAPH_CLIENT_ID="$app_id"
  GRAPH_CLIENT_SECRET="$secret"
}

# get_graph_app_token <tenant_id> <client_id> <client_secret> — client
# credentials grant, indépendant de toute session az cli interactive.
# DRY-RUN : ne fait JAMAIS le curl réel vers login.microsoftonline.com (pas
# d'authentification live avec le vrai secret client) — renvoie un jeton
# factice, uniquement consommé par du code lui-même dry-run-aware en aval.
get_graph_app_token() {
  local tid="$1" app_client_id="$2" app_client_secret="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Récupération du jeton app-only (client_credentials) simulée — aucun appel réel à login.microsoftonline.com."
    echo "DRY-RUN-FAKE-TOKEN"
    return 0
  fi
  curl -sf -X POST "https://login.microsoftonline.com/${tid}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${app_client_id}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    --data-urlencode "client_secret=${app_client_secret}" \
    --data-urlencode "grant_type=client_credentials" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"
}

# generate_temp_password — mot de passe temporaire aléatoire pour la création
# du compte sync-admin (forceChangePasswordNextSignIn=true : à changer au
# premier login manuel, cf. docs/manual-steps.md).
generate_temp_password() {
  python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!@#%^*-_='
print(''.join(secrets.choice(alphabet) for _ in range(24)))
"
}

# get_or_activate_hybrid_identity_admin_role <auth_header> — renvoie l'id
# (tenant-spécifique) du directoryRole, l'active depuis le roleTemplate s'il
# ne l'est pas encore (cas d'un tenant où ce rôle n'a jamais été utilisé).
get_or_activate_hybrid_identity_admin_role() {
  local auth_header="$1"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Lecture/activation du directoryRole ${HYBRID_IDENTITY_ADMIN_ROLE_NAME} simulée — aucun appel Graph réel (le jeton app-only n'est de toute façon pas authentique en dry-run)."
    echo "DRY-RUN-ROLE-ID"
    return 0
  fi

  local role_id
  role_id="$(az rest --method GET \
    --headers "Authorization=${auth_header}" \
    --url "https://graph.microsoft.com/v1.0/directoryRoles?\$filter=roleTemplateId eq '${HYBRID_IDENTITY_ADMIN_ROLE_TEMPLATE_ID}'" \
    --query "value[0].id" -o tsv)"

  if [[ -n "$role_id" && "$role_id" != "None" ]]; then
    echo "$role_id"
    return 0
  fi

  run_cmd az rest --method POST \
    --headers "Authorization=${auth_header}" "Content-Type=application/json" \
    --url "https://graph.microsoft.com/v1.0/directoryRoles" \
    --body "{\"roleTemplateId\": \"${HYBRID_IDENTITY_ADMIN_ROLE_TEMPLATE_ID}\"}" \
    --query "id" -o tsv
}

# assign_role_to_user <auth_header> <role_id> <user_id>
assign_role_to_user() {
  local auth_header="$1" role_id="$2" user_id="$3"
  run_cmd az rest --method POST \
    --headers "Authorization=${auth_header}" "Content-Type=application/json" \
    --url "https://graph.microsoft.com/v1.0/directoryRoles/${role_id}/members/\$ref" \
    --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/directoryObjects/${user_id}\"}"
}

# create_sync_admin <auth_header> <tenant_domain> — crée le compte cloud-only
# et affiche le mot de passe temporaire UNE SEULE FOIS (étape manuelle
# ensuite : connexion portail pour le changer, cf. docs/manual-steps.md).
create_sync_admin() {
  local auth_header="$1" domain="$2"
  local temp_password
  temp_password="$(generate_temp_password)"

  local body
  body="$(python3 -c "
import json
print(json.dumps({
    'accountEnabled': True,
    'displayName': 'sync-admin',
    'mailNickname': 'sync-admin',
    'userPrincipalName': 'sync-admin@${domain}',
    'passwordProfile': {
        'forceChangePasswordNextSignIn': True,
        'password': '${temp_password}',
    },
}))
")"

  local new_user_id
  new_user_id="$(run_cmd az rest --method POST \
    --headers "Authorization=${auth_header}" "Content-Type=application/json" \
    --url "https://graph.microsoft.com/v1.0/users" \
    --body "$body" \
    --query id -o tsv)"

  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Compte sync-admin@${domain} créé (id: ${new_user_id})."
    log_warn "Mot de passe temporaire (à NOTER MAINTENANT, non re-affiché) : ${temp_password}"
    log_warn "Étape manuelle requise ensuite : connexion portail avec ce compte pour définir le mot de passe définitif — cf. docs/manual-steps.md."
  fi

  echo "$new_user_id"
}

# delete_app <auth_header> <object_id> — supprime une app par son object id.
# Ne cible QUE les apps listées par list_connectsync_provisioning_apps
# (filtrées par displayName ci-dessus) : ne touche jamais à un certificat ou
# une app en dehors de ce périmètre. En particulier, ne JAMAIS supprimer le
# certificat DC CN=kingslanding.sevenkingdoms.local s'il apparaissait dans un
# listing de certificats plus large (LDAPS/auth du DC — hors périmètre de
# cette fonction, qui n'agit que sur des objets application ConnectSyncProvisioning_*).
delete_app() {
  local auth_header="$1" object_id="$2"
  run_cmd az rest --method DELETE \
    --headers "Authorization=${auth_header}" \
    --url "https://graph.microsoft.com/v1.0/applications/${object_id}"
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# ensure_sync_admin — idempotent : ne crée/n'attribue le rôle que si
# nécessaire. Ne corrige pas un compte existant mal configuré (userType
# Guest, désactivé...), signale seulement.
ensure_sync_admin() {
  require_vars TENANT_ID TENANT_DOMAIN || return 1

  local state
  state="$(get_sync_admin_state "$TENANT_DOMAIN")"

  if [[ -n "$state" && "$state" != "None" ]]; then
    local user_id user_type enabled
    read -r user_id user_type enabled <<< "$state"

    if [[ "$user_type" == "Member" && "${enabled,,}" == "true" ]]; then
      log_info "sync-admin@${TENANT_DOMAIN} existe déjà (Member, activé)."
    else
      log_warn "sync-admin@${TENANT_DOMAIN} existe mais dans un état inattendu (userType=$user_type, accountEnabled=$enabled) — à examiner manuellement, ce script ne corrige pas un compte déjà mal configuré."
    fi

    local role_count
    role_count="$(user_has_role "$user_id" "$HYBRID_IDENTITY_ADMIN_ROLE_NAME")"
    if [[ "$role_count" -gt 0 ]]; then
      log_info "sync-admin a déjà le rôle ${HYBRID_IDENTITY_ADMIN_ROLE_NAME}."
      return 0
    fi

    log_warn "sync-admin existe mais n'a PAS le rôle ${HYBRID_IDENTITY_ADMIN_ROLE_NAME}. Attribution nécessaire."
    if ! graph_app_credentials_available; then
      log_error "GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET manquants (config/lab.env) : impossible d'attribuer le rôle via SP app-only. Cf. docs/manual-steps.md."
      return 1
    fi
    local auth_header role_id
    auth_header="Bearer $(get_graph_app_token "$TENANT_ID" "$GRAPH_CLIENT_ID" "$GRAPH_CLIENT_SECRET")"
    role_id="$(get_or_activate_hybrid_identity_admin_role "$auth_header")"
    assign_role_to_user "$auth_header" "$role_id" "$user_id"
    return 0
  fi

  log_info "sync-admin@${TENANT_DOMAIN} introuvable, création nécessaire."

  if ! graph_app_credentials_available; then
    log_error "GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET non renseignés (config/lab.env) : impossible de créer sync-admin via un SP app-only, comme l'exige la politique Conditional Access du tenant (erreur 530035 sur toute auth interactive). Cf. docs/manual-steps.md."
    return 1
  fi

  local auth_header new_user_id role_id
  auth_header="Bearer $(get_graph_app_token "$TENANT_ID" "$GRAPH_CLIENT_ID" "$GRAPH_CLIENT_SECRET")"
  new_user_id="$(create_sync_admin "$auth_header" "$TENANT_DOMAIN")"
  role_id="$(get_or_activate_hybrid_identity_admin_role "$auth_header")"
  assign_role_to_user "$auth_header" "$role_id" "$new_user_id"
}

# cleanup_duplicate_connectsync_apps — supprime toutes les apps
# ConnectSyncProvisioning_* sauf la plus récente (createdDateTime). Un seul
# déploiement doit laisser une seule app (conflit de certificat documenté par
# Microsoft en cas de doublon).
cleanup_duplicate_connectsync_apps() {
  local apps
  apps="$(list_connectsync_provisioning_apps)"

  if [[ -z "$apps" ]]; then
    log_info "Aucune app ConnectSyncProvisioning_* trouvée."
    return 0
  fi

  local count
  count="$(wc -l <<< "$apps")"

  if [[ "$count" -le 1 ]]; then
    log_info "Une seule app ConnectSyncProvisioning_* présente, aucun doublon à nettoyer."
    return 0
  fi

  log_warn "$count apps ConnectSyncProvisioning_* trouvées (doublon détecté)."

  if ! graph_app_credentials_available; then
    log_error "GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET manquants : impossible de nettoyer les doublons via SP app-only. Cf. docs/manual-steps.md."
    return 1
  fi

  local auth_header
  auth_header="Bearer $(get_graph_app_token "$TENANT_ID" "$GRAPH_CLIENT_ID" "$GRAPH_CLIENT_SECRET")"

  local newest_id
  newest_id="$(sort -t $'\t' -k4 -r <<< "$apps" | head -1 | cut -f1)"

  local obj_id app_id display_name created
  while IFS=$'\t' read -r obj_id app_id display_name created; do
    if [[ "$obj_id" == "$newest_id" ]]; then
      log_info "Conservée (la plus récente) : $display_name ($created, appId=$app_id)."
      continue
    fi
    log_info "Suppression de l'app en doublon : $display_name ($created, appId=$app_id)."
    delete_app "$auth_header" "$obj_id"
  done <<< "$apps"
}

# prepare_entra_connect — orchestration complète.
prepare_entra_connect() {
  require_vars TENANT_ID TENANT_DOMAIN || return 1

  ensure_graph_automation_bootstrap

  ensure_sync_admin
  cleanup_duplicate_connectsync_apps

  log_info "Préparation Entra Connect terminée. Suite : installation + wizard ABA (étape manuelle, cf. docs/manual-steps.md)."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  prepare_entra_connect
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
