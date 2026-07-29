#!/usr/bin/env bash
# reset-goad.sh — supprime entièrement le déploiement GOAD-Light en cours
# (resource group Azure + dossier d'instance local), pour repartir d'un run
# propre après un échec (conflit de quota non récupéré automatiquement,
# state Terraform désynchronisé, etc.).
#
# Passe par la suppression directe du resource group plutôt que par
# `terraform destroy` : couvre aussi les ressources créées par
# scripts/10-migrate-jumpbox.sh (hors du contrôle de Terraform, migration
# faite via des commandes az directes), sans dépendre de la cohérence du
# state Terraform. Ne touche ni BadZure ni les objets Entra ID.
#
# Sourçable : `source scripts/reset-goad.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# reset_goad.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# reset_goad — supprime le resource group GOAD (s'il existe) et le dossier
# d'instance local correspondant sous GOAD/workspace/.
reset_goad() {
  if [[ -z "${RG_GOAD:-}" ]]; then
    log_info "Aucun resource group GOAD-Light connu (RG_GOAD vide) : rien à supprimer côté Azure."
  elif resource_exists group show --name "$RG_GOAD"; then
    log_info "Suppression du resource group $RG_GOAD (VMs, réseau, et toute ressource migrée par 10-migrate-jumpbox.sh)."
    run_cmd az group delete --name "$RG_GOAD" --yes --no-wait
  else
    log_info "Resource group $RG_GOAD déjà absent."
  fi

  local instance_dir
  instance_dir="$(find_goad_workspace_dir)"
  if [[ -n "$instance_dir" ]]; then
    log_info "Suppression du dossier d'instance local $instance_dir."
    run_cmd rm -rf "$instance_dir"
  else
    log_info "Aucun dossier d'instance GOAD local trouvé (absent, ou plusieurs instances : ambigu, à traiter à la main)."
  fi

  log_info "Reset GOAD terminé. ./scripts/00-deploy.sh goad repartira de zéro."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  reset_goad
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
